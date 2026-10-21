#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# deploy/ops/ram_rrsa_program_onboard.sh —— ACK 工作负载程序身份（RRSA）
#
# 每个 ACK 集群开 RRSA 后都会生成**自己的** OIDC Provider，名字固定为
#   ack-rrsa-<cluster_id>
# 因此两个集群必须各建一个角色，不能共用（issuer 不匹配，AssumeRole 必失败）。
#
# 站点差异集中在 SITE 配置块里：
#   mnl（生产·马尼拉）  new-api / new-api-app     → oss-newapi-mnl/artifacts
#   jkt（dev·雅加达）   newapi-dev / new-api-app  → oss-newapi-jkt-dev/artifacts
#
# 权限模型（两站点一致）：
#   Allow  oss 对象读写，仅限 <bucket>/<prefix>/*
#   Deny   oss:* 命中 actiontrail/*（生产桶同时是审计落盘桶；dev 桶无此前缀也无害）
#   Deny   ram/account/bss/DeleteBucket
#
# 用法：
#   bash deploy/ops/ram_rrsa_program_onboard.sh [--site mnl|jkt] [check|apply|verify]
#
# 环境变量：
#   RAM_REGION      RAM 接口 region，默认 ap-southeast-1（全局服务，仅定 endpoint）
#   OSS_BUCKET      覆盖默认桶
#   OSS_PREFIX      覆盖默认前缀；传空字符串 = 整桶（会打印告警）
#   ALIYUN_BIN / PY_BIN
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

RAM_REGION="${RAM_REGION:-ap-southeast-1}"
ALIYUN="${ALIYUN_BIN:-aliyun}"
PY="${PY_BIN:-python3}"
ACCOUNT_ID="5108890064395960"
TOKEN_FILE="/var/run/secrets/ack.alibabacloud.com/rrsa-tokens/token"

usage() {
  cat <<'EOF'
用法: ram_rrsa_program_onboard.sh [--site mnl|jkt] [check|apply|verify]

  --site mnl   生产·马尼拉  ack-newapi-mnl      ns=new-api     桶=oss-newapi-mnl
  --site jkt   dev·雅加达   ack-newapi-jkt-dev  ns=newapi-dev  桶=oss-newapi-jkt-dev

  check    只读检查（含集群 RRSA 是否已开启）
  apply    建策略 + 建角色 + 绑定（集群未开 RRSA 时直接拒绝）
  verify   回读校验 + 打印 Pod 侧环境变量

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

case "$SITE" in
  mnl)
    CLUSTER_NAME="ack-newapi-mnl"
    CLUSTER_ID="cd57e40ce9a634c1698c2f5c5e09bd93c"
    CLUSTER_REGION="ap-southeast-6"
    NAMESPACE="new-api"
    SA_NAME="new-api-app"
    POLICY="newapi-prod-program"
    ROLE="new-api-prod-program"
    DEFAULT_BUCKET="oss-newapi-mnl"
    DEFAULT_PREFIX="artifacts"
    ;;
  jkt)
    CLUSTER_NAME="ack-newapi-jkt-dev"
    CLUSTER_ID="cb0abf5bc06034f7bbdb991752f6f3e62"
    CLUSTER_REGION="ap-southeast-5"
    NAMESPACE="newapi-dev"
    SA_NAME="new-api-app"
    POLICY="newapi-jkt-dev-program"
    ROLE="new-api-dev-program-jkt"
    DEFAULT_BUCKET="oss-newapi-jkt-dev"
    DEFAULT_PREFIX="artifacts"
    ;;
  *) printf '未知站点: %s（仅支持 mnl | jkt）\n' "$SITE" >&2; exit 1 ;;
esac

BUCKET="${OSS_BUCKET:-$DEFAULT_BUCKET}"
PREFIX="${OSS_PREFIX-$DEFAULT_PREFIX}"
OIDC_PROVIDER="acs:ram::${ACCOUNT_ID}:oidc-provider/ack-rrsa-${CLUSTER_ID}"
OIDC_ISSUER="https://oidc-ack-${CLUSTER_REGION}.oss-${CLUSTER_REGION}.aliyuncs.com/${CLUSTER_ID}"

if [ "$PREFIX" = "actiontrail" ] || [ "${PREFIX#actiontrail/}" != "$PREFIX" ]; then
  printf '拒绝：PREFIX 不能占用审计前缀 actiontrail\n' >&2; exit 1
fi

say()  { printf '%s\n' "$*"; }
info() { printf '  \033[36m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
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
  "$ALIYUN" cs DescribeClusterDetail --ClusterId "$CLUSTER_ID" --region "$CLUSTER_REGION" \
    --cli-query 'rrsa_config.enabled' 2>/dev/null | grep -q 'true'
}

policy_doc() {
  local object_scope="acs:oss:*:*:${BUCKET}"
  [ -n "$PREFIX" ] && object_scope="acs:oss:*:*:${BUCKET}/${PREFIX}/*"
  cat <<EOF
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":[
   "oss:PutObject","oss:GetObject","oss:DeleteObject",
   "oss:ListObjects","oss:GetBucketInfo",
   "oss:InitiateMultipartUpload","oss:UploadPart","oss:UploadPartCopy",
   "oss:CompleteMultipartUpload","oss:AbortMultipartUpload",
   "oss:ListParts","oss:ListMultipartUploads"
  ],"Resource":[
   "acs:oss:*:*:${BUCKET}",
   "${object_scope}"
  ]},
 {"Effect":"Deny","Action":["oss:*"],
  "Resource":[
   "acs:oss:*:*:${BUCKET}/actiontrail",
   "acs:oss:*:*:${BUCKET}/actiontrail/*"
  ]},
 {"Effect":"Deny","Action":["ram:*","account:*","bss:*","oss:DeleteBucket"],
  "Resource":["*"]}
]}
EOF
}

