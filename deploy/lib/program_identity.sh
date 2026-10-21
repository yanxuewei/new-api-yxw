#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# deploy/lib/program_identity.sh —— 程序身份的站点表与权限文档（不独立执行）
#
# 被 source：
#   deploy/ops/ram_rrsa_program_onboard.sh   RRSA：RAM 角色 + OIDC 信任
#   deploy/ops/ram_user_mgmt.sh         AK  ：用户组 + 纯 AK 用户
#
# 存在意义：站点参数和权限 JSON 只定义一次。两个脚本各写一份必然漂移，
# 而漂移的后果是"集群内能写、集群外不能写"这类难查的 403。
# ════════════════════════════════════════════════════════════════════════

PROGRAM_ACCOUNT_ID="${PROGRAM_ACCOUNT_ID:-5108890064395960}"
PROGRAM_TOKEN_FILE="/var/run/secrets/ack.alibabacloud.com/rrsa-tokens/token"

# 设置 SITE_*、BUCKET、PREFIX、OIDC_PROVIDER、OIDC_ISSUER
# 调用方可通过 OSS_BUCKET / OSS_PREFIX 覆盖桶与前缀
program_site() { # $1=mnl|jkt
  case "${1:-}" in
    mnl)
      SITE_NAME="mnl"
      SITE_CLUSTER_NAME="ack-newapi-mnl"
      SITE_CLUSTER_ID="cd57e40ce9a634c1698c2f5c5e09bd93c"
      SITE_REGION="ap-southeast-6"
      SITE_NAMESPACE="new-api"
      SITE_SA="new-api-app"
      SITE_POLICY="newapi-prod-program"
      SITE_ROLE="new-api-prod-program"
      SITE_GROUP="prod-program_group"
      SITE_USER="prod-program"
      SITE_GROUP_COMMENT="生产程序身份组(纯AK,无控制台)|策略:newapi-prod-program+audit-protect|注意:仅限生产桶指定前缀读写,RAM/账单/删桶全挡"
      SITE_DEFAULT_BUCKET="oss-newapi-mnl"
      SITE_DEFAULT_PREFIX="artifacts"
      ;;
    jkt)
      SITE_NAME="jkt"
      SITE_CLUSTER_NAME="ack-newapi-jkt-dev"
      SITE_CLUSTER_ID="cb0abf5bc06034f7bbdb991752f6f3e62"
      SITE_REGION="ap-southeast-5"
      SITE_NAMESPACE="newapi-dev"
      SITE_SA="new-api-app"
      SITE_POLICY="newapi-jkt-dev-program"
      SITE_ROLE="new-api-dev-program-jkt"
      SITE_GROUP="jkt-dev-program_group"
      SITE_USER="jkt-dev-program"
      SITE_GROUP_COMMENT="dev程序身份组(纯AK,无控制台)|策略:newapi-jkt-dev-program|注意:仅dev桶指定前缀读写,勿用于生产"
      SITE_DEFAULT_BUCKET="oss-newapi-jkt-dev"
      SITE_DEFAULT_PREFIX="artifacts"
      ;;
    *) return 1 ;;
  esac

  BUCKET="${OSS_BUCKET:-$SITE_DEFAULT_BUCKET}"
  PREFIX="${OSS_PREFIX-$SITE_DEFAULT_PREFIX}"   # 用 - 而非 :-，允许显式传空表示整桶
  OIDC_PROVIDER="acs:ram::${PROGRAM_ACCOUNT_ID}:oidc-provider/ack-rrsa-${SITE_CLUSTER_ID}"
  OIDC_ISSUER="https://oidc-ack-${SITE_REGION}.oss-${SITE_REGION}.aliyuncs.com/${SITE_CLUSTER_ID}"
  return 0
}

# 审计前缀不可占用：生产桶同时是 ActionTrail 落盘桶
program_prefix_allowed() {
  [ "$PREFIX" = "actiontrail" ] && return 1
  case "$PREFIX" in actiontrail/*) return 1 ;; esac
  return 0
}

program_policy_doc() {
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

program_trust_doc() {
  cat <<EOF
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":"sts:AssumeRole","Principal":{
   "Federated":["${OIDC_PROVIDER}"]},
  "Condition":{"StringEquals":{
   "oidc:iss":"${OIDC_ISSUER}",
   "oidc:aud":"sts.aliyuncs.com",
   "oidc:sub":"system:serviceaccount:${SITE_NAMESPACE}:${SITE_SA}"}}}
]}
EOF
}
