#!/bin/bash
# bodies/apply_pre_secret.sh —— 建/更新 Secret new-api-secrets（pre/perf ns，3 键，无明文回显）
# 载荷 $SEC_B64 = tar.gz：SQL_DSN / SQL_DSN_MIGRATE / SESSION_SECRET
# 载荷 $NS / $DBNAME（header 注入）：目标命名空间与该环境专属库名（默认 pre/newapi_pre）。
# 与 dev 的差别（刻意的，不是漏了）：**没有 LOG_SQL_DSN、没有 REDIS_CONN_STRING** ⇒
#   日志表随主库、缓存走进程内（卡片偏差 ③④）。
NS="${NS:-new-api-pre}"; DBNAME="${DBNAME:-newapi_pre}"
trap 'shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }

echo "=== K1 载荷键自证（只报键名与字节数，绝不 cat 值）"
for f in "$T"/sec/*; do printf '    %-18s bytes=%s\n' "$(basename "$f")" "$(wc -c <"$f")"; done
for k in SQL_DSN SQL_DSN_MIGRATE SESSION_SECRET; do
  [ -s "$T/sec/$k" ] || { echo "    [XX] 缺少键 $k"; exit 1; }
done
for k in LOG_SQL_DSN REDIS_CONN_STRING; do
  [ -e "$T/sec/$k" ] && { echo "    [XX] 载荷里出现了 $k ⇒ 与卡片偏差③④冲突，终止"; exit 1; }
done

echo "=== K2 DSN 结构自检（本地 grep，值不外泄）"
for k in SQL_DSN SQL_DSN_MIGRATE; do
  v=$(cat "$T/sec/$k")
  case "$v" in
    postgres://*|postgresql://*) : ;;
    *) echo "    [XX] $k 前缀不是 postgres:// ⇒ 应用会按 MySQL 解析（model/main.go:151），直接终止"; exit 1 ;;
  esac
  host=$(printf '%s' "$v" | sed -nE 's#^.*://[^@]+@([^:/]+):.*#\1#p')
  port=$(printf '%s' "$v" | sed -nE 's#^.*://[^@]+@[^:/]+:([0-9]+)/.*#\1#p')
  db=$(printf '%s' "$v"   | sed -nE 's#^.*://[^@]+@[^/]+/([^?]+).*#\1#p')
  usr=$(printf '%s' "$v"  | sed -nE 's#^.*://([^:]+):[^@]*@.*#\1#p')
  ssl=$(printf '%s' "$v"  | sed -nE 's#.*sslmode=([a-z-]+).*#\1#p')
  printf '    %-16s host=%s port=%s db=%s user=%s sslmode=%s\n' "$k" "$host" "$port" "$db" "$usr" "$ssl"
  [ "$db" = "$DBNAME" ] || { echo "    [XX] $k 的库名不是 $DBNAME ⇒ 会写进别的环境的库，终止"; exit 1; }
  case "$k" in
    SQL_DSN_MIGRATE) [ "$usr" = newapi_migrate ] || { echo "    [XX] SQL_DSN_MIGRATE 账号不是 newapi_migrate"; exit 1; } ;;
    SQL_DSN)         [ "$usr" = newapi ]         || { echo "    [XX] SQL_DSN 账号不是 newapi"; exit 1; } ;;
  esac
  # host 必须是雅加达 dev 实例；出现马尼拉实例域名即视为"动了正式环境"，直接拒
  case "$host" in
    *pgm-d9j9p421lzx4gw73*) : ;;
    *) echo "    [XX] host 不是雅加达实例（$host）⇒ 拒绝"; exit 1 ;;
  esac
  unset v
done
SS=$(cat "$T/sec/SESSION_SECRET")
printf '    SESSION_SECRET   len=%s fp=%s（与 dev 是否同值由 K4 反证）\n' "${#SS}" "$(printf '%s' "$SS" | sha256sum | cut -c1-12)"
unset SS

echo "=== K3 apply Secret（幂等）"
ARGS=""
for k in SQL_DSN SQL_DSN_MIGRATE SESSION_SECRET; do ARGS="$ARGS --from-file=$k=$T/sec/$k"; done
kubectl -n "$NS" create secret generic new-api-secrets $ARGS --dry-run=client -o yaml > "$T/secret.yaml" 2>"$T/err" \
  || { echo "    [XX] create 失败："; sed 's/^/    /' "$T/err"; exit 1; }
kubectl apply -f "$T/secret.yaml" 2>&1 | sed 's/^/    /'

echo "=== K4 反证：pre 的 SESSION_SECRET 不能等于 dev 的（坑 1 跨环境越权）"
FP_PRE=$(kubectl -n "$NS" get secret new-api-secrets -o go-template='{{ index .data "SESSION_SECRET" }}' 2>/dev/null | base64 -d | sha256sum | cut -c1-12)
FP_DEV=$(kubectl -n newapi-dev get secret new-api-secrets -o go-template='{{ index .data "SESSION_SECRET" }}' 2>/dev/null | base64 -d | sha256sum | cut -c1-12)
printf '    %s fp=%s  dev fp=%s ⇒ ' "$NS" "$FP_PRE" "$FP_DEV"
[ -n "$FP_PRE" ] && [ "$FP_PRE" != "$FP_DEV" ] && echo "不同（合规）" || echo "相同或缺失 ⇒ 违规，必须重生成"

echo "=== K5 键面回读（值只以 base64 长度出现）"
kubectl -n "$NS" get secret new-api-secrets -o go-template='{{range $k, $v := .data}}    {{$k}} b64len={{len $v}}{{"\n"}}{{end}}' 2>&1 | sed 's/^/  /'
echo "=== K6 现网 dev 指纹（改 pre 不该动 dev；与 --dev-baseline 的读数对照）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>&1 | sed 's/^/    /'
