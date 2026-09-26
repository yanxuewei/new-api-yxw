#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# ram_group_annotate.sh —— RAM 用户组「中文备注」批量维护 + fin_group 财务组
#
# 解决的问题：
#   1) 新建财务组 fin_group（AliyunBSSReadOnlyAccess + newapi-audit-protect）
#   2) 给全部 9 个用户组写入**中文详细备注**（用途 / 策略 / 注意点），
#      让控制台「用户组」列表一眼看懂每个组能干什么、不能干什么
#
# 前置：aliyun-cli + 有效 AK/SK
#   export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"
#   aliyun configure --profile default --mode AK
#
# 用法：
#   bash ram_group_annotate.sh check     # 只看差异（只读）
#   bash ram_group_annotate.sh apply     # 备份 → 创建 fin_group → 绑策略 → 写备注
#   bash ram_group_annotate.sh verify    # 校验 9 组备注是否与目标一致 + 长度合规
#   bash ram_group_annotate.sh rollback  # 从最近一次备份恢复备注
#
# 注意：RAM 备注长度上限 **128 字符**（中文按 1 字符计），脚本会强制校验。
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

REGION="${RAM_REGION:-ap-southeast-1}"
ALIYUN="${ALIYUN_BIN:-aliyun}"
PY="${PY_BIN:-/usr/bin/python3}"
BACKUP_DIR=".workbuddy/ram_group_comments"

# ⚠️ 不要命名为 GROUPS —— bash 内建只读数组，赋值会被静默忽略
GROUP_LIST="admin_group cicd-push_group dev_group dev-program_group fin_group iac-terraform_group ops-prod_group ops_group power_user_group super_group"
GROUP_TOTAL=$(printf '%s' "$GROUP_LIST" | wc -w | tr -d ' ')

# ── 日志（一律走 stderr，避免被 $() 吞掉）────────────────────────────
say()  { printf '%s\n' "$*" >&2; }
info() { printf '  \033[36m%s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*" >&2; }
skip() { printf '  \033[33m[SKIP]\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }

ram()  { "$ALIYUN" ram "$@" --region "$REGION" 2>&1; }
is_ok(){ printf '%s' "$1" | grep -q '"RequestId"'; }
is_notexist(){ printf '%s' "$1" | grep -qE 'EntityNotExist|EntityNotFound'; }
is_exists()  { printf '%s' "$1" | grep -qE 'EntityAlreadyExists'; }

need_cli() {
  command -v "$ALIYUN" >/dev/null 2>&1 || die "找不到 aliyun CLI，请先 export PATH=\"\$HOME/.workbuddy/binaries/aliyun-cli:\$PATH\""
  local out; out=$("$ALIYUN" sts GetCallerIdentity 2>&1) || true
  case "$out" in *AccountId*) : ;; *) die "凭证不可用：$(printf '%s' "$out" | head -c 160)" ;; esac
}

# ══════════════════════════════════════════════════════════════════════
# 目标备注定义（唯一真源）—— 格式：<角色>|<策略>|注意:<边界与坑>
# 每条 ≤128 字符，含「能干什么」+「绝对不能干什么」
# ══════════════════════════════════════════════════════════════════════
comments_for() {
  case "$1" in
    admin_group)
      printf '%s' "管理人员组(人)|策略:newapi-admin-identity+audit-protect+enforce-mfa|注意:非生产全量管理,生产仅只读;登录控制台须绑MFA;策略仅组级承载,禁止用户级绑定" ;;
    fin_group)
      printf '%s' "财务组(人)|策略:AliyunBSSReadOnlyAccess+newapi-audit-protect|注意:仅查账单与费用,无资源写权限;纯控制台无AK;要看资源清单可另加ReadOnlyAccess" ;;
    ops_group)
      printf '%s' "非生产运维组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect+newapi-prod-boundary+newapi-prod-oss-guard|注意:生产只读,写全挡;须绑MFA;策略仅组级承载" ;;
    dev_group)
      printf '%s' "开发组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect+newapi-prod-boundary+newapi-prod-oss-guard|注意:非生产读写,生产只读;AK走dev程序组" ;;
    ops-prod_group)
      printf '%s' "生产运维组(人)|策略:newapi-ops-operator+enforce-mfa+audit-protect|注意:生产可写不可销毁,可删生产桶对象;优先走IaC,手工变更须补回Terraform;成员暂空" ;;
    dev-program_group)
      printf '%s' "开发程序身份组(纯AK,无控制台)|策略:newapi-dev-program+newapi-prod-boundary+newapi-prod-oss-guard|注意:生产只读,写全挡;禁开LoginProfile;AK严禁提交git" ;;
    iac-terraform_group)
      printf '%s' "Terraform IaC组(纯AK,无控制台)|策略:newapi-iac-terraform+newapi-audit-protect|注意:唯一能改生产OSS桶配置的自动化身份,故意不挂prod边界;变更须走流水线,勿手工跑" ;;
    cicd-push_group)
      printf '%s' "CI/CD镜像推送组(纯AK,无控制台)|策略:newapi-cicd-acr-push+newapi-audit-protect|注意:仅ACR镜像推拉权限;只发AK给流水线,不开控制台;勿并入其它组" ;;
    power_user_group)
      printf '%s' "所有资源组(人)|策略:PowerUserAccess+newapi-enforce-mfa+newapi-audit-protect|注意:权限近账号级,须绑MFA;仅临时查问题用,勿长期加人" ;;
    super_group)
      printf '%s' "主账号身份组(人)|策略:AdministratorAccess等20条|注意:是第二个主账号,不要轻易加人" ;;
    *) printf '%s' "" ;;
  esac
}

