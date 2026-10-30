#!/usr/bin/env bash
# deploy/perf/cvm/vegeta_run.sh —— 常量 QPS 交叉验证（默认 S1 非流式 chat）
#
# 为什么还要 vegeta：k6 与 vegeta 是两套独立实现，同目标同 QPS 跑出来的
#   success_rate / latency 若差异大，说明是压测工具本身的问题，而不是被测系统。
#
# 用法：
#   export TOKEN=<perf token>
#   ./vegeta_run.sh https://perf.likha.hk 800 120s
#
# 前置：vegeta 缺失时自动安装（最多 3 次）；仍失败则回退 docker；再不行给自助方案。
set -uo pipefail

TARGET="${1:?用法: vegeta_run.sh <target-url> <rate> <dur>}"
RATE="${2:-800}"
DUR="${3:-120s}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../vegeta/targets"
BODY="$HERE/../vegeta/body.json"
[ -s "$TPL" ] || { echo "[!] 缺 $TPL"; exit 2; }
[ -s "$BODY" ] || { echo "[!] 缺 $BODY"; exit 2; }

# shellcheck source=lib/prereq.sh
source "$HERE/lib/prereq.sh"

ensure_tool vegeta docker
VG_RC=$?
USE_DOCKER=0
[ "$VG_RC" -eq 10 ] && USE_DOCKER=1

[ -n "${TOKEN:-}" ] || {
  echo "[!] 需要 perf token（export TOKEN=...），取法见 cvm/README.md"
  exit 2
}

# 用真实 token / 目标地址 / body 绝对路径渲染 targets（原文件里是占位符）
TMPDIR_RUN="$(mktemp -d)"
TGTS="$TMPDIR_RUN/targets"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
sed -e "s#__TOKEN__#${TOKEN}#g" \
    -e "s#http://perf-new-api-slave\.new-api-perf\.svc\.cluster\.local#${TARGET%/}#g" \
    -e "s#@perf/vegeta/body\.json#@${BODY}#g" "$TPL" > "$TGTS"
cp -f "$BODY" "$TMPDIR_RUN/body.json"

echo "=== vegeta  rate=${RATE}/s  dur=${DUR}  target=${TARGET%/}  runner=$([ "$USE_DOCKER" = 1 ] && echo docker || echo vegeta)"

if [ "$USE_DOCKER" = 0 ] && command -v vegeta >/dev/null 2>&1; then
  vegeta attack -targets="$TGTS" -rate="${RATE}/s" -duration="$DUR" | vegeta report -type=text
  exit $?
fi

command -v docker >/dev/null 2>&1 || { perf_die_help vegeta; exit 3; }
docker run --rm \
  -v "$TGTS:/t/targets:ro" -v "$TMPDIR_RUN/body.json:/t/body.json:ro" \
  peterevans/vegeta:latest \
  sh -c "vegeta attack -targets=/t/targets -rate=${RATE}/s -duration=${DUR} | vegeta report -type=text"
