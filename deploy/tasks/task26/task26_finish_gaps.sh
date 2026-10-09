#!/usr/bin/env bash
# =============================================================================
# Day3 · 任务26 收尾补齐脚本（幂等）
#
# 用途：在账号/控制台侧完成两项前置「开通」后，一键补齐任务26 剩余两卡：
#   A. 云监控站点监控（需先在控制台开通「网络分析与监控」——免费，无 API）
#   B. Grafana 工作区（需先在 ARMS 控制台创建；CLI 直连报 601）
#
# 前置（必须由**主账号**在控制台完成，RAM 子账号/CLI 无法闭环）：
#   1) 云监控控制台 → 左侧「网络分析与监控」→ 站点监控 → 立即开通（勾选协议）
#      https://cms.console.aliyun.com/
#   2) ARMS 控制台 → 「Grafana 服务」→ 工作区管理 → 创建工作区
#      地域=新加坡(ap-southeast-1)、版本=专家版(首月免费)/开发者版、Grafana 版本=10.0.x
#      https://arms.console.aliyun.com/
#
# 用法：
#   bash task26_finish_gaps.sh          # 全量补齐 + 复核
#   bash task26_finish_gaps.sh status   # 只看当前状态
# =============================================================================
set -u

R_SG=ap-southeast-1
R_MNL=ap-southeast-6
SITE_TASK="likha-hk-newapi-status"
TARGET_URL="http://www.likha.hk/api/status"
# 探测点：新加坡375 / 香港569 / 东京576 / 马尼拉18877（isp=465 阿里云探针）
ISP_CITIES='[{"city":"375","isp":"465"},{"city":"569","isp":"465"},{"city":"576","isp":"465"},{"city":"18877","isp":"465"}]'
OPTIONS='{"http_method":"get","match_rule":0,"response_content":"\"success\":true","time_out":30000,"acceptable_response_code":"200"}'

MODE="${1:-all}"

hr() { printf '\n──────── %s ────────\n' "$*"; }

site_status() {
  hr "A. 站点监控：配额"
  aliyun cms DescribeMonitorResourceQuotaAttribute --region "$R_SG" 2>&1 \
    | grep -A5 'SiteMonitorTask' | head -8
  echo "── 任务列表 ──"
  aliyun cms DescribeSiteMonitorList --region "$R_SG" 2>&1 | grep -E 'TotalCount|"Name"|"TaskId"|"TaskState"' | head -12
}

grafana_status() {
  hr "B. Grafana：工作区列表"
  aliyun arms ListGrafanaWorkspace --region "$R_SG" 2>&1 | head -25
}

site_apply() {
  hr "A. 站点监控：创建任务"
  local existing
  existing=$(aliyun cms DescribeSiteMonitorList --region "$R_SG" 2>&1 | grep -c "$SITE_TASK" || true)
  if [ "$existing" -gt 0 ]; then
    echo "  已存在同名任务 $SITE_TASK → skip（幂等）"
    return 0
  fi
  aliyun cms CreateSiteMonitor --region "$R_SG" \
    --Address "$TARGET_URL" --TaskName "$SITE_TASK" --TaskType HTTP --Interval 5 \
    --IspCities "$ISP_CITIES" --OptionsJson "$OPTIONS" 2>&1 | head -20
}

grafana_apply() {
  hr "B. Grafana：尝试创建（若控制台已建则 skip）"
  local n
  n=$(aliyun arms ListGrafanaWorkspace --region "$R_SG" 2>&1 | grep -c '"grafanaWorkspaceId"' || true)
  if [ "$n" -gt 0 ]; then
    echo "  已有工作区 → skip（幂等）；去 ARMS 控制台配置数据源 + 4 面板"
    return 0
  fi
  echo "  控制台尚未创建工作区。CLI 直连（历史结论：恒报 601）："
  aliyun arms CreateGrafanaWorkspace --region "$R_SG" --RegionId "$R_SG" \
    --GrafanaWorkspaceName "newapi-obs-mnl" --GrafanaWorkspaceEdition experts_edition \
    --GrafanaVersion "10.0.x" --AccountNumber 10 --PricingCycle Month --Duration 1 \
    --Password "Likx@0bs2026Aa" 2>&1 | head -12
}

case "$MODE" in
  status) site_status; grafana_status ;;
  site)   site_status; site_apply ;;
  grafana) grafana_status; grafana_apply ;;
  all)    site_status; site_apply; grafana_status; grafana_apply ;;
  *) echo "用法: $0 [all|status|site|grafana]"; exit 2 ;;
esac

hr "完成"
