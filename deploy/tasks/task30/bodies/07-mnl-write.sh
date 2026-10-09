#!/bin/bash
# 任务 30 · 步骤 7：马尼拉主站侧对照 Pod（V2 写侧 + 主站延迟基线）
# 用 SQL_DSN_MIGRATE 建 marker 表并写入；同时测主站内网串建连耗时作对照。
set -uo pipefail
NS=new-api

echo "== 0) 清理 =="
kubectl -n "$NS" delete pod t30-pg --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true

echo "== 1) 创建 mnl 探针 Pod t30-pg =="
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
    - name: SQL_DSN_MIGRATE
      valueFrom:
        secretKeyRef:
          name: new-api-secrets
          key: SQL_DSN_MIGRATE
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "2"
        memory: "1Gi"
YAML

echo "== 2) 等待 Ready =="
for i in $(seq 1 60); do
  RS=$(kubectl -n "$NS" get pod t30-pg -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  echo "  poll $i ready=$RS"
  [ "$RS" = "true" ] && break
  sleep 5
done

cat > /tmp/t30_mnl.sh <<'MEAS'
set -u
mask(){ printf '%s' "$1" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'; }
echo "--- 0) 两个 DSN 骨架 ---"
echo "  SQL_DSN         = $(mask "$SQL_DSN")"
echo "  SQL_DSN_MIGRATE = $(mask "$SQL_DSN_MIGRATE")"
echo "--- 1) 主站侧身份 ---"
psql "$SQL_DSN" -Atc "select current_database(), current_user, current_setting('server_version'), coalesce(inet_client_addr()::text,'-')" 2>&1 | head -3
echo "--- 2) marker 表（migrate 账号建）---"
psql "$SQL_DSN_MIGRATE" -Atc "create table if not exists ops_drill_marker(id bigserial primary key, note text, ts timestamptz default now())" 2>&1 | head -3
psql "$SQL_DSN_MIGRATE" -Atc "select count(*) from ops_drill_marker" 2>&1 | head -2
echo "--- 3) V2 写侧：插入 from-mnl 标记 ---"
psql "$SQL_DSN_MIGRATE" -Atc "insert into ops_drill_marker(note) values ('from-mnl-20261005') returning id, note, ts" 2>&1 | head -3
echo "--- 4) 主站建连耗时 20 次（内网串对照）---"
: >/tmp/conn_ms.txt
i=0
while [ "$i" -lt 20 ]; do
  t0=$(date +%s%N)
  psql "$SQL_DSN" -Atc "select 1" >/dev/null 2>&1 && echo $(( ($(date +%s%N) - t0)/1000000 )) >>/tmp/conn_ms.txt
  i=$((i+1))
done
sort -n /tmp/conn_ms.txt | awk '{a[NR]=$1} END{if(NR==0){print "  无样本";exit} printf "  成功 %d/20  min=%s p50=%s p95=%s max=%s (ms)\n", NR, a[1], a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'
echo "--- 5) 主站 pgbench（同口径，作对照）---"
printf 'select 1;\n' > /tmp/q.sql
pgbench -n -c 1 -T 15 -f /tmp/q.sql "$SQL_DSN" 2>&1 | grep -E "tps|latency average|failed" | head -3
echo "--- 6) 当前 pg_stat_activity 快照 ---"
psql "$SQL_DSN" -Atc "select usename, state, count(*) from pg_stat_activity group by 1,2 order by 3 desc" 2>&1 | head -10
echo MEASURE3-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_mnl.sh 2>&1 | tail -50
echo DONE-07
