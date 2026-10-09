#!/usr/bin/env bash
# 只读探针：生产 DSN 实际是否走 TLS + verify-ca/verify-full 可否用
# 临时 psql 客户端 Pod（envFrom new-api-secrets），只执行 SELECT 1 / pg_stat_ssl，不写任何数据。
# 输出所有口令出现前先经 sed 脱敏（postgres://u:p@ → postgres://u:<REDACTED>@）。
set -u
NS=new-api
CLI=t17-sslprobe
kubectl -n $NS delete pod $CLI --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t17-sslprobe
  namespace: new-api
  labels: { app: t17-sslprobe, project: new-api }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  terminationGracePeriodSeconds: 0
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 240"]
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
EOF
if ! kubectl -n $NS wait --for=condition=Ready pod/$CLI --timeout=180s >/dev/null 2>&1; then
  echo "  [XX] 探针 Pod 未就绪（拉镜像失败？）"; kubectl -n $NS delete pod $CLI --ignore-not-found >/dev/null 2>&1; exit 1
fi

# 在 Pod 内执行：$1=变量名 $2=sslmode（空=用生产 DSN 原样）
run() {
  kubectl -n $NS exec -i $CLI -- sh -c '
    V=$1; M=$2
    D=$(printenv "$V")
    [ -n "$D" ] || { echo "(键不存在)"; exit 0; }
    if [ -n "$M" ]; then
      D=$(printf %s "$D" | sed -E "s/[?\&]sslmode=[a-z\-]+//g")
      D="$D?sslmode=$M"
    fi
    psql "$D" -Atq -c "select '\''ssl='\''||ssl from pg_stat_ssl where pid = pg_backend_pid()" 2>&1 \
      | sed -E "s#(postgres(ql)?://[^:/@]*:)[^@]*@#\1<REDACTED>@#g" | tr "\n" " " | cut -c1-200
  ' _ "$1" "$2" 2>&1
}

echo "=== A) 生产 DSN 原样连接 → 实际是否加密（pg_stat_ssl.ssl）==="
echo "  SQL_DSN         : $(run SQL_DSN '')"
echo "  SQL_DSN_MIGRATE : $(run SQL_DSN_MIGRATE '')"

echo "=== B) 逐档试 sslmode（服务端/证书支持到哪一档）==="
for m in require verify-ca verify-full; do
  echo "  SQL_DSN + $m         : $(run SQL_DSN "$m")"
done
for m in verify-ca verify-full; do
  echo "  SQL_DSN_MIGRATE + $m : $(run SQL_DSN_MIGRATE "$m")"
done

kubectl -n $NS delete pod $CLI --ignore-not-found >/dev/null 2>&1
echo "DONE-T17-SSLP"
