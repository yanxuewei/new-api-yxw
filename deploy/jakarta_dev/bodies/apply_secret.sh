#!/bin/bash
# bodies/apply_secret.sh —— 创建/更新 Secret new-api-secrets（4 键，无明文回显）
# header 已注入 $SEC_B64（tar.gz：SQL_DSN / SQL_DSN_MIGRATE / LOG_SQL_DSN / SESSION_SECRET）
trap 'shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] secret 载荷解包失败"; exit 1; }

echo "--- 1) 载荷键自证（只报键名与字节数，绝不 cat 值）"
for f in "$T"/sec/*; do
  printf '    %-18s bytes=%s\n' "$(basename "$f")" "$(wc -c <"$f")"
done
for k in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET REDIS_CONN_STRING; do
  [ -s "$T/sec/$k" ] || { echo "    [XX] 缺少键 $k"; exit 1; }
done
# REDIS_CONN_STRING 结构闸门：必须是 redis:// URL（common/redis.go:35 用 redis.ParseURL 解析，
# k/v 形态会直接 ParseURL 失败 ⇒ 首启 FatalLog）。值不回显，只打 host。
v=$(cat "$T/sec/REDIS_CONN_STRING")
case "$v" in
  redis://*) printf '    %-18s host=%s\n' REDIS_CONN_STRING \
    "$(printf '%s' "$v" | sed -nE 's#^redis://[^@]+@([^:/]+):.*#\1#p')" ;;
  *) echo "    [XX] REDIS_CONN_STRING 前缀不是 redis:// ⇒ ParseURL 必失败"; exit 1 ;;
esac
unset v

echo "--- 2) DSN 结构自检（本地 grep，值不外泄）"
# 形态必须是 URL（postgres://user:pw@host:5432/db?sslmode=require）：model/main.go:151 的 chooseDB()
# 只按 **前缀** 选驱动，libpq 的 k/v 形态会掉进 MySQL 分支（2026-10-12 dev 首启实测 CrashLoop）。
for k in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN; do
  v=$(cat "$T/sec/$k")
  case "$v" in
    postgres://*|postgresql://*) : ;;
    *) echo "    [XX] $k 前缀不是 postgres:// ⇒ 应用会按 MySQL 解析，直接终止"; exit 1 ;;
  esac
  host=$(printf '%s' "$v" | sed -nE 's#^.*://[^@]+@([^:/]+):.*#\1#p')
  port=$(printf '%s' "$v" | sed -nE 's#^.*://[^@]+@[^:/]+:([0-9]+)/.*#\1#p')
  db=$(printf '%s' "$v"   | sed -nE 's#^.*://[^@]+@[^/]+/([^?]+).*#\1#p')
  usr=$(printf '%s' "$v"  | sed -nE 's#^.*://([^:]+):[^@]*@.*#\1#p')
  ssl=$(printf '%s' "$v"  | sed -nE 's#.*sslmode=([a-z-]+).*#\1#p')
  printf '    %-16s host=%s port=%s db=%s user=%s sslmode=%s\n' "$k" "$host" "$port" "$db" "$usr" "$ssl"
  case "$k" in
    SQL_DSN_MIGRATE) [ "$usr" = newapi_migrate ] || echo "    [!!] SQL_DSN_MIGRATE 账号不是 newapi_migrate（master 的 SQL_DSN 就取它）";;
    SQL_DSN)         [ "$db" = newapi ]     || echo "    [!!] SQL_DSN 库名不是 newapi";;
    LOG_SQL_DSN)     [ "$db" = newapi_logs ]|| echo "    [!!] LOG_SQL_DSN 库名不是 newapi_logs";;
  esac
  [ "$port" = 5432 ] || echo "    [!!] 端口不是 5432（dev 实测无托管 PgBouncer，6432 被阻断）"
  unset v
done

echo "--- 3) create secret --dry-run | apply（幂等，键名与生产同构）"
ARGS=""
for k in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET REDIS_CONN_STRING; do ARGS="$ARGS --from-file=$k=$T/sec/$k"; done
kubectl -n newapi-dev create secret generic new-api-secrets $ARGS --dry-run=client -o yaml > "$T/secret.yaml" 2>"$T/err" \
  || { echo "    [XX] create secret 失败："; sed 's/^/    /' "$T/err"; exit 1; }
kubectl apply -f "$T/secret.yaml" 2>&1 | sed 's/^/    /'

echo "--- 4) 集群侧键回读（值只以 base64 长度出现；节点无 jq ⇒ go-template）"
kubectl -n newapi-dev get secret new-api-secrets \
  -o go-template='{{range $k, $v := .data}}    {{$k}} b64len={{len $v}}{{"\n"}}{{end}}' 2>&1
echo "--- 5) 提醒：Secret 变更不会自动重启 Pod（任务 17 已证）⇒ 需要 rollout restart"
kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{.status.replicas}' 2>/dev/null \
  && echo "  <- 现存副本数（若刚改过口令，跑 dev_deploy.sh --apply-app 或 rollout restart 才生效）" \
  || echo "    (Deployment 还没建，属正常首跑)"
