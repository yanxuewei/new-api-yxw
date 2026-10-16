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
JKTCID=cb0abf5bc06034f7bbdb991752f6f3e62
MNLREGION=ap-southeast-6
SGREGION=ap-southeast-1
JKTREGION=ap-southeast-5
SITES="mnl sg jkt"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# 目标 → 清单文件名
target_manifest() {  # target_manifest <site> <stdout|file>
  case "$1:$2" in
    mnl:stdout) echo "$HERE/clusterpipelineconfig-app-stdout.yaml" ;;
    sg:stdout)  echo "$HERE/clusterpipelineconfig-app-stdout-sg.yaml" ;;
    mnl:file)   echo "$HERE/clusterpipelineconfig-app-file.yaml" ;;
    sg:file)    echo "$HERE/clusterpipelineconfig-app-file-sg.yaml" ;;
    jkt:stdout) echo "$HERE/clusterpipelineconfig-app-stdout-jkt.yaml" ;;
    jkt:file)   echo "$HERE/clusterpipelineconfig-app-file-jkt.yaml" ;;
    *) return 1 ;;
  esac
}
target_oldcrd() {  # 老式 CRD 名（迁移期需删，避免同容器双采集；jkt 无老式 CR）
  case "$2" in stdout) echo new-api-app-stdout ;; file) echo new-api-app-file ;; esac
}

site_cid()  { case "$1" in mnl) echo "$MNLCID" ;; sg) echo "$SGCID" ;; jkt) echo "$JKTCID" ;; esac; }
site_reg()  { case "$1" in mnl) echo "$MNLREGION" ;; sg) echo "$SGREGION" ;; jkt) echo "$JKTREGION" ;; esac; }
# jkt dev 走独立执行器（临时私网 kubeconfig 通道），ns 也不同（newapi-dev）
site_remote() { case "$1" in jkt) echo "$REPO/deploy/lib/ack_remote_jkt_dev.sh" ;; *) echo "$REPO/deploy/lib/ack_remote.sh" ;; esac; }
site_ns()     { case "$1" in jkt) echo "newapi-dev" ;; *) echo "new-api" ;; esac; }

apply_one() {  # apply_one <site> <stdout|file>
  local site=$1 target=$2 cid region manifest
  cid=$(site_cid "$site"); region=$(site_reg "$site")
  manifest=$(target_manifest "$site" "$target") || { echo "[!] 未知目标 $site:$target"; return 1; }
  echo "== [$site/$target] apply $(basename "$manifest")"
  local body="/tmp/ns_apply_${site}_${target}_$$.sh"
  { echo "kubectl apply -f - <<'YAMLEOF'"; tr -d '\r' < "$manifest"; echo "YAMLEOF"
    if [ "$site" != "jkt" ]; then
      echo "kubectl -n $(site_ns "$site") delete aliyunlogconfig $(target_oldcrd "$site" "$target") --ignore-not-found"
    fi
    echo "sleep 40"; } > "$body"
  if [ "$site" = "jkt" ]; then
    bash "$(site_remote "$site")" "$body" || echo "[!] $site/$target 远端执行异常"
  else
    bash "$(site_remote "$site")" "$site" "$body" || echo "[!] $site/$target 远端执行异常"
  fi
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

run_targets() {  # run_targets <apply|verify> <stdout|file|all> [site]
  local fn=$1 which=$2 only=${3:-} s t
  local sites=${only:-$SITES}
  case "$which" in
    stdout|file) for s in $sites; do "$fn" "$s" "$which"; done ;;
    all) for t in stdout file; do for s in $sites; do "$fn" "$s" "$t"; done; done ;;
    *) echo "用法: $0 apply|verify [stdout|file|all] [mnl|sg|jkt]"; exit 2 ;;
  esac
}

case "${1:-}" in
  apply)  run_targets apply_one  "${2:-all}" "${3:-}" ;;
  verify) run_targets verify_one "${2:-all}" "${3:-}" ;;
  *) echo "用法: $0 apply|verify [stdout|file|all] [mnl|sg|jkt]"; exit 2 ;;
esac
