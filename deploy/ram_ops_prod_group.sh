#!/usr/bin/env bash
# ops-prod_group —— 人类「生产运维」组
#
# 设计（2026-09-25 定稿）：
#   ops_group      = 非生产运维（挂 prod-boundary + prod-oss-guard → 生产只读）
#   ops-prod_group = 生产运维（**不挂** 两条边界 → 生产可写，但销毁类仍被 ops-operator Deny 拦）
#
# 策略 = newapi-ops-operator + newapi-enforce-mfa + newapi-audit-protect
#   - ops-operator    : 全服务读写 + Deny{account:*, bss写, DeleteInstance/DeleteVpc/
#                       DeleteVSwitch/DeleteDBInstance/DeleteCluster/DeleteLoadBalancer/DeleteBucket}
#   - enforce-mfa     : 未过 MFA 的控制台会话 → 除 MFA 自助动作外全 Deny（AK 调用不判定）
#   - audit-protect   : Deny OSS actiontrail/ 前缀写删
#
# 用法：bash ram_ops_prod_group.sh [check|apply|verify|probe|rollback]
set -uo pipefail

ALIYUN="${ALIYUN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
OSSUTIL="${OSSUTIL:-$HOME/.workbuddy/binaries/ossutil/ossutil}"
PY="${PY:-/usr/bin/python3}"
REGION="${REGION:-ap-southeast-1}"

GROUP="ops-prod_group"
POLICIES=(newapi-ops-operator newapi-enforce-mfa newapi-audit-protect)
# 刻意排除（生产写边界，勿加）：
EXCLUDED=(newapi-prod-boundary newapi-prod-oss-guard)

say() { printf '%s\n' "$*" >&2; }
q() { "$ALIYUN" "$@" --region "$REGION" 2>&1; }

group_exists() {
  q ram GetGroup --GroupName "$GROUP" | grep -q '"GroupName"'
}

attached_policies() {
  q ram ListPoliciesForGroup --GroupName "$GROUP" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print(' '.join(sorted(p['PolicyName'] for p in ((d.get('Policies') or {}).get('Policy') or []))))"
}

# ---------------- check ----------------
do_check() {
  say "=== 预演：$GROUP ==="
  if group_exists; then say "  组已存在 → apply 将跳过创建"; else say "  组不存在 → 将创建"; fi
  local have; have=" $(attached_policies) "
  local p
  for p in "${POLICIES[@]}"; do
    if [ -n "$have" ] && [ "$have" != "  " ] && printf '%s' "$have" | grep -q " $p "; then
      say "  [SKIP] $p 已挂"
    else
      say "  [TODO] $p 待挂"
    fi
  done
  for p in "${EXCLUDED[@]}"; do
    if printf '%s' "$have" | grep -q " $p "; then
      say "  [WARN] $p 不该出现在本组（会挡掉生产写）"
    fi
  done
  say ""
  say "  拟挂 ${#POLICIES[@]} 条，排除 ${#EXCLUDED[@]} 条"
}

# ---------------- apply ----------------
do_apply() {
  say "=== 创建 $GROUP ==="
  if group_exists; then
    say "  [SKIP] 组已存在"
  else
    local out; out=$(q ram CreateGroup --GroupName "$GROUP" \
      --Comments "new-api prod ops (human): full ops write incl. production, MFA enforced")
    if printf '%s' "$out" | grep -q '"GroupName"'; then
      say "  [OK]   组已创建"
    else
      say "  [FAIL] 创建失败：$(printf '%s' "$out" | head -c 200)"; return 1
    fi
  fi

  say ""
  say "=== 挂策略 ==="
  local have; have=" $(attached_policies) "
  local p
  for p in "${POLICIES[@]}"; do
    if printf '%s' "$have" | grep -q " $p "; then
      say "  [SKIP] $p"
      continue
    fi
    if q ram AttachPolicyToGroup --GroupName "$GROUP" --PolicyName "$p" --PolicyType Custom \
       | grep -q '"RequestId"'; then
      say "  [OK]   $GROUP ← $p"
    else
      say "  [FAIL] $GROUP ← $p"
    fi
  done

  say ""
  say "=== 护栏：确认边界策略未混入 ==="
  have=" $(attached_policies) "
  local bad=0
  for p in "${EXCLUDED[@]}"; do
    if printf '%s' "$have" | grep -q " $p "; then
      say "  [FAIL] $p 出现在 $GROUP → 生产写会被挡！"
      bad=1
    fi
  done
  [ $bad -eq 0 ] && say "  [OK]   两条边界策略均未挂（符合设计）"
  return 0
}

