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
#   SQL_DSN_MIGRATE    /root/.deploy_secrets/RDS_PW_newapi_migrate（mnl 内网 5432 / sg 公网 5432 + verify-full）
#   ⚠ PAYMENT_PRIVATE_KEY / TLS_WILDCARD：待用户提供（支付私钥 / G5 证书），本脚本跳过
# 两地差异：
#   马尼拉：SQL_DSN 走内网 6432（PgBouncer 池，任务 41 裁定①）
#   新加坡：SQL_DSN 走公网串 6432 + sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt
#           （任务 41 裁定②乙路 + 任务 30 于 2026-10-05 22:00 的 TLS 升级；CA 见 Secret
#           rds-ca-apse6，备站 Deployment 必须挂载该 Secret，否则建连直接失败）
#           补 SQL_DSN_MIGRATE（2026-10-06 用户核准）：**公网串 5432 直连**，同 verify-full —— 迁移是
#           DDL，不经 6432 池（任务 41 的兼容性风险），接管态才能在 sg 跑 migrate Job
#           REDIS_CONN_STRING（**2026-10-09 起 sg 也写该键**）：值取 deploy/.env 的 `REDIS_CONN_STRING_SG`
#           （SG Tair `r-gs5ltv3m4i3655besh`，见指南任务 29 执行记录 4/5）。⚠ 口令含保留字符必须
#           **百分号转义**（`#` → `%23`），否则 go-redis `url.Parse` 把 `#` 当 fragment 起点，
#           报 `invalid port ":…" after host` 并 FatalLog 退出（任务 29 坑 10，2026-10-09 实踩）；
#           LOG_SQL_DSN 必须走 -public 端点（指南任务 17 坑 12）
#   SESSION_SECRET / SESSION_SECRET_OLD 两地必须读同一个保管文件、取同一个值（任务 55 R40：
#   若各造一个随机值，GTM 接管到备站时全部会话验签失败 ⇒ 全员掉线）
# Secret 名：<ns>/new-api-secrets；ConfigMap 补 LOG_SQL_CLICKHOUSE_TTL_DAYS=90
# ⚠ 覆盖语义：本脚本 apply 的是含 data 的完整对象 ⇒ **data 是整键替换**，未列出的键会被删。
#   因此 body 会先打印 "keys BEFORE" 再打印注入后的键集，两次对照才允许销账。
# 用法：--check | --apply [mnl|sg|both]（默认 both；单站用于只补一侧，避免动另一侧实况）
# =============================================================================
set -uo pipefail

MODE="${1:---check}"
SITE="${2:-both}"
VAULT="${VAULT:-/root/.deploy_secrets}"
ENVFILE="${ENVFILE:-/mnt/e/git_code/new-api-yxw/deploy/.env}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="$HERE/../../logs/task17_secret_$(date +%Y%m%d-%H%M%S)"
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
  # 保管文件存的是 mnl 同区 VPC 端点；sg 跨区必须走 -public 端点（2026-09-30 裁定③，
  # 2026-10-05 已把集群侧修正为 -public）。不在此处做转换的话，本脚本一旦 --apply
  # 就会用 VPC 端点覆盖掉那个修正 ⇒ sg 写日志重新变成分区不可达。
  LOG_DSN="$(tr -d '\r\n' < "$VAULT/LOG_SQL_DSN" | sed 's/-clickhouse\.clickhouseserver/-public.clickhouseserver/')"
  case "$LOG_DSN" in
    *-public.clickhouseserver.*) ;;
    *) die "sg LOG_SQL_DSN 端点不是 -public（跨区必然不可达）：$(printf %s "$LOG_DSN" | sed -E 's#://[^@]*@#://<REDACTED>@#')" ;;
  esac
  # SG Tair 连接串（2026-10-09 起 sg 写该键）：来源 deploy/.env 的 REDIS_CONN_STRING_SG
  REDIS_SG="$(grep '^REDIS_CONN_STRING_SG=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '\r\n')"
  [ -n "$REDIS_SG" ] || die "缺 REDIS_CONN_STRING_SG（$ENVFILE）—— SG Tair 已于 2026-10-09 建成（任务 29），该键必须注入"
  case "$REDIS_SG" in
    *'#'*) die "REDIS_CONN_STRING_SG 含未转义的 '#'：go-redis 会把 # 当 fragment 起点 ⇒ 口令必须写成 %23（任务 29 坑 10）" ;;
  esac
  if [ -s "$VAULT/SESSION_SECRET" ]; then SS="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET")"; else collect_mnl >/dev/null 2>&1 || true; SS="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET" 2>/dev/null)"; fi
  if [ -s "$VAULT/SESSION_SECRET_OLD" ]; then SS_OLD="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET_OLD")"; else collect_mnl >/dev/null 2>&1 || true; SS_OLD="$(tr -d '\r\n' < "$VAULT/SESSION_SECRET_OLD" 2>/dev/null)"; fi
  [ -n "${SS_OLD:-}" ] || die "保管目录缺 SESSION_SECRET_OLD，且 mnl 兜底生成失败 —— 禁止给 sg 另造随机值（会让两地密钥分叉）"
  # TLS 口径与集群实况一致：sg 已于 2026-10-05 22:00 切 verify-full（任务 30），CA 挂在
  # Secret rds-ca-apse6 → /etc/ssl/rds/ca.crt。本脚本是整键覆盖写，若仍留 sslmode=require
  # 就会在一次 --apply 里把那次升级静默回退。
  SQL_DSN="postgres://newapi_sg:${PW_SG}@pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com:6432/newapi?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt"
  # SQL_DSN_MIGRATE：接管态要在 sg 跑迁移 Job（deploy/aliyun/ph/migrate-job.yaml），缺键则该 Job 起不来。
  # 端口必须是 **5432 直连**而非 6432 —— 迁移是 DDL + 可能多语句，经 transaction 池正是任务 41 明确
  # 要避免的路径；与 mnl 分支同口径（mnl 用内网 5432，sg 跨区只能走 -public 5432 + verify-full）。
  PW_MIG_SG="$(tr -d '\r\n' < "$VAULT/RDS_PW_newapi_migrate")"
  SQL_DSN_MIGRATE="postgres://newapi_migrate:${PW_MIG_SG}@pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com:5432/newapi?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt"
}

