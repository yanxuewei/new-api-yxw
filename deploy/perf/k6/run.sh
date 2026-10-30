#!/usr/bin/env bash
# deploy/perf/k6/run.sh —— 压测入口（本机执行；把 sse.js 与动作体打包后经云助手投递到雅加达 dev 节点）
#
# 通道：deploy/lib/ack_remote_jkt_dev.sh（ECS 云助手 → 节点内 kubectl，15 分钟临时私网 kubeconfig）
# 为什么这么绕：集群 API Server 仅内网、本机无法直连；k6 Job 与 mock 都在集群内，客户端不能成为瓶颈（任务 33 坑 1）。
#
# usage:
#   bash deploy/perf/k6/run.sh stage <target-svc|url> <vus> <duration>                 # 单档，如 stage perf-new-api-slave 300 120s
#   bash deploy/perf/k6/run.sh arrival <target-svc|url> <total-rps> [dur] [shards] [reps] # 开环到达率（回答"网关能接多少 QPS"），默认 120s / 3 分片
#   bash deploy/perf/k6/run.sh qps <target-svc|url> [start] [step] [max] [dur] [shards] [reps] # 阶梯自动找 QPS 上限（默认非流式 relay-chat.js）
#   bash deploy/perf/k6/run.sh sweep <target-svc|url> [reps] [start] [step] [max] [dur] # 固定副本数逐档扫描，默认 1 副本、400 起、+100、上限2000、每档120s
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
K6JS_FILE="${K6JS_FILE:-$HERE/sse.js}"   # 可被 env 覆盖，用于接入 perf/k6/*.js（S1/S2/S3）
K6JS_OVERRIDE="$K6JS_FILE"               # 记住外部指定值：各动作体内会重新赋默认脚本，需在 run_body 里纠正
[ "$K6JS_OVERRIDE" = "$HERE/sse.js" ] && K6JS_OVERRIDE=""

[ -s "$K6JS_FILE" ] || { echo "[!] 缺 $K6JS_FILE"; exit 1; }
[ -x "$REMOTE" ] || { echo "[!] 缺通道脚本 $REMOTE"; exit 1; }

# 集群内压测只需要这几个**本机**工具：k6 在集群里以 Job 镜像运行，本机无需安装
for _c in gzip base64 python3; do
  command -v "$_c" >/dev/null 2>&1 || {
    echo "[!] 本机缺 $_c（打包脚本/生成报告需要；k6 本身在集群内跑，无需本机安装）"
    echo "    Debian/Ubuntu: sudo apt-get install -y $_c"
    echo "    macOS:         brew install $_c"
    echo "    Windows:       在 WSL 内执行上述命令"
    exit 1
  }
done

ACTION="${1:?action: stage|sweep|ramp|ladder|dual1500|summary|readback}"; shift || true

# 节点侧需要的最小上下文：sse.js 载荷（Base64）+ 动作参数。值不进 argv，只进本次命令体。
header() {
  cat <<'HDR'
#!/bin/bash
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/local/bin:$PATH
HDR
  # 压测命令不携带脚本：脚本先由 install_script.sh 装成 ConfigMap，避免命令体超限。
  if [ "${WITH_SCRIPT:-0}" = "1" ]; then
    printf "export K6JS_GZ='%s'\n" "$(gzip -9 -c "$K6JS_FILE" | base64 -w0)"
  fi
  printf "export SCRIPT_ID='%s@%s'\n" "$(basename "$K6JS_FILE")" "$(sha256sum "$K6JS_FILE" | cut -c1-12)"
  # 云助手命令体上限约 15KB：采样库与 body 都压缩投递，展开后 eval，功能不变。
  printf "export LIB_GZ='%s'\n" "$(gzip -9 -c "$HERE/lib/sampling.sh" | base64 -w0)"
  local kv
  for kv in "$@"; do printf "export %s='%s'\n" "${kv%%=*}" "${kv#*=}"; done
}

