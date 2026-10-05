#!/bin/bash
# 任务 30 · 步骤 6：SG 探针 Pod 内补测 TLS verify-full（含 sslrootcert 三种口径）+ V1 等价证据
set -uo pipefail
NS=new-api

cat > /tmp/t30_vf.sh <<'MEAS'
set -u
D="$SQL_DSN"
mask(){ printf '%s' "$1" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#'; }
echo "--- A) 原始 DSN（require）---"; mask "$D"

echo "--- B) verify-full 无 rootcert（预期失败，复现）---"
VF=$(printf '%s' "$D" | sed 's/sslmode=require/sslmode=verify-full/')
psql "$VF" -Atc "select 1" 2>&1 | head -2

echo "--- C) verify-full + sslrootcert=system（用系统根 CA）---"
VF2=$(printf '%s' "$D" | sed 's/sslmode=require/sslmode=verify-full\&sslrootcert=system/')
echo "  DSN: $(mask "$VF2")"
psql "$VF2" -Atc "select 'verify-full+system OK', current_database(), current_user" 2>&1 | head -4

echo "--- D) 服务端证书链（PG 协议协商层，psql 内取）---"
VF3=$(printf '%s' "$D" | sed 's/sslmode=require/sslmode=require\&sslrootcert=system/')
psql "$VF3" -Atc "select ssl, version, cipher from pg_stat_ssl where pid = pg_backend_pid()" 2>&1 | head -3

echo "--- E) V1 等价证据：客户端侧地址 / 库 / 用户 / 版本 / 启动时间 ---"
psql "$D" -Atc "select coalesce(inet_client_addr()::text,'-') as client, current_database(), current_user, current_setting('server_version'), pg_postmaster_start_time()::text" 2>&1 | head -3
echo "--- E2) pg_stat_activity 里本会话的 client_addr / backend_start ---"
psql "$D" -Atc "select coalesce(client_addr::text,'-'), coalesce(client_port::text,'-'), backend_start::text from pg_stat_activity where pid = pg_backend_pid()" 2>&1 | head -3

echo "--- F) 503 口径：连接串 SSL 参数回显 ---"
psql "$D" -Atc "select name, setting from pg_settings where name in ('ssl','ssl_min_protocol_version','ssl_max_protocol_version')" 2>&1 | head -6

echo "--- G) 复用同一连接的 20 次串行查询（对比建连成本）---"
psql "$D" -Atc "\timing on
select 1;" 2>&1 | tail -3
echo "--- H) 建连耗时 10 次，分开计时：DNS / TCP / TLS ---"
i=0
while [ "$i" -lt 10 ]; do
  t0=$(date +%s%N)
  psql "$D" -Atc "select 1" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo "  conn$i = $(( (t1-t0)/1000000 )) ms"
  i=$((i+1))
done
echo MEASURE2-DONE
MEAS

kubectl -n "$NS" exec -i t30-pg -- bash -s < /tmp/t30_vf.sh 2>&1 | tail -50
echo DONE-06
