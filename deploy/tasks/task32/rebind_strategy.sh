#!/bin/bash
# task32/rebind_strategy.sh — 把 task32 的 4 条告警规则重绑到指定通知策略
#
# 背景（2026-10-19 实测）：`通知策略` 是**工作区级**资源，规则所在工作区必须与策略一致；
#   cms2 **不校验** notifyStrategies 的 ID 是否存在（伪造 ID 也能建成功、静默不投递）。
#   ⇒ 必须肉眼从控制台复制策略 ID，且确认策略建在**马利拉工作区**
#     `default-cms-5108890064395960-ap-southeast-6`。
#
# usage:
#   bash rebind_strategy.sh --status                 # 只读：列 4 条规则当前绑的策略
#   NEW_STRATEGY=<32位ID> bash rebind_strategy.sh --apply
#
# 注：本脚本只改 `notifyConfig`，不动判据/级别/数据源。
set -uo pipefail
R=ap-southeast-6
WS=default-cms-5108890064395960-ap-southeast-6
MODE="${1:---status}"
NEW="${NEW_STRATEGY:-}"
IDS=(
  88b0ef7c-1d6e-4670-8c92-771a74321f57   # [P1] 无可用副本
  cms_v2_7c0dd247-e039-4e06-8507-d7580e9d2a69  # [P1] ALB 5xx
  1febfa25-e23f-4098-b1a5-034d6d344caf   # [P2] 副本不足
  c78c8cc9-a791-49e3-a376-78e2150b0a65   # [P3] 重启
)
say() { printf '%s\n' "$*"; }

case "$MODE" in
  --status)
    aliyun cms2 alert rule list --region "$R" --workspace "$WS" -o json 2>/dev/null | tr -d '\r' \
     | python3 -c "
import sys,json
d=json.load(sys.stdin); rows=(((d.get('data') or {}).get('data') or {}).get('alertRules') or [])
for r in rows:
    if (r.get('labels') or {}).get('task')=='task32':
        print('  %-46s %-12s strategy=%s' % (r.get('displayName'), r.get('severityLevels'), r.get('notifyStrategyId')))
"
    ;;
  --apply)
    [ -n "$NEW" ] || { echo "[!] 需 NEW_STRATEGY=<策略ID>"; exit 1; }
    if [ ${#NEW} -ne 32 ]; then echo "[!] 策略 ID 应为 32 位十六进制（当前 ${#NEW} 位）"; exit 1; fi
    for id in "${IDS[@]}"; do
      say "[rebind] $id"
      aliyun cms2 alert rule patch --region "$R" --alert-rule-id "$id" \
        --body "{\"notifyConfig\":{\"type\":\"NOTIFY_POLICY\",\"notifyStrategies\":[\"$NEW\"]}}" -o text 2>&1 | head -2
    done
    say ""; say "=== 回读 ==="; "$0" --status
    ;;
  *) echo "usage: $0 --status | NEW_STRATEGY=<id> $0 --apply"; exit 2 ;;
esac
