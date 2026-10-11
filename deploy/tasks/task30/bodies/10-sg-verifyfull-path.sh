#!/bin/bash
# 任务 30 · 步骤 10：补 09 未跑完段（pgbench -C / 串行查询 / verify-full 可行路径 / 连接账目）
set -uo pipefail
NS=new-api

kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
cat <<'YAML' | kubectl -n new-api apply -f - 2>&1 | head -2
apiVersion: v1
kind: Pod
metadata:
  name: t30-pg
  namespace: new-api
  labels:
    app: t30-probe
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  containers:
  - name: pg
    image: postgres:17
    command: ["sleep", "3000"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    resources:
      requests: {cpu: "500m", memory: "256Mi"}
      limits: {cpu: "2", memory: "1Gi"}
YAML
for i in $(seq 1 40); do
  RS=$(kubectl -n "$NS" get pod t30-pg -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$RS" = "true" ] && break
  sleep 5
done
echo "  pod ready=$RS"

cat > /tmp/t30_bd2.sh <<'MEAS'
set -u
D="$SQL_DSN"; H=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
D5432=$(printf '%s' "$D" | sed 's/:6432/:5432/')
printf 'select 1;\n' > /tmp/q.sql

echo "--- D) psql 单进程内 20 次串行查询（仅 1 次建连）---"
t0=$(date +%s%N)
psql "$D" -Atc "$(for k in $(seq 1 20); do printf 'select 1; '; done)" >/dev/null 2>&1
t1=$(date +%s%N)
echo "  含 1 次建连 = $(( (t1-t0)/1000000 )) ms（对比 20 次独立建连 ≈ 5600 ms）"

echo "--- E) pgbench -C（每事务新建连接）单连接 10s ---"
pgbench -n -C -c 1 -T 10 -f /tmp/q.sql "$D" 2>&1 | grep -E "latency average|tps =|failed" | head -3
echo "--- E2) pgbench 复用连接（对照）单连接 10s ---"
pgbench -n -c 1 -T 10 -f /tmp/q.sql "$D" 2>&1 | grep -E "latency average|tps =|failed" | head -3

echo "--- F) verify-full 可行路径：从 5432 链路取证书作 sslrootcert ---"
echo Q | timeout 10 openssl s_client -connect "$H:5432" -servername "$H" -showcerts 2>/dev/null > /tmp/ch.txt
echo "  5432 链内证书数 = $(grep -c 'BEGIN CERTIFICATE' /tmp/ch.txt)"
awk '/BEGIN CERT/,/END CERT/' /tmp/ch.txt > /tmp/ca.pem
openssl x509 -in /tmp/ca.pem -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /'
openssl x509 -in /tmp/ca.pem -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /'
openssl x509 -in /tmp/ca.pem -noout -checkhost "$H" 2>&1 | sed 's/^/    checkhost: /'

VF=$(printf '%s' "$D" | sed 's#sslmode=require#sslmode=verify-full\&sslrootcert=/tmp/ca.pem#')
echo "  [6432 + verify-full + rootcert=leaf]"
psql "$VF" -Atc "select 'VERIFY-FULL 6432 OK'" 2>&1 | head -3
VF2=$(printf '%s' "$D5432" | sed 's#sslmode=require#sslmode=verify-full\&sslrootcert=/tmp/ca.pem#')
echo "  [5432 + verify-full + rootcert=leaf]"
psql "$VF2" -Atc "select 'VERIFY-FULL 5432 OK'" 2>&1 | head -3

echo "--- F2) PG 侧 SSL 参数回显 ---"
psql "$D" -Atc "select name||'='||setting from pg_settings where name like 'ssl%' order by name" 2>&1 | head -8
echo "--- F3) 本会话 SSL 版本/套件 ---"
psql "$D" -Atc "select ssl, version, cipher, bits from pg_stat_ssl where pid = pg_backend_pid()" 2>&1 | head -3

echo "--- G) 连接账目（探针清理后）---"
psql "$D" -Atc "select usename, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc" 2>&1 | head -8
echo BD2-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_bd2.sh 2>&1 | tail -50
kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=false >/dev/null 2>&1
echo DONE-10
