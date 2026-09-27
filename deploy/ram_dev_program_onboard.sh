#!/usr/bin/env bash
# ram_dev_program_onboard.sh — 开发同学「程序身份」开户
#
# 设计（人/程序双身份）：
#   人  : zhangzijun / xiangdong —— 已在 ops_group，控制台 + MFA，不发 AK
#   程序: dev-zhangzijun / dev-xiangdong —— 本脚本创建，仅 AK，无控制台登录
#
# 权限 = newapi-dev-program（自建）
#      + newapi-prod-boundary  (Deny 生产 RG 写)
#      + newapi-prod-oss-guard  (Deny 生产桶写，ARN 维度硬保护)
#
# 用法: bash ram_dev_program_onboard.sh [check|apply|verify]
set -uo pipefail

REGION=ap-southeast-1
AL="/Users/yanxuewei/.workbuddy/binaries/aliyun-cli/aliyun"
OUT="$(cd "$(dirname "$0")" && pwd)/.workbuddy/dev_program"
SECRETS_OUT="$HOME/.aliyun/newapi-dev-secrets.json"

GROUP="dev-program_group"
POLICY="newapi-dev-program"
DEV_USERS="dev-zhangzijun dev-xiangdong"

DEV_DOC='{"Version":"1","Statement":[
 {"Effect":"Allow","Action":[
   "ecs:Describe*","ecs:List*","vpc:Describe*","vpc:List*",
   "cs:Describe*","cs:List*","cs:Get*",
   "rds:Describe*","rds:List*","slb:Describe*","slb:List*",
   "alb:Describe*","alb:List*","alb:Get*",
   "waf:Describe*","waf:List*","waf:Get*",
   "alidns:Describe*","alidns:List*",
   "cms:Describe*","cms:Get*","cms:List*","cms:Query*",
   "log:Get*","log:List*","sls:Get*","sls:List*",
   "oss:Get*","oss:List*",
   "cr:Get*","cr:List*","cr:Pull*",
   "kms:Describe*","kms:List*",
   "pvtz:Describe*","cen:Describe*","cen:List*",
   "bss:Describe*","bss:Query*",
   "sts:GetCallerIdentity",
   "actiontrail:Describe*","actiontrail:Lookup*"
 ],"Resource":["*"]},
 {"Effect":"Allow",
  "Action":["oss:PutObject","oss:GetObject","oss:DeleteObject","oss:AbortMultipartUpload","oss:ListObjects","oss:GetBucketInfo"],
  "Resource":["acs:oss:*:*:oss-newapi-nonprod","acs:oss:*:*:oss-newapi-nonprod/*","acs:oss:*:*:oss-newapi-dev-*","acs:oss:*:*:oss-newapi-dev-*/*"]},
 {"Effect":"Allow",
  "Action":["cr:PushRepository","cr:PullRepository","cr:GetRepository","cr:ListRepository"],
  "Resource":["acs:cr:*:*:repository/*/newapi*","acs:cr:*:*:repository/newapi*","acs:cr:*:*:namespace/newapi*"]},
 {"Effect":"Deny",
  "Action":["ram:*","account:*","bss:Modify*","bss:Pay*","bss:Create*","bss:Renew*"],
  "Resource":["*"]}
]}'

say() { printf '%s\n' "$*"; }
ok=0; skip=0; fail=0

ensure_policy() {
  if "$AL" ram GetPolicy --PolicyName "$POLICY" --PolicyType Custom --region "$REGION" >/dev/null 2>&1; then
    say "  [SKIP] 策略已存在: $POLICY"; skip=$((skip+1)); return 0
  fi
  if "$AL" ram CreatePolicy --PolicyName "$POLICY" --PolicyDocument "$DEV_DOC" --region "$REGION" >/dev/null 2>&1; then
    say "  [OK]   创建策略 $POLICY"; ok=$((ok+1))
  else
    say "  [FAIL] 创建策略 $POLICY"; fail=$((fail+1)); return 1
  fi
}

ensure_group() {
  if "$AL" ram GetGroup --GroupName "$GROUP" --region "$REGION" >/dev/null 2>&1; then
    say "  [SKIP] 用户组已存在: $GROUP"; skip=$((skip+1))
  else
    "$AL" ram CreateGroup --GroupName "$GROUP" --Comments "new-api dev program identities (AK only)" \
      --region "$REGION" >/dev/null 2>&1 \
      && { say "  [OK]   创建用户组 $GROUP"; ok=$((ok+1)); } \
      || { say "  [FAIL] 创建用户组 $GROUP"; fail=$((fail+1)); }
  fi
  local p
  for p in "$POLICY" newapi-prod-boundary newapi-prod-oss-guard; do
    "$AL" ram AttachPolicyToGroup --GroupName "$GROUP" --PolicyName "$p" --PolicyType Custom \
      --region "$REGION" >/dev/null 2>&1 \
      && { say "  [OK]   $GROUP ← $p"; ok=$((ok+1)); } \
      || { say "  [SKIP] $GROUP ← $p (已绑或失败)"; skip=$((skip+1)); }
  done
}

