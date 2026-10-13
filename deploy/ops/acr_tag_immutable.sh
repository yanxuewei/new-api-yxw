#!/usr/bin/env bash
# deploy/ops/acr_tag_immutable.sh — 为 ACR 命名空间 / 仓库开启「镜像 tag 不可变」
#
# 背景
#   ACR 企业版里有**两层** tag 不可变设置，互不覆盖：
#     ① 命名空间层：`DefaultRepoConfiguration.TagImmutability`
#        —— 只对「命名空间自动创建的仓库」生效（即 `AutoCreateRepo=true` 的推送路径）。
#     ② 仓库层：每个 Repository 自己的 `TagImmutability`
#        —— 真正决定某个仓库的 tag 能否被覆盖；显式 CreateRepository / 控制台建仓时由建仓参数决定。
#   因此本脚本两层都做：先设命名空间默认，再对命名空间下**已存在**的仓库逐个打开。
#
# 目标范围（默认 prod，仅生产）：
#   prod → newapi-prod
#   all  → newapi-prod / newapi-pre / newapi-test / newapi-dev
#   注：pre/test/dev 默认不开（需要反复覆盖 tag 做回归）；显式传 all 才会动。
#
# 用法: bash deploy/ops/acr_tag_immutable.sh [check|apply|verify|all] [prod|all]
#   check   只读：打印命名空间配置 + 仓库逐条 tag 不可变状态
#   apply   打开 tag 不可变（幂等：已是 true 则跳过）
#   verify  回读断言：命名空间默认 true 且范围内每个仓库 true
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

NS_PROD="newapi-prod"
NS_ALL=(newapi-prod newapi-pre newapi-test newapi-dev)

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 预检 ----------
precheck() {
  local raw name status
  raw="$("$ALIYUN" cr GetInstance --region "$REGION" --InstanceId "$INSTANCE_ID" 2>&1)" \
    || die "GetInstance 调用失败：$raw"
  name="$(printf '%s' "$raw" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("InstanceName",""))' 2>/dev/null)"
  status="$(printf '%s' "$raw" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("InstanceStatus",""))' 2>/dev/null)"
  [[ "$name" == "$INSTANCE_NAME_EXPECT" ]] \
    || die "实例名不匹配：期望 ${INSTANCE_NAME_EXPECT}，实得 ${name}（实例 ID 可能写错）"
  [[ "$status" == "RUNNING" ]] || die "实例状态为 ${status}，非 RUNNING"
  log "预检通过：${name}（${INSTANCE_ID}）@ ${REGION_DESC} ${REGION} · ${status}"
}

# ---------- 读取命名空间配置：输出 tagImmutability<TAB>autoCreate<TAB>defaultRepoType ----------
ns_cfg() {  # $1=namespace
  "$ALIYUN" cr GetNamespace --region "$REGION" --InstanceId "$INSTANCE_ID" \
    --NamespaceName "$1" 2>&1 | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__PARSE_ERROR__\t\t"); raise SystemExit
if not d.get("IsSuccess", False):
    print("__API_ERROR__\t\t"); raise SystemExit
cfg = d.get("DefaultRepoConfiguration") or {}
if not isinstance(cfg, dict):
    cfg = {}
print("%s\t%s\t%s" % (cfg.get("TagImmutability"), d.get("AutoCreateRepo"), d.get("DefaultRepoType")))
'
}

# ---------- 列出仓库：输出 repoName<TAB>repoId<TAB>repoType<TAB>tagImmutability<TAB>summary ----------
list_repos() {  # $1=namespace
  "$ALIYUN" cr ListRepository --region "$REGION" --InstanceId "$INSTANCE_ID" \
    --RepoNamespaceName "$1" --PageSize 100 2>&1 | "$PY" -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("__PARSE_ERROR__"); raise SystemExit
if not d.get("IsSuccess", False):
    print("__API_ERROR__"); raise SystemExit
for r in d.get("Repositories", []) or []:
    print("\t".join([
        str(r.get("RepoName", "")),
        str(r.get("RepoId", "")),
        str(r.get("RepoType", "")),
        str(r.get("TagImmutability", "")),
        str(r.get("Summary", "") or ""),
    ]))
'
}

# ---------- 命名空间层：设默认 TagImmutability=true ----------
ns_enable() {  # $1=namespace  -> 0 已改/已是 true
  local cfg ti
  cfg="$(ns_cfg "$1")"
  ti="$(printf '%s' "$cfg" | cut -f1)"
  case "$ti" in
    __PARSE_ERROR__|__API_ERROR__) die "GetNamespace(${1}) 返回异常" ;;
  esac
  if [[ "$ti" == "True" || "$ti" == "true" ]]; then
    log "  skip  ${1} 命名空间默认 TagImmutability 已为 true"
    return 0
  fi
  out="$("$ALIYUN" cr UpdateNamespace --region "$REGION" --InstanceId "$INSTANCE_ID" \
           --NamespaceName "$1" \
           --DefaultRepoConfiguration '{"RepoType":"PRIVATE","TagImmutability":true}' 2>&1)"
  if printf '%s' "$out" | grep -q '"IsSuccess":true'; then
    log "  ok    ${1} 命名空间默认 TagImmutability → true"
  else
    log "  FAIL  ${1} UpdateNamespace :: $(printf '%s' "$out" | head -c 200)"
    return 1
  fi
}

