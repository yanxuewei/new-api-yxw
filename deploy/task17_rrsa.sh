#!/bin/bash
# task17_rrsa.sh — 任务 17 第 1 步：RRSA 角色 + KMS 只读策略（两地各一角色）
#
# 为什么两地要两个角色：信任策略里 oidc:iss / Federated 绑定的是**集群专属 OIDC Provider**，
# 马尼拉与新加坡的 OIDC 不同 → 同一角色无法同时被两集群 AssumeRole。
#
# usage: task17_rrsa.sh [--check|--apply]
set -uo pipefail

MODE="${1:---check}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/logs/task17_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

# 凭据名统一口径（UPPER_SNAKE，与 ExternalSecret fetch.key 对齐；修正原文档两处不一致）
SECRETS=(SQL_DSN SQL_DSN_MIGRATE REDIS_CONN_STRING SESSION_SECRET SESSION_SECRET_OLD PAYMENT_PRIVATE_KEY TLS_WILDCARD)

say() { echo "$@" >&2; }

# --- 取集群 rrsa 信息 ---
get_rrsa() { # $1=site $2=region $3=cid ; echo "OIDC_ARN|ISSUER"
  local site="$1" region="$2" cid="$3"
  local jf="$LOGDIR/cd_${site}.json"
  aliyun cs DescribeClusterDetail --ClusterId "$cid" --region "$region" > "$jf" 2>&1 || return 1
  python3 - "$jf" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rr=d.get("rrsa_config") or {}
arn=rr.get("oidc_arn","")
iss=(rr.get("issuer","") or "").split(",")[0].strip()
print("%s|%s" % (arn, iss))
PY
}

# --- 生成信任策略 ---
make_trust() { # $1=oidc_arn $2=issuer $3=out
  python3 - "$1" "$2" "$3" <<'PY'
import json,sys
arn,iss,out=sys.argv[1],sys.argv[2],sys.argv[3]
doc={"Version":"1","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow",
  "Principal":{"Federated":[arn]},
  "Condition":{"StringEquals":{
    "oidc:aud":"sts.aliyuncs.com",
    "oidc:iss":iss,
    "oidc:sub":"system:serviceaccount:new-api:new-api-app"}}}]}
open(out,"w").write(json.dumps(doc,ensure_ascii=False))
PY
}

# --- 生成 KMS 只读策略（精确到凭据 ARN，不给 *）---
make_policy() { # $1=out
  python3 - "$1" "${SECRETS[@]}" <<'PY'
import json,sys
out=sys.argv[1]; names=sys.argv[2:]
acct="5108890064395960"
res=[]
for reg in ("ap-southeast-6","ap-southeast-1"):
    for n in names:
        res.append("acs:kms:%s:%s:secret/new-api/prod/%s" % (reg, acct, n))
doc={"Version":"1","Statement":[{"Action":["kms:GetSecretValue"],"Effect":"Allow","Resource":res}]}
open(out,"w").write(json.dumps(doc,ensure_ascii=False))
PY
}

POLICY_NAME=new-api-kms-readonly
POLICY_FILE="$LOGDIR/policy.json"
make_policy "$POLICY_FILE"
say "[i] KMS 策略已生成：$POLICY_FILE（$(python3 -c "import json;print(len(json.load(open('$POLICY_FILE'))['Statement'][0]['Resource']),'个 ARN')")）"

if [ "$MODE" = "--apply" ]; then
  say "== 建/更新策略 $POLICY_NAME =="
  if aliyun ram GetPolicy --PolicyName "$POLICY_NAME" --PolicyType Custom --region ap-southeast-1 >/dev/null 2>&1; then
    say "  [skip] 策略已存在"
  else
    aliyun ram CreatePolicy --PolicyName "$POLICY_NAME" \
      --PolicyDocument "$(cat "$POLICY_FILE")" --region ap-southeast-1 > "$LOGDIR/policy_create.json" 2>&1 \
      && say "  [ok] 创建成功" || { say "  [FAIL]"; head -5 "$LOGDIR/policy_create.json"; }
  fi
fi

for pair in "mnl ap-southeast-6 cd57e40ce9a634c1698c2f5c5e09bd93c new-api-rrsa-kms-mnl" \
            "sg  ap-southeast-1 ca75829e3492d491d9d434de087913798 new-api-rrsa-kms-sg"; do
  set -- $pair
  SITE="$1"; REGION="$2"; CID="$3"; ROLE="$4"
  say ""
  say "======== [$SITE] 角色 $ROLE ========"
  INFO=$(get_rrsa "$SITE" "$REGION" "$CID") || { say "  [FAIL] 取 rrsa 失败"; continue; }
  OIDC_ARN="${INFO%%|*}"; ISSUER="${INFO##*|}"
  say "  oidc_arn = $OIDC_ARN"
  say "  issuer   = $ISSUER"
  TRUST="$LOGDIR/trust_$SITE.json"; make_trust "$OIDC_ARN" "$ISSUER" "$TRUST"

  if [ "$MODE" != "--apply" ]; then
    say "  (dry-run) 将创建角色 $ROLE，信任策略："
    say "  $(cat "$TRUST")"
    continue
  fi

  if aliyun ram GetRole --RoleName "$ROLE" --region ap-southeast-1 >/dev/null 2>&1; then
    say "  [skip] 角色已存在"
  else
    aliyun ram CreateRole --RoleName "$ROLE" --Description "new-api RRSA KMS access ($SITE)" \
      --AssumeRolePolicyDocument "$(cat "$TRUST")" --region ap-southeast-1 > "$LOGDIR/role_$SITE.json" 2>&1 \
      && say "  [ok] 角色创建成功" || { say "  [FAIL]"; head -5 "$LOGDIR/role_$SITE.json"; continue; }
  fi
  aliyun ram AttachPolicyToRole --RoleName "$ROLE" --PolicyName "$POLICY_NAME" --PolicyType Custom \
    --region ap-southeast-1 > "$LOGDIR/attach_$SITE.json" 2>&1 \
    && say "  [ok] 已附加策略 $POLICY_NAME" || { say "  [FAIL] 附加策略"; head -5 "$LOGDIR/attach_$SITE.json"; }
done

say ""
say "[i] 日志：$LOGDIR"
