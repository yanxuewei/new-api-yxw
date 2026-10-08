#!/usr/bin/env bash
# =============================================================================
# 任务 17 · 手工 Secret 注入（KMS 替代方案，2026-09-30 用户裁定：不购 KMS 实例）
# -----------------------------------------------------------------------------
# 值来源：
#   SQL_DSN            /root/.deploy_secrets/RDS_PW_newapi        （2026-09-30 轮换）
#   REDIS_CONN_STRING  /mnt/e/git_code/new-api-yxw/deploy/.env
#   SESSION_SECRET     本脚本生成（写入 /root/.deploy_secrets/SESSION_SECRET）
#   SESSION_SECRET_OLD 同上
#   LOG_SQL_DSN        /root/.deploy_secrets/LOG_SQL_DSN
#   SQL_DSN_MIGRATE    /root/.deploy_secrets/RDS_PW_newapi_migrate
#   ⚠ PAYMENT_PRIVATE_KEY / TLS_WILDCARD：待用户提供（支付私钥 / G5 证书），本脚本跳过
# 两地差异：
#   马尼拉：SQL_DSN 走内网 6432（PgBouncer 池，任务 41 裁定①）
#   新加坡：SQL_DSN 走公网串 6432 + sslmode=require（任务 41 裁定②乙路）；REDIS 缺 SG Tair，暂不建
# Secret 名：<ns>/new-api-secrets；ConfigMap 补 LOG_SQL_CLICKHOUSE_TTL_DAYS=90
# 用法：--check | --apply
# =============================================================================
set -uo pipefail

MODE="${1:---check}"
VAULT=/root/.deploy_secrets
ENVFILE=/mnt/e/git_code/new-api-yxw/deploy/.env
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/logs/task17_secret_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
exec 3>&2
say(){ printf '%s\n' "$*" >&3; }
ok(){ printf '  [OK] %s\n' "$*" >&3; }
warn(){ printf '  [!!] %s\n' "$*" >&3; }
die(){ printf '  [XX] %s\n' "$*" >&3; exit 1; }

genpw(){ openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 43; }

# ---- 收集值 ----
collect_mnl() {
  PW_APP="$(tr -d '\r\n' < "$VAULT/RDS_PW_newapi")"
  PW_MIG="$(tr -d '\r\n' < "$VAULT/RDS_PW_newapi_migrate")"
  REDIS="$(grep '^REDIS_CONN_STRING=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '\r\n')"
  LOG_DSN="$(tr -d '\r\n' < "$VAULT/LOG_SQL_DSN")"
  if [ -s "$VAULT/SESSION_SECRET" ]; then SS="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET")"; else SS="$(genpw)"; printf '%s\n' "$SS" > "$VAULT/SESSION_SECRET"; chmod 600 "$VAULT/SESSION_SECRET"; fi
  if [ -s "$VAULT/SESSION_SECRET_OLD" ]; then SS_OLD="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET_OLD")"; else SS_OLD="$(genpw)"; printf '%s\n' "$SS_OLD" > "$VAULT/SESSION_SECRET_OLD"; chmod 600 "$VAULT/SESSION_SECRET_OLD"; fi
  SQL_DSN="postgres://newapi:${PW_APP}@pgm-5tstdhko64x2c01w.pgsql.ap-southeast-6.rds.aliyuncs.com:6432/newapi"
  SQL_DSN_MIGRATE="postgres://newapi_migrate:${PW_MIG}@pgm-5tstdhko64x2c01w.pgsql.ap-southeast-6.rds.aliyuncs.com:5432/newapi"
}
collect_sg() {
  PW_SG="$(tr -d '\r\n' < "$VAULT/RDS_PW_newapi_sg")"
  LOG_DSN="$(tr -d '\r\n' < "$VAULT/LOG_SQL_DSN")"
  if [ -s "$VAULT/SESSION_SECRET" ]; then SS="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET")"; else collect_mnl >/dev/null 2>&1 || true; SS="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET" 2>/dev/null)"; fi
  SQL_DSN="postgres://newapi_sg:${PW_SG}@pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com:6432/newapi?sslmode=require"
}