ensure_dev_user() { # username
  local u="$1"
  if "$AL" ram GetUser --UserName "$u" --region "$REGION" >/dev/null 2>&1; then
    say "  [SKIP] 用户已存在: $u"; skip=$((skip+1))
  else
    "$AL" ram CreateUser --UserName "$u" --DisplayName "$u" --Comments "program identity (no console login)" \
      --region "$REGION" >/dev/null 2>&1 \
      && { say "  [OK]   创建用户 $u"; ok=$((ok+1)); } \
      || { say "  [FAIL] 创建用户 $u"; fail=$((fail+1)); return 1; }
  fi
  "$AL" ram AddUserToGroup --UserName "$u" --GroupName "$GROUP" --region "$REGION" >/dev/null 2>&1 \
    && { say "  [OK]   $u → $GROUP"; ok=$((ok+1)); } \
    || { say "  [SKIP] $u → $GROUP (已加入或失败)"; skip=$((skip+1)); }
}

case "${1:-check}" in
check)
  say "== 检查现状（只读）=="
  "$AL" ram GetPolicy --PolicyName "$POLICY" --PolicyType Custom --region "$REGION" >/dev/null 2>&1 \
    && say "  策略 $POLICY : 已存在" || say "  策略 $POLICY : 待创建"
  "$AL" ram GetGroup --GroupName "$GROUP" --region "$REGION" >/dev/null 2>&1 \
    && say "  用户组 $GROUP : 已存在" || say "  用户组 $GROUP : 待创建"
  for u in $DEV_USERS; do
    "$AL" ram GetUser --UserName "$u" --region "$REGION" >/dev/null 2>&1 \
      && say "  用户 $u : 已存在" || say "  用户 $u : 待创建"
  done
  ;;
apply)
  mkdir -p "$OUT"
  say "== 1. 策略 =="
  ensure_policy
  say "== 2. 用户组与绑定 =="
  ensure_group
  say "== 3. 程序用户 =="
  for u in $DEV_USERS; do ensure_dev_user "$u"; done

  say "== 4. 生成 AccessKey（Secret 仅返回一次，立即落盘）=="
  NEW_KEYS=""
  for u in $DEV_USERS; do
    resp=$("$AL" ram CreateAccessKey --UserName "$u" --region "$REGION" 2>&1)
    if echo "$resp" | grep -q '"AccessKeyId"'; then
      need=$u
      if [ -z "$NEW_KEYS" ]; then NEW_KEYS="$u"; else NEW_KEYS="$NEW_KEYS,$u"; fi
      echo "$resp" >"$OUT/ak_${u}.json"
      say "  [OK]   生成 AK: $u"
      ok=$((ok+1))
    else
      msg=$(echo "$resp" | head -c 120)
      if echo "$resp" | grep -qi 'LimitExceeded\|already'; then
        say "  [SKIP] $u 已有 AK（不再新建，避免超 2 个上限）"
        skip=$((skip+1))
      else
        say "  [FAIL] $u 生成 AK: $msg"
        fail=$((fail+1))
      fi
    fi
  done

  if [ -n "$NEW_KEYS" ]; then
    /usr/bin/python3 - "$SECRETS_OUT" "$OUT" "$NEW_KEYS" <<'PY'
import json, os, sys, stat
secrets_out, outdir, users = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
data = {}
if os.path.exists(secrets_out):
    data = json.load(open(secrets_out))
data.setdefault("_note", "new-api dev program identities (AK only, no console login)")
data.setdefault("_region", "ap-southeast-1")
data.setdefault("_warning", "plaintext secrets; chmod 600; rotate per policy")
ak = data.setdefault("access_keys", {})
for u in users:
    p = os.path.join(outdir, "ak_%s.json" % u)
    if not os.path.exists(p):
        continue
    k = json.load(open(p))["AccessKey"]
    ak[u] = {"AccessKeyId": k["AccessKeyId"], "AccessKeySecret": k["AccessKeySecret"],
             "Status": k["Status"]}
json.dump(data, open(secrets_out, "w"), indent=2, ensure_ascii=False)
os.chmod(secrets_out, stat.S_IRUSR | stat.S_IWUSR)
print("  凭据已写入 %s (600)" % secrets_out)
print("  账号: %s" % ", ".join(ak.keys()))
PY
    # 明文中间文件抹掉
    for u in $DEV_USERS; do : >"$OUT/ak_${u}.json" 2>/dev/null || true; done
  fi

  say ""
  say "结果: ok=$ok skip=$skip fail=$fail"
  ;;
verify)
  say "== 复核 =="
  "$AL" ram ListPoliciesForGroup --GroupName "$GROUP" --region "$REGION" 2>&1 \
   | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
ps=((d.get('Policies') or {}).get('Policy') or [])
print('  %s 策略数=%d' % ('$GROUP', len(ps)))
for p in sorted(ps, key=lambda x:x['PolicyName']): print('    %-28s %s' % (p['PolicyName'], p.get('PolicyType')))"
  "$AL" ram ListUsersForGroup --GroupName "$GROUP" --region "$REGION" 2>&1 \
   | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
us=[u['UserName'] for u in ((d.get('Users') or {}).get('User') or [])]
print('  成员: %s' % (us or '—'))"
  for u in $DEV_USERS; do
    printf "  %-18s AK=" "$u"
    "$AL" ram ListAccessKeys --UserName "$u" --region "$REGION" 2>&1 \
     | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
ks=((d.get('AccessKeys') or {}).get('AccessKey') or [])
print('%s  login=%s' % ([(k['AccessKeyId'][:14]+'..',k['Status']) for k in ks] or '-', 'NO (program identity)'))"
  done
  ;;
*)
  say "用法: bash ram_dev_program_onboard.sh [check|apply|verify]" ;;
esac
