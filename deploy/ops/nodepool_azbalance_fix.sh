#!/usr/bin/env bash
# =============================================================================
# deploy/ops/nodepool_azbalance_fix.sh —— 断言/修复 ESS 伸缩组的「可用区均衡」开关
#
#   ★ 为什么需要它（2026-09-29 实测，血坑）：
#     ACK 建节点池时会把 ESS 的 `MultiAZPolicy` 设为 `BALANCE`，**但不会打开
#     独立的 `AzBalance` 开关**。仅设 MultiAZPolicy=BALANCE 时，ESS 在实例创建
#     阶段**完全不做跨可用区均衡** —— 弹性伸缩组会顺着第一个能买到机型/有库存的
#     交换机把所有实例都放进去（实测：新加坡 desired=2 得到 1a:2 / 1b:0）。
#     该字段 **DescribeScalingGroups 不回读**，所以「已开启」无法直接验证，
#     只能靠实例的可用区分布间接证明，或幂等重设。
#
#     ⚠️ 每次经 ACK 侧（ModifyClusterNodePool / 控制台）改动节点池后，都建议重跑本脚本，
#        防止 ACK 回写覆盖 ESS 参数。
#
#   用法：
#     bash deploy/ops/nodepool_azbalance_fix.sh mnl            # 马尼拉
#     bash deploy/ops/nodepool_azbalance_fix.sh sg             # 新加坡
#     bash deploy/ops/nodepool_azbalance_fix.sh <region> <asg_id> [--rebalance]
#
#   参数：
#     --rebalance   额外打开 AutoRebalance（对**已存在**的失衡分布做再均衡；
#                   会短暂多起 1 台再削，费用按量计，秒级）
# =============================================================================
set -uo pipefail

case "${1:-}" in
  mnl) REGION=ap-southeast-6; ASG=asg-5tsd68ew4u0wutaqk5cy ;;
  sg)  REGION=ap-southeast-1; ASG=asg-t4ngzbg7m9u84y59dkxl ;;
  *)   REGION="${1:-}"; ASG="${2:-}" ;;
esac
REBALANCE=0
case "${3:-${2:-}}" in --rebalance) REBALANCE=1 ;; esac
[ "${2:-}" = "--rebalance" ] && { REBALANCE=1; ASG="${ASG:-}"; }

if [ -z "${REGION:-}" ] || [ -z "${ASG:-}" ]; then
  echo "用法：$0 mnl|sg | <region> <asg_id> [--rebalance]" >&2
  exit 2
fi

echo "============================================================"
echo " ESS 可用区均衡断言  region=$REGION  asg=$ASG  rebalance=$REBALANCE"
echo "============================================================"

ARGS=( --RegionId "$REGION" --region "$REGION" --ScalingGroupId "$ASG" --AzBalance true )
if [ "$REBALANCE" = "1" ]; then
  ARGS+=( --AutoRebalance true --BalanceMode BalancedBestEffort )
fi

OUT="$(aliyun ess ModifyScalingGroup "${ARGS[@]}" 2>&1)"
printf '%s\n' "$OUT" | head -6
case "$OUT" in
  *'"RequestId"'*) echo "  [OK] AzBalance=true 已断言" ;;
  *) echo "  [FAIL] 断言失败（见上）" ;;
esac

echo
echo "---- 当前实况（AzBalance 不回读，用可用区分布间接证明）----"
aliyun ess DescribeScalingGroups --RegionId "$REGION" --region "$REGION" --PageSize 50 2>/dev/null \
  | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for g in (d.get('ScalingGroups') or {}).get('ScalingGroup') or []:
    if g.get('ScalingGroupId')=='$ASG':
        print('  min=%s max=%s total=%s multiAZ=%s' % (g.get('MinSize'), g.get('MaxSize'), g.get('TotalCapacity'), g.get('MultiAZPolicy')))
"
aliyun ecs DescribeInstances --RegionId "$REGION" --region "$REGION" --PageSize 100 2>/dev/null \
  | python3 -c "
import sys,json
from collections import Counter
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
c=Counter()
for i in (d.get('Instances') or {}).get('Instance') or []:
    if (i.get('InstanceName') or '').startswith('worker-k8s-for-cs-'):
        c[i.get('ZoneId')]+=1
print('  可用区分布:', ' '.join('%s:%d'%kv for kv in sorted(c.items())) or 'NONE')
"
