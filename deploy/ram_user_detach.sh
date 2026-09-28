#!/usr/bin/env bash
# ram_user_detach.sh — 解除 4 个 RAM 用户的用户级策略，改由用户组单点承载
#
# 背景：2026-09-25 已把策略同时绑到「用户 + 用户组」两层（并集 = 同一集合，权限零变化）。
#       本脚本解除用户级那一层，让「组承载」真正成立，避免两层维护漂移。
#
# 用法: bash ram_user_detach.sh [check|apply|verify|rollback|smoke]
#   check     只读预演：列出每个用户的用户级策略 + 是否已被组覆盖
#   apply     解绑被组覆盖的用户级策略（未被覆盖的自动跳过，绝不降权）；写回滚清单
#   verify    复核：用户级应为空、组策略/成员仍在
#   rollback  按最近一次 apply 的清单把策略绑回用户级
#   smoke     用 cicd-push / iac-terraform 的 AK 实测关键动作（解绑前后各跑一次比对）
#
# 安全约束：只在 COVERED 时才解绑。MISSING 一律跳过并告警 —— 解绑它会立刻降权。
set -uo pipefail

REGION="${REGION:-ap-southeast-1}"
ALIYUN="${ALIYUN:-$HOME/.workbuddy/binaries/aliyun-cli/aliyun}"
PY="${PY:-/usr/bin/python3}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/.workbuddy/ram_detach"
SECRETS="$HOME/.aliyun/newapi-ram-secrets.json"

USERS="admin ops cicd-push iac-terraform"
# 注意：变量名不能用 GROUPS —— bash 内建只读数组 GROUPS（当前进程所属组 GID），
# 赋值会被静默忽略，$GROUPS 展开成首元素（macOS = 20），会把组名写成 "20"。
USER_GROUPS="admin_group ops_group cicd-push_group iac-terraform_group"

say() { printf '%s\n' "$*"; }
rule() { say "----------------------------------------------------------------------------"; }

[ -x "$ALIYUN" ] || { say "[FATAL] 找不到 aliyun CLI: $ALIYUN"; exit 1; }

# ---------------------------------------------------------------- dump
dump() {
  mkdir -p "$OUT"
  local u g
  for u in $USERS; do
    "$ALIYUN" ram ListPoliciesForUser --UserName "$u" --region "$REGION" \
      >"$OUT/user_${u}_pol.json" 2>"$OUT/user_${u}_pol.err"
    "$ALIYUN" ram ListGroupsForUser --UserName "$u" --region "$REGION" \
      >"$OUT/user_${u}_grp.json" 2>"$OUT/user_${u}_grp.err"
  done
  for g in $USER_GROUPS; do
    "$ALIYUN" ram ListPoliciesForGroup --GroupName "$g" --region "$REGION" \
      >"$OUT/group_${g}_pol.json" 2>"$OUT/group_${g}_pol.err"
    "$ALIYUN" ram ListUsersForGroup --GroupName "$g" --region "$REGION" \
      >"$OUT/group_${g}_usr.json" 2>"$OUT/group_${g}_usr.err"
  done
}

# ---------------------------------------------------------------- plan
plan() {
  "$PY" - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
users = "admin ops cicd-push iac-terraform".split()

def jl(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}

rows = []
for u in users:
    up = (jl(f"{out}/user_{u}_pol.json").get("Policies") or {}).get("Policy") or []
    groups = [g["GroupName"] for g in
              ((jl(f"{out}/user_{u}_grp.json").get("Groups") or {}).get("Group") or [])]
    cov = {}
    for g in groups:
        for p in ((jl(f"{out}/group_{g}_pol.json").get("Policies") or {}).get("Policy") or []):
            cov[(p["PolicyName"], p.get("PolicyType"))] = g
    for p in up:
        k = (p["PolicyName"], p.get("PolicyType"))
        act = "COVERED" if k in cov else "MISSING"
        rows.append((u, p["PolicyName"], p.get("PolicyType"), act, ",".join(groups)))

with open(f"{out}/plan.tsv", "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")

print("%-15s %-30s %-8s %-9s %s" % ("USER", "POLICY", "TYPE", "ACTION", "GROUPS"))
print("-" * 92)
for r in rows:
    print("%-15s %-30s %-8s %-9s %s" % r)

miss = [r for r in rows if r[3] == "MISSING"]
print("-" * 92)
print("total=%d  covered=%d  missing=%d" % (len(rows), len(rows) - len(miss), len(miss)))
for r in miss:
    print("[WARN] %s / %s 未被任何组覆盖 → 解绑会降权，跳过" % (r[0], r[1]))
PY
}

