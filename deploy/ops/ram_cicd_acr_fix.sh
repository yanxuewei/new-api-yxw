#!/usr/bin/env bash
# deploy/ops/ram_cicd_acr_fix.sh — 修正 newapi-cicd-acr-push 中「永不匹配」的 ACR 资源 ARN
#
# 背景（官方规范：alibabacloud.com/help/en/doc-detail/144229.html）
#   ACR ARN = acs:cr:$regionid:$accountid:repository/$instanceid/$namespacename[/$repositoryname]
#   资源类型只有：* / instance / repository / chart —— 没有 "namespace/" 前缀。
#
# 现有 3 条 ARN 的实测判定（针对实例 cri-avfqy9xkqi5bj8ee、命名空间 newapi-prod…）：
#   acs:cr:*:*:repository/newapi/*     → $instanceid 被解析为字面 "newapi"      → 永不匹配
#   acs:cr:*:*:repository/*/newapi/*   → $namespacename 被解析为字面 "newapi"   → 不匹配 newapi-prod
#   acs:cr:*:*:namespace/newapi*       → "namespace/" 非合法资源类型            → 永不匹配
# 后果：cicd-push 身份下 PushRepository / PullRepository / GetNamespace / ListNamespace 全部 DENY，
#       CI 推镜像会被 ACR 拒（denied: requested access to the resource is denied）。
#
# 用法: bash deploy/ops/ram_cicd_acr_fix.sh [check|apply|verify|rollback] [版本号]
#   check     只读，判定当前默认版本的 ACR ARN
#   apply     备份现有文档 → 新建策略版本并设为默认（拆 2 条 statement，见下）
#   verify    回读默认版本逐条判定
#   rollback  把指定版本设回默认（默认 v1）
#
# 新策略结构（最小权限，限定实例）：
#   S1: cr:ListNamespace                                  → repository/<inst>/*        （官方 ListNamespace 的资源口径）
#   S2: cr:GetNamespace, cr:GetRepository, cr:ListRepository,
#       cr:PullRepository, cr:PushRepository              → repository/<inst>/newapi*
#                                                           + repository/<inst>/newapi*/*
# 原 S2（GetAuthorizationToken 等 → "*"）保持不动。
set -uo pipefail

ALIYUN="${HOME}/.workbuddy/binaries/aliyun-cli/aliyun"
PY="${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3)"

POLICY_NAME="newapi-cicd-acr-push"
REGION="ap-southeast-6"
# 需要授予推送权的 ACR 实例（未来新增实例时在此追加）
INSTANCES=("cri-avfqy9xkqi5bj8ee")
# 命名空间前缀（newapi-prod / newapi-pre / newapi-test / newapi-dev 均命中）
NS_PREFIX="newapi*"
# 已知命名空间（用于 ARN 判定）
NS_KNOWN=(newapi-prod newapi-pre newapi-test newapi-dev)
BACKUP_DIR=".workbuddy/backup"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 读取当前默认 PolicyDocument（明文 JSON 落在 stdout） ----------
get_default_doc() {
  "$ALIYUN" ram ListPolicyVersions --PolicyName "$POLICY_NAME" --PolicyType Custom 2>&1 \
    | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__ERR__", file=sys.stderr); print(raw[:200], file=sys.stderr); raise SystemExit(1)
for v in d.get("PolicyVersions", {}).get("PolicyVersion", []):
    if v.get("IsDefaultVersion"):
        print(v.get("PolicyDocument", ""))
        raise SystemExit(0)
raise SystemExit(1)
'
}

