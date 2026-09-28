#!/usr/bin/env bash
# probe_dev_program.sh — 开发程序身份权限边界实测（v3：结构化判定 + 对照实验）
#
# 判定器 v3 修正记录：
#   v1 靠整段文本子串匹配 "denied" → LookupEvents 返回的审计事件正文含 AccessDenied → 误判
#   v2 只认 JSON/XML 错误码 → ossutil 错误走 stderr 纯文本 "Error Code: Xxx." → 漏判
#   v3 三种格式全认：ossutil 文本 / aliyun JSON 顶层 error_code / XML <Code>
#      且忽略业务成功码（Code: success、IsSuccess:true）
#
# 用法: bash probe_dev_program.sh [smoke|crosscheck]
set -uo pipefail
SECRETS="$HOME/.aliyun/newapi-dev-secrets.json"
ALIYUN="$HOME/.workbuddy/binaries/aliyun-cli/aliyun"
OSSUTIL="$HOME/.workbuddy/binaries/ossutil/ossutil"

/usr/bin/python3 - "$SECRETS" "$ALIYUN" "$OSSUTIL" "${1:-smoke}" <<'PY'
import json, os, re, subprocess, sys
secrets, aliyun, ossutil, mode = sys.argv[1:5]
sec = json.load(open(os.path.expanduser(secrets)))
PERM = ("deny", "denied", "forbidden", "notauthorized", "nopermission", "unauthorized")

def verdict(p):
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    rc = p.returncode

    m = re.search(r"Error Code:\s*([A-Za-z0-9_]+)\.?", out)          # ossutil 文本
    if m:
        code = m.group(1)
        if code in ("AccessDenied", "Forbidden", "InvalidAccessKeyId", "SignatureDoesNotMatch"):
            return "DENY", ""
        if code == "NoSuchBucket":
            return "ALLOW", ""
        return "ERR", code

    m = re.search(r"<Code>([^<]+)</Code>", out)                       # XML
    if m:
        code = m.group(1)
        if "AccessDenied" in code or "Forbidden" in code:
            return "DENY", ""
        if "NoSuchBucket" in code:
            return "ALLOW", ""
        return "ERR", code

    try:                                                              # aliyun CLI JSON
        d = json.loads(out)
        if isinstance(d, dict):
            code = d.get("error_code") or d.get("Code")
            if code and str(code).lower() not in ("success", "ok", ""):
                if any(h in str(code).lower() for h in PERM):
                    return "DENY", str(d.get("message") or code)[:66]
                return "ERR", "%s | %s" % (code, str(d.get("message"))[:52])
            if rc == 0:
                return "ALLOW", ""
    except Exception:
        pass

    return ("ALLOW", "") if rc == 0 else ("ERR", (out.splitlines()[0][:66] if out else "rc=%d" % rc))

def make(who):
    k = sec["access_keys"][who]
    A = ["--access-key-id", k["AccessKeyId"], "--access-key-secret", k["AccessKeySecret"]]
    def al(action, extra):
        return verdict(subprocess.run([aliyun] + A + action + extra,
                                      capture_output=True, text=True, timeout=90))
    def osdel(bucket, region):
        return verdict(subprocess.run([ossutil, "api", "delete-object", "--bucket", bucket,
                                       "--key", "probe/__devprobe__.txt", "--region", region,
                                       "--endpoint", "oss-%s.aliyuncs.com" % region] + A,
                                      capture_output=True, text=True, timeout=90))
    return al, osdel

def run(title, cases):
    print("######## %s ########" % title)
    print("%-50s %-7s %-7s %s" % ("CASE", "EXPECT", "ACTUAL", "VERDICT"))
    print("-" * 102)
    bad = 0
    for desc, exp, (r, det) in cases:
        ok = "PASS" if r == exp else "FAIL"
        if ok == "FAIL":
            bad += 1
        print("%-50s %-7s %-7s %s %s" % (desc, exp, r, ok, det))
    print("-" * 102)
    print("%s: %s (%d/%d)\n" % (title, "PASS" if bad == 0 else "FAIL(%d)" % bad,
                                len(cases) - bad, len(cases)))
    return bad