# ---------------------------------------------------------------- apply
apply() {
  dump
  rule
  say "== 解绑前状态 =="
  rule
  plan
  rule

  local manifest="$OUT/rollback_manifest_$(date +%Y%m%d_%H%M%S).tsv"
  local n_ok=0 n_skip=0 n_fail=0
  local u p t act gs

  while IFS=$'\t' read -r u p t act gs; do
    [ -n "${u:-}" ] || continue
    if [ "$act" != "COVERED" ]; then
      say "  [SKIP] $u / $p — 组未覆盖，保留用户级绑定"
      n_skip=$((n_skip + 1))
      continue
    fi
    if "$ALIYUN" ram DetachPolicyFromUser --UserName "$u" --PolicyName "$p" \
         --PolicyType "$t" --region "$REGION" >/dev/null 2>"$OUT/detach_${u}_${p}.err"; then
      say "  [OK]   detach  $u  ←  $p  ($t)"
      printf '%s\t%s\t%s\n' "$u" "$p" "$t" >>"$manifest"
      n_ok=$((n_ok + 1))
    else
      say "  [FAIL] detach  $u  ←  $p  : $(tr -d '\n' <"$OUT/detach_${u}_${p}.err" | head -c 200)"
      n_fail=$((n_fail + 1))
    fi
  done <"$OUT/plan.tsv"

  rule
  say "解绑完成: ok=$n_ok  skip=$n_skip  fail=$n_fail"
  say "回滚清单: $manifest"
  [ "$n_ok" -gt 0 ] && say "回滚命令: bash ram_user_detach.sh rollback"
  [ "$n_fail" -eq 0 ]
}

# ---------------------------------------------------------------- verify
verify() {
  dump
  rule
  say "== 解绑后复核 =="
  rule
  "$PY" - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
users = "admin ops cicd-push iac-terraform".split()
groups = "admin_group ops_group cicd-push_group iac-terraform_group".split()

def jl(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}

bad = 0
print("① 用户级策略（期望为空）")
for u in users:
    ps = ((jl(f"{out}/user_{u}_pol.json").get("Policies") or {}).get("Policy") or [])
    mark = "OK" if not ps else "FAIL"
    if ps:
        bad += 1
    print("   %-15s %-5s %s" % (u, mark, [p["PolicyName"] for p in ps] or "—"))

print("② 组策略（期望保持）")
for g in groups:
    ps = ((jl(f"{out}/group_{g}_pol.json").get("Policies") or {}).get("Policy") or [])
    mark = "OK" if ps else "FAIL"
    if not ps:
        bad += 1
    print("   %-20s %-5s n=%d %s" % (g, mark, len(ps), [p["PolicyName"] for p in ps]))

print("③ 组成员（期望保持）")
for g in groups:
    us = [x["UserName"] for x in
          ((jl(f"{out}/group_{g}_usr.json").get("Users") or {}).get("User") or [])]
    mark = "OK" if us else "FAIL"
    if not us:
        bad += 1
    print("   %-20s %-5s %s" % (g, mark, us or "—"))

print()
print("VERIFY=%s" % ("PASS" if bad == 0 else "FAIL(%d)" % bad))
sys.exit(0 if bad == 0 else 1)
PY
}

# ---------------------------------------------------------------- rollback
rollback() {
  local mf
  mf="$(ls -1t "$OUT"/rollback_manifest_*.tsv 2>/dev/null | head -1)"
  [ -n "$mf" ] || { say "[FATAL] 找不到回滚清单（$OUT/rollback_manifest_*.tsv）"; exit 1; }
  rule
  say "== 回滚：把策略绑回用户级 =="
  say "清单: $mf ($(wc -l <"$mf" | tr -d ' ') 条)"
  rule
  local u p t n_ok=0 n_fail=0
  while IFS=$'\t' read -r u p t; do
    [ -n "${u:-}" ] || continue
    if "$ALIYUN" ram AttachPolicyToUser --UserName "$u" --PolicyName "$p" \
         --PolicyType "$t" --region "$REGION" >/dev/null 2>&1; then
      say "  [OK]   attach  $u  ←  $p  ($t)"
      n_ok=$((n_ok + 1))
    else
      say "  [FAIL] attach  $u  ←  $p"
      n_fail=$((n_fail + 1))
    fi
  done <"$mf"
  rule
  say "回滚完成: ok=$n_ok  fail=$n_fail"
}