body_payload() {
  printf "export BODY_GZ='%s'\n" "$(gzip -9 -c "$1" | base64 -w0)"
  cat <<'LOAD'
LIB_SRC="$(printf '%s' "$LIB_GZ" | base64 -d | gzip -d)"
[ -n "$LIB_SRC" ] || { echo "[!] 采样库解码失败"; exit 2; }
eval "$LIB_SRC"
BODY_SRC="$(printf '%s' "$BODY_GZ" | base64 -d | gzip -d)"
[ -n "$BODY_SRC" ] || { echo "[!] body 解码失败"; exit 2; }
eval "$BODY_SRC"
LOAD
}

REPORT_DIR="$ROOT/deploy/perf/perf_reports"
DESC=""   # 本次压测参数摘要，由分发处赋值，用于报告文件名

# 脚本按内容寻址：同内容复用同一 ConfigMap，避免压测命令携带脚本超限。
script_cm() {
  printf 'k6-sse-%s' "$(sha256sum "$K6JS_FILE" | cut -c1-12)"
}

install_script_configmap() {
  local cm="$1" full out rc=0
  full="$(mktemp "${TMPDIR:-/tmp}/perf_k6_install.XXXXXX.sh")" || return 1
  { WITH_SCRIPT=1 header "K6JS_CM=$cm"; body_payload "$BODIES/install_script.sh"; } > "$full"
  out=$(bash "$REMOTE" "$full" 2>&1) || rc=$?
  rm -f "$full"
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | grep -q "configmap/$cm 就绪" || return 1
  return 0
}

run_body() {
  local body="$1" tag="$2"; shift 2
  # 外部指定了脚本就以它为准（动作体内的 K6JS_FILE=默认脚本 只是兜底）
  [ -n "${K6JS_OVERRIDE:-}" ] && K6JS_FILE="$K6JS_OVERRIDE"
  [ -s "$BODIES/$body" ] || { echo "[!] 缺 body：$BODIES/$body"; exit 1; }
  umask 077
  local full cm=""
  case "$body" in
    stage.sh|dual1500.sh|sharded.sh|arrival.sh|qps_ladder.sh|scenario.sh)
      cm=$(script_cm)
      echo "[perf-k6] 下发脚本 ConfigMap：$cm"
      install_script_configmap "$cm" || { echo "[!] 脚本下发失败，终止"; return 2; } ;;
  esac
  full="$(mktemp "${TMPDIR:-/tmp}/perf_k6_${tag}.XXXXXX.sh")" || { echo "[!] 临时脚本创建失败"; exit 1; }
  { header "K6JS_CM=$cm" "$@"; body_payload "$BODIES/$body"; } > "$full"
  echo "[perf-k6] action=$tag payload=$# body=$(wc -c <"$full")B"
  # 压测开始前先创建本次专属子目录，后续所有中间文件和报告直接落在这里
  local run_ts run_dir
  run_ts=$(date +%Y%m%d-%H%M%S)
  run_dir="$REPORT_DIR/$run_ts"
  mkdir -p "$run_dir"
  LAST_RUN_DIR="$run_dir"   # 供调用方（如 ramp）收集各阶段目录
  echo "[perf-k6] 本次输出目录：$run_dir"
  # 捕获远端输出：一边打屏，一边落盘（报告的数据源），跑完自动渲染 HTML
  local out rc log samples safe
  rc=0
  out=$(bash "$REMOTE" "$full" 2>&1) || rc=$?
  printf '%s\n' "$out"
  rm -f "$full"
  log="$run_dir/${run_ts}-${tag}.log"
  samples="${log%.log}.samples.tsv"
  # 逐 Pod 采样序列与摘要分开归档：日志只留可解析指标，原始时间序列单独存 tsv。
  # 无采样标记时全部内容留在日志，不能截掉任何一行。
  printf '%s\n' "$out" | awk -v s="$samples" '
    /^===SAMPLES===$/ {dump=1; next}
    dump {print > s; next}
    {print}
  ' > "$log"
  [ -s "$samples" ] || rm -f "$samples"
  printf 'runner_rc=%s\n' "$rc" >> "$log"
  LAST_LOG="$log"   # 供调用方（ramp/ladder）做 SLO 判定
  if [ -s "$samples" ]; then
    echo "[perf-k6] 日志：$log（采样序列：$samples）"
  else
    echo "[perf-k6] 日志：$log"
  fi
  case "$tag" in
    stage_*|dual1500|s3_*|s4_*|s5_*|s9_*|s10_*|shard_*)
      # 文件名 = perf_report_<参数摘要>_<启动时刻>.html（参数里的路径/冒号等替换为 -）
      safe=$(printf '%s' "${DESC:-$tag}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g;s/-*$//')
      local html="$run_dir/perf_report_${safe}_${run_ts}.html"
      python3 "$HERE/report.py" --logs "$log" --out "$html" --json "$run_dir/${run_ts}-${tag}.json" --eip-mbps "${EIP_MBPS:-100}" || true
      echo "[perf-k6] 本次报告：$html"
      # 完整报告：递归聚合全部历史运行目录，而不是只取本次目录
      local AGG="$run_dir/perf_report_ALL_${run_ts}.html"
      HIST="$ROOT/deploy/logs/perf_reports"
      DIRS=(--log-dir "$REPORT_DIR")
      [ -d "$HIST" ] && DIRS+=(--log-dir "$HIST")
      python3 "$HERE/report.py" "${DIRS[@]}" --out "$AGG" --eip-mbps "${EIP_MBPS:-100}" || true
      cp -f "$AGG" "$REPORT_DIR/perf_report_ALL_latest.html" 2>/dev/null || true
      echo "[perf-k6] 完整报告：$AGG（副本 $REPORT_DIR/perf_report_ALL_latest.html）" ;;
    arrival_*)
      # 开环档只出单次报告、不并入 ALL：横轴是 rps 而不是 VU，混进 VU 曲线会误导
      safe=$(printf '%s' "${DESC:-$tag}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/--*/-/g;s/-*$//')
      local html="$run_dir/perf_report_${safe}_${run_ts}.html"
      python3 "$HERE/report.py" --logs "$log" --out "$html" --json "$run_dir/${run_ts}-${tag}.json" --eip-mbps "${EIP_MBPS:-100}" || true
      echo "[perf-k6] 本次报告：$html（开环档不并入 ALL）" ;;
    qps_*)
      # 多档阶梯不是"一次运行"，report.py 的单次口径套不上：结论直接看 body 打印的 [QPS] 行
      echo "[perf-k6] 阶梯结果见上方 [QPS] 行与末行结论；未生成 HTML" ;;
  esac
  case "$body" in
    stage.sh|dual1500.sh|sharded.sh|arrival.sh|scenario.sh)
      local verdict check_rc=0
      verdict=$(python3 "$HERE/report.py" --check "$log" --eip-mbps "${EIP_MBPS:-100}" 2>&1) || check_rc=$?
      printf '%s\n' "$verdict"
      case "$check_rc:$verdict" in
        '0:[check] PASS '*) return 0 ;;
        '1:[check] FAIL '*) return 1 ;;
        *) return 2 ;;
      esac ;;

  esac
  return "$rc"
}