# ---------- 生成新策略文档 ----------
gen_new_doc() {
  "$PY" - "$1" "${INSTANCES[@]}" "$NS_PREFIX" <<'PYEOF'
import json, sys
orig = json.loads(sys.argv[1])
insts = sys.argv[2:-1]
prefix = sys.argv[-1]

ns_arns, repo_arns = [], []
for i in insts:
    ns_arns.append(f"acs:cr:*:*:repository/{i}/{prefix}")
    repo_arns.append(f"acs:cr:*:*:repository/{i}/{prefix}/*")
# ListNamespace 的官方资源口径是 repository/$instanceid/*（实例内全命名空间，只读）
list_ns_arns = [f"acs:cr:*:*:repository/{i}/*" for i in insts]

old_stmts = orig.get("Statement", [])
new_stmts, touched = [], False
for s in old_stmts:
    acts = s.get("Action")
    acts = acts if isinstance(acts, list) else [acts]
    res = s.get("Resource")
    is_cr = any(str(a).lower().startswith("cr:") for a in acts)
    # 只改「cr: 且非 Resource:*」的那条；其余原样保留
    if is_cr and res != "*" and not touched:
        touched = True
        ns_action = [a for a in acts if a == "cr:ListNamespace"]
        rest = [a for a in acts if a != "cr:ListNamespace"]
        if ns_action:
            new_stmts.append({"Effect": s.get("Effect", "Allow"),
                              "Action": ns_action, "Resource": list_ns_arns})
        if rest:
            new_stmts.append({"Effect": s.get("Effect", "Allow"),
                              "Action": rest, "Resource": ns_arns + repo_arns})
    else:
        new_stmts.append(s)
if not touched:
    print("__NO_CR_STATEMENT__", file=sys.stderr); raise SystemExit(2)
doc = {"Version": orig.get("Version", "1"), "Statement": new_stmts}
print(json.dumps(doc, ensure_ascii=False, indent=2))
PYEOF
}

# ---------- ARN 判定 ----------
judge() {  # stdin: 一行一个 ARN
  JUDGE_INSTANCES="$(printf '%s\n' "${INSTANCES[@]}")" \
  JUDGE_NS="${NS_KNOWN[*]}" \
  "$PY" -c '
import os, re, sys

KNOWN_INST = set(x.strip() for x in os.environ.get("JUDGE_INSTANCES", "").splitlines() if x.strip())
KNOWN_NS = set(x.strip() for x in os.environ.get("JUDGE_NS", "").split() if x.strip())

for line in sys.stdin:
    a = line.strip()
    if not a or not a.startswith("acs:cr:"):
        continue
    # 资源类型必须是 * / instance / repository / chart
    m = re.match(r"^acs:cr:[^:]*:[^:]*:([^/]+)(?:/(.*))?$", a)
    if not m:
        print(f"  FAIL {a}\n         → 不符合 acs:cr:$region:$account:<type>/... 结构"); continue
    rtype, tail = m.group(1), m.group(2) or ""
    if rtype not in ("*", "instance", "repository", "chart"):
        print(f"  FAIL {a}\n         → 资源类型 \"{rtype}/\" 非法（官方仅 * / instance / repository / chart）→ 永不匹配")
        continue
    if rtype != "repository":
        print(f"  OK   {a}\n         → 资源类型 {rtype}（非命名空间/仓库级）")
        continue

    parts = tail.split("/")
    inst = parts[0] if parts else ""
    ns = parts[1] if len(parts) > 1 else ""

    # 实例段判定
    if inst == "*":
        lvl, note = "WARN", "实例段通配 *（语义合法但未限定实例，非最小权限）"
    elif inst.startswith("cri-"):
        if inst in KNOWN_INST:
            lvl, note = "OK", f"实例 {inst}"
        else:
            lvl, note = "WARN", f"实例 {inst} 不在本次授予列表 {sorted(KNOWN_INST)}"
    elif inst == "":
        lvl, note = "OK", "实例范围内（实例级 ARN）"
    else:
        lvl, note = "FAIL", f"实例段 \"{inst}\" 不是实例 ID（应为 cri-* 或 *）→ 永不匹配任何真实实例"

    # 命名空间段判定（仅当实例段已通过）
    if lvl != "FAIL" and ns:
        if ns == "*":
            pass
        elif "*" in ns:
            pass  # 前缀通配，如 newapi*
        elif ns in KNOWN_NS:
            pass
        else:
            lvl, note = "FAIL", f"命名空间 \"{ns}\" 不存在（实际为 {sorted(KNOWN_NS)}）→ 不匹配"

    print(f"  {lvl} {a}\n         → {note}")
'
}

