#!/usr/bin/env bash
# deploy/perf/k6/run.sh —— 压测入口（本机执行；把 sse.js 与动作体打包后经云助手投递到雅加达 dev 节点）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl，15 分钟临时私网 kubeconfig）
# 为什么这么绕：集群 API Server 仅内网、本机无法直连；k6 Job 与 mock 都在集群内，客户端不能成为瓶颈（任务 33 坑 1）。
#
# usage:
#   bash deploy/perf/k6/run.sh stage <target-svc> <vus> <duration>                     # 单副本单阶段，如 stage perf-new-api-slave 300 120s
#   bash deploy/perf/k6/run.sh ramp  <target-svc> [start] [step] [max] [duration]      # 阶梯递增找瓶颈，默认 300→3000 步长300 每阶段90s
#   bash deploy/perf/k6/run.sh ladder <target-svc> [start] [step] [max] [dur] [reps]     # 副本阶梯：1 副本压到瓶颈→扩到 2 副本同参数重压（默认 reps=1,2）
#   bash deploy/perf/k6/run.sh scale <replicas> [deploy]                                # 只调副本数（压测后恢复现场）
#   bash deploy/perf/k6/run.sh dual1500 [vus-each] [duration]                          # 双副本并行，默认 750+750 × 120s（合计 1500）
#   bash deploy/perf/k6/run.sh summary [job...]                                         # 打印最近 Job 的 k6 摘要
#   bash deploy/perf/k6/run.sh readback                                                 # 环境/健康/CPU/mock 指标回读（只读）
#
# 环境变量：
#   EIP_MBPS   公网路径的 EIP 标称带宽（默认 100，雅加达 dev 现网实测 100 Mbps），仅用于报告的带宽利用率判定
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
REMOTE="$ROOT/deploy/lib/ack_remote_jkt_dev.sh"
BODIES="$HERE/bodies"
K6JS_FILE="$HERE/sse.js"   # 每个动作可切换（burst/admin/long 用各自脚本）

[ -s "$K6JS_FILE" ] || { echo "[!] 缺 $K6JS_FILE"; exit 1; }
[ -x "$REMOTE" ] || { echo "[!] 缺通道脚本 $REMOTE"; exit 1; }

ACTION="${1:?action: stage|ramp|ladder|dual1500|summary|readback}"; shift || true

# 节点侧需要的最小上下文：sse.js 载荷（Base64）+ 动作参数。值不进 argv，只进本次命令体。
header() {
  cat <<'HDR'
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
HDR
  printf "export K6JS_GZ='%s'\n" "$(gzip -9 -c "$K6JS_FILE" | base64 -w0)"
  local kv
  for kv in "$@"; do printf "export %s='%s'\n" "${kv%%=*}" "${kv#*=}"; done
}

REPORT_DIR="$ROOT/deploy/perf/perf_reports"
DESC=""   # 本次压测参数摘要，由分发处赋值，用于报告文件名