trust_doc() {
  cat <<EOF
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":"sts:AssumeRole","Principal":{
   "Federated":["${OIDC_PROVIDER}"]},
  "Condition":{"StringEquals":{
   "oidc:iss":"${OIDC_ISSUER}",
   "oidc:aud":"sts.aliyuncs.com",
   "oidc:sub":"system:serviceaccount:${NAMESPACE}:${SA_NAME}"}}}
]}
EOF
}

role_exists()   { ram GetRole --RoleName "$ROLE" | grep -q '"Role"'; }
policy_exists() { ram GetPolicy --PolicyName "$POLICY" --PolicyType Custom | grep -q '"Policy"'; }
attached()      { ram ListPoliciesForRole --RoleName "$ROLE" | grep -q "\"$POLICY\""; }

print_context() {
  say ""
  info "站点: ${SITE}（${CLUSTER_NAME} / ${CLUSTER_REGION}）"
  info "Pod : ${NAMESPACE}/${SA_NAME}"
  info "目标: ${BUCKET}/${PREFIX:-<整桶>}"
  info "OIDC: ${OIDC_PROVIDER}"
}

do_check() {
  say "== 检查现状（只读）=="
  if rrsa_enabled; then ok "集群 RRSA 已开启"; else fail "集群 RRSA 未开启 → 需先到控制台开启（集群信息 → 安全与审计 → RRSA）"; fi
  policy_exists && ok "策略 $POLICY 已存在" || say "  策略 $POLICY : 待创建"
  role_exists   && ok "角色 $ROLE 已存在"   || say "  角色 $ROLE : 待创建"
  if role_exists; then
    attached && ok "已绑定 $POLICY" || say "  绑定 : 未挂 $POLICY"
  fi
  print_context
}

do_apply() {
  rrsa_enabled || die "集群 ${CLUSTER_NAME} 未开启 RRSA，无法创建角色（信任策略引用的 Provider 尚不存在）。请先到控制台开启。"

  say "== 1. 自定义策略 $POLICY =="
  if policy_exists; then
    skip "策略已存在（改文档请走新版本：CreatePolicyVersion --SetAsDefault）"
  else
    ram CreatePolicy --PolicyName "$POLICY" --PolicyDocument "$(policy_doc)" >/dev/null \
      && ok "已创建策略 $POLICY" || die "创建策略失败"
  fi

  say "== 2. RAM 角色 $ROLE（RRSA 信任）=="
  if role_exists; then
    skip "角色已存在；若 SA/集群变更需 UpdateRole 重写信任策略"
  else
    ram CreateRole --RoleName "$ROLE" \
        --Description "${CLUSTER_NAME} workload (RRSA, OSS ${BUCKET}/${PREFIX:-<bucket>})" \
        --AssumeRolePolicyDocument "$(trust_doc)" >/dev/null \
      && ok "已创建角色 $ROLE" || die "创建角色失败"
  fi

  say "== 3. 绑定策略到角色 =="
  if attached; then
    skip "已绑定"
  else
    ram AttachPolicyToRole --RoleName "$ROLE" --PolicyName "$POLICY" --PolicyType Custom >/dev/null \
      && ok "已绑定 $ROLE ← $POLICY" || die "绑定失败"
  fi

  say ""
  say "== 4. Pod 侧环境变量 =="
  print_env
}

print_env() {
  say "  ALIBABA_CLOUD_ROLE_ARN=acs:ram::${ACCOUNT_ID}:role/${ROLE}"
  say "  ALIBABA_CLOUD_OIDC_PROVIDER_ARN=${OIDC_PROVIDER}"
  say "  ALIBABA_CLOUD_OIDC_TOKEN_FILE=${TOKEN_FILE}"
  info "ACK 会为使用该 SA 的 Pod 自动挂载 token，无需额外 volume"
}

do_verify() {
  say "== 回读校验 =="
  local rc=0
  rrsa_enabled && ok "集群 RRSA 已开启" || { fail "集群 RRSA 未开启"; rc=1; }
  policy_exists && ok "策略存在" || { fail "策略缺失"; rc=1; }
  role_exists   && ok "角色存在" || { fail "角色缺失"; rc=1; }

  if role_exists; then
    local sub
    sub=$(ram GetRole --RoleName "$ROLE" | "$PY" -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
doc=d.get('Role',{}).get('AssumeRolePolicyDocument','')
print('yes' if 'system:serviceaccount:${NAMESPACE}:${SA_NAME}' in doc else 'no')" 2>/dev/null)
    [ "$sub" = yes ] && ok "信任策略绑定 SA ${NAMESPACE}/${SA_NAME}" || { fail "信任策略 SA 不匹配"; rc=1; }
  fi

  attached && ok "已挂 $POLICY" || { fail "策略未绑定"; rc=1; }

  print_context
  say ""
  say "== 运行时验证（接入代码后执行）=="
  say "  kubectl -n ${NAMESPACE} exec deploy/<deploy> -- ls -l ${TOKEN_FILE}"
  say "  # 期望 200：PutObject 到 ${BUCKET}/${PREFIX:-<bucket>}/probe.txt"
  say "  # 期望 AccessDenied：任意 oss 动作命中 ${BUCKET}/actiontrail/"
  say "  # 期望 AccessDenied：aliyun ram ListUsers"

  say ""
  if [ "$rc" = 0 ]; then
    ok "RAM 侧校验全部通过"
    say ""
    say "== Pod 环境变量 =="
    print_env
  else
    fail "存在未通过项"
  fi
  return "$rc"
}

need_cli
case "$CMD" in
  check)  do_check ;;
  apply)  do_apply ;;
  verify) do_verify ;;
esac
