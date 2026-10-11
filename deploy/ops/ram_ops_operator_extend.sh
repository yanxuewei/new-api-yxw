#!/usr/bin/env bash
# =============================================================================
# newapi-ops-operator 自定义策略 —— 版本发布/回滚（IaC）
#
# 背景：该策略原先在控制台创建（2026-09-25），正文无 IaC 可追溯；
#       2026-10-10 起以本目录 JSON 为**唯一真源**，用 CreatePolicyVersion 发布新版本。
#
# 本次 v3 新增（用户 2026-10-10 要求：daimingming 看不到 Tair/证书等控制台）：
#   Allow+ : kvstore:*（Tair/Redis）· hdm:*（DAS）· yundun-cert:*（数字证书管理服务）
#            arms:*（ARMS + Grafana 工作区）· clickhouse:*（CK 企业版）· quotas:*（配额中心）
#            resourcemanager:Get*/List* + ram:Get|ListResourceGroup*（资源组只读，取官方示例）
#            tag:Get*/List*/Describe* + 跨服务只读标签动作（取 AliyunTAGReadOnlyAccess）
#   Deny+  : kvstore:DeleteInstance  ← 与 rds:DeleteDBInstance 同口径（本组设计：生产可写不可销毁）
#
# 用法：
#   bash deploy/ops/ram_ops_operator_extend.sh check      # 只读：现状 + 差异
#   bash deploy/ops/ram_ops_operator_extend.sh apply      # 发布新版本并设为默认
#   bash deploy/ops/ram_ops_operator_extend.sh verify     # 复核默认版本含新动作
#   bash deploy/ops/ram_ops_operator_extend.sh rollback   # 默认版本回退到 v2
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC_FILE="$SCRIPT_DIR/ram_policy_newapi-ops-operator.v3.json"
POLICY="newapi-ops-operator"
POLICY_DESC='newapi ops(v3 2026-10-10): ECS/VPC/ACK/RDS/Tair/DAS/SLB/ALB/WAF/DNS/CK/ARMS/CMS/SLS/OSS/CR/CEN/PVtz 运维读写 + 证书/配额/资源组/标签; Deny account,bss写,DeleteInstance/DeleteVpc/DeleteCluster/DeleteLoadBalancer/DeleteBucket'
REGION="${REGION:-ap-southeast-1}"
ALIYUN="${ALIYUN:-$(command -v aliyun || echo "$HOME/.workbuddy/binaries/aliyun-cli/aliyun")}"
PY="${PY:-/usr/bin/python3}"

say() { printf '%s\n' "$*" >&2; }
q() { "$ALIYUN" ram "$@" --region "$REGION" 2>&1; }

# 本次新增的动作（用于差异展示与 verify 断言）
NEW_ALLOW=("kvstore:*" "hdm:*" "yundun-cert:*" "arms:*" "clickhouse:*" "quotas:*" \
           "resourcemanager:Get*" "resourcemanager:List*" \
           "tag:Get*" "tag:List*" "tag:Describe*")
NEW_DENY=("kvstore:DeleteInstance")

current_default_doc() {
  q GetPolicy --PolicyName "$POLICY" --PolicyType Custom | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d['DefaultPolicyVersion']['PolicyDocument'])
except Exception:
    print('')"
}

list_versions() {
  q ListPolicyVersions --PolicyName "$POLICY" --PolicyType Custom | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for v in d['PolicyVersions']['PolicyVersion']:
        print('  %-4s default=%-5s created=%s' % (v['VersionId'], v['IsDefaultVersion'], v['CreateDate']))
except Exception as e:
    print('  (读取失败)', e)"
}

