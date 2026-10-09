#!/usr/bin/env bash
# acr_namespace_init.sh — 在马尼拉 ACR 实例中创建 new-api 四套环境的命名空间
#
# 用法: bash deploy/acr_namespace_init.sh [check|apply|verify|all]
#   check   只列出缺失/已存在，不写
#   apply   创建缺失的命名空间（已存在则跳过）
#   verify  逐个回读核对（含默认仓库类型）
#   all     check + apply + verify
#
# 幂等：重复 apply 不产生副作用；实例 ID 预检失败即中止。
set -uo pipefail

ALIYUN="${HOME}/.workbuddy/binaries/aliyun-cli/aliyun"
PY="${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3)"
REGION="ap-southeast-6"
INSTANCE_ID="cri-avfqy9xkqi5bj8ee"
INSTANCE_NAME_EXPECT="acr-newapi-mnl"
REGION_DESC="菲律宾（马尼拉）"

# 四套环境；顺序即创建顺序（prod → pre → test → dev）
NS_LIST=(newapi-prod newapi-pre newapi-test newapi-dev)

# 命名空间默认仓库类型：PRIVATE（不开公开拉取；实例级公开匿名拉取已关闭）
DEFAULT_REPO_TYPE="PRIVATE"
# 不自动创建仓库（仓库名应由 CI 推送时显式产生，避免误建空仓）
AUTO_CREATE_REPO="false"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 预检：实例 ID / 名称 / 状态 ----------
precheck() {
  local raw name status
  raw="$("$ALIYUN" cr GetInstance --region "$REGION" --InstanceId "$INSTANCE_ID" 2>&1)" \
    || die "GetInstance 调用失败：$raw"
  name="$(printf '%s' "$raw" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("InstanceName",""))' 2>/dev/null)"
  status="$(printf '%s' "$raw" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("InstanceStatus",""))' 2>/dev/null)"
  [[ -n "$name" ]] || die "无法解析实例信息：$raw"
  [[ "$name" == "$INSTANCE_NAME_EXPECT" ]] \
    || die "实例名不匹配：期望 ${INSTANCE_NAME_EXPECT}，实得 ${name}（实例 ID 可能写错）"
  [[ "$status" == "RUNNING" ]] || die "实例状态为 ${status}，非 RUNNING"
  log "预检通过：${name}（${INSTANCE_ID}）@ ${REGION_DESC} ${REGION} · ${status}"
}

# ---------- 读取现有命名空间（每行一个） ----------
list_existing() {
  "$ALIYUN" cr ListNamespace --region "$REGION" --InstanceId "$INSTANCE_ID" --PageSize 100 2>&1 \
    | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__PARSE_ERROR__"); raise SystemExit
if not d.get("IsSuccess", False):
    print("__API_ERROR__"); raise SystemExit
for n in d.get("Namespaces", []):
    print(n.get("NamespaceName", ""))
'
}

exists() {  # $1=namespace -> 0 存在 / 1 不存在
  local ns="$1"
  printf '%s\n' "$EXISTING" | grep -qxF "$ns"
}

# ---------- check ----------
do_check() {
  local missing=0
  precheck
  EXISTING="$(list_existing)"
  case "$EXISTING" in
    __PARSE_ERROR__|__API_ERROR__) die "ListNamespace 返回异常" ;;
  esac
  if [[ -z "$EXISTING" ]]; then
    log "现有命名空间：0 个"
  else
    log "现有命名空间：$(printf '%s' "$EXISTING" | wc -l | tr -d ' ') 个"
  fi
  for ns in "${NS_LIST[@]}"; do
    if exists "$ns"; then
      printf '  [存在] %s\n' "$ns" >&2
    else
      printf '  [缺失] %s\n' "$ns" >&2
      missing=$((missing + 1))
    fi
  done
  log "check 完成：缺失 ${missing} / ${#NS_LIST[@]}"
}

# ---------- apply ----------
do_apply() {
  local created=0 skipped=0 failed=0
  precheck
  EXISTING="$(list_existing)"
  case "$EXISTING" in
    __PARSE_ERROR__|__API_ERROR__) die "ListNamespace 返回异常" ;;
  esac
  for ns in "${NS_LIST[@]}"; do
    if exists "$ns"; then
      log "  skip  ${ns}（已存在）"
      skipped=$((skipped + 1))
      continue
    fi
    out="$("$ALIYUN" cr CreateNamespace --region "$REGION" --InstanceId "$INSTANCE_ID" \
             --NamespaceName "$ns" --AutoCreateRepo "$AUTO_CREATE_REPO" \
             --DefaultRepoType "$DEFAULT_REPO_TYPE" 2>&1)"
    if printf '%s' "$out" | grep -q '"IsSuccess":true'; then
      log "  ok    ${ns}"
      created=$((created + 1))
    elif printf '%s' "$out" | grep -qE 'NAMESPACE_EXIST|already exist'; then
      log "  skip  ${ns}（并发已存在）"
      skipped=$((skipped + 1))
    else
      log "  FAIL  ${ns} :: $(printf '%s' "$out" | head -c 200)"
      failed=$((failed + 1))
    fi
  done
  log "apply 完成：created=${created} skipped=${skipped} failed=${failed}"
  [[ "$failed" -eq 0 ]] || return 1
}

# ---------- verify ----------
do_verify() {
  local ok=0 bad=0
  precheck
  for ns in "${NS_LIST[@]}"; do
    out="$("$ALIYUN" cr GetNamespace --region "$REGION" --InstanceId "$INSTANCE_ID" \
             --NamespaceName "$ns" 2>&1)"
    printf '%-14s ' "$ns" >&2
    if printf '%s' "$out" | grep -q '"IsSuccess":true'; then
      # 断言：repoType 必须 PRIVATE、状态 NORMAL；不符即判 FAIL（生产仓不得公开）
      res="$(printf '%s\n' "$out" | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
cfg = d.get("DefaultRepoConfiguration") or {}
if not isinstance(cfg, dict):
    cfg = {}
rt = d.get("DefaultRepoType"); st = d.get("NamespaceStatus")
verdict = "OK" if (rt == "PRIVATE" and st == "NORMAL") else "FAIL"
print("%s|status=%s repoType=%s autoCreate=%s tagImmut=%s nsId=%s rg=%s" % (
    verdict, st, rt, d.get("AutoCreateRepo"), cfg.get("TagImmutability"),
    d.get("NamespaceId"), d.get("ResourceGroupId")))
' 2>&1)"
      printf '%s\n' "$res" >&2
      case "$res" in
        OK\|*) ok=$((ok + 1)) ;;
        *)     bad=$((bad + 1)) ;;
      esac
    else
      printf 'FAIL :: %s\n' "$(printf '%s' "$out" | head -c 160)" >&2
      bad=$((bad + 1))
    fi
  done
  log "verify 完成：ok=${ok} bad=${bad}"
  [[ "$bad" -eq 0 ]] || return 1
}

# ---------- main ----------
MODE="${1:-all}"
case "$MODE" in
  check)  do_check ;;
  apply)  do_apply ;;
  verify) do_verify ;;
  all)    do_check && echo "---" >&2 && do_apply && echo "---" >&2 && do_verify ;;
  *)      die "未知模式：$MODE（可用 check|apply|verify|all）" ;;
esac
