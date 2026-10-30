#!/usr/bin/env bash
# deploy/perf/cvm/qps_ceiling.sh —— 在普通 CVM 上阶梯升档，找「仍满足 SLO 的最高 QPS」
#
# 用法：
#   export TOKEN=<perf token>
#   ./qps_ceiling.sh https://perf.likha.hk 200 200 2000 60s nostream 128
#   ./qps_ceiling.sh http://10.2.x.x:3000 200 200 2000 60s stream 1000
#
# 参数：<target> <start> <step> <max> <dur> [stream|nostream] [max_tokens]
# 判据：错误率 < SLO_ERR、P95 < SLO_P95、dropped==0、实得 ≥ TOL×目标
# 环境：SLO_ERR(默认0.05 百分数) SLO_P95(默认800ms) TOL(默认0.98)
#
# 说明：单机 k6 的并发/CPU 会成为上限，若「实得远低于目标」且错误率≈0，
#      多半是压测机不够，不是被测系统不够 —— 换更大机型或换集群内压测复核。
set -uo pipefail

TARGET="${1:?用法: qps_ceiling.sh <target> <start> <step> <max> <dur> [stream|nostream] [max_tokens]}"
START="${2:-200}"; STEP="${3:-200}"; MAX="${4:-2000}"; DUR="${5:-60s}"
MODE="${6:-nostream}"; MAXT="${7:-128}"
SLO_ERR="${SLO_ERR:-0.05}"; SLO_P95="${SLO_P95:-800}"; TOL="${TOL:-0.98}"

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run.sh"
OUT="$(mktemp)"; TMPD="$(mktemp -d)"
trap 'rm -f "$OUT"; rm -rf "$TMPD"' EXIT

# 阶梯开始前先把 k6 准备好，避免跑到一半才因缺依赖中断
# shellcheck source=lib/prereq.sh
source "$HERE/lib/prereq.sh"
ensure_tool k6 docker || true

echo "=== 阶梯 target=$TARGET ${START}→${MAX} 步长 ${STEP}  每档 ${DUR}  mode=$MODE"
echo "=== SLO 错误率<${SLO_ERR}%  P95<${SLO_P95}ms  dropped=0  实得≥${TOL}×目标"
printf '%-8s %-9s %-8s %-9s %-8s %s\n' "目标" "实得" "P95" "错误率" "dropped" "判定"

BEST=0; BEST_ACH=0; BEST_P95=0
R="$START"
while [ "$R" -le "$MAX" ]; do
  "$RUN" "$TARGET" "$R" "$DUR" "$MODE" "$MAXT" > "$TMPD/out.txt" 2>&1
  rc=$?

  rps=$(grep -E '^ *http_reqs' "$TMPD/out.txt" | tail -1 | awk '{x=$3; sub("/s","",x); print x+0}')
  fail=$(grep -E '^ *http_req_failed' "$TMPD/out.txt" | tail -1 | awk '{print $3+0}')
  tot=$(grep -E '^ *http_req_failed' "$TMPD/out.txt" | tail -1 | awk '{print $6+0}')
  drop=$(grep -E '^ *dropped_iterations' "$TMPD/out.txt" | tail -1 | awk '{print $3+0}')
  p95=$(grep -E '^ *http_req_waiting' "$TMPD/out.txt" | tail -1 | awk '{m=0; for(i=1;i<=NF;i++){if($i ~ /^p\(95\)=/){x=$i; sub("p\\(95\\)=","",x); sub("ms","",x); if(x+0>m) m=x+0}}; print m}')
  err=$(awk -v f="${fail:-0}" -v t="${tot:-0}" 'BEGIN{if(t>0) printf "%.3f", f*100/t; else print "0"}')
  [ -z "${rps:-}" ] && rps=0
  [ -z "${p95:-}" ] && p95=0
  [ -z "${drop:-}" ] && drop=0

  verdict=FAIL
  if [ "$rc" -eq 0 ] \
     && awk -v e="$err" -v p="$p95" -v d="$drop" -v a="$rps" -v t="$R" -v se="$SLO_ERR" -v sp="$SLO_P95" -v tol="$TOL" \
        'BEGIN{exit !(e+0<se+0 && p+0<sp+0 && d+0==0 && a+0>=t*tol)}'; then
    verdict=PASS
  fi
  printf '%-8s %-9s %-8s %-9s %-8s %s\n' "$R" "$rps" "${p95}ms" "${err}%" "$drop" "$verdict"

  if [ "$verdict" = PASS ]; then
    BEST="$R"; BEST_ACH="$rps"; BEST_P95="$p95"
  else
    echo "=== 首个失败档 = $R，停止上探"
    grep -E '✗|error' "$TMPD/out.txt" | head -5 | sed 's/^/    /'
    break
  fi
  R=$((R + STEP))
done

echo "=== 结论：最高通过 QPS 档 = $BEST（实得 ${BEST_ACH}/s、P95 ${BEST_P95}ms）"
[ "$BEST" = 0 ] && echo "    起始档就没过：降低 START 或先确认压测机/网络"
exit 0
