#!/usr/bin/env bash
# 任务 26 追加（2026-10-08）：SLS 纳秒时间戳（控制台时间列精确到 ms）——两集群应用与校验
#
# 用法：bash deploy/sls/apply_pipeline_ns.sh apply   # 两集群应用新式 pipeline 配置
#       bash deploy/sls/apply_pipeline_ns.sh verify  # 两站点查最新日志的 __time_ns_part__
#
# 背景与四处坑见 deploy/Day3任务26_SLS与可观测_执行报告.md「⏱ 追加（2026-10-08）」。
# 关键点速查：
#   · __time__ 恒为秒级；ms 靠 __time_ns_part__（0~999999999）
#   · 必须「global.EnableTimestampNanosecond + 处理器 SetTime」两件套（源码 gotime/processor_gotime.go）
#   · 开关只有 pipeline 的 global 能持久化；老式 CRD / UpdateConfig / SD 全被剥键
#   · CLI 查 SLS 必须显式 --region，否则跨地域查项目会报 ProjectNotExist 假错
set -uo pipefail

MNLCID=cd57e40ce9a634c1698c2f5c5e09bd93c
SGCID=ca75829e3492d491d9d434de087913798
MNLREGION=ap-southeast-6
SGREGION=ap-southeast-1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

apply_site() {  # apply_site <mnl|sg>
  local site=$1 cid region manifest
  case "$site" in
    mnl) cid=$MNLCID; region=$MNLREGION; manifest="$HERE/clusterpipelineconfig-app-stdout.yaml" ;;
    sg)  cid=$SGCID;  region=$SGREGION;  manifest="$HERE/clusterpipelineconfig-app-stdout-sg.yaml" ;;
  esac
  echo "== [$site] apply $manifest"
  local body="/tmp/ns_apply_${site}_$$.sh"
  { echo "kubectl apply -f - <<'YAMLEOF'"; tr -d '\r' < "$manifest"; echo "YAMLEOF"
    echo "kubectl -n new-api delete aliyunlogconfig new-api-app-stdout --ignore-not-found"
    echo "sleep 40"; } > "$body"
  bash "$REPO/deploy/ack_remote.sh" "$site" "$body" || echo "[!] $site 远端执行异常"
  rm -f "$body"
  echo "-- [$site] SLS 侧复核（global / processors）"
  aliyun sls GetLogtailPipelineConfig --region "$region" --project "k8s-log-$cid" \
    --configName new-api-app-stdout-ns | jq -c '{global,processors}' 2>/dev/null || echo "[!] 配置未就绪"
}

verify_site() {  # verify_site <mnl|sg>
  local site=$1 cid region
  case "$site" in
    mnl) cid=$MNLCID; region=$MNLREGION ;;
    sg)  cid=$SGCID;  region=$SGREGION ;;
  esac
  local from to body
  from=$(date -d '10 minutes ago' +%s); to=$(date +%s)
  body=$(printf '{"from":%s,"to":%s,"query":"*","line":6,"reverse":true}' "$from" "$to")
  echo "== [$site] 最新日志（ns 应非 NULL）"
  aliyun sls GetLogsV2 --region "$region" --project "k8s-log-$cid" --logstore app-stdout --body "$body" \
    | jq -r '.data[] | "\(.__time__)\tns=\(.__time_ns_part__ // "NULL")\t\(._time_)"' 2>/dev/null
}

case "${1:-}" in
  apply)  apply_site mnl; apply_site sg ;;
  verify) verify_site mnl; verify_site sg ;;
  *) echo "用法: $0 apply|verify"; exit 2 ;;
esac