chars() { printf '%s' "$1" | "$PY" -c 'import sys;print(len(sys.stdin.read()))'; }

# 当前全部组 → "name<TAB>comments"
current_all() {
  ram ListGroups | "$PY" -c "
import sys,json
raw=sys.stdin.read(); i=raw.find('{')
try: d=json.loads(raw[i:])
except Exception: sys.exit(0)
for g in d.get('Groups',{}).get('Group',[]):
    print('%s\t%s' % (g['GroupName'], (g.get('Comments') or '').replace('\n',' ')))
"
}
# ── 当前状态缓存（避免反复拉 ListGroups）─────────────────────────────
# ⚠️ 不要用 awk '$1=""; print' 取备注：awk 重建记录会用 OFS(空格) 连接，
#    结果多一个前导空格 → 备注比对永远不相等（踩过：误判 9/9 不一致）
CUR_FILE=""
load_current() {
  [ -n "$CUR_FILE" ] && [ -s "$CUR_FILE" ] && return 0
  CUR_FILE=$(mktemp)
  current_all > "$CUR_FILE"
}
reset_current() { CUR_FILE=""; }

cur_of() { # $1=组名 → 纯备注（不换行）
  load_current
  "$PY" -c "
import sys
n=sys.argv[1]
for ln in open(sys.argv[2], encoding='utf-8'):
    p=ln.rstrip('\n').split('\t',1)
    if p[0]==n:
        sys.stdout.write(p[1] if len(p)>1 else ''); break
" "$1" "$CUR_FILE"
}
group_exists() { load_current; cut -f1 "$CUR_FILE" | grep -qx "$1"; }

# ══════════════════════════════════════════════════════════════════════
cmd_check() {
  head1 "① 备注差异检查（只读）"
  local g want got n=0
  for g in $GROUP_LIST; do
    want=$(comments_for "$g"); got=$(cur_of "$g")
    if ! group_exists "$g"; then
      info "$(printf '%-20s' "$g") 组不存在 → 将新建"
    elif [ "$want" = "$got" ]; then
      ok "$(printf '%-20s' "$g") 备注已一致"
    else
      n=$((n+1))
      say ""
      info "$(printf '%-20s' "$g") 需更新"
      say "    当前: ${got:-（空）}"
      say "    目标: ${want}"
    fi
  done
  say ""
  if [ "$n" -eq 0 ]; then ok "全部一致，无需变更"; else info "共 ${n} 个组待更新 → 执行：bash $0 apply"; fi
}

# 确保组存在 + 绑定指定策略（幂等）；策略写法 "PolicyName:PolicyType"
ensure_group() {
  local g="$1"; shift
  if group_exists "$g"; then
    skip "${g} 已存在"
  else
    local r; r=$(ram CreateGroup --GroupName "$g" --Comments "$(comments_for "$g")")
    if is_ok "$r"; then ok "已创建 ${g}"; reset_current
    elif is_exists "$r"; then skip "${g} 已存在（并发创建）"
    else fail "${g} 创建失败: $(printf '%s' "$r" | head -c 200)"; return 0; fi
  fi
  local p pn pt r2
  for p in "$@"; do
    pn="${p%%:*}"; pt="${p##*:}"
    r2=$(ram AttachPolicyToGroup --GroupName "$g" --PolicyName "$pn" --PolicyType "$pt")
    if is_ok "$r2"; then ok "  ${g} ← ${pn} (${pt})"
    elif printf '%s' "$r2" | grep -qE 'EntityAlreadyExists|PolicyAlreadyAttached'; then skip "  ${g} ← ${pn} 已绑定"
    else fail "  ${g} ← ${pn}: $(printf '%s' "$r2" | head -c 160)"; fi
  done
}

