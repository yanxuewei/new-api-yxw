#!/usr/bin/env bash
# probe_rg_condition.sh — 验证 acs:ResourceGroupId 条件键对 OSS 是否真正生效
#
# 做法：临时把 newapi-prod-boundary 绑到 iac-terraform（有 AK、有 oss:* Allow），
#       用 AK 直连实测生产桶/非生产桶，测完【立即解绑】恢复原状。
# 零副作用：全部用「删除不存在的对象」，不写任何数据。
#
# 用法: bash probe_rg_condition.sh
set -uo pipefail

REGION=ap-southeast-1
AL="/Users/yanxuewei/.workbuddy/binaries/aliyun-cli/aliyun"
OSSUTIL="$HOME/.workbuddy/binaries/ossutil/ossutil"
SECRETS="$HOME/.aliyun/newapi-ram-secrets.json"
BOUNDARY="newapi-prod-boundary"
PROBE_USER="iac-terraform"
KEY="probe/__rgprobe_nonexistent__.txt"

probe() {
  /usr/bin/python3 - "$SECRETS" "$OSSUTIL" "$KEY" <<'PY'
import json, subprocess, sys
sec, ossutil, key = sys.argv[1], sys.argv[2], sys.argv[3]
ak = json.load(open(sec))["access_keys"]["iac-terraform"]
buckets = [
    ("oss-newapi-mnl",         "ap-southeast-6", "生产主桶 rg-ph-mnl"),
    ("oss-newapi-backup-sgp",  "ap-southeast-1", "生产备桶 rg-sg"),
    ("oss-newapi-nonprod",     "ap-southeast-6", "非生产桶(不存在,对照组)"),
]
DENY = ("accessdenied", "access denied", "forbidden", "denied")

def run(bucket, region):
    cmd = [ossutil, "api", "delete-object", "--bucket", bucket, "--key", key,
           "--region", region, "--endpoint", "oss-%s.aliyuncs.com" % region,
           "--access-key-id", ak["AccessKeyId"], "--access-key-secret", ak["AccessKeySecret"]]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    out = ((p.stdout or "") + (p.stderr or ""))
    low = out.lower()
    if any(h in low for h in DENY):
        return "DENY", out.strip().splitlines()[0][:90] if out.strip() else ""
    if "nosuchbucket" in low or "no such bucket" in low:
        return "NOBUCKET", ""
    if p.returncode == 0:
        return "ALLOW", ""
    return "ERR", (out.strip().splitlines()[0][:90] if out.strip() else "rc=%d" % p.returncode)

print("%-24s %-26s %-9s %s" % ("BUCKET", "NOTE", "RESULT", "DETAIL"))
print("-" * 96)
for b, r, note in buckets:
    res, det = run(b, r)
    print("%-24s %-26s %-9s %s" % (b, note, res, det))
PY
}

echo "======== A. 基线（未绑 boundary）========"
probe

echo
echo "======== 绑定 $BOUNDARY → $PROBE_USER ========"
"$AL" ram AttachPolicyToUser --UserName "$PROBE_USER" --PolicyName "$BOUNDARY" \
  --PolicyType Custom --region "$REGION" 2>&1 | head -c 200
echo "  attached"
sleep 15

echo
echo "======== B. 绑定后（RG 条件若生效 → 生产桶应 DENY，非生产桶不受影响）========"
probe

echo
echo "======== 回滚：解绑 $BOUNDARY ← $PROBE_USER ========"
"$AL" ram DetachPolicyFromUser --UserName "$PROBE_USER" --PolicyName "$BOUNDARY" \
  --PolicyType Custom --region "$REGION" 2>&1 | head -c 200
echo "  detached"
sleep 10

echo
echo "======== C. 解绑后（应恢复基线）========"
probe

echo
echo "======== 用户级绑定复核（应为空）========"
"$AL" ram ListPoliciesForUser --UserName "$PROBE_USER" --region "$REGION" 2>&1 \
 | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
print([p['PolicyName'] for p in ((d.get('Policies') or {}).get('Policy') or [])] or '— 空 ✅')"
