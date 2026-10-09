#!/bin/bash
# 12-sg-dsn-verifyfull.sh — 任务 30 缺口②第二步：SG SQL_DSN 切 verify-full 并复验
# 前置：11-sg-verifyfull.sh 已建 Secret rds-ca-apse6（含 根CA + ap-southeast-6 中间CA）
# 执行位：bash deploy/lib/ack_remote.sh sg <node_id> /tmp/body12.sh 40
# ⚠ 副作用：备站 Deployment 未来部署时【必须】把 rds-ca-apse6 挂到 /etc/ssl/rds，
#   否则 sslrootcert 路径不存在 → 连接失败。回滚 = sed 换回 sslmode=require。
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
POD=t30-vf2

echo "### 0) 改前 DSN（打码）"
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' | base64 -d \
  | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'

echo "### 1) 计算新 DSN 并 patch（口令走 --patch-file，不进 ps）"
OLD=$(kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' | base64 -d)
NEW=$(printf '%s' "$OLD" | sed -E 's/[?&]sslmode=[^&]*//g; s/[?&]sslrootcert=[^&]*//g')
case "$NEW" in *\?*) SEP='&';; *) SEP='?';; esac
NEW="${NEW}${SEP}sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt"
NEWJ=$(printf '%s' "$NEW" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$/"/')
printf '{"stringData":{"SQL_DSN":%s}}\n' "$NEWJ" > /tmp/dsn_patch.json
echo "patch json bytes=$(wc -c < /tmp/dsn_patch.json | tr -d ' ')"
kubectl -n "$NS" patch secret new-api-secrets --type merge --patch-file /tmp/dsn_patch.json 2>&1
rm -f /tmp/dsn_patch.json

echo "### 2) 改后回读（打码）"
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' | base64 -d \
  | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'
echo ""

echo "### 3) 端到端复验：直接用 Secret 里的新 DSN（不再改写）"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
cat <<YAML | kubectl -n "$NS" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels: {app: t30-vf2}
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  containers:
  - name: pg
    image: postgres:17
    command: ["sh","-c","sleep 900"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    resources:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "1",    memory: "512Mi"}
    volumeMounts:
    - {name: rds-ca, mountPath: /etc/ssl/rds, readOnly: true}
  volumes:
  - name: rds-ca
    secret: {secretName: rds-ca-apse6}
YAML

for i in $(seq 1 30); do
  ph=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Running" ] && break
  sleep 4
done
echo "pod phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)"

kubectl -n "$NS" exec -i "$POD" -- sh -s <<'EOS' 2>&1
set -u
echo "DSN(打码)=$(printf '%s' "$SQL_DSN" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#')"
echo "--- A) 直接用 Secret DSN 连接 ---"
out=$(psql "$SQL_DSN" -Atc "select current_user||'|'||current_database()||'|'||(select ssl::text||'/'||coalesce(version,'-')||'/'||coalesce(cipher,'-') from pg_stat_ssl where pid=pg_backend_pid())" 2>&1); rc=$?
echo "rc=$rc  out=$out"
echo "--- B) 确认服务端看到的是 TLS ---"
psql "$SQL_DSN" -Atc "select pg_backend_pid(), inet_client_addr() is null as client_addr_null" 2>&1 | head -2
echo "--- C) 读一条业务表（证数据面可用）---"
psql "$SQL_DSN" -Atc "select count(*) from information_schema.tables where table_schema='public'" 2>&1 | head -2
EOS

echo "### 4) 清理探针 Pod"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s 2>&1
sleep 2
echo "remaining=$(kubectl -n "$NS" get pod --no-headers 2>&1 | head -3)"
echo "### DONE"