# ---------------------------------------------------------------- smoke
smoke() {
  local OSSUTIL="${OSSUTIL:-$HOME/.workbuddy/binaries/ossutil/ossutil}"
  "$PY" - "$SECRETS" "$REGION" "$ALIYUN" "$OSSUTIL" <<'PY'
import json, subprocess, sys
sec, region, aliyun, ossutil = sys.argv[1:5]
region_mnl = "ap-southeast-6"
aks = json.load(open(sec)).get("access_keys", {})

DENY_HINTS = ("forbidden", "denied", "notauthorized", "not authorized",
              "no permission", "nopermission", "unauthorized")

def verdict(p):
    out = (p.stdout or "") + (p.stderr or "")
    low = out.lower()
    if any(h in low for h in DENY_HINTS):
        return "DENY", out.strip().splitlines()[0][:110] if out.strip() else ""
    if p.returncode == 0:
        return "ALLOW", ""
    return "ERR", (out.strip().splitlines()[0][:110] if out.strip() else "rc=%d" % p.returncode)

def ak(user):
    k = aks.get(user)
    return (k["AccessKeyId"], k["AccessKeySecret"]) if k else (None, None)

def run_aliyun(user, action, extra):
    aid, asec = ak(user)
    if not aid:
        return "NO-AK", "no AK for %s" % user
    cmd = [aliyun, "--access-key-id", aid, "--access-key-secret", asec] + action + extra
    try:
        return verdict(subprocess.run(cmd, capture_output=True, text=True, timeout=90))
    except Exception as e:
        return "ERR", str(e)[:110]

def run_oss(user, bucket, key, region_):
    aid, asec = ak(user)
    if not aid:
        return "NO-AK", "no AK for %s" % user
    cmd = [ossutil, "api", "delete-object",
           "--bucket", bucket, "--key", key,
           "--region", region_, "--endpoint", "oss-%s.aliyuncs.com" % region_,
           "--access-key-id", aid, "--access-key-secret", asec]
    try:
        return verdict(subprocess.run(cmd, capture_output=True, text=True, timeout=90))
    except Exception as e:
        return "ERR", str(e)[:110]

# (user, desc, expect, kind, args)
cases = [
    ("cicd-push", "cr ListInstance      [策略 Allow cr:* Instance, Resource=*]", "ALLOW",
     "aliyun", (["cr", "ListInstance"], ["--RegionId", region_mnl])),
    ("cicd-push", "cr GetInstance       [策略 Allow]", "ALLOW",
     "aliyun", (["cr", "GetInstance"], ["--RegionId", region_mnl,
                                        "--InstanceId", "cri-avfqy9xkqi5bj8ee"])),
    ("cicd-push", "ram ListUsers         [策略未授权 → 隐式拒绝]", "DENY",
     "aliyun", (["ram", "ListUsers"], ["--region", region])),
    ("iac-terraform", "vpc DescribeVpcs     [策略 Allow vpc:*]", "ALLOW",
     "aliyun", (["vpc", "DescribeVpcs"], ["--RegionId", region_mnl])),
    ("iac-terraform", "ram CreateUser       [策略显式 Deny]", "DENY",
     "aliyun", (["ram", "CreateUser"], ["--UserName", "__probe-denied-usercbn__", "--region", region])),
    ("iac-terraform", "actiontrail DescribeTrails [策略未授权]", "DENY",
     "aliyun", (["actiontrail", "DescribeTrails"], ["--region", region_mnl])),
    ("iac-terraform", "OSS del actiontrail/ [audit-protect 显式 Deny，零副作用]", "DENY",
     "oss", ("oss-newapi-mnl", "actiontrail/__probe_denied__.txt", region_mnl)),
    ("iac-terraform", "OSS del probe/       [策略 Allow oss:*，非审计前缀对照]", "ALLOW",
     "oss", ("oss-newapi-mnl", "probe/__probe_allow__.txt", region_mnl)),
]

print("%-15s %-58s %-7s %-7s %s" % ("USER", "CASE", "EXPECT", "ACTUAL", "VERDICT"))
print("-" * 108)
bad = 0
for u, desc, exp, kind, args in cases:
    r, det = run_aliyun(u, *args) if kind == "aliyun" else run_oss(u, *args)
    ok = "PASS" if r == exp else "FAIL"
    if ok == "FAIL":
        bad += 1
    print("%-15s %-58s %-7s %-7s %s %s" % (u, desc, exp, r, ok, det))
print("-" * 108)
print("SMOKE=%s  (%d/%d)" % ("PASS" if bad == 0 else "FAIL(%d)" % bad, len(cases) - bad, len(cases)))
PY
}

# ---------------------------------------------------------------- main
case "${1:-check}" in
  check)    dump; rule; say "== 解绑预演（只读）=="; rule; plan ;;
  apply)    apply ;;
  verify)   verify ;;
  rollback) rollback ;;
  smoke)    rule; say "== 关键动作实测（AK 直连）=="; rule; smoke ;;
  *)        say "用法: bash ram_user_detach.sh [check|apply|verify|rollback|smoke]"; exit 1 ;;
esac
