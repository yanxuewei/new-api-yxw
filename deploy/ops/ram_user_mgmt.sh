#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# deploy/ops/ram_user_mgmt.sh —— 阿里云 RAM 用户 / 用户组 / 策略 增删改查
#
# 面向运维同学。基于 aliyun-cli，需先配置 AK/SK：
#   export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"
#   aliyun configure --profile default --mode AK
#   或 export ALIBABA_CLOUD_ACCESS_KEY_ID / ALIBABA_CLOUD_ACCESS_KEY_SECRET
#
# 安全约定（与《用户设置指南.md》一致）：
#   1. 策略只挂用户组，不挂用户 —— 本脚本刻意**不提供** attach-user
#   2. 写操作默认预演 + 需输入 yes；加 --yes 跳过
#   3. 删除前做前置检查，不留悬空引用
#
# 用法：bash deploy/ops/ram_user_mgmt.sh <命令> [参数...]   （不带参数 = 帮助）
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

# 程序身份的站点表与权限文档（与 ram_rrsa_program_onboard.sh 共用一份，避免权限漂移）
HERE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/program_identity.sh
. "$HERE_DIR/../lib/program_identity.sh" 2>/dev/null || PROGRAM_LIB_MISSING=1

REGION="${RAM_REGION:-ap-southeast-1}"
# 账号站点决定 RAM 用户的控制台登录地址：国际站 alibabacloud.com（默认）/ 中国站 aliyun.com
SITE="${RAM_SITE:-}"
if [ -z "$SITE" ]; then
  case "$REGION" in cn-*) SITE=cn ;; *) SITE=intl ;; esac
fi
case "$SITE" in
  cn) LOGIN_URL="https://signin.aliyun.com/login.htm" ;;
  *)  SITE=intl; LOGIN_URL="https://signin.alibabacloud.com/login.htm" ;;
esac
ALIYUN="${ALIYUN_BIN:-aliyun}"
PY="${PY_BIN:-/usr/bin/python3}"
ASSUME_YES=0

# ── 基础 ──────────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
info() { printf '  \033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
skip() { printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

die() { fail "$*"; exit 1; }

need_cli() {
  command -v "$ALIYUN" >/dev/null 2>&1 || die "找不到 aliyun CLI。请先：export PATH=\"\$HOME/.workbuddy/binaries/aliyun-cli:\$PATH\""
  local out
  out=$("$ALIYUN" sts GetCallerIdentity 2>&1) || true
  case "$out" in
    *AccountId*) : ;;
    *) die "凭证不可用。请先配置 AK/SK：aliyun configure --profile default --mode AK
       原始返回：$(printf '%s' "$out" | head -c 200)" ;;
  esac
}

# 结构化判定：成功以 JSON 含 RequestId/具体字段为准；失败看顶层 error_code
ram() { "$ALIYUN" ram "$@" --region "$REGION" 2>&1; }

is_ok()   { printf '%s' "$1" | grep -q '"RequestId"'; }
is_notexist() { printf '%s' "$1" | grep -qE 'EntityNotExist|EntityNotFound'; }
is_exists()   { printf '%s' "$1" | grep -qE 'EntityAlreadyExists'; }

