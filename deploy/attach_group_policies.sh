#!/usr/bin/env bash
# attach_group_policies.sh — 把 4 个 RAM 用户身上的权限策略镜像到同名用户组，并把用户加入组
# 对应：admin/ops/cicd-push/iac-terraform  →  admin_group/ops_group/cicd-push_group/iac-terraform_group
# 幂等：已绑的策略 / 已在组内的成员会跳过。策略以「并集」生效，组+用户双绑不会改变最终权限。
# 用法：bash attach_group_policies.sh [check]
set -uo pipefail

ALIYUN="${ALIYUN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
PY="${PY:-/usr/bin/python3}"
REGION="${REGION:-ap-southeast-1}"   # RAM 是全局服务，用 ap-southeast-1（cn-hangzhou 亦可）
OUTDIR="${OUTDIR:-$PWD/.workbuddy/ram_group_out}"
mkdir -p "$OUTDIR"
[ -x "$ALIYUN" ] || { echo "[FATAL] aliyun CLI 不存在: $ALIYUN"; exit 1; }

say() { printf '%s\n' "$*"; }
chk=${1:-apply}

# user:group:policyname,policyname,...
MAP=(
  "admin:admin_group:newapi-admin-identity,newapi-enforce-mfa,newapi-audit-protect"
  "ops:ops_group:newapi-ops-operator,newapi-enforce-mfa,newapi-audit-protect"
  "cicd-push:cicd-push_group:newapi-cicd-acr-push,newapi-audit-protect"
  "iac-terraform:iac-terraform_group:newapi-iac-terraform,newapi-audit-protect"
)

group_policies() { # groupname -> 现绑策略名，每行一个
  "$ALIYUN" ram ListPoliciesForGroup --GroupName "$1" --region "$REGION" 2>/dev/null \
    | "$PY" -c "import sys,json
d=json.load(sys.stdin)
for p in (d.get('Policies') or {}).get('Policy') or []: print(p['PolicyName'])"
}
group_members() {
  "$ALIYUN" ram ListUsersForGroup --GroupName "$1" --region "$REGION" 2>/dev/null \
    | "$PY" -c "import sys,json
d=json.load(sys.stdin)
for u in (d.get('Users') or {}).get('User') or []: print(u['UserName'])"
}

for row in "${MAP[@]}"; do
  IFS=: read -r user group policies <<<"$row"
  say "=== $user  →  $group ==="
  have=$(group_policies "$group")
  IFS=',' read -ra want <<<"$policies"
  for p in "${want[@]}"; do
    if printf '%s\n' "$have" | grep -qx "$p"; then
      say "  [SKIP] 策略已绑  $p"
      continue
    fi
    if [ "$chk" = "check" ]; then say "  [TODO] 待绑    $p"; continue; fi
    if "$ALIYUN" ram AttachPolicyToGroup --GroupName "$group" --PolicyName "$p" \
         --PolicyType Custom --region "$REGION" >/dev/null 2>&1; then
      say "  [OK]   绑定策略  $p"
    else
      say "  [FAIL] 绑定失败  $p"
    fi
  done

  m=$(group_members "$group")
  if printf '%s\n' "$m" | grep -qx "$user"; then
    say "  [SKIP] 成员已在组  $user"
  elif [ "$chk" = "check" ]; then
    say "  [TODO] 待加成员  $user"
  else
    if "$ALIYUN" ram AddUserToGroup --UserName "$user" --GroupName "$group" \
         --region "$REGION" >/dev/null 2>&1; then
      say "  [OK]   加入用户组  $user"
    else
      say "  [FAIL] 加成员失败  $user"
    fi
  fi
  say ""
done

say "=== 复核 ==="
for row in "${MAP[@]}"; do
  IFS=: read -r user group policies <<<"$row"
  gp=$(group_policies "$group" | sort | paste -sd, -)
  gm=$(group_members "$group" | paste -sd, -)
  gl=$("$ALIYUN" ram ListGroupsForUser --UserName "$user" --region "$REGION" 2>/dev/null \
       | "$PY" -c "import sys,json
d=json.load(sys.stdin)
print(','.join(g['GroupName'] for g in (d.get('Groups') or {}).get('Group') or []))")
  say "  $group"
  say "      策略: $gp"
  say "      成员: $gm"
  say "      $user 所属组: $gl"
done

for x in "$ALIYUN" ram ListPoliciesForGroup; do :; done
{ for row in "${MAP[@]}"; do
    IFS=: read -r user group policies <<<"$row"
    "$ALIYUN" ram ListPoliciesForGroup --GroupName "$group" --region "$REGION"
    "$ALIYUN" ram ListUsersForGroup    --GroupName "$group" --region "$REGION"
    "$ALIYUN" ram ListPoliciesForUser  --UserName  "$user"  --region "$REGION"
done; } >"$OUTDIR/ram_group_snapshot.json" 2>&1
say ""
say "原始快照：$OUTDIR/ram_group_snapshot.json"