build_body() { # $1=site
  local site="$1"
  if [ "$site" = "mnl" ]; then
    collect_mnl
    cat > /tmp/t17_secret_body.sh <<BEOF
#!/usr/bin/env bash
set -e
kubectl -n new-api create secret generic new-api-secrets --dry-run=client -o yaml \
  --from-literal="SQL_DSN=$SQL_DSN" \
  --from-literal="SQL_DSN_MIGRATE=$SQL_DSN_MIGRATE" \
  --from-literal="REDIS_CONN_STRING=$REDIS" \
  --from-literal="SESSION_SECRET=$SS" \
  --from-literal="SESSION_SECRET_OLD=$SS_OLD" \
  --from-literal="LOG_SQL_DSN=$LOG_DSN" \
  | kubectl apply -f - >/dev/null && echo "secret applied (mnl, 6 keys)"
kubectl -n new-api patch configmap new-api-config --type merge -p '{"data":{"LOG_SQL_CLICKHOUSE_TTL_DAYS":"90"}}' && echo "configmap patched (TTL=90)"
kubectl -n new-api get secret new-api-secrets -o jsonpath='{.data}' | tr ',' '\n' | sed 's/[{:}]//g' | awk '{print "  key:", $1}' | sed 's/^ *//'
echo "MNL-SECRET-DONE"
BEOF
  else
    collect_sg
    cat > /tmp/t17_secret_body.sh <<BEOF
#!/usr/bin/env bash
set -e
kubectl -n new-api create secret generic new-api-secrets --dry-run=client -o yaml \
  --from-literal="SQL_DSN=$SQL_DSN" \
  --from-literal="SESSION_SECRET=$SS" \
  --from-literal="LOG_SQL_DSN=$LOG_DSN" \
  | kubectl apply -f - >/dev/null && echo "secret applied (sg, 3 keys — REDIS 等 SG Tair / PAYMENT·TLS 待补)"
kubectl -n new-api patch configmap new-api-config --type merge -p '{"data":{"LOG_SQL_CLICKHOUSE_TTL_DAYS":"90"}}' && echo "configmap patched (TTL=90)"
kubectl -n new-api get secret new-api-secrets -o jsonpath='{.data}' | tr ',' '\n' | sed 's/[{:}]//g' | awk '{print "  key:", $1}' | sed 's/^ *//'
echo "SG-SECRET-DONE"
BEOF
  fi
  chmod 600 /tmp/t17_secret_body.sh
}

case "$MODE" in
  --check)
    say "STEP check | 凭据值来源盘点"
    for f in RDS_PW_newapi RDS_PW_newapi_migrate RDS_PW_newapi_sg LOG_SQL_DSN CK_ADMIN_DSN SESSION_SECRET SESSION_SECRET_OLD; do
      [ -s "$VAULT/$f" ] && ok "保管文件 $VAULT/$f" || warn "缺失 $VAULT/$f"
    done
    grep -q '^REDIS_CONN_STRING=' "$ENVFILE" && ok "REDIS_CONN_STRING 在 deploy/.env" || warn "deploy/.env 缺 REDIS_CONN_STRING"
    warn "PAYMENT_PRIVATE_KEY / TLS_WILDCARD 待用户提供（不在本脚本范围）"
    say "check 完成"
    ;;
  --apply)
    hr=1
    say "STEP apply | 两地注入 new-api-secrets + ConfigMap TTL"
    build_body mnl
    bash "$HERE/ack_remote.sh" mnl /tmp/t17_secret_body.sh >&3 2>&3 || die "马尼拉注入失败"
    build_body sg
    bash "$HERE/ack_remote.sh" sg /tmp/t17_secret_body.sh >&3 2>&3 || die "新加坡注入失败"
    shred -u /tmp/t17_secret_body.sh 2>/dev/null || rm -f /tmp/t17_secret_body.sh
    ok "两地注入完成（含密码的 body 已销毁）"
    say "待补：PAYMENT_PRIVATE_KEY（支付私钥）、TLS_WILDCARD（G5 证书）、SG REDIS（SG Tair 未建）"
    ;;
  *) die "未知参数：$MODE（--check | --apply）" ;;
esac