err_msg() { printf '%s' "$1" | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('[%s] %s' % (d.get('error_code') or d.get('Code') or 'Error', (d.get('message') or d.get('Message') or '')[:160]))
except Exception:
    pass" 2>/dev/null; }

jq_get() { # json_path  (点分路径，数组下标用数字；列表按行输出)
  "$PY" -c "
import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    if k=='' : continue
    if isinstance(d,list): d=d[int(k)]
    else: d=d.get(k)
    if d is None: break
if d is None:
    print('')
elif isinstance(d,list):
    print('\n'.join(json.dumps(x,ensure_ascii=False) for x in d))
elif isinstance(d,dict):
    print(json.dumps(d,ensure_ascii=False))
else:
    print(d)" 2>/dev/null
}

confirm() { # 提示文本
  [ "$ASSUME_YES" = "1" ] && { info "$1 → 已用 --yes 跳过确认"; return 0; }
  printf '  \033[33m%s\033[0m 输入 yes 继续: ' "$1"
  local a=""
  read -r a || true
  [ "$a" = "yes" ] || { say "  已取消"; return 1; }
  return 0
}

gen_pw() {
  "$PY" -c "
import random, string
pool = string.ascii_letters + string.digits
print('Aa1!' + ''.join(random.choice(pool) for _ in range(12)))"
}

# ── 查询 ──────────────────────────────────────────────────────────────
list_users() {
  head1 "RAM 用户列表（region=${REGION}）"
  say ""
  printf '  %-18s %-24s %-22s %-9s %-9s\n' "登录名称" "显示名称" "用户组" "控制台" "AK"
  printf '  %s\n' "-------------------------------------------------------------------------------------"
  local users u grps disp ctx ak
  users=$(ram ListUsers | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print('\n'.join(u['UserName'] for u in ((d.get('Users') or {}).get('User') or [])))" 2>/dev/null)
  if [ -z "$users" ]; then fail "未取到用户列表（检查权限或 region）"; return 1; fi
  for u in $users; do
    grps=$(ram ListGroupsForUser --UserName "$u" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
g=[x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])]
print(','.join(g) if g else '-')" 2>/dev/null)
    disp=$(ram GetUser --UserName "$u" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
print((d.get('User') or {}).get('DisplayName') or '-')" 2>/dev/null)
    ctx=$(ram GetLoginProfile --UserName "$u" | jq_get "LoginProfile.UserName")
    [ -n "$ctx" ] && ctx="已开启" || ctx="未开启"
    ak=$(ram ListAccessKeys --UserName "$u" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('0'); raise SystemExit
ks=((d.get('AccessKeys') or {}).get('AccessKey') or [])
act=[k for k in ks if k.get('Status')=='Active']
print('%d/%d' % (len(act), len(ks)))" 2>/dev/null)
    printf '  %-18s %-24s %-22s %-9s %-9s\n' "$u" "${disp:0:22}" "$grps" "$ctx" "$ak"
  done
  say ""
  info "AK 列 = 启用中/总数；控制台 = 是否配置登录密码"
}

list_groups() {
  head1 "RAM 用户组（region=${REGION}）"
  say ""
  printf '  %-22s %-8s %s\n' "用户组" "成员数" "已挂策略"
  printf '  %s\n' "-------------------------------------------------------------------------------------"
  local groups g pols cnt cm
  groups=$(ram ListGroups | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print('\n'.join(x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])))" 2>/dev/null)
  for g in $groups; do
    pols=$(ram ListPoliciesForGroup --GroupName "$g" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('-'); raise SystemExit
ps=[x['PolicyName'] for x in ((d.get('Policies') or {}).get('Policy') or [])]
print(', '.join(sorted(ps)) if ps else '-')" 2>/dev/null)
    cm=$(ram ListUsersForGroup --GroupName "$g" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('0'); raise SystemExit
print(len(((d.get('Users') or {}).get('User') or [])))" 2>/dev/null)
    printf '  %-22s %-8s %s\n' "$g" "$cm" "$pols"
  done
  say ""
  info "运维视角：改权限 = 改组策略（组内成员同步生效）"
}

list_policies() {
  head1 "自定义权限策略（region=${REGION}）"
  say ""
  printf '  %-26s %-6s %-9s %s\n' "策略名称" "版本" "关联数" "备注"
  printf '  %s\n' "-------------------------------------------------------------------------------------"
  ram ListPolicies --PolicyType Custom | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
for p in sorted(((d.get('Policies') or {}).get('Policy') or []), key=lambda x:x['PolicyName']):
    print('  %-26s %-6s %-9s %s' % (p['PolicyName'], p.get('DefaultVersion','-'), p.get('AttachmentCount',0), (p.get('Description') or '-')[:70]))" 2>/dev/null
  say ""
  printf '  %-26s %-9s %s\n' "系统策略（被引用）" "" ""
  for g in super_group power_user_group; do
    ram ListPoliciesForGroup --GroupName "$g" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
ps=[x['PolicyName'] for x in ((d.get('Policies') or {}).get('Policy') or []) if x.get('PolicyType')=='System']
for p in sorted(ps): print('  %-26s %-9s %s' % (p, 'system', '$g'))" 2>/dev/null
  done
}

who() {
  local u="${1:-}"
  [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh who <user>"
  head1 "用户详情：$u"
  local out
  out=$(ram GetUser --UserName "$u")
  if ! is_ok "$out"; then fail "用户不存在或无权限：$(err_msg "$out")"; return 1; fi
  printf '  显示名称  : %s\n' "$(printf '%s' "$out" | jq_get "User.DisplayName")"
  printf '  UserId    : %s\n' "$(printf '%s' "$out" | jq_get "User.UserId")"
  printf '  创建时间  : %s\n' "$(printf '%s' "$out" | jq_get "User.CreateDate")"

  say ""
  say "  —— 所属用户组 ——"
  ram ListGroupsForUser --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
gs=[x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])]
print('   ', ', '.join(gs) if gs else '(无组 → 该用户默认无任何权限)')" 2>/dev/null

  local g
  for g in $(ram ListGroupsForUser --UserName "$u" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(' '.join(x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])))" 2>/dev/null); do
    printf '     %-20s ' "$g"
    ram ListPoliciesForGroup --GroupName "$g" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
ps=[x['PolicyName'] for x in ((d.get('Policies') or {}).get('Policy') or [])]
print(', '.join(sorted(ps)) if ps else '-')" 2>/dev/null
  done

  say ""
  say "  —— 用户级策略（应为空，本项目铁律：只挂组）——"
  ram ListPoliciesForUser --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
ps=[x['PolicyName'] for x in ((d.get('Policies') or {}).get('Policy') or [])]
print('   ', ', '.join(ps) if ps else '空 ✓')" 2>/dev/null

  say ""
  say "  —— AccessKey ——"
  ram ListAccessKeys --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
ks=((d.get('AccessKeys') or {}).get('AccessKey') or [])
if not ks: print('    (无)')
for k in ks: print('    %s  %s  %s' % (k.get('AccessKeyId'), k.get('Status'), k.get('CreateDate','')))" 2>/dev/null

  say ""
  say "  —— 控制台登录 ——"
  out=$(ram GetLoginProfile --UserName "$u")
  if [ -n "$(printf '%s' "$out" | jq_get "LoginProfile.UserName")" ]; then
    printf '    已开启（MFABindRequired=%s, PasswordResetRequired=%s）\n' \
      "$(printf '%s' "$out" | jq_get "LoginProfile.MFABindRequired")" \
      "$(printf '%s' "$out" | jq_get "LoginProfile.PasswordResetRequired")"
  else
    say "    未开启（程序身份应为此状态 ✓）"
  fi

  say ""
  say "  —— MFA ——"
  out=$(ram GetUserMFAInfo --UserName "$u")
  local sn; sn=$(printf '%s' "$out" | jq_get "MFADevice.SerialNumber")
  if [ -n "$sn" ]; then
    printf '    已绑定  %s\n' "$sn"
  else
    say "    未绑定 ⚠（若该用户在挂 newapi-enforce-mfa 的组里，登录后除 MFA 自助动作外全被拒）"
  fi
}

# ── 新增 ──────────────────────────────────────────────────────────────
add_user() {
  local name="" disp="" want_ak=0 want_console=0 grp_csv="" email="" password=""
  name="${1:-}"; shift || true
  [ -n "$name" ] || die "用法: deploy/ops/ram_user_mgmt.sh add-user <登录名称> [显示名称] [--ak] [--console] [--group G1,G2] [--email 邮箱] [--password 初始密码]"
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then disp="$1"; shift; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --ak) want_ak=1 ;;
      --console) want_console=1 ;;
      --group) shift; grp_csv="${1:-}" ;;
      --email) shift; email="${1:-}" ;;
      --password) shift; password="${1:-}" ;;
      *) fail "未知参数：$1"; return 1 ;;
    esac
    shift
  done
  [ -n "$disp" ] || disp="$name"
  [ "$want_ak" = 1 ] && [ "$want_console" = 1 ] && \
    info "提示：同时开控制台+AK 会产生「人被 MFA 保护、AK 绕过 MFA」的缺口，建议拆成两个用户"
  [ -n "$password" ] && [ "$want_console" = 0 ] && \
    info "提示：未加 --console，--password 不会生效"

  # 自定义初始密码：按阿里云密码策略先本地挡一道（8-32 位，四类字符至少占三类）
  if [ -n "$password" ]; then
    local cls=0
    case "$password" in *[A-Z]*)           cls=$((cls+1));; esac
    case "$password" in *[a-z]*)           cls=$((cls+1));; esac
    case "$password" in *[0-9]*)           cls=$((cls+1));; esac
    case "$password" in *[!A-Za-z0-9]*)    cls=$((cls+1));; esac
    if [ "${#password}" -lt 8 ] || [ "${#password}" -gt 32 ]; then
      fail "自定义密码需 8-32 位（当前 ${#password} 位）"; return 1
    fi
    [ "$cls" -ge 3 ] || { fail "自定义密码需含大写/小写/数字/特殊字符中的至少三类"; return 1; }
  fi

  # --group 支持逗号分隔多个组：dev_group,ops-prod_group（顺带容错空格与空项）
  local groups=() g
  if [ -n "$grp_csv" ]; then
    while IFS= read -r g; do
      g="${g// /}"
      [ -n "$g" ] && groups+=("$g")
    done < <(printf '%s\n' "$grp_csv" | tr ',' '\n')
  fi

  head1 "新增用户：$name"
  say "  显示名称：$disp    控制台：$([ $want_console = 1 ] && echo 是 || echo 否)    AK：$([ $want_ak = 1 ] && echo 是 || echo 否)"
  say "  加入组：${grp_csv:-（无）}    安全邮箱：${email:-（无）}    初始密码：$([ -n "$password" ] && echo 自定义 || echo 随机生成)"
  confirm "即将创建用户" || return 1

  local out
  out=$(ram GetUser --UserName "$name")
  if is_ok "$out"; then
    skip "用户已存在：$name"
    if [ -n "$email" ]; then
      # UpdateUser 的 --NewUserName 是必填参数；传同名字符串 = 只改安全邮箱
      out=$(ram UpdateUser --UserName "$name" --NewUserName "$name" --NewEmail "$email")
      if is_ok "$out"; then ok "已补设安全邮箱：$email"; else fail "安全邮箱设置失败：$(err_msg "$out")"; fi
    fi
  else
    local create=(--UserName "$name" --DisplayName "$disp")
    [ -n "$email" ] && create+=(--Email "$email")
    out=$(ram CreateUser ${create[@]+"${create[@]}"})
    if is_ok "$out"; then ok "创建用户 ${name}（UserId=$(printf '%s' "$out" | jq_get "User.UserId")）"
    else fail "创建失败：$(err_msg "$out")"; return 1; fi
  fi

  if [ "$want_console" = 1 ]; then
    local pw="$password"
    [ -n "$pw" ] || pw=$(gen_pw)
    out=$(ram CreateLoginProfile --UserName "$name" --Password "$pw" \
          --PasswordResetRequired true --MFABindRequired true)
    if is_ok "$out"; then
      ok "已开启控制台登录（强制首次改密 + 强制绑 MFA）"
      # 控制台登录名是 UPN：<user>@<账号别名>.onaliyun.com
      # （GetUser/ListUsers 不返回该字段，只能按账号别名拼；取不到别名时退回裸用户名）
      local upn="$name" alias
      alias=$(ram GetAccountAlias | jq_get "AccountAlias")
      [ -n "$alias" ] && upn="$name@$alias.onaliyun.com"
      # 只用首尾分割线，不打竖边框（值长短不一，竖线反而难对齐）
      say ""
      say "  ───────────────────────────────────────────────────────"
      say "  登录名称 : $upn"
      say "  初始密码 : $pw"
      say "  登录地址 : $LOGIN_URL"
      [ -n "$email" ] && say "  安全邮箱 : $email"
      say "  ───────────────────────────────────────────────────────"
      say "  ⚠ 请通过安全渠道交给本人；首次登录会强制改密与绑定 MFA"
      [ "$SITE" = intl ] && info "登录地址按国际站显示；中国站（aliyun.com）账号请改用 RAM_SITE=cn"
    else
      fail "控制台登录创建失败：$(err_msg "$out")"
    fi
  fi

  if [ "$want_ak" = 1 ]; then
    out=$(ram CreateAccessKey --UserName "$name")
    if is_ok "$out"; then
      ok "已创建 AccessKey"
      say ""
      say "  ───────────────────────────────────────────────────────"
      say "  AccessKeyId     : $(printf '%s' "$out" | jq_get "AccessKey.AccessKeyId")"
      say "  AccessKeySecret : $(printf '%s' "$out" | jq_get "AccessKey.AccessKeySecret")"
      say "  ───────────────────────────────────────────────────────"
      say "  ⚠ Secret 仅此一次显示，请立即保存；不要提交到 git"
    else
      fail "AK 创建失败：$(err_msg "$out")"
    fi
  fi

  for g in ${groups[@]+"${groups[@]}"}; do
    join_group "$g" "$name"
  done
}

