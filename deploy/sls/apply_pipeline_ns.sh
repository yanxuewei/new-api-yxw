#!/usr/bin/env bash
# 任务 26 追加（2026-10-08 建 / 2026-10-09 扩至 app-file）：SLS 时间戳精度（控制台时间列精确到 ms）
#   —— 两集群「应用 + 校验」一键脚本
#
# 用法：
#   bash deploy/sls/apply_pipeline_ns.sh apply  [stdout|file|all]   # 默认 all
#   bash deploy/sls/apply_pipeline_ns.sh verify [stdout|file|all]   # 默认 all
#
# 两个日志库的精度来源不同，别混：
#   · app-stdout：源=容器 runtime 字段 `_time_`（自带纳秒）→ processor_gotime(SourceKey=_time_)
#   · app-file  ：源=**日志行内容**（需 new-api 日志格式先带毫秒，见 UPSTREAM_CHANGES.md）
#                 → processor_regex(抓 log_ts) + processor_gotime(SourceKey=log_ts, SetTime)
#
# 关键点速查（四处坑见 deploy/docs/Day3任务26_SLS与可观测_执行报告.md「追加 / 追加 4」）：
#   · __time__ 恒为秒级；ms 靠 __time_ns_part__（0~999999999）
#   · 必须「global.EnableTimestampNanosecond + 处理器 SetTime」两件套（源码 gotime/processor_gotime.go）
#   · 开关只有 pipeline 的 global 能持久化；老式 CRD / UpdateConfig / SD 全被剥键
#   · CLI 查 SLS 必须显式 --region，否则跨地域查项目会报 ProjectNotExist 假错
#   · processor_regex 的 FullMatch 默认 true（要求整字段匹配）→ 抓行内子串必须显式 false
set -uo pipefail

MNLCID=cd57e40ce9a634c1698c2f5c5e09bd93c
SGCID=ca75829e3492d491d9d434de087913798
MNLREGION=ap-southeast-6
SGREGION=ap-southeast-1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# 目标 → 清单文件名
target_manifest() {  # target_manifest <site> <stdout|file>
  case "$1:$2" in
    mnl:stdout) echo "$HERE/clusterpipelineconfig-app-stdout.yaml" ;;
    sg:stdout)  echo "$HERE/clusterpipelineconfig-app-stdout-sg.yaml" ;;
    mnl:file)   echo "$HERE/clusterpipelineconfig-app-file.yaml" ;;
    sg:file)    echo "$HERE/clusterpipelineconfig-app-file-sg.yaml" ;;
    *) return 1 ;;
  esac
}
target_oldcrd() {  # 老式 CRD 名（迁移期需删，避免同容器双采集）
  case "$2" in stdout) echo new-api-app-stdout ;; file) echo new-api-app-file ;; esac
}

site_cid()  { case "$1" in mnl) echo "$MNLCID" ;; sg) echo "$SGCID" ;; esac; }
site_reg()  { case "$1" in mnl) echo "$MNLREGION" ;; sg) echo "$SGREGION" ;; esac; }

apply_one() {  # apply_one <site> <stdout|file>
  local site=$1 target=$2 cid region manifest
  cid=$(site_cid "$site"); region=$(site_reg "$site")
  manifest=$(target_manifest "$site" "$target") || { echo "[!] 未知目标 $site:$target"; return 1; }
  echo "== [$site/$target] apply $(basename "$manifest")"
  local body="/tmp/ns_apply_${site}_${target}_$$.sh"
  { echo "kubectl apply -f - <<'YAMLEOF'"; tr -d '\r' < "$manifest"; echo "YAMLEOF"
    echo "kubectl -n new-api delete aliyunlogconfig $(target_oldcrd "$site" "$target") --ignore-not-found"
    echo "sleep 40"; } > "$body"
  bash "$REPO/deploy/lib/ack_remote.sh" "$site" "$body" || echo "[!] $site/$target 远端执行异常"
  rm -f "$body"
  echo "-- [$site/$target] SLS 侧复核（global / processors）"
  aliyun sls GetLogtailPipelineConfig --region "$region" --project "k8s-log-$cid" \
    --configName "new-api-app-$target-ns" | jq -c '{global,processors}' 2>/dev/null || echo "[!] 配置未就绪"
}

verify_one() {  # verify_one <site> <stdout|file>
  local site=$1 target=$2 cid region from to body
  cid=$(site_cid "$site"); region=$(site_reg "$site")
  from=$(date -d '15 minutes ago' +%s); to=$(date +%s)
  body=$(printf '{"from":%s,"to":%s,"query":"*","line":6,"reverse":true}' "$from" "$to")
  echo "== [$site/$target] 最新日志"
  if [ "$target" = stdout ]; then
    aliyun sls GetLogsV2 --region "$region" --project "k8s-log-$cid" --logstore app-stdout --body "$body" \
      | jq -r '.data[] | "\(.__time__)\tns=\(.__time_ns_part__ // "NULL")\t\(._time_)"' 2>/dev/null
  else
    aliyun sls GetLogsV2 --region "$region" --project "k8s-log-$cid" --logstore app-file --body "$body" \
      | jq -r '.data[] | "\(.__time__)\tns=\(.__time_ns_part__ // "NULL")\tlog_ts=\(.log_ts // "-")\t\(.content)"' 2>/dev/null
  fi
}

run_targets() {  # run_targets <apply|verify> <stdout|file|all>
  local fn=$1 which=$2 t
  case "$which" in
    stdout|file) "$fn" mnl "$which"; "$fn" sg "$which" ;;
    all) for t in stdout file; do "$fn" mnl "$t"; "$fn" sg "$t"; done ;;
    *) echo "用法: $0 apply|verify [stdout|file|all]"; exit 2 ;;
  esac
}

case "${1:-}" in
  apply)  run_targets apply_one  "${2:-all}" ;;
  verify) run_targets verify_one "${2:-all}" ;;
  *) echo "用法: $0 apply|verify [stdout|file|all]"; exit 2 ;;
esac
