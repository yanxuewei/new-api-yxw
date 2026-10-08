#!/bin/bash
# 任务 30 · 步骤 3a：新加坡 → 马尼拉 RDS 公网链路「TCP/RTT」段（快，节点级零凭据）
# 拆自 02-sg-net.sh：TLS 段单独跑，避免整体超 5 分钟云助手窗口
set -uo pipefail

H=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
P=6432

echo "== 工具 =="
for t in getent ping nc timeout; do
  command -v "$t" >/dev/null 2>&1 && echo "  have $t" || echo "  MISSING $t"
done

echo "== DNS =="
getent hosts "$H" | head -2
echo "== 本机出口信息 =="
hostname
curl -s --max-time 4 http://100.100.100.200/latest/meta-data/zone-id 2>/dev/null; echo
curl -s --max-time 4 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null; echo

echo "== 1) TCP 建连耗时 20 次（$H:$P，含 SYN/ACK 一个 RTT）=="
: >/tmp/tcp_ms.txt
i=0
while [ "$i" -lt 20 ]; do
  t0=$(date +%s%N)
  if timeout 4 bash -c "exec 3<>/dev/tcp/$H/$P" 2>/dev/null; then echo $(( ($(date +%s%N) - t0) / 1000000 )) >>/tmp/tcp_ms.txt; fi
  i=$((i+1))
done
n=$(wc -l </tmp/tcp_ms.txt)
echo "  成功 $n/20"
sort -n /tmp/tcp_ms.txt | awk '{a[NR]=$1} END{if(NR==0){print "  无成功样本";exit} printf "  min=%s p50=%s p95=%s max=%s (ms)\n", a[1], a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'

echo "== 2) 端口对照 =="
for p in 5432 6432; do
  if timeout 4 bash -c "exec 3<>/dev/tcp/$H/$p" 2>/dev/null; then echo "  $p TCP = OPEN"; else echo "  $p TCP = CLOSED/TIMEOUT"; fi
done

echo "== 3) ICMP（可能被过滤，通不通都记录）=="
ping -c 10 -W 2 "$H" 2>&1 | tail -3 | sed 's/^/  /' || echo "  ping 不可用/失败"

echo "== 4) 私网对照（同实例内网串，从 SG 应不可达）=="
I=pgm-5tstdhko64x2c01w.pgsql.ap-southeast-6.rds.aliyuncs.com
if timeout 4 bash -c "exec 3<>/dev/tcp/$I/6432" 2>/dev/null; then echo "  内网串 6432 = OPEN（意外）"; else echo "  内网串 6432 = 不可达（预期，跨区无路由）"; fi
echo DONE-3A