# ---------- check ----------
do_check() {
  local doc
  doc="$(get_default_doc)" || die "无法读取 ${POLICY_NAME} 的默认版本"
  log "策略 ${POLICY_NAME} 当前默认版本的 ACR 资源 ARN 判定："
  printf '%s' "$doc" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for s in d.get("Statement", []):
    res = s.get("Resource")
    res = res if isinstance(res, list) else [res]
    for r in res:
        if isinstance(r, str) and r.startswith("acs:cr:"):
            print(r)
' | judge
  log ""
  log "期望的正确形态：acs:cr:*:*:repository/<实例ID>/newapi*（+ /newapi*/*）"
}

# ---------- dry：生成新文档 + CLI 预演，不写 ----------
do_dry() {
  local doc new
  doc="$(get_default_doc)" || die "无法读取默认版本"
  new="$(gen_new_doc "$doc")" || die "生成新文档失败"
  log "===== 新策略文档（不会写入） ====="
  printf '%s\n' "$new" >&2
  log ""
  log "===== CLI dry-run ====="
  "$ALIYUN" ram CreatePolicyVersion --PolicyName "$POLICY_NAME" \
    --PolicyDocument "$new" --SetAsDefault true --RotateStrategy None --cli-dry-run >&2 2>&1
}

# ---------- apply ----------
do_apply() {
  local doc new ts bdir
  doc="$(get_default_doc)" || die "无法读取默认版本"
  ts="$(date +%Y%m%d_%H%M%S)"
  bdir="${BACKUP_DIR}/ram_policy_${ts}"
  mkdir -p "$bdir"
  printf '%s' "$doc" > "${bdir}/${POLICY_NAME}.json"
  log "已备份当前文档 → ${bdir}/${POLICY_NAME}.json"

  new="$(gen_new_doc "$doc")" || die "生成新文档失败（未找到 cr 资源级 statement？）"
  printf '%s' "$new" > "${bdir}/${POLICY_NAME}.new.json"
  log "新文档预览："
  printf '%s' "$new" >&2

  out="$("$ALIYUN" ram CreatePolicyVersion --PolicyName "$POLICY_NAME" \
           --PolicyDocument "$new" --SetAsDefault true --RotateStrategy None 2>&1)"
  if printf '%s' "$out" | grep -q '"PolicyVersion"'; then
    log "已创建新版本并设为默认：$(printf '%s' "$out" | "$PY" -c 'import sys,json;d=json.load(sys.stdin);v=d.get("PolicyVersion",{});print(v.get("VersionId"),"IsDefault=",v.get("IsDefaultVersion"))' 2>/dev/null)"
  else
    die "创建策略版本失败：$(printf '%s' "$out" | head -c 300)"
  fi
}

# ---------- verify ----------
do_verify() {
  local doc
  doc="$(get_default_doc)" || die "无法读取默认版本"
  log "回读默认版本，逐条判定："
  printf '%s' "$doc" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for s in d.get("Statement", []):
    acts = s.get("Action"); acts = acts if isinstance(acts, list) else [acts]
    res = s.get("Resource"); res = res if isinstance(res, list) else [res]
    print("Statement:", ",".join(acts)[:110])
    for r in res:
        print("  ", r)
' >&2
  log ""
  log "判定："
  printf '%s' "$doc" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
res = []
for s in d.get("Statement", []):
    r = s.get("Resource"); r = r if isinstance(r, list) else [r]
    res += [x for x in r if isinstance(x, str) and x.startswith("acs:cr:")]
print("\n".join(res))
' | judge
}

# ---------- rollback ----------
do_rollback() {
  local vid="${1:-v1}"
  out="$("$ALIYUN" ram SetDefaultPolicyVersion --PolicyName "$POLICY_NAME" --VersionId "$vid" 2>&1)"
  if printf '%s' "$out" | grep -q '"RequestId"'; then
    log "已将默认版本回退到 ${vid}"
  else
    die "回退失败：$(printf '%s' "$out" | head -c 300)"
  fi
}

MODE="${1:-check}"
case "$MODE" in
  check)    do_check ;;
  dry)      do_dry ;;
  apply)    do_apply ;;
  verify)   do_verify ;;
  rollback) do_rollback "${2:-v1}" ;;
  *)        die "未知模式：$MODE（可用 check|dry|apply|verify|rollback）" ;;
esac