# ---------------- verify ----------------
do_verify() {
  say "=== $GROUP 状态 ==="
  q ram GetGroup --GroupName "$GROUP" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
g=d.get('Group') or {}
print('  GroupName : %s' % g.get('GroupName'))
print('  Comments  : %s' % g.get('Comments'))
print('  CreateDate: %s' % g.get('CreateDate'))"
  printf '  Policies  : '
  attached_policies
  printf '  Members   : '
  q ram ListUsersForGroup --GroupName "$GROUP" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
print([u['UserName'] for u in ((d.get('Users') or {}).get('User') or [])] or '空（待加人）')"

  say ""
  say "=== 全局组视图 ==="
  local g
  for g in admin_group ops_group ops-prod_group dev-program_group iac-terraform_group cicd-push_group; do
    printf '  %-20s ' "$g"
    q ram ListPoliciesForGroup --GroupName "$g" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
print(sorted(p['PolicyName'] for p in ((d.get('Policies') or {}).get('Policy') or [])) or '空')"
  done
}

# ---------------- probe ----------------
# 用 iac-terraform（唯一有 AK 的用户）临时承载「ops-prod_group 等效组合」，
# 实测生产写是否真的被放行、销毁类是否仍被 ops-operator Deny 拦。测完还原。
do_probe() {
  local SECRETS="$HOME/.aliyun/newapi-ram-secrets.json"
  [ -f "$SECRETS" ] || { say "缺 $SECRETS"; return 1; }
  local AKID AKSK
  AKID=$("$PY" -c "import json;print(json.load(open('$SECRETS'))['access_keys']['iac-terraform']['AccessKeyId'])")
  AKSK=$("$PY" -c "import json;print(json.load(open('$SECRETS'))['access_keys']['iac-terraform']['AccessKeySecret'])")

  say "=== 绑定探针前基线（iac-terraform 现有权限）==="
  probe_run "$AKID" "$AKSK"

  say ""
  say "=== 临时挂 newapi-ops-operator 到 iac-terraform（模拟 ops-prod_group 组合）==="
  q ram AttachPolicyToUser --UserName iac-terraform --PolicyName newapi-ops-operator --PolicyType Custom >/dev/null
  say "  attached; 等 15s 生效"
  sleep 15

  say ""
  say "=== 挂载后实测 ==="
  probe_run "$AKID" "$AKSK"

  say ""
  say "=== 解绑还原 ==="
  q ram DetachPolicyFromUser --UserName iac-terraform --PolicyName newapi-ops-operator --PolicyType Custom >/dev/null
  say "  detached"
  sleep 8
  printf '  iac-terraform 用户级绑定：'
  q ram ListPoliciesForUser --UserName iac-terraform | "$PY" -c "
import sys,json;d=json.load(sys.stdin)
print([p['PolicyName'] for p in ((d.get('Policies') or {}).get('Policy') or [])] or '空 OK')"
}