run_body() {
  local body="$1" tag="$2"; shift 2
  [ -s "$BODIES/$body" ] || { echo "[!] 缺 body：$BODIES/$body"; exit 1; }
  local full="/tmp/perf_k6_${tag}.$$.sh"
  { header "$@"; cat "$BODIES/$body"; } > "$full"; chmod 700 "$full"
  echo "[perf-k6] action=$tag payload=$# body=$(wc -c <"$full")B"
  # 压测开始前先创建本次专属子目录，后续所有中间文件和报告直接落在这里
  local run_ts run_dir
  run_ts=$(date +%Y%m%d-%H%M%S)
  run_dir="$REPORT_DIR/$run_ts"
  mkdir -p "$run_dir"
  LAST_RUN_DIR="$run_dir"   # 供调用方（如 ramp）收集各阶段目录
  echo "[perf-k6] 本次输出目录：$run_dir"
  # 捕获远端输出：一边打屏，一边落盘（报告的数据源），跑完自动渲染 HTML
  local out rc log safe
  out=$(bash "$REMOTE" "$full" 2>&1); rc=$?
  printf '%s\n' "$out"
  rm -f "$full"
  log="$run_dir/${run_ts}-${tag}.log"
  printf '%s\n' "$out" > "$log"
  LAST_LOG="$log"   # 供调用方（ramp/ladder）做 SLO 判定
  echo "[perf-k6] 日志：$log"
  case "$tag" in
    stage_*|dual1500|s3_*|s4_*|s5_*|s9_*|s10_*|shard_*)
      # 文件名 = perf_report_<参数摘要>_<启动时刻>.html（参数里的路径/冒号等替换为 -）
      safe=$(printf '%s' "${DESC:-$tag}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g;s/-*$//')
      local html="$run_dir/perf_report_${safe}_${run_ts}.html"
      python3 "$HERE/report.py" --logs "$log" --out "$html" --eip-mbps "${EIP_MBPS:-100}" || true
      echo "[perf-k6] 本次报告：$html"
      # 完整报告：聚合本次目录 + 历史目录
      local AGG="$run_dir/perf_report_ALL_${run_ts}.html"
      HIST="$ROOT/deploy/logs/perf_reports"
      DIRS=(--log-dir "$run_dir")
      [ -d "$HIST" ] && DIRS+=(--log-dir "$HIST")
      python3 "$HERE/report.py" "${DIRS[@]}" --out "$AGG" --eip-mbps "${EIP_MBPS:-100}" || true
      cp -f "$AGG" "$REPORT_DIR/perf_report_ALL_latest.html" 2>/dev/null || true
      echo "[perf-k6] 完整报告：$AGG（副本 $REPORT_DIR/perf_report_ALL_latest.html）" ;;
  esac
  return $rc
}

# 阶梯压测核心：固定副本数，VU 从 start 递增到 max，SLO 破线即停。
# 用 report.py --check 判定（不依赖 k6 退出码：stage.sh 末尾是 grep，rc 不可靠）。
# 累加到 RAMP_DIRS 供调用方出汇总报告。
run_ramp() {
  local tgt="$1" start="$2" step="$3" max="$4" dur="$5" rep="${6:-}" pfx="${7:-ramp}"
  local p rtag="" v chk chkrc tag hit=0
  case "$tgt" in *://*) p=public ;; *) p=clusterip ;; esac
  [ -n "$rep" ] && rtag="r${rep}-"
  echo "[perf-k6] ${pfx} 开始：target=$tgt  ${start}→${max} 步长${step} 每阶段${dur}${rep:+ 副本=$rep}"
  v=$start
  while [ "$v" -le "$max" ]; do
    echo ""
    echo "[perf-k6] ===== ${pfx} 阶段 VU=$v${rep:+ (${rep} 副本)} ====="
    DESC="${pfx}-${p}-${rtag}vu${v}-dur${dur}"
    tag="${pfx}_${tgt//[^a-zA-Z0-9]/_}_${rtag}${v}"
    LAST_RUN_DIR=""; LAST_LOG=""
    local args=("TARGET_SVC=$tgt" "VUS=$v" "DUR=$dur")
    [ -n "$rep" ] && args+=("REQ_REPLICAS=$rep")
    run_body stage.sh "$tag" "${args[@]}"
    [ -n "$LAST_RUN_DIR" ] && RAMP_DIRS+=("$LAST_RUN_DIR")
    # SLO 判定：破线即视为到达该副本数的容量上限
    if [ -s "${LAST_LOG:-}" ]; then
      chk=$(python3 "$HERE/report.py" --check "$LAST_LOG" --eip-mbps "${EIP_MBPS:-100}" 2>&1); chkrc=$?
      echo "  $chk"
      if [ "$chkrc" -ne 0 ]; then
        echo "[perf-k6] VU=$v 破线 ⇒ 该副本数下容量上限已确认，停止递增。"
        hit=1
        break
      fi
    else
      echo "[perf-k6] VU=$v 未产出日志，判定失败，停止递增。"
      hit=1
      break
    fi
    v=$((v + step))
    if [ "$v" -le "$max" ]; then
      echo "[perf-k6] 等待 15s 冷却后进入下一阶段..."
      sleep 15
    fi
  done
  [ "$hit" -eq 0 ] && echo "[perf-k6] [!] 跑到 max=${max} 仍未破线${rep:+（${rep} 副本）}⇒ 容量高于本阶梯上限，请加大 max 重跑"
  return 0
}