cmd_apply() {
  need_cli
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  local bak="${BACKUP_DIR}/backup_${ts}.tsv"

  head1 "① 备份当前备注 → ${bak}"
  reset_current; load_current && cp "$CUR_FILE" "$bak"
  ok "$(wc -l < "$bak" | tr -d ' ') 条记录已备份"

  # ── 特殊组：财务组 / 开发组（创建 + 绑策略，幂等）─────────────────
  head1 "② 特殊组"
  info "fin_group（财务，2 条策略）"
  ensure_group fin_group "AliyunBSSReadOnlyAccess:System" "newapi-audit-protect:Custom"
  info "dev_group（开发·人身份，5 条策略，与 ops_group 完全同权）"
  ensure_group dev_group "newapi-ops-operator:Custom" "newapi-enforce-mfa:Custom" \
    "newapi-audit-protect:Custom" "newapi-prod-boundary:Custom" "newapi-prod-oss-guard:Custom"
  info "power_user_group（应急全权组，补 2 条护栏：MFA 强制 + 审计保护）"
  ensure_group power_user_group "newapi-enforce-mfa:Custom" "newapi-audit-protect:Custom"

  # ── 备注写入 ────────────────────────────────────────────────────
  head1 "③ 写入中文备注"
  info "脚本是唯一真源：会覆盖控制台手工改动（已备份，rollback 可回退）"
  local g want got
  for g in $GROUP_LIST; do
    want=$(comments_for "$g")
    local len; len=$(chars "$want")
    if [ "$len" -gt 128 ]; then fail "${g} 备注 ${len} 字符，超 128 上限，跳过"; continue; fi
    got=$(cur_of "$g")
    if ! group_exists "$g"; then
      fail "${g} 组不存在，跳过（先建组）"; continue
    fi
    if [ "$want" = "$got" ]; then skip "${g} 备注已一致（${len} 字符）"; continue; fi
    local r3; r3=$(ram UpdateGroup --GroupName "$g" --NewComments "$want")
    if is_ok "$r3"; then ok "${g} 备注已更新（${len} 字符）"; reset_current; else fail "${g}: $(printf '%s' "$r3" | head -c 200)"; fi
  done
  say ""
  info "回滚：bash $0 rollback   （备份文件 ${bak}）"
}

cmd_verify() {
  head1 "① 特殊组存在性与策略"
  local gg
  for gg in fin_group dev_group power_user_group; do
    if group_exists "$gg"; then ok "${gg} 存在"; else fail "${gg} 不存在"; fi
    ram ListPoliciesForGroup --GroupName "$gg" | "$PY" -c "
import sys,json
raw=sys.stdin.read(); i=raw.find('{')
try: d=json.loads(raw[i:])
except Exception: sys.exit(0)
ps=d.get('Policies',{}).get('Policy',[])
print('    策略 %d 条: %s' % (len(ps), ', '.join(p['PolicyName'] for p in ps)))
" >&2
  done

  head1 "② 备注一致性（${GROUP_TOTAL} 组）"
  local bad=0 g want got len
  for g in $GROUP_LIST; do
    want=$(comments_for "$g"); got=$(cur_of "$g"); len=$(chars "$want")
    if [ "$want" = "$got" ]; then
      ok "$(printf '%-20s' "$g") 一致（${len} 字符）"
    else
      bad=$((bad+1)); fail "$(printf '%-20s' "$g") 不一致"
      say "    实际: ${got:-（空）}"
    fi
  done
  head1 "③ 结论"
  if [ "$bad" -eq 0 ]; then ok "${GROUP_TOTAL}/${GROUP_TOTAL} 通过"; else fail "${bad}/${GROUP_TOTAL} 个组未达标"; fi
  return "$bad"
}

cmd_rollback() {
  local bak; bak=$(ls -1t ${BACKUP_DIR}/backup_*.tsv 2>/dev/null | head -1)
  [ -n "$bak" ] || die "找不到备份文件"
  head1 "从 ${bak} 恢复备注"
  local g c
  while IFS=$'\t' read -r g c; do
    [ -n "$g" ] || continue
    local r; r=$(ram UpdateGroup --GroupName "$g" --NewComments "$c")
    if is_ok "$r"; then ok "${g} → ${c:-（空）}"; else fail "${g}: $(printf '%s' "$r" | head -c 160)"; fi
  done < "$bak"
}

case "${1:-help}" in
  check)    cmd_check ;;
  apply)    cmd_apply ;;
  verify)   cmd_verify ;;
  rollback) need_cli; cmd_rollback ;;
  *) cat >&2 <<EOF
ram_group_annotate.sh —— RAM 用户组中文备注维护 + fin_group 财务组

  check      只读检查：当前备注 vs 目标备注
  apply      备份 → 建 fin_group + 绑策略 → 写入 9 组中文备注
  verify     校验 fin_group 策略 + 9 组备注一致性
  rollback   从最近备份恢复备注

环境变量：RAM_REGION(默认 ap-southeast-1) ALIYUN_BIN(默认 aliyun)
EOF
  ;;
esac
