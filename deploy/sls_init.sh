#!/usr/bin/env bash
# new-api · SLS 初始化（Project + Logstore，幂等）
#
# 用法: bash sls_init.sh [check|apply|verify|all]     默认 all
#
# 口径（对齐方案 §7.2「观测 SLS + ARMS」）：
#   两站各 1 个 Project，各 7 个 Logstore（6 个业务 TTL 30 + 1 个审计 TTL 180）。
#   成本与合规口径不同 → sys / audit 必须分 store。
#
# 铁律：Project 必须创建时指定资源组（生产 RG）；SLS 是 region 级服务，
#       每个调用都必须带 --region，否则落到错误地域。
#
# 真实调用方式（`aliyun sls` 是 ROA 风格，没有 --ProjectName 这种写法）：
#   aliyun sls CreateProject  --region <r> --body '{"projectName":...}'
#   aliyun sls CreateLogStore --project <p> --region <r> --body '{"logstoreName":...}'
set -uo pipefail

ALIYUN="${ALIYUN:-${HOME}/.workbuddy/binaries/aliyun-cli/aliyun}"
PY="${PY:-${HOME}/.workbuddy/binaries/python/versions/3.13.12/bin/python3}"

# 站点：project|region|resourceGroupId|description
SITES=(
  "sls-newapi-mnl|ap-southeast-6|rg-aek4nyivmmsb6iy|new-api prod mnl"
  "sls-newapi-sg|ap-southeast-1|rg-aek4zvb3ldoiyua|new-api prod sg"
)

# Logstore：name:ttl
LOGSTORES="app-stdout:30 app-file:30 alb_access:30 waf-log:30 rds-audit:30 actiontrail:30 app-file-audit:180"

say() { printf '%s\n' "$*" >&2; }

proj_exists() { # $1=project $2=region
  "$ALIYUN" sls ListProject --region "$2" --projectName "$1" 2>/dev/null \
    | "$PY" -c '
import sys, json
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); raise SystemExit
print("1" if any(p.get("projectName") == want for p in d.get("projects", [])) else "0")
' "$1"
}

ls_exists() { # $1=project $2=region $3=logstore
  "$ALIYUN" sls ListLogStores --project "$1" --region "$2" 2>/dev/null \
    | "$PY" -c '
import sys, json
want = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); raise SystemExit
print("1" if want in (d.get("logstores") or []) else "0")
' "$3"
}

create_project() { # $1=project $2=region $3=rg $4=desc
  local body out rc
  body=$(printf '{"projectName":"%s","description":"%s","resourceGroupId":"%s","dataRedundancyType":"ZRS"}' "$1" "$4" "$3")
  out=$("$ALIYUN" sls CreateProject --region "$2" --body "$body" 2>&1); rc=$?
  if [ "${rc}" -ne 0 ] || [ -n "${out}" ]; then
    say "    FAIL CreateProject ${1} :: ${out}"
    return 1
  fi
  return 0
}

create_logstore() { # $1=project $2=region $3=logstore $4=ttl
  local body out rc
  body=$(printf '{"logstoreName":"%s","ttl":%s,"shardCount":2,"mode":"standard","autoSplit":true,"maxSplitShard":64}' "$3" "$4")
  out=$("$ALIYUN" sls CreateLogStore --project "$1" --region "$2" --body "$body" 2>&1); rc=$?
  if [ "${rc}" -ne 0 ] || [ -n "${out}" ]; then
    say "    FAIL CreateLogStore ${1}/${3} :: ${out}"
    return 1
  fi
  return 0
}

run_check() {
  local site proj region rg desc missing=0 total=0
  for site in "${SITES[@]}"; do
    IFS='|' read -r proj region rg desc <<<"$site"
    printf '%-18s %-16s %s\n' "${proj}" "${region}" "${rg}"
    if [ "$(proj_exists "$proj" "$region")" = "1" ]; then
      say "    [OK]   project exists"
    else
      say "    [MISS] project missing"
      missing=$((missing + 1))
    fi
    local item ls ttl
    for item in ${LOGSTORES}; do
      ls=${item%%:*}; ttl=${item##*:}
      total=$((total + 1))
      if [ "$(ls_exists "$proj" "$region" "$ls")" = "1" ]; then
        say "    [OK]   logstore ${ls} (ttl=${ttl})"
      else
        say "    [MISS] logstore ${ls} (ttl=${ttl})"
        missing=$((missing + 1))
      fi
    done
  done
  say ""
  say "check: ${missing} missing / ${total} logstore-slots · 站点 ${#SITES[@]}"
  return 0
}

run_apply() {
  local site proj region rg desc item ls ttl created=0 skipped=0 failed=0
  for site in "${SITES[@]}"; do
    IFS='|' read -r proj region rg desc <<<"$site"
    say ">>> ${proj} (${region} / ${rg})"
    if [ "$(proj_exists "$proj" "$region")" = "1" ]; then
      say "    [skip] project exists"
      skipped=$((skipped + 1))
    else
      if create_project "$proj" "$region" "$rg" "$desc"; then
        say "    [new]  project created"
        created=$((created + 1))
      else
        failed=$((failed + 1)); continue
      fi
    fi
    for item in ${LOGSTORES}; do
      ls=${item%%:*}; ttl=${item##*:}
      if [ "$(ls_exists "$proj" "$region" "$ls")" = "1" ]; then
        say "    [skip] ${ls} (ttl=${ttl})"
        skipped=$((skipped + 1))
      else
        if create_logstore "$proj" "$region" "$ls" "$ttl"; then
          say "    [new]  ${ls} (ttl=${ttl})"
          created=$((created + 1))
        else
          failed=$((failed + 1))
        fi
      fi
    done
  done
  say ""
  say "apply: created=${created} skipped=${skipped} failed=${failed}"
  return 0
}

run_verify() {
  local site proj region rg desc
  for site in "${SITES[@]}"; do
    IFS='|' read -r proj region rg desc <<<"$site"
    printf '=== %s (%s) ===\n' "${proj}" "${region}"
    "$ALIYUN" sls ListProject --region "$region" --projectName "$proj" 2>/dev/null \
      | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
for p in d.get("projects", []):
    if p.get("projectName") == sys.argv[1]:
        print("  rg=%s  dr=%s  status=%s" % (p.get("resourceGroupId"), p.get("dataRedundancyType"), p.get("status")))
' "$proj"
    "$ALIYUN" sls ListLogStores --project "$proj" --region "$region" 2>/dev/null
    local item ls
    for item in ${LOGSTORES}; do
      ls=${item%%:*}
      printf '    %-16s ' "${ls}"
      # GetLogStore 的 logstore 是 path 参数，参数名不含 Name
      "$ALIYUN" sls GetLogStore --project "$proj" --logstore "$ls" --region "$region" 2>/dev/null \
        | "$PY" -c '
import sys, json
d = json.load(sys.stdin)
print("ttl=%s shard=%s mode=%s" % (d.get("ttl"), d.get("shardCount"), d.get("mode")))
'
    done
  done
  return 0
}

main() {
  local cmd="${1:-all}"
  case "${cmd}" in
    check)  run_check ;;
    apply)  run_apply; run_verify ;;
    verify) run_verify ;;
    all)    run_check; say ""; run_apply; say ""; run_verify ;;
    *)      say "usage: bash sls_init.sh [check|apply|verify|all]"; exit 2 ;;
  esac
}

main "$@"
