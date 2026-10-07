#!/bin/bash
# 11-sg-verifyfull.sh — 任务 30 缺口②：SG 侧 verify-full 落地与复验
# 执行位：deploy/ack_remote.sh sg deploy/task30_bodies/11-sg-verifyfull.sh <node_id> 40
# 步骤：① 落地 RDS CA（根 + ap-southeast-6 中间）为 Secret rds-ca-apse6
#       ② 建一次性探针 Pod 挂载 Secret 到 /etc/ssl/rds
#       ③ 正例 verify-full @6432 与 @5432；负例（无 rootcert / 错 rootcert / system）
# 只建 Secret + 一次性 Pod；探针 Pod 必须在本脚本末尾删除。
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
CA=/tmp/rds-apse6-ca.crt
SEC=rds-ca-apse6
POD=t30-vf

echo "### 0) 证书落地（本机 openssl 复核）"
printf '%s' "__CA_B64__" | base64 -d > "$CA" 2>/dev/null || printf '%s' "__CA_B64__" | base64 -D > "$CA"
echo "cert_count=$(grep -c 'BEGIN CERTIFICATE' "$CA")  bytes=$(wc -c < "$CA" | tr -d ' ')"
openssl x509 -in "$CA" -noout -subject -fingerprint -sha256 2>&1 | head -2

echo "### 1) Secret 建/更新（幂等）"
kubectl -n "$NS" create secret generic "$SEC" --from-file=ca.crt="$CA" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>&1

echo "### 2) Secret 回读校验"
kubectl -n "$NS" get secret "$SEC" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d | grep -c 'BEGIN CERTIFICATE'

echo "### 3) SG SQL_DSN 现状（口令打码）"
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' 2>/dev/null \
  | base64 -d | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'

echo "### 4) 探针 Pod（一次性）"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
cat <<YAML | kubectl -n "$NS" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels: {app: t30-vf}
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  containers:
  - name: pg
    image: postgres:17
    command: ["sh","-c","sleep 1500"]
    env:
    - name: DSN_BASE
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    resources:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "1",    memory: "512Mi"}
    volumeMounts:
    - {name: rds-ca, mountPath: /etc/ssl/rds, readOnly: true}
  volumes:
  - name: rds-ca
    secret: {secretName: ${SEC}}
YAML

for i in $(seq 1 30); do
  ph=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Running" ] && break
  sleep 4
done
echo "pod phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)"

echo "### 5) 证书在 Pod 内可见性"
kubectl -n "$NS" exec "$POD" -- sh -c 'ls -l /etc/ssl/rds/ && openssl x509 -in /etc/ssl/rds/ca.crt -noout -subject 2>&1 | head -1' 2>&1

echo "### 6) verify-full 正例 / 负例"
kubectl -n "$NS" exec -i "$POD" -- sh -s <<'EOS' 2>&1
set -u
BASE=$(printf '%s' "$DSN_BASE" | sed -E 's/[?&]sslmode=[^&]*//g; s/[?&]sslrootcert=[^&]*//g')
case "$BASE" in *\?*) SEP="&";; *) SEP="?";; esac
HOSTPORT=$(printf '%s' "$BASE" | sed -E 's#^.*@([^/]+).*$#\1#')
HOST=${HOSTPORT%:*}
echo "HOST=$HOST  (当前 DSN 端口=${HOSTPORT##*:})"

run() {  # run <标签> <dsn>
  echo "--- $1 ---"
  out=$(psql "$2" -Atc "select current_user||'|'||current_database()||'|'||(select ssl::text||'/'||coalesce(version,'-') from pg_stat_ssl where pid=pg_backend_pid())" 2>&1)
  rc=$?
  echo "rc=$rc  out=$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
}

VF64="${BASE}${SEP}sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt"
VF54="postgres://$(printf '%s' "$BASE" | sed -E 's#^postgres://##; s#@[^/]+/#@'"$HOST"':5432/#')${SEP}sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt"
REQ="${BASE}${SEP}sslmode=require"
NOROOT="${BASE}${SEP}sslmode=verify-full"
SYSR="postgres://$(printf '%s' "$BASE" | sed -E 's#^postgres://##; s#@[^/]+/#@'"$HOST"':5432/#')${SEP}sslmode=verify-full&sslrootcert=system"
BADROOT="${BASE}${SEP}sslmode=verify-full&sslrootcert=/etc/ssl/rds/leaf-nothere.crt"

run "A 正例 verify-full @默认端口(6432)" "$VF64"
run "B 正例 verify-full @5432(直连)" "$VF54"
run "C 对照 sslmode=require @6432" "$REQ"
run "D 负例 verify-full 无 sslrootcert（期望失败）" "$NOROOT"
run "E 负例 verify-full + sslrootcert=system（期望失败）" "$SYSR"
run "F 负例 verify-full + 不存在 rootcert（期望失败）" "$BADROOT"

echo "--- resolve 公网解析（应与 DSN host 一致）---"
getent hosts "$HOST" || nslookup "$HOST" 2>&1 | tail -3
EOS

echo "### 7) 清理探针 Pod"
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false 2>&1
sleep 3
echo "remaining pod=$(kubectl -n "$NS" get pod "$POD" --no-headers 2>&1 | head -1)"
echo "### DONE"
