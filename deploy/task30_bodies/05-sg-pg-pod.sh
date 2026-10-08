#!/bin/bash
# 任务 30 · 步骤 5：在 SG 集群一次性 Pod 内跑「数据面」实测（psql / pgbench / V1 / V3）
# 凭据走 secretKeyRef 注入 Pod，口令不进命令行、不出集群。
set -uo pipefail
NS=new-api

echo "== 0) ResourceQuota =="
kubectl -n "$NS" get resourcequota -o wide 2>&1 | head -5
echo "== 0b) 清理旧探针 =="
kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

echo "== 1) 创建探针 Pod t30-pg（postgres:17，含 psql/pgbench）=="
cat <<'YAML' | kubectl -n new-api apply -f - 2>&1 | head -3
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
    command: ["sleep", "7200"]
    env:
    - name: SQL_DSN
      valueFrom:
        secretKeyRef:
          name: new-api-secrets
          key: SQL_DSN
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "2"
        memory: "1Gi"
YAML

echo "== 2) 等待 Ready（最多 300s，含拉镜像）=="
for i in $(seq 1 60); do
  PH=$(kubectl -n "$NS" get pod t30-pg -o jsonpath='{.status.phase}' 2>/dev/null)
  RS=$(kubectl -n "$NS" get pod t30-pg -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  echo "  poll $i phase=$PH ready=$RS"
  [ "$RS" = "true" ] && break
  [ "$PH" = "Failed" ] && { echo "  Pod Failed，events:"; kubectl -n "$NS" describe pod t30-pg 2>&1 | tail -12; break; }
  sleep 5
done
kubectl -n "$NS" get pod t30-pg -o wide 2>&1 | head -3

echo "== 3) Pod 内工具 =="
kubectl -n "$NS" exec t30-pg -- sh -c 'for t in psql pgbench openssl bash; do printf "  %s=%s\n" "$t" "$(command -v $t || echo MISSING)"; done' 2>&1 | head -6

echo "=========== 数据面测量（Pod 内） ==========="
cat > /tmp/t30_measure.sh <<'MEAS'
set -u
echo "--- 0) DSN 骨架（口令掩码）---"
echo "$SQL_DSN" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'
echo "--- 1) V1：确实是马尼拉主库？（addr/db/port/version）---"
psql "$SQL_DSN" -Atc "select inet_server_addr()::text, inet_server_port()::text, current_database(), current_user, version()" 2>&1 | head -3
echo "--- 2) SSL 实际状态 ---"
psql "$SQL_DSN" -Atc "show ssl" 2>&1 | head -2
echo "--- 3) verify-full 端到端（把 sslmode 换成 verify-full 再连）---"
VF=$(printf '%s' "$SQL_DSN" | sed 's/sslmode=require/sslmode=verify-full/')
echo "  VF骨架: $(printf '%s' "$VF" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#')"
psql "$VF" -Atc "select 'verify-full OK'" 2>&1 | head -3
echo "--- 4) 建连耗时 50 次（含 DNS+TCP+TLS+认证+一次查询）---"
: >/tmp/conn_ms.txt
i=0
while [ "$i" -lt 50 ]; do
  t0=$(date +%s%N)
  if psql "$SQL_DSN" -Atc "select 1" >/dev/null 2>&1; then echo $(( ($(date +%s%N) - t0) / 1000000 )) >>/tmp/conn_ms.txt; fi
  i=$((i+1))
done
echo "  成功 $(wc -l </tmp/conn_ms.txt)/50"
sort -n /tmp/conn_ms.txt | awk '{a[NR]=$1} END{if(NR==0){print "  无样本";exit} printf "  min=%s p50=%s p95=%s max=%s (ms)\n", a[1], a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'
echo "--- 5) pgbench 简单查询（select 1，免建表）---"
printf 'select 1;\n' > /tmp/q.sql
echo "  [c1  -T30]"; pgbench -n -c 1  -T 30 -f /tmp/q.sql "$SQL_DSN" 2>&1 | grep -E "tps|latency average|number of transactions|failed" | head -4
echo "  [c16 -T30]"; pgbench -n -c 16 -T 30 -f /tmp/q.sql "$SQL_DSN" 2>&1 | grep -E "tps|latency average|number of transactions|failed" | head -4
echo "--- 6) V3：连接账目（按用户/状态）---"
psql "$SQL_DSN" -Atc "select usename, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc" 2>&1 | head -12
echo "--- 7) 本 Pod 自身连接（application_name/client_addr）---"
psql "$SQL_DSN" -Atc "select count(*) from pg_stat_activity where application_name like '%psql%' or client_addr is not null" 2>&1 | head -3
echo "--- 8) max_connections / pgbouncer 视角 ---"
psql "$SQL_DSN" -Atc "show max_connections" 2>&1 | head -2
psql "$SQL_DSN" -Atc "show pool_mode" 2>&1 | head -2
psql "$SQL_DSN" -Atc "show default_pool_size" 2>&1 | head -2
psql "$SQL_DSN" -Atc "show max_client_conn" 2>&1 | head -2
echo MEASURE-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_measure.sh 2>&1 | tail -80
echo "== 9) Pod 保留（供 V2 用）；如需释放：kubectl -n new-api delete pod t30-pg"
echo DONE-05