do_check() {
  say "=== 策略 $POLICY（Custom）现有版本 ==="
  list_versions
  say ""
  say "=== 本文件拟发布的差异 ==="
  say "  真源文档: $DOC_FILE"
  local cur; cur="$(current_default_doc)"
  local a
  for a in "${NEW_ALLOW[@]}"; do
    if printf '%s' "$cur" | grep -qF "\"$a\""; then
      say "  [已有] Allow $a"
    else
      say "  [新增] Allow $a"
    fi
  done
  for a in "${NEW_DENY[@]}"; do
    if printf '%s' "$cur" | grep -qF "\"$a\""; then
      say "  [已有] Deny  $a"
    else
      say "  [新增] Deny  $a"
    fi
  done
  say ""
  say "  JSON 语法自检："
  "$PY" -c "import json;d=json.load(open('$DOC_FILE'));print('    OK  Statement=%d Allow=%d Deny=%d' % (len(d['Statement']), len(d['Statement'][0]['Action']), len(d['Statement'][1]['Action'])))" || return 1
}

do_apply() {
  [ -f "$DOC_FILE" ] || { say "缺 $DOC_FILE"; return 1; }
  say "=== 发布新版本并设为默认 ==="
  local doc; doc="$(tr -d '\n' < "$DOC_FILE")"
  local out
  out=$(q CreatePolicyVersion --PolicyName "$POLICY" --PolicyDocument "$doc" --SetAsDefault true)
  if printf '%s' "$out" | grep -q '"VersionId"'; then
    say "  [OK] 新版本已发布并设为默认：$(printf '%s' "$out" | "$PY" -c "import sys,json;d=json.load(sys.stdin);print(d['PolicyVersion']['VersionId'])" 2>/dev/null)"
  else
    say "  [FAIL] $out"; return 1
  fi
  say ""
  do_verify
  say ""
  do_desc
}

do_verify() {
  say "=== 复核默认版本 ==="
  local cur; cur="$(current_default_doc)"
  [ -n "$cur" ] || { say "  [FAIL] 取不到默认版本正文"; return 1; }
  local bad=0 a
  for a in "${NEW_ALLOW[@]}"; do
    if printf '%s' "$cur" | grep -qF "\"$a\""; then say "  [OK]   Allow $a"; else say "  [FAIL] Allow $a 缺失"; bad=1; fi
  done
  for a in "${NEW_DENY[@]}"; do
    if printf '%s' "$cur" | grep -qF "\"$a\""; then say "  [OK]   Deny  $a"; else say "  [FAIL] Deny  $a 缺失"; bad=1; fi
  done
  # 反向：原有动作不得丢
  for a in "ecs:*" "cs:*" "rds:*" "sls:*" "cms:*" "oss:*" "account:*"; do
    if printf '%s' "$cur" | grep -qF "\"$a\""; then say "  [OK]   保留 $a"; else say "  [FAIL] 原有 $a 丢了！"; bad=1; fi
  done
  say ""
  [ $bad -eq 0 ] && say "  VERIFY=PASS" || say "  VERIFY=FAIL"
  return $bad
}

do_desc() {
  say "=== 同步策略描述 ==="
  say "  新描述：$POLICY_DESC"
  local out; out=$(q UpdatePolicyDescription --PolicyName "$POLICY" --NewDescription "$POLICY_DESC")
  if printf '%s' "$out" | grep -q '"RequestId"'; then
    say "  [OK] 描述已更新"
  else
    say "  [FAIL] $out"; return 1
  fi
}

do_rollback() {
  say "=== 默认版本回退到 v2 ==="
  local out; out=$(q SetDefaultPolicyVersion --PolicyName "$POLICY" --VersionId v2)
  if printf '%s' "$out" | grep -q '"RequestId"'; then
    say "  [OK] 默认版本已回退 v2"
  else
    say "  [FAIL] $out"; return 1
  fi
  say "  提示：v3 版本记录仍存在，可在控制台删除，或再次 apply 重建。"
}

case "${1:-check}" in
  check)    do_check ;;
  apply)    do_apply ;;
  verify)   do_verify ;;
  desc)     do_desc ;;
  rollback) do_rollback ;;
  *) say "用法: $0 [check|apply|verify|desc|rollback]"; exit 2 ;;
esac