build_body() { # $1=site
  local site="$1"
  if [ "$site" = "mnl" ]; then
    collect_mnl
    cat > /tmp/t17_secret_body.sh <<BEOF
#!/usr/bin/env bash
set -e
# ⚠ 本脚本是**整键覆盖写**（apply 一个含 data 的完整对象 ⇒ data 里未列出的键会被删）。
#   所以先打印注入前的键集，与注入后对照，证明"没有键被静默删除"（任务 28 坑 8 的同源风险）。
echo "== keys BEFORE =="; kubectl -n new-api get secret new-api-secrets -o json | python3 -c "import sys,json;print(chr(10).join('  key: '+k for k in sorted(json.load(sys.stdin)['data'])))" 2>/dev/null || echo "  (无该 Secret，首建)"
kubectl -n new-api create secret generic new-api-secrets --dry-run=client -o yaml \
  --from-literal="SQL_DSN=$SQL_DSN" \
  --from-literal="SQL_DSN_MIGRATE=$SQL_DSN_MIGRATE" \
  --from-literal="REDIS_CONN_STRING=$REDIS" \
  --from-literal="SESSION_SECRET=$SS" \
  --from-literal="SESSION_SECRET_OLD=$SS_OLD" \
  --from-literal="LOG_SQL_DSN=$LOG_DSN" \
  | kubectl apply -f - >/dev/null && echo "secret applied (mnl, 6 keys)"
kubectl -n new-api patch configmap new-api-config --type merge -p '{"data":{"LOG_SQL_CLICKHOUSE_TTL_DAYS":"90"}}' && echo "configmap patched (TTL=90)"
kubectl -n new-api get secret new-api-secrets -o json | python3 -c "import sys,json;print(chr(10).join('  key: '+k for k in sorted(json.load(sys.stdin)['data'])))"
echo "MNL-SECRET-DONE"
BEOF
  else
    collect_sg
    cat > /tmp/t17_secret_body.sh <<BEOF
#!/usr/bin/env bash
set -e
echo "== keys BEFORE =="; kubectl -n new-api get secret new-api-secrets -o json | python3 -c "import sys,json;print(chr(10).join('  key: '+k for k in sorted(json.load(sys.stdin)['data'])))" 2>/dev/null || echo "  (无该 Secret，首建)"
kubectl -n new-api create secret generic new-api-secrets --dry-run=client -o yaml \
  --from-literal="SQL_DSN=$SQL_DSN" \
  --from-literal="SQL_DSN_MIGRATE=$SQL_DSN_MIGRATE" \
  --from-literal="SESSION_SECRET=$SS" \
  --from-literal="SESSION_SECRET_OLD=$SS_OLD" \
  --from-literal="REDIS_CONN_STRING=$REDIS_SG" \
  --from-literal="LOG_SQL_DSN=$LOG_DSN" \
  | kubectl apply -f - >/dev/null && echo "secret applied (sg, 6 keys — PAYMENT_PRIVATE_KEY / TLS_WILDCARD 待补；SESSION_SECRET·_OLD 与 mnl 同值)"
kubectl -n new-api patch configmap new-api-config --type merge -p '{"data":{"LOG_SQL_CLICKHOUSE_TTL_DAYS":"90"}}' && echo "configmap patched (TTL=90)"
kubectl -n new-api get secret new-api-secrets -o json | python3 -c "import sys,json;print(chr(10).join('  key: '+k for k in sorted(json.load(sys.stdin)['data'])))"
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
    case "$SITE" in
      mnl|sg|both) : ;;
      *) die "SITE 必须是 mnl|sg|both（给了：$SITE）" ;;
    esac
    say "STEP apply | 注入 new-api-secrets + ConfigMap TTL（site=$SITE）"
    if [ "$SITE" = "sg" ]; then
      say "  ⚠ 单站模式：只写 sg，**不碰 mnl**（整键覆盖写，两站实况可能已分叉；见核心更新总结 §5-⑧）"
    fi
    if [ "$SITE" != "sg" ]; then
      build_body mnl
      bash "$HERE/../../lib/ack_remote.sh" mnl /tmp/t17_secret_body.sh >&3 2>&3 || die "马尼拉注入失败"
    fi
    if [ "$SITE" != "mnl" ]; then
      build_body sg
      bash "$HERE/../../lib/ack_remote.sh" sg /tmp/t17_secret_body.sh >&3 2>&3 || die "新加坡注入失败"
    fi
    shred -u /tmp/t17_secret_body.sh 2>/dev/null || rm -f /tmp/t17_secret_body.sh
    ok "注入完成（site=$SITE，含密码的 body 已销毁）"
    say "待补：PAYMENT_PRIVATE_KEY（支付私钥）、TLS_WILDCARD（G5 证书）；SG REDIS_CONN_STRING 自 2026-10-09 起已由本脚本写入（值取 deploy/.env 的 REDIS_CONN_STRING_SG）"
    ;;
  *) die "未知参数：$MODE（--check | --apply [mnl|sg|both]）" ;;
esac