# ---------- 仓库层：逐仓库开 TagImmutability ----------
repo_enable() {  # $1=namespace
  local repos n=0 fail=0 name id rtype ti summ out
  repos="$(list_repos "$1")"
  case "$repos" in
    __PARSE_ERROR__|__API_ERROR__) die "ListRepository(${1}) 返回异常" ;;
  esac
  if [[ -z "$repos" ]]; then
    log "  note  ${1} 下暂无仓库（仓库层设置在建仓时生效，见脚本头注释 ②）"
    return 0
  fi
  while IFS=$'\t' read -r name id rtype ti summ; do
    [[ -n "$name" ]] || continue
    if [[ "$ti" == "True" || "$ti" == "true" ]]; then
      log "  skip  ${1}/${name} 仓库 TagImmutability 已为 true"
      continue
    fi
    [[ -n "$summ" ]] || summ="managed-by:deploy/ops/acr_tag_immutable.sh"
    out="$("$ALIYUN" cr UpdateRepository --region "$REGION" --InstanceId "$INSTANCE_ID" \
             --RepoId "$id" --RepoType "$rtype" --Summary "$summ" \
             --RepoNamespaceName "$1" --RepoName "$name" --TagImmutability true 2>&1)"
    if printf '%s' "$out" | grep -q '"IsSuccess":true'; then
      log "  ok    ${1}/${name} 仓库 TagImmutability → true"
      n=$((n + 1))
    else
      log "  FAIL  ${1}/${name} UpdateRepository :: $(printf '%s' "$out" | head -c 200)"
      fail=$((fail + 1))
    fi
  done <<< "$repos"
  log "  ${1} 仓库层：改动 ${n} 个，失败 ${fail} 个"
  [[ "$fail" -eq 0 ]] || return 1
}

# ---------- check ----------
do_check() {
  local cfg
  precheck
  for ns in "${TARGETS[@]}"; do
    cfg="$(ns_cfg "$ns")"
    printf '%-14s 命名空间默认 tagImmut=%s autoCreate=%s defaultRepoType=%s\n' \
      "$ns" "$(printf '%s' "$cfg" | cut -f1)" "$(printf '%s' "$cfg" | cut -f2)" "$(printf '%s' "$cfg" | cut -f3)" >&2
    list_repos "$ns" | while IFS=$'\t' read -r name id rtype ti summ; do
      [[ -n "$name" ]] || continue
      printf '               └─ %-24s repoId=%s type=%s tagImmut=%s\n' "$name" "$id" "$rtype" "$ti" >&2
    done
  done
}

# ---------- apply ----------
do_apply() {
  local rc=0
  precheck
  for ns in "${TARGETS[@]}"; do
    log "[${ns}]"
    ns_enable "$ns" || rc=1
    repo_enable "$ns" || rc=1
  done
  return "$rc"
}

# ---------- verify ----------
do_verify() {
  local ok=0 bad=0 cfg ti
  precheck
  for ns in "${TARGETS[@]}"; do
    cfg="$(ns_cfg "$ns")"
    ti="$(printf '%s' "$cfg" | cut -f1)"
    if [[ "$ti" == "True" || "$ti" == "true" ]]; then
      printf 'OK    %-14s 命名空间默认 tagImmut=true\n' "$ns" >&2
      ok=$((ok + 1))
    else
      printf 'FAIL  %-14s 命名空间默认 tagImmut=%s\n' "$ns" "$ti" >&2
      bad=$((bad + 1))
    fi
    while IFS=$'\t' read -r name id rtype rti summ; do
      [[ -n "$name" ]] || continue
      if [[ "$rti" == "True" || "$rti" == "true" ]]; then
        printf '  OK   %s/%s 仓库 tagImmut=true\n' "$ns" "$name" >&2
      else
        printf '  FAIL %s/%s 仓库 tagImmut=%s\n' "$ns" "$name" "$rti" >&2
        bad=$((bad + 1))
      fi
    done <<< "$(list_repos "$ns")"
  done
  log "verify 完成：ok=${ok} bad=${bad}"
  [[ "$bad" -eq 0 ]] || return 1
}

# ---------- main ----------
MODE="${1:-check}"
SCOPE="${2:-prod}"
case "$SCOPE" in
  prod) TARGETS=("$NS_PROD") ;;
  all)  TARGETS=("${NS_ALL[@]}") ;;
  *)    die "未知范围：$SCOPE（可用 prod|all）" ;;
esac

case "$MODE" in
  check)  do_check ;;
  apply)  do_apply ;;
  verify) do_verify ;;
  all)    do_check && echo "---" >&2 && do_apply && echo "---" >&2 && do_verify ;;
  *)      die "未知模式：$MODE（可用 check|apply|verify|all）" ;;
esac