# 把一组 run_dir 聚合成一份 HTML，并刷新根目录 latest 副本
emit_report() {
  local pfx="$1"; shift
  local dirs=("$@") ts out
  [ "${#dirs[@]}" -gt 0 ] || { echo "[perf-k6] 无阶段数据，跳过汇总报告"; return 0; }
  ts=$(date +%Y%m%d-%H%M%S)
  out="$REPORT_DIR/perf_report_${pfx}_${ts}.html"
  local args=()
  for d in "${dirs[@]}"; do args+=(--log-dir "$d"); done
  local HIST="$ROOT/deploy/logs/perf_reports"
  [ -d "$HIST" ] && args+=(--log-dir "$HIST")
  python3 "$HERE/report.py" "${args[@]}" --out "$out" --eip-mbps "${EIP_MBPS:-100}" || true
  cp -f "$out" "$REPORT_DIR/perf_report_ALL_latest.html" 2>/dev/null || true
  echo "[perf-k6] ${pfx} 汇总报告：$out（共 ${#dirs[@]} 阶段）"
}

# 长阶梯被动中断（Ctrl+C / IDE 停止）时，已完成的阶段照常出报告，不白跑
RAMP_DIRS=()
LADDER_DIRS=()
on_interrupt() {
  trap '' INT   # 出报告期间不再被二次中断
  echo ""
  echo "[perf-k6] 收到 SIGINT（Ctrl+C / IDE 停止）。已完成的阶段仍会出报告。"
  local pool=()
  if [ "${#LADDER_DIRS[@]}" -gt 0 ]; then pool=("${LADDER_DIRS[@]}"); fi
  if [ "${#RAMP_DIRS[@]}" -gt 0 ]; then pool+=("${RAMP_DIRS[@]}"); fi
  if [ "${#pool[@]}" -gt 0 ]; then
    emit_report "partial" "${pool[@]}"
  else
    echo "[perf-k6] 尚无完成的阶段，无可出报告。"
  fi
  exit 130
}
trap on_interrupt INT

