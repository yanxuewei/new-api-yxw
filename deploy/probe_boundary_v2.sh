#!/usr/bin/env bash
# probe_boundary_v2.sh — 验证 newapi-prod-boundary v2（Deny 写 / 放行只读）
#
# v2 语义：对生产 RG(rg-ph-mnl, rg-sg) 的资源
#   - 只读动作(Describe/List/Get/Query) → 放行
#   - 其余(含所有写)                    → Deny
# 测法：临时绑 iac-terraform，AK 直连实测，测完立即解绑。零副作用（不创建任何资源）。
#
# 用法: bash probe_boundary_v2.sh
set -uo pipefail

REGION=ap-southeast-1
AL="/Users/yanxuewei/.workbuddy/binaries/aliyun-cli/aliyun"
SECRETS="$HOME/.aliyun/newapi-ram-secrets.json"
BOUNDARY="newapi-prod-boundary"
PROBE_USER="iac-terraform"

V2DOC='{"Version":"1","Statement":[{"Effect":"Deny","NotAction":["*:Describe*","*:List*","*:Get*","*:Query*"],"Resource":["*"],"Condition":{"StringEquals":{"acs:ResourceGroupId":["rg-aek4nyivmmsb6iy","rg-aek4zvb3ldoiyua"]}}}]}'

echo "======== 1. 发布 boundary v2（CreatePolicyVersion + SetAsDefault）========"
"$AL" ram CreatePolicyVersion --PolicyName "$BOUNDARY" --PolicyDocument "$V2DOC" \
  --SetAsDefault true --region "$REGION" 2>&1 | head -c 300
echo
"$AL" ram GetPolicy --PolicyName "$BOUNDARY" --PolicyType Custom --region "$REGION" 2>&1 \
 | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
doc=((d.get('DefaultPolicyVersion') or {}).get('PolicyDocument')) or ''
print('  默认版本=%s  %s' % ((d.get('Policy') or {}).get('DefaultVersion'), doc))"

echo
echo "======== 2. 基线实测（未绑）========"
probe() {
  /usr/bin/python3 - "$SECRETS" "$HOME/.workbuddy/binaries/ossutil/ossutil" "$AL" "$REGION" <<'PY'
import json, subprocess, sys
sec, ossutil, aliyun, region = sys.argv[1:5]
ak = json.load(open(sec))["access_keys"]["iac-terraform"]
DENY = ("accessdenied", "access denied", "forbidden", "denied", "not authorized", "no permission")

def verdict(p):
    out = (p.stdout or "") + (p.stderr or "")
    low = out.lower()
    if any(h in low for h in DENY):
        return "DENY", out.strip().splitlines()[0][:80] if out.strip() else ""
    if "nosuchbucket" in low or "no such bucket" in low:
        return "NOBUCKET", ""
    if p.returncode == 0:
        return "ALLOW", ""
    return "ERR", (out.strip().splitlines()[0][:80] if out.strip() else "rc=%d" % p.returncode)

def ali(action, extra):
    cmd = [aliyun, "--access-key-id", ak["AccessKeyId"], "--access-key-secret",
           ak["AccessKeySecret"]] + action + extra
    return verdict(subprocess.run(cmd, capture_output=True, text=True, timeout=90))

def oss(bucket, r):
    cmd = [ossutil, "api", "delete-object", "--bucket", bucket,
           "--key", "probe/__boundary_probe__.txt", "--region", r,
           "--endpoint", "oss-%s.aliyuncs.com" % r,
           "--access-key-id", ak["AccessKeyId"], "--access-key-secret", ak["AccessKeySecret"]]
    return verdict(subprocess.run(cmd, capture_output=True, text=True, timeout=90))

cases = [
    ("生产OSS写 oss-newapi-mnl/probe/", "DENY",  lambda: oss("oss-newapi-mnl", "ap-southeast-6")),
    ("生产OSS写 backup-sgp/probe/",     "DENY",  lambda: oss("oss-newapi-backup-sgp", "ap-southeast-1")),
    ("生产VPC读 DescribeVpcs(mnl)",     "ALLOW", lambda: ali(["vpc", "DescribeVpcs"], ["--RegionId", "ap-southeast-6"])),
    ("生产VPC读 DescribeVSwitches(mnl)","ALLOW", lambda: ali(["vpc", "DescribeVSwitches"], ["--RegionId", "ap-southeast-6"])),
    ("生产VPC写 DeleteVSwitch(不存在ID)","DENY",  lambda: ali(["vpc", "DeleteVSwitch"], ["--RegionId", "ap-southeast-6", "--VSwitchId", "vsw-000000000000000000"])),
    ("生产ECS读 DescribeInstances(mnl)","ALLOW", lambda: ali(["ecs", "DescribeInstances"], ["--RegionId", "ap-southeast-6"])),
    ("非生产桶(不存在,对照组)",           "ALLOW", lambda: oss("oss-newapi-nonprod", "ap-southeast-6")),
]
print("%-36s %-7s %-9s %s" % ("CASE", "EXPECT", "ACTUAL", "VERDICT"))
print("-" * 92)
bad = 0
for desc, exp, fn in cases:
    r, det = fn()
    if exp == "ALLOW" and r == "NOBUCKET":
        r = "ALLOW"          # 桶不存在 == 没被权限拦，视作放行
    ok = "PASS" if r == exp else "FAIL"
    if ok == "FAIL":
        bad += 1
    print("%-36s %-7s %-9s %s %s" % (desc, exp, r, ok, det))
print("-" * 92)
print("PROBE=%s (%d/%d)" % ("PASS" if bad == 0 else "FAIL(%d)" % bad, len(cases) - bad, len(cases)))
PY
}
probe

echo
echo "======== 3. 绑定 $BOUNDARY → $PROBE_USER ========"
"$AL" ram AttachPolicyToUser --UserName "$PROBE_USER" --PolicyName "$BOUNDARY" \
  --PolicyType Custom --region "$REGION" 2>&1 | head -c 200
echo "  attached"
sleep 15

echo
echo "======== 4. 绑定后实测 ========"
probe

echo
echo "======== 5. 回滚：解绑 ========"
"$AL" ram DetachPolicyFromUser --UserName "$PROBE_USER" --PolicyName "$BOUNDARY" \
  --PolicyType Custom --region "$REGION" 2>&1 | head -c 200
echo "  detached"
sleep 8

echo
echo "======== 6. 解绑后复核（用户级应为空）========"
"$AL" ram ListPoliciesForUser --UserName "$PROBE_USER" --region "$REGION" 2>&1 \
 | /usr/bin/python3 -c "
import sys,json;d=json.load(sys.stdin)
print(' ', [p['PolicyName'] for p in ((d.get('Policies') or {}).get('Policy') or [])] or '— 空 OK')"
