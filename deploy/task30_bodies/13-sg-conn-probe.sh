#!/bin/bash
# 13-sg-conn-probe.sh — 任务 30 V4 拔线自愈：SG 节点侧到 RDS 公网串的 TCP 连通率探测
# 由 deploy/ack_remote.sh sg 执行；TAG 由调用方 sed 注入（baseline / broken / recovered）
# 说明：节点在 VPC 内，出网经 NAT SNAT 到 4 个 sg_standby_eip 之一（per-flow 哈希）
#       ⇒ 白名单里移除 1 个 /32 后，命中该 EIP 的连接会被丢弃（表现为超时）。
#       ICMP 不受 RDS 白名单管辖 ⇒ 同时 ping 作「链路未坏、仅白名单拦截」的区分证据。
set -uo pipefail
TAG="${TAG:-unknown}"
HOST=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com
PORT=6432
N="${N:-100}"
TO="${TO:-3}"

echo "TAG=$TAG HOST=$HOST PORT=$PORT N=$N timeout=${TO}s"
echo "node_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "--- 0) ICMP 对照（白名单不影响 ICMP）---"
ping -c 5 -W 2 "$HOST" 2>&1 | tail -2

echo "--- 1) TCP 连通率（每连接独立 → 触发 SNAT 哈希轮换）---"
ok=0; fail=0; seq_str=""
for i in $(seq 1 "$N"); do
  if timeout "$TO" bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    ok=$((ok+1)); seq_str="${seq_str}."
  else
    fail=$((fail+1)); seq_str="${seq_str}X"
  fi
done
echo "ok=$ok fail=$fail total=$((ok+fail))"
awk -v o="$ok" -v n="$N" 'BEGIN{printf "success_rate=%.1f%%\n", (n>0? o*100.0/n : 0)}'
echo "seq=$seq_str"

echo "--- 2) 本节点 NAT 出口回显（对照白名单）---"
for i in 1 2 3 4 5 6; do
  curl -s --max-time 6 --noproxy '*' https://ifconfig.me 2>/dev/null | tr -d '\n'; echo " <- probe$i"
done

echo "--- 3) 白名单变更即时性观察（连续 10 次带时间戳）---"
for i in $(seq 1 10); do
  t0=$(date +%s%N)
  if timeout "$TO" bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then r=OK; else r=FAIL; fi
  t1=$(date +%s%N)
  echo "$(date -u +%H:%M:%S) #$i $r $(( (t1-t0)/1000000 ))ms"
done
echo "### PROBE DONE"
