#!/bin/bash
# 任务 30 · 步骤 9：建连 276ms 的成本拆解（本地进程 / TLS / 池 / 直连 5432 对照）+ verify-full 可行路径验证
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

cat > /tmp/t30_bd.sh <<'MEAS'
set -u
D="$SQL_DSN"; H=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
D5432=$(printf '%s' "$D" | sed 's/:6432/:5432/')
stat(){ sort -n "$1" | awk '{a[NR]=$1} END{if(NR==0){print "  无样本";exit} printf "  n=%d min=%s p50=%s p95=%s max=%s (ms)\n", NR, a[1], a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'; }

echo "--- A) psql 进程启动基线（不连库，纯 fork/exec + 动态链接）---"
: >/tmp/a.txt; i=0; while [ $i -lt 20 ]; do t0=$(date +%s%N); psql --version >/dev/null 2>&1; echo $(( ($(date +%s%N)-t0)/1000000 )) >>/tmp/a.txt; i=$((i+1)); done
stat /tmp/a.txt

echo "--- B) 经池 6432 建连 20 次（当前口径）---"
: >/tmp/b.txt; i=0; while [ $i -lt 20 ]; do t0=$(date +%s%N); psql "$D" -Atc "select 1" >/dev/null 2>&1 && echo $(( ($(date +%s%N)-t0)/1000000 )) >>/tmp/b.txt; i=$((i+1)); done
stat /tmp/b.txt

echo "--- C) 直连 5432 建连 20 次（同实例同账号，仅换端口）---"
: >/tmp/c.txt; i=0; while [ $i -lt 20 ]; do t0=$(date +%s%N); psql "$D5432" -Atc "select 1" >/dev/null 2>&1 && echo $(( ($(date +%s%N)-t0)/1000000 )) >>/tmp/c.txt; i=$((i+1)); done
stat /tmp/c.txt

echo "--- D) 同连接内 20 次查询成本（psql 单进程，$1 次往返）---"
psql "$D" -Atc "$(for k in $(seq 1 20); do printf 'select 1; '; done)" 2>/dev/null | head -1
t0=$(date +%s%N); psql "$D" -Atc "$(for k in $(seq 1 20); do printf 'select 1; '; done)" >/dev/null 2>&1; t1=$(date +%s%N)
echo "  20 次串行查询（含 1 次建连）= $(( (t1-t0)/1000000 )) ms"

echo "--- E) pgbench -C（每次事务新建连接）10s 单连接 ---"
printf 'select 1;\n' > /tmp/q.sql
pgbench -n -C -c 1 -T 10 -f /tmp/q.sql "$D" 2>&1 | grep -E "latency average|tps|failed" | head -3
echo "--- E2) pgbench 复用连接（对照）10s ---"
pgbench -n -c 1 -T 10 -f /tmp/q.sql "$D" 2>&1 | grep -E "latency average|tps" | head -2

echo "--- F) verify-full 可行路径：从 5432 取证书链当 rootcert（证书同一张）---"
echo Q | timeout 10 openssl s_client -connect "$H:5432" -servername "$H" -showcerts 2>/dev/null > /tmp/ch.txt
echo "  5432 链内证书数 = $(grep -c 'BEGIN CERTIFICATE' /tmp/ch.txt)"
awk '/BEGIN CERT/,/END CERT/' /tmp/ch.txt > /tmp/ca.pem
openssl x509 -in /tmp/ca.pem -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null | sed 's/^/    /'
VF=$(printf '%s' "$D" | sed 's/sslmode=require/sslmode=verify-full\&sslrootcert=\/tmp\/ca.pem/')
psql "$VF" -Atc "select 'verify-full(pin leaf) OK'" 2>&1 | head -3
echo "--- F2) 同样 rootcert 打 5432 ---"
psql "$(printf '%s' "$D5432" | sed 's/sslmode=require/sslmode=verify-full\&sslrootcert=\/tmp\/ca.pem/')" -Atc "select 'verify-full5432 OK'" 2>&1 | head -3

echo "--- G) 连接账目（探针清理后应回落）---"
psql "$D" -Atc "select usename, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc" 2>&1 | head -8
echo BD-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_bd.sh 2>&1 | tail -60
kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=false >/dev/null 2>&1
echo DONE-09