add_group() {
  local name="${1:-}" cmt="${2:-}"
  [ -n "$name" ] || die "用法: deploy/ops/ram_user_mgmt.sh add-group <组名> [备注]"
  head1 "新增用户组：$name"
  local out
  out=$(ram GetGroup --GroupName "$name")
  if is_ok "$out"; then skip "用户组已存在：$name"; else
    [ -n "$cmt" ] || cmt="$name"
    confirm "即将创建用户组 $name" || return 1
    out=$(ram CreateGroup --GroupName "$name" --Comments "$cmt")
    if is_ok "$out"; then ok "创建用户组 $name"; else fail "创建失败：$(err_msg "$out")"; return 1; fi
  fi
  say ""
  say "  下一步：绑定策略（策略只挂组，不挂用户）"
  say "    bash $0 attach $name newapi-ops-operator"
  say "    bash $0 attach $name newapi-enforce-mfa"
  say "    bash $0 attach $name newapi-audit-protect"
}

attach_policy() {
  local g="${1:-}" p="${2:-}" t="${3:-Custom}"
  [ -n "$g" ] && [ -n "$p" ] || die "用法: deploy/ops/ram_user_mgmt.sh attach <group> <policy> [Custom|System]"
  head1 "绑定策略：$g ← $p ($t)"
  local have
  have=$(ram ListPoliciesForGroup --GroupName "$g")
  if printf '%s' "$have" | grep -q "\"$p\""; then skip "已绑定"; return 0; fi
  confirm "即将绑定" || return 1
  local out; out=$(ram AttachPolicyToGroup --GroupName "$g" --PolicyName "$p" --PolicyType "$t")
  if is_ok "$out"; then ok "绑定成功"; else fail "绑定失败：$(err_msg "$out")"; return 1; fi
}

