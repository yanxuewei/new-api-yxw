#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# deploy/ops/ram_rrsa_program_onboard.sh —— 集群内工作负载身份（RRSA）
#
# 只负责 RRSA：每集群一个 OIDC Provider（ack-rrsa-<cluster_id>），
# 因此每个站点各建一个角色，不能跨集群复用（issuer 不匹配）。
#
# 站点参数与权限 JSON 见 deploy/lib/program_identity.sh（与 AK 路线共用）。
# 集群外程序的 AK 开户在 deploy/ops/ram_user_mgmt.sh add-program-ak。
#
# 用法：
#   bash deploy/ops/ram_rrsa_program_onboard.sh [--site mnl|jkt] [check|apply|verify]
#
# 环境变量：OSS_BUCKET / OSS_PREFIX / RAM_REGION / ALIYUN_BIN / PY_BIN
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/program_identity.sh
. "$HERE/../lib/program_identity.sh" || { echo "缺少 deploy/lib/program_identity.sh" >&2; exit 1; }

RAM_REGION="${RAM_REGION:-ap-southeast-1}"
ALIYUN="${ALIYUN_BIN:-aliyun}"
PY="${PY_BIN:-python3}"

usage() {
  cat <<'EOF'
用法: ram_rrsa_program_onboard.sh [--site mnl|jkt] [check|apply|verify]

  --site mnl   生产·马尼拉  ack-newapi-mnl      ns=new-api     桶=oss-newapi-mnl
  --site jkt   dev·雅加达   ack-newapi-jkt-dev  ns=newapi-dev  桶=oss-newapi-jkt-dev

  check    只读检查（含集群 RRSA 是否已开启）
  apply    建策略 + 建角色 + 绑定；集群未开 RRSA 时直接拒绝
  verify   回读校验 + 打印 Pod 侧环境变量

集群外程序的 AK 开户: bash deploy/ops/ram_user_mgmt.sh add-program-ak <mnl|jkt>
环境变量: OSS_BUCKET / OSS_PREFIX / RAM_REGION / ALIYUN_BIN / PY_BIN
EOF
}

SITE="mnl"
CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --site)   SITE="${2:-}"; shift 2 ;;
    --site=*) SITE="${1#*=}"; shift ;;
    check|apply|verify) CMD="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n\n' "$1" >&2; usage; exit 1 ;;
  esac
done
[ -n "$CMD" ] || CMD=check

program_site "$SITE" || { printf '未知站点: %s（仅支持 mnl | jkt）\n' "$SITE" >&2; exit 1; }
program_prefix_allowed || { printf '拒绝：PREFIX 不能占用审计前缀 actiontrail\n' >&2; exit 1; }
[ -n "$PREFIX" ] || printf '\033[33m[WARN]\033[0m OSS_PREFIX 为空 ⇒ 授权整桶 %s\n' "$BUCKET" >&2