# 阶梯压测核心：固定副本数，VU 从 start 递增到 max，SLO 破线即停。
# report.py 同时检查场景阈值、k6 退出状态与采集完整性。
# 累加到 RAMP_DIRS 供调用方出汇总报告。
run_ramp() {
  local tgt="$1" start="$2" step="$3" max="$4" dur="$5" rep="${6:-}" pfx="${7:-ramp}"
  local p rtag="" v chkrc tag hit=0 prev_log="" prev_vu=""
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
    chkrc=0
    run_body stage.sh "$tag" "${args[@]}" || chkrc=$?
    [ -n "$LAST_RUN_DIR" ] && RAMP_DIRS+=("$LAST_RUN_DIR")
    if [ -s "${LAST_LOG:-}" ]; then
      case "$chkrc" in
        0) prev_log="$LAST_LOG"; prev_vu="$v" ;;
        1) echo "[perf-k6] VU=$v 未通过 SLO，停止递增；仅记录失败档，不宣称精确容量上限。"; hit=1; break ;;
        *) echo "[perf-k6] VU=$v 数据不完整或无法评估，停止递增；不能用作容量边界。"; return 2 ;;
      esac
    else
      echo "[perf-k6] VU=$v 未产出日志，停止递增；不能用作容量边界。"
      return 2
    fi
    v=$((v + step))
    if [ "$v" -le "$max" ]; then
      echo "[perf-k6] 等待 15s 冷却后进入下一阶段..."
      sleep 15
    fi
  done
  [ "$hit" -eq 0 ] && echo "[perf-k6] 跑到 max=${max} 仍未破线${rep:+（${rep} 副本）}；仅证明该实测档通过，尚未找到失败边界。"
  if [ -n "$prev_log" ]; then
    echo "[perf-k6] 本组最优通过档（${prev_vu} VU${rep:+，${rep} 副本}）："
    python3 "$HERE/report.py" --check "$prev_log" --eip-mbps "${EIP_MBPS:-100}" 2>&1 | sed 's/^\[check\] /  /'
  fi
  return "$hit"
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
  # 单组报告只包含本次阶段的目录；历史目录仅用于 ALL 全量报告，避免内网报告混入公网数据。
  python3 "$HERE/report.py" "${args[@]}" --out "$out" --eip-mbps "${EIP_MBPS:-100}" || true
  # 本次分阶段报告只覆盖本次阶段；ALL_latest 仍代表全部历史，避免把它缩成一次子集。
  local full="$REPORT_DIR/perf_report_ALL_${ts}.html" hist_args=(--log-dir "$REPORT_DIR")
  local HIST="$ROOT/deploy/logs/perf_reports"
  [ -d "$HIST" ] && hist_args+=(--log-dir "$HIST")
  python3 "$HERE/report.py" "${hist_args[@]}" --out "$full" --eip-mbps "${EIP_MBPS:-100}" || true
  cp -f "$full" "$REPORT_DIR/perf_report_ALL_latest.html" 2>/dev/null || true
  echo "[perf-k6] ${pfx} 汇总报告：$out（共 ${#dirs[@]} 阶段）"
  echo "[perf-k6] 全量报告：$full（副本 $REPORT_DIR/perf_report_ALL_latest.html）"
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
  # 中断时压测环境可能已改过副本数或 mock 配置：给出可执行的恢复依据，不静默留坑。
  local before=""
  if [ -n "${LAST_LOG:-}" ] && [ -s "$LAST_LOG" ]; then
    before=$(grep -m1 '^replicas_before=' "$LAST_LOG" 2>/dev/null | cut -d= -f2)
  fi
  if [ -n "$before" ] && [ "$before" != "0" ]; then
    echo "[perf-k6] 注意：本次压测前副本数=$before，恢复命令：bash $HERE/run.sh scale $before"
  else
    echo "[perf-k6] 注意：若本次动了副本数或 mock 配置，请用 run.sh scale <原副本数> 与 mock_ctl.sh 恢复；具体值见最近日志的 replicas_before / mock_config。"
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
  sweep)
    # 同一路径 + 同一副本数下逐档扫描：先 scale 到指定副本，再从 start 起每档 +step，
    # 首个 SLO 失败即停；结束时打印本组最优通过档。
    # usage: sweep <target-svc|url> [reps=1] [start=400] [step=100] [max=2000] [dur=120s]
    K6JS_FILE="$HERE/sse.js"
    TGT="${1:?sweep 需要 <target-svc|url>}"
    S_REPS="${2:-1}"; S_START="${3:-400}"; S_STEP="${4:-100}"; S_MAX="${5:-2000}"; S_DUR="${6:-120s}"
    case "$TGT" in *://*) S_PATH=public ;; *) S_PATH=clusterip ;; esac
    echo "[perf-k6] sweep：${S_PATH} 路径，固定 ${S_REPS} 副本，${S_START}→${S_MAX} 步长${S_STEP}，每档${S_DUR}"
    RAMP_DIRS=()
    RC=0
    run_ramp "$TGT" "$S_START" "$S_STEP" "$S_MAX" "$S_DUR" "$S_REPS" "sweep" || RC=$?
    emit_report "sweep_${S_PATH}_r${S_REPS}" "${RAMP_DIRS[@]}"
    exit "$RC" ;;
  ramp)
    # 阶梯递增压测：逐级加 VU，找系统真实饱和点（错误率/延迟劣化即终止）
    # usage: ramp <target-svc|url> [start=300] [step=300] [max=3000] [dur=90s]
    K6JS_FILE="$HERE/sse.js"
    TGT="${1:?ramp 需要 <target-svc|url>}"
    RAMP_DIRS=()
    RC=0
    run_ramp "$TGT" "${2:-300}" "${3:-300}" "${4:-3000}" "${5:-90s}" "" "ramp" || RC=$?
    emit_report "ramp" "${RAMP_DIRS[@]}"
    exit "$RC" ;;
  ladder)
    # 副本阶梯：先在 1 副本下压到瓶颈，再扩到 2 副本用同参数重压，直接看扩容收益
    # usage: ladder <target-svc> [start=300] [step=300] [max=3000] [dur=90s] [replicas=1,2]
    K6JS_FILE="$HERE/sse.js"
    TGT="${1:-perf-new-api-slave}"
    L_START="${2:-300}"; L_STEP="${3:-300}"; L_MAX="${4:-3000}"; L_DUR="${5:-90s}"
    L_REPS="${6:-1,2}"
    case "$TGT" in *://*) echo "[!] ladder 只用于集群内直连（需要能 scale），不支持 URL"; exit 2 ;; esac
    LADDER_DIRS=()
    LADDER_RC=0
    IFS=',' read -r -a REP_ARR <<< "$L_REPS"
    for R in "${REP_ARR[@]}"; do
      echo ""
      echo "[perf-k6] ########## 副本数 = $R ##########"
      RAMP_DIRS=()
      RC=0
      run_ramp "$TGT" "$L_START" "$L_STEP" "$L_MAX" "$L_DUR" "$R" "ladder" || RC=$?
      LADDER_DIRS+=("${RAMP_DIRS[@]}")
      [ "$RC" -gt "$LADDER_RC" ] && LADDER_RC=$RC
      [ "$RC" -ge 2 ] && break
      # 副本之间留出稳定窗口，避免上一轮残留连接影响扩容后的基线
      echo "[perf-k6] 副本 $R 测完，等待 30s 待连接排空..."
      sleep 30
    done
    emit_report "ladder" "${LADDER_DIRS[@]}"
    echo "[perf-k6] 提示：仅比较配置完整且相同的同 VU 档，不跨副本拟合容量。"
    exit "$LADDER_RC" ;;
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
  arrival)
    # 开环到达率：按目标 rps 发请求，不受单请求耗时反压 ⇒ 才能回答"网关能接多少 QPS"
    TGT="${1:?arrival 需要 <target-svc|url>}"; R="${2:?arrival 需要 <总目标 rps>}"
    D="${3:-120s}"; N="${4:-3}"
    K6JS_FILE="$HERE/sse_arrival.js"
    DESC="arrival-${TGT//[^a-zA-Z0-9]/_}-${R}rps-dur${D}-s${N}"
    ARGS=("TARGET_SVC=$TGT" "TOTAL_RATE=$R" "DUR=$D" "SHARDS=$N")
    [ -n "${5:-}" ] && ARGS+=("REQ_REPLICAS=$5")
    run_body arrival.sh "arrival_${R}" "${ARGS[@]}" ;;
  qps)
    # 开环阶梯：一次调用内连续升档，首个 FAIL 即停 ⇒ 直接给出「最高通过 QPS」
    # 默认用 relay-chat.js（非流式）；流式请显式 K6JS_FILE=$HERE/relay-chat.js 并置 STREAM=true 的环境语义
    TGT="${1:?qps 需要 <target-svc|url>}"
    S="${2:-200}"; SP="${3:-200}"; M="${4:-4000}"; D="${5:-60s}"; N="${6:-8}"
    # 注意：K6JS_FILE 在脚本开头已被初始化为 sse.js，这里必须优先取「外部覆盖值」
    K6JS_FILE="${K6JS_OVERRIDE:-$HERE/relay-chat.js}"
    DESC="qps-${TGT//[^a-zA-Z0-9]/_}-${S}-${M}"
    ARGS=("TARGET_SVC=$TGT" "START=$S" "STEP=$SP" "MAX=$M" "DUR=$D" "SHARDS=$N")
    [ -n "${7:-}" ] && ARGS+=("REQ_REPLICAS=$7")
    run_body qps_ladder.sh "qps_${S}_${M}" "${ARGS[@]}" ;;
  *) echo "[!] 未知动作：$ACTION（stage|arrival|sweep|ramp|ladder|dual1500|shard|summary|readback）"; exit 2 ;;
esac
