#!/bin/bash
# task32/cms2_rules.sh — 云监控 2.0（cms2）告警规则落地（任务 32）
#
# 作用：把本目录的 3 份规则 body 下发到 cms2 工作区 `default-cms-5108890064395960-ap-southeast-6`，
#       全部绑定通知策略 `6ff55b598b914557a018931a17f9eca8`（电话+短信+邮件，仅 CRITICAL 走电话）。
#
# usage:
#   bash cms2_rules.sh --list            # 只读：列本卡规则
#   bash cms2_rules.sh --diff            # 只读：打印将下发的 body
#   CONFIRM=yes bash cms2_rules.sh --apply
#
# 实测要点（2026-10-19，别踩）：
#   · `workspace` 必须与 rule 所在地域一致（这里 ap-southeast-6），`--region ap-southeast-6`；
#   · `notifyConfig.type=NOTIFY_POLICY` + `notifyStrategies[1]` 可**跨工作区**引用策略（实测通过）；
#   · severity 决定是否走电话：CRITICAL→电话；WARN/INFO 只走邮件/IM（由策略内部规则决定）；
#   · 幂等靠 displayName 去重（cms2 无 create-or-update，重复创建会多一条，故先查后建）。
set -uo pipefail
R=ap-southeast-6
WS=default-cms-5108890064395960-ap-southeast-6
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES=(cms2_rule_p1_no_replica.json cms2_rule_p1_alb_5xx.json cms2_rule_p2_replica_short.json cms2_rule_p3_restart.json)
MODE="${1:---list}"
say() { printf '%s\n' "$*"; }

list_rules() {
  aliyun cms2 alert rule list --region "$R" --workspace "$WS" --labels '{"task":"task32"}' --page-size 20 -o json 2>&1 | tr -d '\r' \
   | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=(d.get('data') or {}).get('data') or {}
rows=d.get('alertRules') or []
print('  count=%d' % len(rows))
for r in rows:
    print('   %-38s %-46s %-9s %s' % (r.get('uuid'), r.get('displayName'), r.get('severityLevels'), r.get('notifyStrategyId')))
"
}

case "$MODE" in
  --list) list_rules ;;
  --diff)
    for f in "${RULES[@]}"; do echo "=== $f ==="; python3 -m json.tool "$DIR/$f" | head -40; echo; done ;;
  --apply)
    [ "${CONFIRM:-}" = yes ] || { echo "[!] 写操作需 CONFIRM=yes"; exit 1; }
    for f in "${RULES[@]}"; do
      name=$(python3 -c "import json,io;print(json.load(io.open('$DIR/$f',encoding='utf-8'))['displayName'])")
      if aliyun cms2 alert rule list --region "$R" --workspace "$WS" --page-size 50 -o json 2>/dev/null | grep -q "$name"; then
        say "[skip] 已存在：$name"
      else
        say "[create] $f → $name"
        tr -d '\r' < "$DIR/$f" > /tmp/_r.json
        aliyun cms2 alert rule create --region "$R" --body @/tmp/_r.json -o text 2>&1 | head -3
      fi
    done
    say ""; list_rules ;;
  *) echo "usage: $0 --list|--diff|--apply (CONFIRM=yes)"; exit 2 ;;
esac
