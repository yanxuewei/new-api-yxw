#!/usr/bin/env bash
# deploy/perf/cvm/run.sh —— 在**普通 CVM/ECS** 上跑单档压测（不依赖 K8s、不用云助手）
#
# 用途：从被测集群之外发压，量到的是「入口 + 网关」的端到端能力（含 ALB/NAT/EIP），
#       与 deploy/perf/k6（集群内 Job，量网关自身）互补。
#
# 用法：
#   export TOKEN=<perf 专用 token>
#   ./run.sh https://perf.likha.hk 800 120s nostream 128
#   ./run.sh https://perf.likha.hk 1500 120s stream 1000
#
# 前置：k6（推荐 0.54.x）。缺失时**自动安装**（最多 3 次）；仍失败则回退 docker；
#       两者都不行会打印原因与自助方案（见 lib/prereq.sh）。
set -uo pipefail

TARGET="${1:?用法: run.sh <target-url> <rate> <dur> [stream|nostream] [max_tokens]}"
RATE="${2:?缺少 rate（每秒请求数）}"
DUR="${3:-120s}"
MODE="${4:-nostream}"
MAXT="${5:-128}"

case "$MODE" in
  stream)   STREAM=true ;;
  nostream) STREAM=false ;;
  *) echo "[!] mode 只能是 stream / nostream"; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../k6/relay-chat.js"
[ -s "$SCRIPT" ] || { echo "[!] 缺脚本 $SCRIPT"; exit 2; }

# shellcheck source=lib/prereq.sh
source "$HERE/lib/prereq.sh"

ensure_tool k6 docker
K6_RC=$?
USE_DOCKER=0
[ "$K6_RC" -eq 10 ] && USE_DOCKER=1

[ -n "${TOKEN:-}" ] || {
  echo "[!] 需要 perf token。取法："
  echo "    kubectl -n new-api-perf get secret perf-load-test-credentials -o jsonpath='{.data.token_key}' | base64 -d"
  exit 2
}

echo "=== target=$TARGET  rate=${RATE}/s  dur=$DUR  mode=$MODE  max_tokens=$MAXT  runner=$([ "$USE_DOCKER" = 1 ] && echo docker || echo k6)"
ENVPAIRS=(
  "BASE=$TARGET" "TOKEN=$TOKEN" "EXECUTOR=arrival" "RATE=$RATE" "DUR=$DUR"
  "STREAM=$STREAM" "MAX_TOKENS=$MAXT" "MODEL=${MODEL:-mock-gpt}"
)

if [ "$USE_DOCKER" = 0 ] && command -v k6 >/dev/null 2>&1; then
  ARGS=()
  for kv in "${ENVPAIRS[@]}"; do ARGS+=(-e "$kv"); done
  exec k6 run "${ARGS[@]}" "$SCRIPT"
fi

command -v docker >/dev/null 2>&1 || { perf_die_help k6; exit 3; }
ARGS=(--rm -i -v "$SCRIPT:/scripts/relay-chat.js:ro")
for kv in "${ENVPAIRS[@]}"; do ARGS+=(-e "$kv"); done
exec docker run "${ARGS[@]}" grafana/k6:0.54.0 run /scripts/relay-chat.js