join_group() {
  local g="${1:-}" u="${2:-}"
  [ -n "$g" ] && [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh join <group> <user>"
  head1 "加入用户组：$u → $g"
  local in
  in=$(ram ListUsersForGroup --GroupName "$g")
  if printf '%s' "$in" | grep -q "\"$u\""; then skip "$u 已在该组"; return 0; fi
  confirm "即将加入（会立即生效该组全部策略）" || return 1
  local out; out=$(ram AddUserToGroup --GroupName "$g" --UserName "$u")
  if is_ok "$out"; then ok "加入成功"; else fail "加入失败：$(err_msg "$out")"; return 1; fi
  say ""
  say "  该用户现在的有效权限 = 所有所属组策略的并集，Deny 优先"
}

# ── 修改 ──────────────────────────────────────────────────────────────
set_display() {
  local u="${1:-}" d="${2:-}"
  [ -n "$u" ] && [ -n "$d" ] || die "用法: deploy/ops/ram_user_mgmt.sh set-display <user> <显示名>"
  head1 "改显示名称：$u → $d"
  confirm "即将修改" || return 1
  # UpdateUser 的 --NewUserName 是必填参数；传同名字符串 = 只改显示名称
  local out; out=$(ram UpdateUser --UserName "$u" --NewUserName "$u" --NewDisplayName "$d")
  if is_ok "$out"; then ok "修改成功"; else fail "失败：$(err_msg "$out")"; return 1; fi
}

reset_password() {
  local u="${1:-}"
  [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh reset-password <user>"
  head1 "重置控制台密码：$u"
  local pw; pw=$(gen_pw)
  confirm "即将重置密码（要求本人下次登录修改，且需 MFA）" || return 1
  local out
  out=$(ram GetLoginProfile --UserName "$u")
  if printf '%s' "$out" | grep -q '"LoginProfile"'; then
    out=$(ram UpdateLoginProfile --UserName "$u" --Password "$pw" --PasswordResetRequired true)
  else
    out=$(ram CreateLoginProfile --UserName "$u" --Password "$pw" \
          --PasswordResetRequired true --MFABindRequired true)
  fi
  if is_ok "$out"; then
    ok "已重置"
    printf '  新密码：\033[1m%s\033[0m\n' "$pw"
    say "  ⚠ 通过安全渠道交给本人"
  else
    fail "失败：$(err_msg "$out")"; return 1
  fi
}

new_ak() {
  local u="${1:-}"
  [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh new-ak <user>"
  head1 "新建 AccessKey：$u"
  local n
  n=$(ram ListAccessKeys --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print(len(((d.get('AccessKeys') or {}).get('AccessKey') or [])))" 2>/dev/null)
  [ "${n:-0}" -ge 2 ] && { fail "该用户已有 $n 个 AK（上限 2），请先禁用/删除不用的"; return 1; }
  confirm "即将创建 AK（Secret 仅显示一次）" || return 1
  local out; out=$(ram CreateAccessKey --UserName "$u")
  if is_ok "$out"; then
    ok "AK 已创建"
    printf '  AccessKeyId     : %s\n' "$(printf '%s' "$out" | jq_get "AccessKey.AccessKeyId")"
    printf '  AccessKeySecret : %s\n' "$(printf '%s' "$out" | jq_get "AccessKey.AccessKeySecret")"
    say "  ⚠ 立即保存，关闭后无法再查看"
  else
    fail "失败：$(err_msg "$out")"; return 1
  fi
}

toggle_ak() {
  local u="${1:-}" k="${2:-}" st="${3:-Inactive}"
  [ -n "$u" ] && [ -n "$k" ] || die "用法: deploy/ops/ram_user_mgmt.sh toggle-ak <user> <ak-id> [Active|Inactive]"
  case "$st" in Active|Inactive) : ;; *) die "状态只能是 Active 或 Inactive" ;; esac
  head1 "切换 AK 状态：$u / $k → $st"
  confirm "即将切换" || return 1
  local out; out=$(ram UpdateAccessKey --UserName "$u" --UserAccessKeyId "$k" --Status "$st")
  if is_ok "$out"; then
    ok "已切换为 $st"
    [ "$st" = "Inactive" ] && info "禁用后依赖该 AK 的服务会立即失败，请确认已通知使用方"
  else
    fail "失败：$(err_msg "$out")"; return 1
  fi
}

del_ak() {
  local u="${1:-}" k="${2:-}"
  [ -n "$u" ] && [ -n "$k" ] || die "用法: deploy/ops/ram_user_mgmt.sh del-ak <user> <ak-id>"
  head1 "删除 AccessKey：$u / $k"
  printf '  \033[31m⚠ 不可恢复。依赖该 AK 的服务会立即中断。\033[0m\n'
  say "  建议先 toggle-ak 禁用并观察一段时间确认无调用。"
  confirm "确认删除 AK" || return 1
  local out; out=$(ram DeleteAccessKey --UserName "$u" --UserAccessKeyId "$k")
  if is_ok "$out"; then ok "已删除"; else fail "失败：$(err_msg "$out")"; return 1; fi
}

leave_group() {
  local g="${1:-}" u="${2:-}"
  [ -n "$g" ] && [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh leave <group> <user>"
  head1 "移出用户组：$u ✗ $g"
  confirm "即将移出（会立即失去该组全部权限）" || return 1
  local out; out=$(ram RemoveUserFromGroup --GroupName "$g" --UserName "$u")
  if is_ok "$out"; then ok "已移出"; else fail "失败：$(err_msg "$out")"; return 1; fi
  say ""
  printf '  %s 剩余组：' "$u"
  ram ListGroupsForUser --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
gs=[x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])]
print(', '.join(gs) if gs else '(无组 → 已无任何权限)')" 2>/dev/null
}

detach_policy() {
  local g="${1:-}" p="${2:-}" t="${3:-Custom}"
  [ -n "$g" ] && [ -n "$p" ] || die "用法: deploy/ops/ram_user_mgmt.sh detach <group> <policy> [Custom|System]"
  head1 "解绑策略：$g ✗ $p"
  confirm "即将解绑（会立即影响该组所有成员）" || return 1
  local out; out=$(ram DetachPolicyFromGroup --GroupName "$g" --PolicyName "$p" --PolicyType "$t")
  if is_ok "$out"; then ok "已解绑"; else fail "失败：$(err_msg "$out")"; return 1; fi
}

# ── 删除 ──────────────────────────────────────────────────────────────
del_user() {
  local u="${1:-}"
  [ -n "$u" ] || die "用法: deploy/ops/ram_user_mgmt.sh del-user <user>"
  head1 "删除用户：$u"
  ram GetUser --UserName "$u" >/dev/null 2>&1
  local out; out=$(ram GetUser --UserName "$u")
  is_ok "$out" || { skip "用户不存在：$u"; return 0; }

  # 前置检查 1：用户组（删除前自动全部移出，避免悬空引用）
  local gs
  gs=$(ram ListGroupsForUser --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(x['GroupName'] for x in ((d.get('Groups') or {}).get('Group') or [])))" 2>/dev/null)
  if [ -n "$gs" ]; then
    info "仍属于 ${gs// /, }，删除前将自动移出"
  else
    ok "不属于任何用户组"
  fi

  # 前置检查 2：AK
  local aks
  aks=$(ram ListAccessKeys --UserName "$u" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(k['AccessKeyId'] for k in ((d.get('AccessKeys') or {}).get('AccessKey') or [])))" 2>/dev/null)
  if [ -n "$aks" ]; then
    fail "仍有 AccessKey：$aks"
    say "  建议先禁用观察，再删除：bash $0 toggle-ak $u <ak-id> Inactive"
    return 1
  fi
  ok "无残留 AccessKey"

  # 前置检查 3：控制台登录
  local haslp=0
  [ -n "$(ram GetLoginProfile --UserName "$u" | jq_get "LoginProfile.UserName")" ] && haslp=1
  [ "$haslp" = 1 ] && info "该用户有控制台登录配置，将一并删除"

  say ""
  printf '  \033[31m⚠ 删除不可恢复：登录密码、AK、MFA 全部失效，依赖它的服务会中断。\033[0m\n'
  [ -n "$gs" ] && say "  将先移出用户组：${gs// /, }"
  confirm "确认删除 $u" || return 1

  local g
  for g in $gs; do
    out=$(ram RemoveUserFromGroup --GroupName "$g" --UserName "$u")
    if is_ok "$out"; then ok "已移出用户组 $g"
    else fail "移出用户组 $g 失败：$(err_msg "$out")"; return 1; fi
  done

  if [ "$haslp" = 1 ]; then
    out=$(ram DeleteLoginProfile --UserName "$u")
    is_ok "$out" && ok "已删除控制台登录配置" || fail "删除登录配置失败：$(err_msg "$out")"
  fi
  out=$(ram DeleteUser --UserName "$u")
  if is_ok "$out"; then ok "用户 $u 已删除"; else fail "删除失败：$(err_msg "$out")"; return 1; fi
}

del_group() {
  local g="${1:-}"
  [ -n "$g" ] || die "用法: deploy/ops/ram_user_mgmt.sh del-group <group>"
  head1 "删除用户组：$g"
  local out; out=$(ram GetGroup --GroupName "$g")
  is_ok "$out" || { skip "用户组不存在：$g"; return 0; }

  local us ps
  us=$(ram ListUsersForGroup --GroupName "$g" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(x['UserName'] for x in ((d.get('Users') or {}).get('User') or [])))" 2>/dev/null)
  if [ -n "$us" ]; then
    fail "组内仍有成员：$us"
    say "  请先移除：bash $0 leave $g <user>"
    return 1
  fi
  ok "无成员"

  ps=$(ram ListPoliciesForGroup --GroupName "$g" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
print(' '.join(x['PolicyName'] for x in ((d.get('Policies') or {}).get('Policy') or [])))" 2>/dev/null)
  if [ -n "$ps" ]; then
    fail "组上仍挂着策略：$ps"
    say "  请先解绑：bash $0 detach $g <policy>"
    return 1
  fi
  ok "无绑定策略"

  say ""
  printf '  \033[31m⚠ 删除不可恢复。\033[0m\n'
  confirm "确认删除用户组 $g" || return 1
  out=$(ram DeleteGroup --GroupName "$g")
  if is_ok "$out"; then ok "用户组 $g 已删除"; else fail "删除失败：$(err_msg "$out")"; return 1; fi
}

# ── 程序身份（AK 路线）────────────────────────────────────────────────
# 集群内工作负载用 RRSA（ram_rrsa_program_onboard.sh），集群外程序只能用 AK。
# 两者共用同一条策略，权限范围一致；差异只在"身份载体"。

program_ak_secret_file() { printf '%s/newapi-%s-program-ak.json' "${AK_SECRET_DIR:-$HOME/.aliyun}" "$SITE_NAME"; }

add_program_ak() {
  local site="${1:-}"
  [ -n "$site" ] || die "用法: deploy/ops/ram_user_mgmt.sh add-program-ak <mnl|jkt>"
  [ "${PROGRAM_LIB_MISSING:-0}" = 1 ] && die "缺少 deploy/lib/program_identity.sh"
  program_site "$site" || die "未知站点：$site（仅支持 mnl | jkt）"
  program_prefix_allowed || die "OSS_PREFIX 不能占用审计前缀 actiontrail"

  local secret_file; secret_file=$(program_ak_secret_file)
  head1 "程序身份 · AK 路线：${SITE_NAME}（${SITE_CLUSTER_NAME}）"
  say "  用户组 : $SITE_GROUP"
  say "  用户   : $SITE_USER（仅 AK，无控制台登录）"
  say "  策略   : $SITE_POLICY + newapi-audit-protect（只挂组）"
  say "  权限   : OSS ${BUCKET}/${PREFIX:-<整桶>}/*（actiontrail 前缀 Deny）"
  say "  Secret : $secret_file（0600，不回显）"
  confirm "即将创建/补齐上述资源" || return 1

  local out p t

  # 1) 策略
  out=$(ram GetPolicy --PolicyName "$SITE_POLICY" --PolicyType Custom)
  if is_ok "$out"; then
    skip "策略已存在：$SITE_POLICY"
  else
    out=$(ram CreatePolicy --PolicyName "$SITE_POLICY" --PolicyDocument "$(program_policy_doc)")
    is_ok "$out" && ok "已创建策略 $SITE_POLICY" || { fail "创建策略失败：$(err_msg "$out")"; return 1; }
  fi

  # 2) 用户组
  out=$(ram GetGroup --GroupName "$SITE_GROUP")
  if is_ok "$out"; then
    skip "用户组已存在：$SITE_GROUP"
  else
    out=$(ram CreateGroup --GroupName "$SITE_GROUP" --Comments "$SITE_GROUP_COMMENT")
    is_ok "$out" && ok "已创建用户组 $SITE_GROUP" || { fail "创建用户组失败：$(err_msg "$out")"; return 1; }
  fi

  # 3) 绑定策略（只挂组）
  for p in "$SITE_POLICY" newapi-audit-protect; do
    out=$(ram ListPoliciesForGroup --GroupName "$SITE_GROUP")
    if printf '%s' "$out" | grep -q "\"$p\""; then
      skip "已绑定 $p"
      continue
    fi
    t=Custom
    out=$(ram GetPolicy --PolicyName "$p" --PolicyType Custom)
    if ! is_ok "$out"; then
      t=System
      out=$(ram GetPolicy --PolicyName "$p" --PolicyType System)
    fi
    if ! is_ok "$out"; then
      fail "策略不存在：$p（跳过绑定）"
      continue
    fi
    out=$(ram AttachPolicyToGroup --GroupName "$SITE_GROUP" --PolicyName "$p" --PolicyType "$t")
    is_ok "$out" && ok "已绑定 $SITE_GROUP ← $p（$t）" || fail "绑定 $p 失败：$(err_msg "$out")"
  done

  # 4) 纯 AK 用户（不建控制台登录）
  out=$(ram GetUser --UserName "$SITE_USER")
  if is_ok "$out"; then
    skip "用户已存在：$SITE_USER"
  else
    out=$(ram CreateUser --UserName "$SITE_USER" --DisplayName "$SITE_USER" \
            --Comments "program identity (AK only, no console login)")
    is_ok "$out" && ok "已创建用户 $SITE_USER" || { fail "创建用户失败：$(err_msg "$out")"; return 1; }
  fi

  out=$(ram GetLoginProfile --UserName "$SITE_USER")
  if printf '%s' "$out" | grep -q '"LoginProfile"'; then
    fail "$SITE_USER 存在控制台登录配置，拒绝继续（纯程序身份不允许登录）"
    return 1
  fi
  ok "无控制台登录"

  # 5) 加入用户组
  out=$(ram ListUsersForGroup --GroupName "$SITE_GROUP")
  if printf '%s' "$out" | grep -q "\"$SITE_USER\""; then
    skip "$SITE_USER 已在该组"
  else
    out=$(ram AddUserToGroup --GroupName "$SITE_GROUP" --UserName "$SITE_USER")
    is_ok "$out" && ok "$SITE_USER → $SITE_GROUP" || { fail "加入用户组失败：$(err_msg "$out")"; return 1; }
  fi

  # 6) AccessKey：Secret 只落盘，不进终端
  local n akid aksecret
  n=$(ram ListAccessKeys --UserName "$SITE_USER" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(len(((d.get('AccessKeys') or {}).get('AccessKey') or [])))" 2>/dev/null)
  if [ "${n:-0}" -ge 1 ]; then
    skip "已有 ${n} 个 AK（上限 2），不重复创建；如需轮转先禁用旧的再 new-ak"
  else
    out=$(ram CreateAccessKey --UserName "$SITE_USER")
    if ! is_ok "$out"; then
      fail "创建 AK 失败：$(err_msg "$out")"
      return 1
    fi
    akid=$(printf '%s' "$out" | jq_get "AccessKey.AccessKeyId")
    aksecret=$(printf '%s' "$out" | jq_get "AccessKey.AccessKeySecret")
    mkdir -p "$(dirname "$secret_file")"
    umask 077
    printf '{"site":"%s","user":"%s","accessKeyId":"%s","accessKeySecret":"%s"}\n' \
      "$SITE_NAME" "$SITE_USER" "$akid" "$aksecret" > "$secret_file"
    chmod 600 "$secret_file"
    ok "已创建 AK：$akid"
    say "  Secret 已写入（0600）：$secret_file"
    say "  ⚠ 仅此一次可见；请立即转入密钥管理并删除该文件"
  fi

  say ""
  say "  交付约束：禁止进入 git / 镜像层 / 聊天记录；建议 90 天轮转"
  say "  轮转：new-ak $SITE_USER → 切换 → toggle-ak $SITE_USER <旧AK> Inactive → 观察 → del-ak"
}

verify_program_ak() {
  local site="${1:-}"
  [ -n "$site" ] || die "用法: deploy/ops/ram_user_mgmt.sh verify-program-ak <mnl|jkt>"
  [ "${PROGRAM_LIB_MISSING:-0}" = 1 ] && die "缺少 deploy/lib/program_identity.sh"
  program_site "$site" || die "未知站点：$site（仅支持 mnl | jkt）"

  head1 "校验程序身份 · AK 路线：${SITE_NAME}"
  local rc=0 out

  out=$(ram GetPolicy --PolicyName "$SITE_POLICY" --PolicyType Custom)
  is_ok "$out" && ok "策略存在：$SITE_POLICY" || { fail "策略缺失：$SITE_POLICY"; rc=1; }

  out=$(ram GetGroup --GroupName "$SITE_GROUP")
  if is_ok "$out"; then
    ok "用户组存在：$SITE_GROUP"
    out=$(ram ListPoliciesForGroup --GroupName "$SITE_GROUP")
    printf '%s' "$out" | grep -q "\"$SITE_POLICY\"" && ok "已挂 $SITE_POLICY" || { fail "未挂 $SITE_POLICY"; rc=1; }
    printf '%s' "$out" | grep -q '"newapi-audit-protect"' && ok "已挂 newapi-audit-protect" || say "  提示：未挂 newapi-audit-protect"
  else
    fail "用户组缺失：$SITE_GROUP"; rc=1
  fi

  out=$(ram GetUser --UserName "$SITE_USER")
  if is_ok "$out"; then
    ok "用户存在：$SITE_USER"
    out=$(ram GetLoginProfile --UserName "$SITE_USER")
    printf '%s' "$out" | grep -q '"LoginProfile"' && { fail "存在控制台登录配置"; rc=1; } || ok "无控制台登录"

    out=$(ram ListUsersForGroup --GroupName "$SITE_GROUP")
    printf '%s' "$out" | grep -q "\"$SITE_USER\"" && ok "已在 $SITE_GROUP" || { fail "未加入 $SITE_GROUP"; rc=1; }

    local up
    up=$(ram ListPoliciesForUser --UserName "$SITE_USER" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
print(len(((d.get('Policies') or {}).get('Policy') or [])))" 2>/dev/null)
    if [ "${up:-?}" = 0 ]; then
      ok "无用户级直挂策略"
    else
      fail "存在 ${up} 条用户级直挂策略（违反只挂组）"; rc=1
    fi

    ram ListAccessKeys --UserName "$SITE_USER" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
ks=((d.get('AccessKeys') or {}).get('AccessKey') or [])
print('  AK: ' + (', '.join('%s(%s)' % (k['AccessKeyId'], k.get('Status')) for k in ks) if ks else '无'))
act=[k for k in ks if k.get('Status')=='Active']
raise SystemExit(0 if act else 3)" 2>/dev/null || { fail "没有启用中的 AK"; rc=1; }
  else
    fail "用户缺失：$SITE_USER"; rc=1
  fi

  say ""
  say "  范围：OSS ${BUCKET}/${PREFIX:-<整桶>}/* ；Secret：$(program_ak_secret_file)"
  if [ "$rc" = 0 ]; then ok "校验全部通过"; else fail "存在未通过项"; fi
  return "$rc"
}

# ── 帮助与分发 ────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
ram_user_mgmt.sh —— 阿里云 RAM 用户/组/策略 增删改查

查询
  users                          列出所有用户（含所属组、控制台状态、AK 数）
  groups                         列出所有用户组（含策略、成员数）
  policies                       列出所有自定义策略 + 被引用的系统策略
  who <user>                     查单个用户全貌（组/策略/AK/MFA/登录）

新增
  add-user <名称> [显示名] [--ak] [--console] [--group G1,G2] [--email 邮箱] [--password 初始密码]
                                 建用户；--ak 建 AK；--console 开控制台登录并打印初始密码
                                 --group 可用逗号分隔一次性加入多个组
                                 --email 设置安全邮箱（仅中国站 aliyun.com 支持；用户已存在时补设）
                                 --password 自定义初始密码；不给则随机生成
                                 （要求 8-32 位，且大写/小写/数字/特殊字符至少占三类，需与 --console 同用）
                                 例：add-user yxw yxw --console --group dev_group,ops-prod_group --email yxw@5108890064395960.onaliyun.com
  add-group <组名> [备注]        建用户组
  attach <组> <策略> [Custom|System]   给组绑策略
  join <组> <用户>               把用户加入组
  add-program-ak <mnl|jkt>       程序身份（AK 路线）：建/补齐 用户组 + 纯 AK 用户 + 策略
                                 Secret 写入 $AK_SECRET_DIR（默认 ~/.aliyun，0600），不回显
                                 集群内工作负载请改用 RRSA：deploy/ops/ram_rrsa_program_onboard.sh
  verify-program-ak <mnl|jkt>    回读校验：组/用户/无控制台/无用户级策略/AK 状态

修改
  set-display <用户> <显示名>    改显示名称
  reset-password <用户>          重置/开启控制台密码（打印新密码）
  new-ak <用户>                  新建 AccessKey（打印 Secret）
  toggle-ak <用户> <AKID> [Active|Inactive]   启用/禁用 AK
  del-ak <用户> <AKID>           删除 AccessKey（不可恢复；删用户前必须清空）
  leave <组> <用户>              把用户移出组
  detach <组> <策略> [Custom|System]    解绑组策略

删除
  del-user <用户>                删用户（自动移出所有用户组；仍要求先清空 AK；需 yes 确认）
  del-group <组>                 删用户组（先检查成员与策略）

全局
  -h | help                      显示本帮助
  --yes                          跳过交互确认（脚本/CI 用，谨慎）

环境
  RAM_REGION   默认 ap-southeast-1     ALIYUN_BIN  默认 aliyun
  RAM_SITE     控制台登录地址站点：intl = 国际站（signin.alibabacloud.com，默认）
                                   cn   = 中国站（signin.aliyun.com）
               不设置时按 RAM_REGION 推断：cn-* 视为中国站，其余为国际站
  需先配置 AK/SK：aliyun configure --profile default --mode AK

铁律（本脚本刻意遵守）
  1. 策略只挂用户组，不挂用户 —— 因此**没有** attach-user 命令
  2. 人用控制台 + MFA，程序用 AK，两者分开建用户
  3. 删用户会自动移出所有用户组（不留悬空引用），但 AK 必须先手动清空/禁用
EOF
}

main() {
  # 全局 --yes 可出现在任意位置
  local args=()
  local a
  for a in "$@"; do
    if [ "$a" = "--yes" ]; then ASSUME_YES=1; else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}

  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    users|groups|policies|who) need_cli ;;
    add-user|add-group|attach|join|add-program-ak|verify-program-ak|set-display|reset-password|new-ak|toggle-ak|del-ak|leave|detach|del-user|del-group) need_cli ;;
    help|-h|--help) usage; exit 0 ;;
    *) say "未知命令：$cmd"; say ""; usage; exit 1 ;;
  esac

  case "$cmd" in
    users)          list_users ;;
    groups)         list_groups ;;
    policies)       list_policies ;;
    who)            who "${1:-}" ;;
    add-user)       add_user "$@" ;;
    add-group)      add_group "${1:-}" "${2:-}" ;;
    attach)         attach_policy "${1:-}" "${2:-}" "${3:-Custom}" ;;
    join)           join_group "${1:-}" "${2:-}" ;;
    set-display)    set_display "${1:-}" "${2:-}" ;;
    reset-password) reset_password "${1:-}" ;;
    new-ak)         new_ak "${1:-}" ;;
    toggle-ak)      toggle_ak "${1:-}" "${2:-}" "${3:-Inactive}" ;;
    del-ak)         del_ak "${1:-}" "${2:-}" ;;
    leave)          leave_group "${1:-}" "${2:-}" ;;
    detach)         detach_policy "${1:-}" "${2:-}" "${3:-Custom}" ;;
    del-user)       del_user "${1:-}" ;;
    del-group)      del_group "${1:-}" ;;
    add-program-ak)    add_program_ak "${1:-}" ;;
    verify-program-ak) verify_program_ak "${1:-}" ;;
  esac
}

main "$@"
