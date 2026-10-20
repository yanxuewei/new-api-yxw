#!/usr/bin/env bash
# deploy/perf/k6/run.sh —— 压测入口（本机执行；把 sse.js 与动作体打包后经云助手投递到雅加达 dev 节点）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl，15 分钟临时私网 kubeconfig）
# 为什么这么绕：集群 API Server 仅内网、本机无法直连；k6 Job 与 mock 都在集群内，客户端不能成为瓶颈（任务 33 坑 1）。
#
# usage:
#   bash deploy/perf/k6/run.sh stage <target-svc> <vus> <duration>   # 单副本阶梯，如 stage perf-new-api-slave 300 120s
#   bash deploy/perf/k6/run.sh dual1500 [vus-each] [duration]        # 双副本并行，默认 750+750 × 120s（合计 1500）
#   bash deploy/perf/k6/run.sh summary [job...]                      # 打印最近 Job 的 k6 摘要
#   bash deploy/perf/k6/run.sh readback                              # 环境/健康/CPU/mock 指标回读（只读）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
BODIES="$HERE/bodies"
K6JS="$HERE/sse.js"

[ -s "$K6JS" ] || { echo "[!] 缺 $K6JS"; exit 1; }
[ -x "$REMOTE" ] || { echo "[!] 缺通道脚本 $REMOTE"; exit 1; }

ACTION="${1:?action: stage|dual1500|summary|readback}"; shift || true

# 节点侧需要的最小上下文：sse.js 载荷（Base64）+ 动作参数。值不进 argv，只进本次命令体。
header() {
  cat <<'HDR'
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
HDR
  printf "export K6JS_B64='%s'\n" "$(base64 -w0 "$K6JS")"
  local kv
  for kv in "$@"; do printf "export %s='%s'\n" "${kv%%=*}" "${kv#*=}"; done
}

run_body() {
  local body="$1" tag="$2"; shift 2
  [ -s "$BODIES/$body" ] || { echo "[!] 缺 body：$BODIES/$body"; exit 1; }
  local full="/tmp/perf_k6_${tag}.$$.sh"
  { header "$@"; cat "$BODIES/$body"; } > "$full"; chmod 700 "$full"
  echo "[perf-k6] action=$tag payload=$# body=$(wc -c <"$full")B"
  bash "$REMOTE" "$full"
  local rc=$?; rm -f "$full"; return $rc
}

case "$ACTION" in
  stage)
    TGT="${1:?stage 需要 <target-svc>}"; VUS="${2:?stage 需要 <vus>}"; DUR="${3:-120s}"
    run_body stage.sh "stage_${TGT}_${VUS}" "TARGET_SVC=$TGT" "VUS=$VUS" "DUR=$DUR" ;;
  dual1500)
    EACH="${1:-750}"; DUR="${2:-120s}"
    run_body dual1500.sh dual1500 "VUS_EACH=$EACH" "DUR=$DUR" ;;
  summary)
    run_body summary.sh summary "JOBS=$*" ;;
  readback)
    run_body readback.sh readback ;;
  *) echo "[!] 未知动作：$ACTION（stage|dual1500|summary|readback）"; exit 2 ;;
esac