say()  { printf '%s\n' "$*"; }
info() { printf '  \033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
skip() { printf '  \033[33m[SKIP]\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 1; }

need_cli() {
  command -v "$ALIYUN" >/dev/null 2>&1 || die "找不到 aliyun CLI（export PATH=\"\$HOME/.workbuddy/binaries/aliyun-cli:\$PATH\"）"
  "$ALIYUN" sts GetCallerIdentity >/dev/null 2>&1 || die "凭证不可用：aliyun configure --profile default --mode AK"
}

ram() { "$ALIYUN" ram "$@" --region "$RAM_REGION" 2>&1; }

rrsa_enabled() {
  "$ALIYUN" cs DescribeClusterDetail --ClusterId "$SITE_CLUSTER_ID" --region "$SITE_REGION" \
    --cli-query 'rrsa_config.enabled' 2>/dev/null | grep -q 'true'
}

policy_exists() { ram GetPolicy --PolicyName "$SITE_POLICY" --PolicyType Custom | grep -q '"Policy"'; }
role_exists()   { ram GetRole --RoleName "$SITE_ROLE" | grep -q '"Role"'; }
role_attached() { ram ListPoliciesForRole --RoleName "$SITE_ROLE" | grep -q "\"$SITE_POLICY\""; }

print_context() {
  say ""
  info "站点: ${SITE_NAME}（${SITE_CLUSTER_NAME} / ${SITE_REGION}）"
  info "Pod : ${SITE_NAMESPACE}/${SITE_SA}"
  info "目标: ${BUCKET}/${PREFIX:-<整桶>}"
  info "OIDC: ${OIDC_PROVIDER}"
}

print_env() {
  say "  ALIBABA_CLOUD_ROLE_ARN=acs:ram::${PROGRAM_ACCOUNT_ID}:role/${SITE_ROLE}"
  say "  ALIBABA_CLOUD_OIDC_PROVIDER_ARN=${OIDC_PROVIDER}"
  say "  ALIBABA_CLOUD_OIDC_TOKEN_FILE=${PROGRAM_TOKEN_FILE}"
  info "ACK 会为使用该 SA 的 Pod 自动挂载 token，无需额外 volume"
}

do_check() {
  say "== 检查现状：RRSA =="
  rrsa_enabled && ok "集群 RRSA 已开启" || fail "集群 RRSA 未开启 → 需先到控制台开启（集群信息 → 安全与审计 → RRSA）"
  policy_exists && ok "策略 $SITE_POLICY 已存在" || say "  策略 $SITE_POLICY : 待创建"
  role_exists   && ok "角色 $SITE_ROLE 已存在"   || say "  角色 $SITE_ROLE : 待创建"
  role_exists && { role_attached && ok "已绑定 $SITE_POLICY" || say "  绑定 : 未挂 $SITE_POLICY"; }
  print_context
}

do_apply() {
  rrsa_enabled || die "集群 ${SITE_CLUSTER_NAME} 未开启 RRSA，无法创建角色（信任策略引用的 Provider 尚不存在）。请先到控制台开启。"

  say "== 1. 自定义策略 $SITE_POLICY =="
  if policy_exists; then
    skip "策略已存在（改文档请走新版本：CreatePolicyVersion --SetAsDefault）"
  else
    ram CreatePolicy --PolicyName "$SITE_POLICY" --PolicyDocument "$(program_policy_doc)" >/dev/null \
      && ok "已创建策略 $SITE_POLICY" || die "创建策略失败"
  fi

  say "== 2. RAM 角色 $SITE_ROLE（RRSA 信任）=="
  if role_exists; then
    skip "角色已存在；若 SA/集群变更需 UpdateRole 重写信任策略"
  else
    ram CreateRole --RoleName "$SITE_ROLE" \
        --Description "${SITE_CLUSTER_NAME} workload (RRSA, OSS ${BUCKET}/${PREFIX:-<bucket>})" \
        --AssumeRolePolicyDocument "$(program_trust_doc)" >/dev/null \
      && ok "已创建角色 $SITE_ROLE" || die "创建角色失败"
  fi

  say "== 3. 绑定策略到角色 =="
  if role_attached; then
    skip "已绑定"
  else
    ram AttachPolicyToRole --RoleName "$SITE_ROLE" --PolicyName "$SITE_POLICY" --PolicyType Custom >/dev/null \
      && ok "已绑定 $SITE_ROLE ← $SITE_POLICY" || die "绑定失败"
  fi

  say ""
  say "== 4. Pod 侧环境变量 =="
  print_env
}

do_verify() {
  say "== 回读校验：RRSA =="
  local rc=0
  rrsa_enabled && ok "集群 RRSA 已开启" || { fail "集群 RRSA 未开启"; rc=1; }
  policy_exists && ok "策略存在" || { fail "策略缺失"; rc=1; }
  role_exists   && ok "角色存在" || { fail "角色缺失"; rc=1; }

  if role_exists; then
    local sub
    sub=$(ram GetRole --RoleName "$SITE_ROLE" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
doc=d.get('Role',{}).get('AssumeRolePolicyDocument','')
print('yes' if 'system:serviceaccount:${SITE_NAMESPACE}:${SITE_SA}' in doc else 'no')" 2>/dev/null)
    [ "$sub" = yes ] && ok "信任策略绑定 SA ${SITE_NAMESPACE}/${SITE_SA}" || { fail "信任策略 SA 不匹配"; rc=1; }
  fi

  role_attached && ok "已挂 $SITE_POLICY" || { fail "策略未绑定"; rc=1; }

  print_context
  say ""
  say "== 运行时验证（接入代码后执行）=="
  say "  kubectl -n ${SITE_NAMESPACE} exec deploy/<deploy> -- ls -l ${PROGRAM_TOKEN_FILE}"
  say "  # 期望 200：PutObject 到 ${BUCKET}/${PREFIX:-<bucket>}/probe.txt"
  say "  # 期望 AccessDenied：任意 oss 动作命中 ${BUCKET}/actiontrail/"
  say "  # 期望 AccessDenied：aliyun ram ListUsers"
  say ""
  if [ "$rc" = 0 ]; then ok "RAM 侧校验全部通过"; say ""; print_env; else fail "存在未通过项"; fi
  return "$rc"
}

need_cli
case "$CMD" in
  check)  do_check ;;
  apply)  do_apply ;;
  verify) do_verify ;;
esac
