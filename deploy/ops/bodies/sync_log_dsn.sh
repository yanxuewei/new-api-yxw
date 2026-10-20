#!/bin/bash
# deploy/ops/bodies/sync_log_dsn.sh —— 把 newapi-dev 的 LOG_SQL_DSN 复制到 pre / perf 的 new-api-secrets
#
# 目的：三个环境共用同一个日志库（newapi_logs）。pre/perf 原先只建了 4 个键、**没有 LOG_SQL_DSN**
#   ⇒ `model.InitLogDB` 走 `LOG_SQL_DSN == ""` 分支，日志表回落主库（jakarta_dev_ledger §…；两环境 README 均登记为已知偏差）。
#
# 纪律：
#   · 默认 APPLY=0 只读取证；APPLY=1 才写。
#   · 值**不进 argv**：patch 载荷走 600 临时文件（--patch-file），执行完 shred。
#   · 输出只出 scheme/host/port/db/user + 长度 + sha256 前 12 位；口令一律不出现（masked 行也做了打码）。
#   · 源必须是 newapi-dev，目标白名单只允许 new-api-pre / new-api-perf（防误写生产）。
set -uo pipefail

SRC_NS="${SRC_NS:-newapi-dev}"
TGT_NS_LIST="${TGT_NS_LIST:-new-api-pre new-api-perf}"
SEC="${SEC:-new-api-secrets}"
APPLY="${APPLY:-0}"
RESTART="${RESTART:-0}"

T=$(mktemp -d); chmod 700 "$T"
cleanup() { find "$T" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

for n in $SRC_NS $TGT_NS_LIST; do
  case "$n" in
    newapi-dev|new-api-pre|new-api-perf) : ;;
    *) echo "[XX] 命名空间 '$n' 不在白名单 ⇒ 终止"; exit 1 ;;
  esac
done

mask() { sed -E -e 's#(://[^:/]+):[^@]*@#\1:***@#g' -e 's#([?&]password=)[^&]*#\1***#g'; }

shape() {  # $1=明文 DSN
  local v="$1" scheme usr host port db
  scheme=$(printf '%s' "$v" | sed -nE 's#^([a-zA-Z0-9+]+)://.*#\1#p')
  usr=$(printf '%s' "$v"    | sed -nE 's#^[a-zA-Z0-9+]+://([^:@/]+)[:@].*#\1#p')
  host=$(printf '%s' "$v"   | sed -nE 's#^[a-zA-Z0-9+]+://[^@]*@([^:/?]+).*#\1#p')
  port=$(printf '%s' "$v"   | sed -nE 's#^[a-zA-Z0-9+]+://[^@]*@[^:/?]+:([0-9]+).*#\1#p')
  db=$(printf '%s' "$v"     | sed -nE 's#^[a-zA-Z0-9+]+://[^@]*@[^/]+/([^?]+).*#\1#p')
  printf 'scheme=%s host=%s port=%s db=%s user=%s len=%s sha256=%s' \
    "${scheme:-?}" "${host:-?}" "${port:-?}" "${db:-?}" "${usr:-?}" "${#v}" \
    "$(printf '%s' "$v" | sha256sum | cut -c1-12)"
}

echo "=== S1 源（$SRC_NS/$SEC）"
SRC_B64=$(kubectl -n "$SRC_NS" get secret "$SEC" -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null)
[ -n "$SRC_B64" ] || { echo "  [XX] $SRC_NS/$SEC 没有 LOG_SQL_DSN ⇒ 无可复制的源"; exit 1; }
SRC=$(printf '%s' "$SRC_B64" | base64 -d)
SRC_FP=$(printf '%s' "$SRC" | sha256sum | cut -c1-12)
printf '  %s\n' "$(shape "$SRC")"
printf '  masked: %s\n' "$(printf '%s' "$SRC" | mask | cut -c1-100)"

echo "=== S2 目标现状（写入前）"
for n in $TGT_NS_LIST; do
  b=$(kubectl -n "$n" get secret "$SEC" -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null)
  if [ -z "$b" ]; then
    printf '  %-14s 无 LOG_SQL_DSN\n' "$n"
  else
    v=$(printf '%s' "$b" | base64 -d)
    printf '  %-14s %s  同源=%s\n' "$n" "$(shape "$v")" \
      "$([ "$(printf '%s' "$v" | sha256sum | cut -c1-12)" = "$SRC_FP" ] && echo YES || echo NO)"
    unset v
  fi
done
unset SRC

if [ "$APPLY" != 1 ]; then
  echo "=== 结论：APPLY=0（只读），未做任何写入。加 APPLY=1 执行复制。"
  echo "--- S1–S2 结束"
  exit 0
fi

echo "=== S3 写入（patch --type=merge，载荷走 600 临时文件）"
for n in $TGT_NS_LIST; do
  printf '{"data":{"LOG_SQL_DSN":"%s"}}' "$SRC_B64" > "$T/patch.json"; chmod 600 "$T/patch.json"
  kubectl -n "$n" patch secret "$SEC" --type=merge --patch-file "$T/patch.json" 2>&1 | sed 's/^/  /'
  rm -f "$T/patch.json"
done
unset SRC_B64

echo "=== S4 回读（与源 sha256 逐字同值才算成功）"
FAIL=0
for n in $TGT_NS_LIST; do
  v=$(kubectl -n "$n" get secret "$SEC" -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null | base64 -d)
  fp=$(printf '%s' "$v" | sha256sum | cut -c1-12)
  if [ "$fp" = "$SRC_FP" ]; then r=YES; else r=NO; FAIL=1; fi
  printf '  %-14s fp=%s 与源同值=%s\n' "$n" "$fp" "$r"
  unset v fp
done
printf '  源 %-11s fp=%s\n' "$SRC_NS" "$SRC_FP"

echo "=== S5 键面与副本（Secret 变更本身不会重启 Pod）"
for n in $TGT_NS_LIST; do
  echo "  -- $n"
  kubectl -n "$n" get secret "$SEC" -o go-template='{{range $k, $v := .data}}     {{$k}} b64len={{len $v}}{{"\n"}}{{end}}' 2>&1 | sed 's/^/  /'
  kubectl -n "$n" get deploy -o custom-columns=N:.metadata.name,REP:.status.readyReplicas --no-headers 2>&1 | sed 's/^/     /'
done

if [ "$RESTART" = 1 ]; then
  echo "=== S6 rollout restart（envFrom 只在容器创建时求值 ⇒ 必须重建 Pod 才注入）"
  for n in $TGT_NS_LIST; do
    for d in $(kubectl -n "$n" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      case "$d" in
        *new-api-master|*new-api-slave) ;;
        *) echo "    跳过 $n/$d（非 pre/perf 业务负载）"; continue ;;
      esac
      kubectl -n "$n" rollout restart "deploy/$d" 2>&1 | sed 's/^/    /'
    done
  done
  for n in $TGT_NS_LIST; do
    for d in $(kubectl -n "$n" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      case "$d" in
        *new-api-master|*new-api-slave) kubectl -n "$n" rollout status "deploy/$d" --timeout=180s 2>&1 | sed 's/^/    /' ;;
      esac
    done
  done
fi

echo "--- S1–S6 结束（FAIL=$FAIL）"
exit "$FAIL"
