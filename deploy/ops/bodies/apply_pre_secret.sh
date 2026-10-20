#!/bin/bash
# deploy/ops/bodies/apply_pre_secret.sh —— 建/更新 Secret new-api-secrets（pre/perf ns，3 键，无明文回显）
# 载荷 $SEC_B64 = tar.gz：SQL_DSN / SQL_DSN_MIGRATE / SESSION_SECRET
# 载荷 $NS / $DBNAME（header 注入）：目标命名空间与该环境专属库名（默认 pre/newapi_pre）。
# 与 dev 的差别：本 body 只**托管** 3 个键（SQL_DSN / SQL_DSN_MIGRATE / SESSION_SECRET）。
#   `LOG_SQL_DSN`（日志库）与 `REDIS_CONN_STRING`（共享 Tair）属运维另加 ⇒ 本 body **合并保留、绝不删除**；
#   其中 LOG_SQL_DSN 缺失时会从 newapi-dev 复制同源值（2026-10-20 起三环境共用日志库 newapi_logs）。
NS="${NS:-new-api-pre}"; DBNAME="${DBNAME:-newapi_pre}"
trap 'shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }

echo "=== K1 载荷键自证（只报键名与字节数，绝不 cat 值）"
for f in "$T"/sec/*; do printf '    %-18s bytes=%s\n' "$(basename "$f")" "$(wc -c <"$f")"; done
for k in SQL_DSN SQL_DSN_MIGRATE SESSION_SECRET; do
  [ -s "$T/sec/$k" ] || { echo "    [XX] 缺少键 $k"; exit 1; }
done
# 载荷只允许上面 3 个键；LOG_SQL_DSN / REDIS_CONN_STRING 由 K3 合并保留，**不从载荷注入**
for f in "$T"/sec/*; do
  case "$(basename "$f")" in
    SQL_DSN|SQL_DSN_MIGRATE|SESSION_SECRET) : ;;
    *) echo "    [XX] 载荷含未托管的键 $(basename "$f") ⇒ 终止"; exit 1 ;;
  esac
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

echo "=== K3 apply Secret（merge：只覆盖托管的 3 键，保留 LOG_SQL_DSN / REDIS_CONN_STRING）"
if ! kubectl -n "$NS" get secret new-api-secrets >/dev/null 2>&1; then
  ARGS=""
  for k in SQL_DSN SQL_DSN_MIGRATE SESSION_SECRET; do ARGS="$ARGS --from-file=$k=$T/sec/$k"; done
  kubectl -n "$NS" create secret generic new-api-secrets $ARGS >/dev/null 2>&1 \
    && echo "    首次创建（3 键；日志库键由 K3b 补）" \
    || { echo "    [XX] create 失败"; exit 1; }
fi
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data}' > "$T/cur.json" 2>/dev/null || true
[ -s "$T/cur.json" ] || echo '{}' > "$T/cur.json"
python3 - "$T" <<'PY'
import base64, json, os, sys
T = sys.argv[1]
try:
    cur = json.load(open(os.path.join(T, "cur.json")))
except Exception:
    cur = {}
for k in ("SQL_DSN", "SQL_DSN_MIGRATE", "SESSION_SECRET"):
    with open(os.path.join(T, "sec", k), "rb") as f:
        cur[k] = base64.b64encode(f.read()).decode()
json.dump({"data": cur}, open(os.path.join(T, "patch.json"), "w"))
PY
chmod 600 "$T/patch.json"
kubectl -n "$NS" patch secret new-api-secrets --type=merge --patch-file "$T/patch.json" 2>&1 | sed 's/^/    /'
rm -f "$T/patch.json" "$T/cur.json"

echo "=== K3b 日志库键：缺则从 newapi-dev 复制同源值（三环境共用 newapi_logs）"
if [ -z "$(kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null)" ]; then
  B=$(kubectl -n newapi-dev get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null)
  if [ -n "$B" ]; then
    printf '{"data":{"LOG_SQL_DSN":"%s"}}' "$B" > "$T/logpatch.json"; chmod 600 "$T/logpatch.json"
    kubectl -n "$NS" patch secret new-api-secrets --type=merge --patch-file "$T/logpatch.json" 2>&1 | sed 's/^/    /'
    printf '    已从 newapi-dev 复制 fp=%s\n' "$(printf '%s' "$B" | base64 -d | sha256sum | cut -c1-12)"
    rm -f "$T/logpatch.json"; unset B
  else
    echo "    [!] dev 也没有 LOG_SQL_DSN ⇒ 跳过（日志库将回落主库）"
  fi
else
  echo "    已存在，保留现值（不覆盖）"
fi

echo "=== K4 反证：pre 的 SESSION_SECRET 不能等于 dev 的（坑 1 跨环境越权）"
FP_PRE=$(kubectl -n "$NS" get secret new-api-secrets -o go-template='{{ index .data "SESSION_SECRET" }}' 2>/dev/null | base64 -d | sha256sum | cut -c1-12)
FP_DEV=$(kubectl -n newapi-dev get secret new-api-secrets -o go-template='{{ index .data "SESSION_SECRET" }}' 2>/dev/null | base64 -d | sha256sum | cut -c1-12)
printf '    %s fp=%s  dev fp=%s ⇒ ' "$NS" "$FP_PRE" "$FP_DEV"
[ -n "$FP_PRE" ] && [ "$FP_PRE" != "$FP_DEV" ] && echo "不同（合规）" || echo "相同或缺失 ⇒ 违规，必须重生成"

echo "=== K5 键面回读（值只以 base64 长度出现）"
kubectl -n "$NS" get secret new-api-secrets -o go-template='{{range $k, $v := .data}}    {{$k}} b64len={{len $v}}{{"\n"}}{{end}}' 2>&1 | sed 's/^/  /'
echo "=== K6 现网 dev 指纹（改 pre 不该动 dev；与 --dev-baseline 的读数对照）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>&1 | sed 's/^/    /'