case "$ACTION" in
  stage)
    K6JS_FILE="$HERE/sse.js"
    # TGT 可为 Service 名（集群内直连）或完整 URL（如 https://perf.likha.hk，走公网 ALB 路径）
    TGT="${1:?stage 需要 <target-svc|url>}"; VUS="${2:?stage 需要 <vus>}"; DUR="${3:-120s}"
    case "$TGT" in *://*) P=public ;; *) P=clusterip ;; esac
    DESC="stage-${P}-vu${VUS}-dur${DUR}"
    run_body stage.sh "stage_${TGT//[^a-zA-Z0-9]/_}_${VUS}" "TARGET_SVC=$TGT" "VUS=$VUS" "DUR=$DUR" ;;
  ramp)
    # 阶梯递增压测：逐级加 VU，找系统真实饱和点（错误率/延迟劣化即终止）
    # usage: ramp <target-svc|url> [start=300] [step=300] [max=3000] [dur=90s]
    K6JS_FILE="$HERE/sse.js"
    TGT="${1:?ramp 需要 <target-svc|url>}"
    RAMP_DIRS=()
    run_ramp "$TGT" "${2:-300}" "${3:-300}" "${4:-3000}" "${5:-90s}" "" "ramp"
    emit_report "ramp" "${RAMP_DIRS[@]}" ;;
  ladder)
    # 副本阶梯：先在 1 副本下压到瓶颈，再扩到 2 副本用同参数重压，直接看扩容收益
    # usage: ladder <target-svc> [start=300] [step=300] [max=3000] [dur=90s] [replicas=1,2]
    K6JS_FILE="$HERE/sse.js"
    TGT="${1:-perf-new-api-slave}"
    L_START="${2:-300}"; L_STEP="${3:-300}"; L_MAX="${4:-3000}"; L_DUR="${5:-90s}"
    L_REPS="${6:-1,2}"
    case "$TGT" in *://*) echo "[!] ladder 只用于集群内直连（需要能 scale），不支持 URL"; exit 2 ;; esac
    LADDER_DIRS=()
    IFS=',' read -r -a REP_ARR <<< "$L_REPS"
    for R in "${REP_ARR[@]}"; do
      echo ""
      echo "[perf-k6] ########## 副本数 = $R ##########"
      RAMP_DIRS=()
      run_ramp "$TGT" "$L_START" "$L_STEP" "$L_MAX" "$L_DUR" "$R" "ladder"
      LADDER_DIRS+=("${RAMP_DIRS[@]}")
      # 副本之间留出稳定窗口，避免上一轮残留连接影响扩容后的基线
      echo "[perf-k6] 副本 $R 测完，等待 30s 待连接排空..."
      sleep 30
    done
    emit_report "ladder" "${LADDER_DIRS[@]}"
    echo "[perf-k6] 提示：报告「副本数」行可区分 1/2 副本；同 VU 档横向对比即为扩容收益。" ;;
  scale)
    # 仅调整副本数（不带压测），用于压测后恢复现场
    # usage: scale <replicas> [deploy=perf-new-api-slave]
    N="${1:?scale 需要 <replicas>}"; D="${2:-perf-new-api-slave}"
    echo "[perf-k6] scale deploy/$D -> $N"
    run_body scale.sh "scale_${N}" "REQ_REPLICAS=$N" "REQ_DEPLOY=$D" ;;
  dual1500)
    K6JS_FILE="$HERE/sse.js"
    EACH="${1:-750}"; DUR="${2:-120s}"
    DESC="dual-slave2-vu$((EACH * 2))-dur${DUR}"
    run_body dual1500.sh dual1500 "VUS=$((EACH * 2))" "DUR=$DUR" ;;
  summary)
    run_body summary.sh summary "JOBS=$*" ;;
  readback)
    run_body readback.sh readback ;;
  shard)
    V="${1:-1500}"; D="${2:-120s}"; N="${3:-4}"
    K6JS_FILE="$HERE/sse.js"; DESC="shard-${N}x-vu${V}-dur${D}"
    run_body sharded.sh "shard_${N}" "VUS=$V" "DUR=$D" "SHARDS=$N" ;;
  burst)
    V="${1:-1500}"; D="${2:-90s}"
    K6JS_FILE="$HERE/s3_burst.js"; DESC="s3-burst-vu${V}-dur${D}"
    run_body scenario.sh "s3_${V}" "MODE=burst" "VUS=$V" "DUR=$D" ;;
  admin)
    R="${1:-800}"; D="${2:-60s}"
    K6JS_FILE="$HERE/s4_admin.js"; DESC="s4-admin-rate${R}-dur${D}"
    run_body scenario.sh "s4_${R}" "MODE=admin" "RATE=$R" "DUR=$D" ;;
  degrade)
    V="${1:-300}"; D="${2:-90s}"
    DESC="s5-degrade-vu${V}-dur${D}"
    run_body scenario.sh "s5_${V}" "MODE=degrade" "VUS=$V" "DUR=$D" ;;
  rolling)
    V="${1:-300}"; D="${2:-120s}"
    DESC="s10-rolling-vu${V}-dur${D}"
    run_body scenario.sh "s10_${V}" "MODE=rolling" "VUS=$V" "DUR=$D" ;;
  long)
    M="${1:-13}"
    K6JS_FILE="$HERE/s9_long.js"; DESC="s9-long-${M}min"
    run_body scenario.sh "s9_${M}" "MODE=long" "MIN=$M" "BASE_URL=${BASE_URL:-https://perf.likha.hk}" ;;
  *) echo "[!] 未知动作：$ACTION（stage|ramp|ladder|dual1500|summary|readback）"; exit 2 ;;
esac