probe_run() {
  local AKID="$1" AKSK="$2"
  "$PY" - "$ALIYUN" "$OSSUTIL" "$AKID" "$AKSK" <<'PY'
import sys, subprocess, json
aliyun, ossutil, akid, aksk = sys.argv[1:5]
DENY_KEYS = ("accessdenied", "access denied", "forbidden", "not authorized", "no permission")

def verdict(p):
    out = (p.stdout or "") + (p.stderr or "")
    low = out.lower()
    if any(h in low for h in DENY_KEYS):
        return "DENY"
    if "nosuchbucket" in low or "no such bucket" in low or "nosuchkey" in low:
        return "ALLOW"
    if p.returncode == 0:
        return "ALLOW"
    return "ERR"

def al(action, extra):
    return verdict(subprocess.run([aliyun, "--access-key-id", akid, "--access-key-secret", aksk]
                                  + action + extra, capture_output=True, text=True, timeout=90))

def os_api(sub, extra, region="ap-southeast-6"):
    return verdict(subprocess.run([ossutil, "api", sub, "--region", region,
                                   "--endpoint", "oss-%s.aliyuncs.com" % region,
                                   "--access-key-id", akid, "--access-key-secret", aksk]
                                  + extra, capture_output=True, text=True, timeout=90))

# 注意：不含 DeleteBucket / DeleteVpc 等不可逆动作的实测 —— 判定器一旦误判即真删。
# 那类保护由 ops-operator 显式 Deny 静态保证（策略正文明列），不做破坏性验证。
cases = [
    ("生产 VPC 幂等写 (ModifyVpcAttribute)", "ALLOW",
     al(["vpc", "ModifyVpcAttribute"], ["--RegionId", "ap-southeast-6",
        "--VpcId", "vpc-5tst1tgeessxn1azwasg2",
        "--Description", "new-api Philippines(Manila) prod"])),
    ("生产 VPC 只读 (DescribeVpcs)", "ALLOW",
     al(["vpc", "DescribeVpcs"], ["--RegionId", "ap-southeast-6"])),
    ("生产桶 写对象 probe/", "ALLOW",
     os_api("put-object", ["--bucket", "oss-newapi-mnl", "--key", "probe/__opsprodprobe__.txt",
                           "--body", "/etc/hostname"])),
    ("生产桶 删对象 probe/", "ALLOW",
     os_api("delete-object", ["--bucket", "oss-newapi-mnl", "--key", "probe/__opsprodprobe__.txt"])),
    ("生产桶 读 rds-backup/", "ALLOW",
     os_api("get-object", ["--bucket", "oss-newapi-mnl", "--key", "rds-backup/__nope__.txt"])),
    ("审计前缀 写 actiontrail/ (audit-protect)", "DENY",
     os_api("put-object", ["--bucket", "oss-newapi-mnl", "--key", "actiontrail/__probe__.txt",
                           "--body", "/etc/hostname"])),
]

print("  %-46s %-7s %-7s %s" % ("CASE", "EXPECT", "ACTUAL", "VERDICT"))
print("  " + "-" * 76)
bad = 0
for desc, exp, act in cases:
    ok = "PASS" if act == exp else "FAIL"
    if ok == "FAIL":
        bad += 1
    print("  %-46s %-7s %-7s %s" % (desc, exp, act, ok))
print("  " + "-" * 76)
print("  PROBE=%s (%d/%d)" % ("PASS" if bad == 0 else "FAIL(%d)" % bad, len(cases) - bad, len(cases)))
PY
}

# ---------------- rollback ----------------
do_rollback() {
  say "=== 回滚 $GROUP ==="
  local users
  users=$(q ram ListUsersForGroup --GroupName "$GROUP" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print(' '.join(u['UserName'] for u in ((d.get('Users') or {}).get('User') or [])))")
  local u
  for u in $users; do
    if q ram RemoveUserFromGroup --GroupName "$GROUP" --UserName "$u" | grep -q '"RequestId"'; then
      say "  [OK]   移除成员 $u"
    else
      say "  [FAIL] 移除成员 $u（组非空则无法删除）"
    fi
  done
  local p
  for p in "${POLICIES[@]}"; do
    if q ram DetachPolicyFromGroup --GroupName "$GROUP" --PolicyName "$p" --PolicyType Custom | grep -q '"RequestId"'; then
      say "  [OK]   解绑 $p"
    else
      say "  [SKIP] $p（未挂或解绑失败）"
    fi
  done
  if q ram DeleteGroup --GroupName "$GROUP" | grep -q '"RequestId"'; then
    say "  [OK]   组已删除"
  else
    say "  [FAIL] 删除组失败（可能仍有成员或策略）"
  fi
}

case "${1:-check}" in
  check)    do_check ;;
  apply)    do_apply ;;
  verify)   do_verify ;;
  probe)    do_probe ;;
  rollback) do_rollback ;;
  all)      do_apply && say "" && do_verify ;;
  *)        say "用法: bash ram_ops_prod_group.sh [check|apply|verify|probe|rollback|all]"; exit 1 ;;
esac