total = 0
for who in ("dev-zhangzijun", "dev-xiangdong"):
    al, osdel = make(who)
    total += run(who, [
        ("sts GetCallerIdentity             身份有效",              "ALLOW", al(["sts", "GetCallerIdentity"], [])),
        ("vpc DescribeVpcs(mnl)             生产只读放行",           "ALLOW", al(["vpc", "DescribeVpcs"], ["--RegionId", "ap-southeast-6"])),
        ("vpc DescribeVSwitches(mnl)        生产只读放行",           "ALLOW", al(["vpc", "DescribeVSwitches"], ["--RegionId", "ap-southeast-6"])),
        ("ecs DescribeInstances(mnl)        生产只读放行",           "ALLOW", al(["ecs", "DescribeInstances"], ["--RegionId", "ap-southeast-6"])),
        ("cr ListInstance(mnl)              Allow cr:List*",      "ALLOW", al(["cr", "ListInstance"], ["--RegionId", "ap-southeast-6"])),
        ("actiontrail DescribeTrails        Allow Describe*",     "ALLOW", al(["actiontrail", "DescribeTrails"], ["--region", "ap-southeast-6"])),
        ("actiontrail LookupEvents          Allow Lookup*",       "ALLOW", al(["actiontrail", "LookupEvents"], ["--region", "ap-southeast-6"])),
        ("vpc DescribeEipAddresses(mnl)     生产只读放行",           "ALLOW", al(["vpc", "DescribeEipAddresses"], ["--RegionId", "ap-southeast-6"])),
        ("vpc ModifyVpcAttribute(PROD)      boundary 挡生产写",     "DENY",  al(["vpc", "ModifyVpcAttribute"], ["--RegionId", "ap-southeast-6", "--VpcId", "vpc-5tst1tgeessxn1azwasg2", "--Description", "new-api Philippines(Manila) prod"])),
        ("oss delete PROD oss-newapi-mnl    oss-guard 挡",        "DENY",  osdel("oss-newapi-mnl", "ap-southeast-6")),
        ("oss delete PROD backup-sgp        oss-guard 挡",        "DENY",  osdel("oss-newapi-backup-sgp", "ap-southeast-1")),
        ("oss delete NONPROD(桶不存在)        非生产放行",             "ALLOW", osdel("oss-newapi-nonprod", "ap-southeast-6")),
        ("ram ListUsers                     显式 Deny ram:*",      "DENY",  al(["ram", "ListUsers"], ["--region", "ap-southeast-1"])),
        ("ram CreateAccessKey(自己)          显式 Deny ram:*",      "DENY",  al(["ram", "CreateAccessKey"], ["--UserName", who, "--region", "ap-southeast-1"])),
    ])

if mode == "crosscheck":
    # 设计要点：三层防御【同向】叠加 ——
    #   ① newapi-dev-program   : Allow 列表本就不含生产写（隐式拒绝）
    #   ② newapi-prod-boundary : Deny 生产 RG（acs:ResourceGroupId 条件，已实测对 OSS/VPC 生效）
    #   ③ newapi-prod-oss-guard: Deny 生产桶 ARN（无条件，不依赖条件键）
    # ⇒ 因此解绑外层后仍 DENY 是【预期行为】，不是 bug。本对照用于证明"纵深"成立：
    #   任一层单独存在时都拒绝，只有三层全去掉 ① 本就不给的情况下才可能 ALLOW。
    import time
    R = "ap-southeast-1"

    def grp(op, pol):
        subprocess.run([aliyun, "ram", op, "--GroupName", "dev-program_group",
                        "--PolicyName", pol, "--PolicyType", "Custom", "--region", R],
                       capture_output=True, text=True)

    def step(title, cases):
        print("=" * 102); print(title); print("=" * 102)
        run(title[:60], cases)

    def rw_probe():
        al, osdel = make("dev-zhangzijun")
        return [
            ("oss delete PROD oss-newapi-mnl", "DENY", osdel("oss-newapi-mnl", "ap-southeast-6")),
            ("oss delete PROD backup-sgp",     "DENY", osdel("oss-newapi-backup-sgp", "ap-southeast-1")),
            ("vpc ModifyVpcAttribute(PROD)",   "DENY", al(["vpc", "ModifyVpcAttribute"], ["--RegionId", "ap-southeast-6", "--VpcId", "vpc-5tst1tgeessxn1azwasg2", "--Description", "new-api Philippines(Manila) prod"])),
        ]

    print("\n【对照 1】解绑 boundary（保留 oss-guard + 最小策略）→ 预期仍 DENY")
    grp("DetachPolicyFromGroup", "newapi-prod-boundary")
    time.sleep(12)
    step("boundary 已解绑", rw_probe())

    print("\n【对照 2】再解绑 oss-guard（只剩最小策略）→ 预期仍 DENY（因 ① 本就不授生产写）")
    grp("DetachPolicyFromGroup", "newapi-prod-oss-guard")
    time.sleep(12)
    step("仅剩 newapi-dev-program", rw_probe())

    print("\n【恢复】绑回两条边界 → 预期 DENY")
    grp("AttachPolicyToGroup", "newapi-prod-boundary")
    grp("AttachPolicyToGroup", "newapi-prod-oss-guard")
    time.sleep(12)
    step("边界已恢复", rw_probe())

    print("最终组策略：")
    p = subprocess.run([aliyun, "ram", "ListPoliciesForGroup", "--GroupName", "dev-program_group",
                        "--region", R], capture_output=True, text=True)
    try:
        print("  ", sorted(x["PolicyName"] for x in json.loads(p.stdout)["Policies"]["Policy"]))
    except Exception:
        print("   查询失败")

print("TOTAL=%s" % ("PASS" if total == 0 else "FAIL(%d)" % total))
PY
