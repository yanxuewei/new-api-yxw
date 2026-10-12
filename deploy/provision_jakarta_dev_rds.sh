#!/usr/bin/env bash
# 雅加达 dev RDS 数据面开通（零成本写操作，幂等）
# 依据：指南 §任务 13 已实测语法（CharacterSetName 三段式、建库不绑账号、Super 每实例 1 个）
#      + §任务 15 已实测 SSL 命令（ModifyDBInstanceSSL 只接受 DBInstanceId/ConnectionString/SSLEnabled/CAType）
# 凭据口径：2026-10-05 裁定不使用 KMS —— 口令只生成本机保管目录（600），本脚本不回显、不落 Git
set -euo pipefail

REGION=ap-southeast-5
RDS_ID=pgm-d9j9p421lzx4gw73
RDS_HOST=pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com
SEC_DIR=/root/.deploy_secrets_dev
DB_MAIN=newapi
DB_LOG=newapi_logs

[ "$(id -u)" = 0 ] || { echo "需 root（保管目录在 /root）" >&2; exit 1; }
umask 077
mkdir -p "$SEC_DIR"; chmod 700 "$SEC_DIR"

fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }   # 只打指纹，不打明文
gen_pw() {   # RDS 口令规则：8-32 位，至少三种字符类别（全量读入后再裁剪，避免 pipefail 下的 SIGPIPE）
  local s up lo di
  s=$(head -c 1024 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  up=$(printf '%s' "$s" | tr -dc 'A-Z' | cut -c1-6)
  lo=$(printf '%s' "$s" | tr -dc 'a-z' | cut -c1-8)
  di=$(printf '%s' "$s" | tr -dc '0-9' | cut -c1-4)
  printf '%s' "${up:-Dev}x${lo}${di}"
}
get_pw() { # <key> → 已有则复用，没有则生成并落盘（600）
  local K=$1 F="$SEC_DIR/$1"
  if [ -s "$F" ]; then cat "$F"; return; fi
  local P; P=$(gen_pw); printf '%s' "$P" > "$F"; chmod 600 "$F"; printf '%s' "$P"
}

echo "===== 0. 实例现状 ====="
aliyun rds DescribeDBInstanceAttribute --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
  | jq -r '.Items.DBInstanceAttribute[0]|"engine=\(.Engine) \(.EngineVersion) class=\(.DBInstanceClass) status=\(.DBInstanceStatus) pay=\(.PayType) zone=\(.ZoneId)"'

echo
echo "===== 1. SSL 绑内网串（dev 只有内网串 ⇒ 与主站不同，可走 verify-full）====="
CUR=$(aliyun rds DescribeDBInstanceSSL --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
      | jq -r 'del(.ServerKey,.ServerCert,.CaCert)|.SSLEnabled')     # ⚠ 必须先剥私钥再打印
echo "当前 SSLEnabled=$CUR"
if [ "$CUR" != "on" ]; then
  aliyun rds ModifyDBInstanceSSL --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
    --ConnectionString "$RDS_HOST" --SSLEnabled 1 --CAType aliyun \
    | jq -r '"下发 RequestId=\(.RequestId)"'
  for _ in $(seq 1 30); do
    CUR=$(aliyun rds DescribeDBInstanceSSL --RegionId "$REGION" --DBInstanceId "$RDS_ID" | jq -r '.SSLEnabled')
    [ "$CUR" = "on" ] && break; sleep 10
  done
fi
aliyun rds DescribeDBInstanceSSL --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
  | jq -r 'del(.ServerKey,.ServerCert,.CaCert)|"回读 SSLEnabled=\(.SSLEnabled) ACL=\(.ACL) 绑定串=\(.ConnectionString) 到期=\(.SSLExpireTime)"'

echo
echo "===== 2. 建库（不绑账号：权限全部交给后续 SQL，指南任务 13 坑 6）====="
for DB in "$DB_MAIN" "$DB_LOG"; do
  EXIST=$(aliyun rds DescribeDatabases --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
          | jq -r --arg d "$DB" '[.Databases.Database[]?|select(.DBName==$d)|.DBName][0] // empty')
  if [ -n "$EXIST" ]; then echo "reuse   库 $DB"; else
    aliyun rds CreateDatabase --RegionId "$REGION" --DBInstanceId "$RDS_ID" --DBName "$DB" \
      --CharacterSetName 'UTF8,C,en_US.utf8' --DBDescription "jakarta dev $DB" \
      | jq -r '"created   库 '"$DB"' RequestId=\(.RequestId)"'
    sleep 3
  fi
done

echo
echo "===== 3. 建账号（Super 限 1 个；migrate/app 均 Normal）====="
declare -A ACC=( [newapi_ops]="Super" [newapi_migrate]="Normal" [newapi]="Normal" )
declare -A PWK=( [newapi_ops]="dev_ops" [newapi_migrate]="dev_migrate" [newapi]="dev_app" )
HAVE=$(aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
       | jq -r '.Accounts.DBInstanceAccount[]?|.AccountName')
for A in newapi_ops newapi_migrate newapi; do
  if grep -qx "$A" <<<"$HAVE"; then
    echo "reuse   账号 $A"
  else
    case "$A" in
      newapi_ops)     PWKEY=dev_ops     ;;
      newapi_migrate) PWKEY=dev_migrate ;;
      newapi)         PWKEY=dev_app     ;;
    esac
    PW=$(get_pw "$PWKEY")
    aliyun rds CreateAccount --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
      --AccountName "$A" --AccountPassword "$PW" --AccountType "${ACC[$A]}" \
      --AccountDescription "jakarta dev $A" >/dev/null
    echo "created 账号 $A (${ACC[$A]})  口令指纹=$(fp "$PW") len=${#PW} → $SEC_DIR/$PWKEY"
    sleep 2
  fi
done

echo
echo "===== 4. 回读核验 ====="
aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
  | jq -r '.Accounts.DBInstanceAccount[]|[.AccountName,.AccountType,.AccountStatus,((.DatabasePrivileges.DatabasePrivilege|length)|tostring)]|@tsv' \
  | sed 's/^/  账号  /'
aliyun rds DescribeDatabases --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
  | jq -r '.Databases.Database[]?|[.DBName,.DBStatus,.CharacterSetName]|@tsv' | sed 's/^/  库    /'
aliyun rds DescribeDBInstanceIPArrayList --RegionId "$REGION" --DBInstanceId "$RDS_ID" \
  | jq -r '.Items.DBInstanceIPArray[]|[.SecurityIPGroupName,(.SecurityIPList)]|@tsv' | sed 's/^/  白名单 /'

echo
echo "===== 5. 保管目录产物（DSN 明文只在这台机器，600）====="
{
  printf 'host=%s port=5432 dbname=%s user=newapi_migrate password=%s sslmode=require' "$RDS_HOST" "$DB_MAIN" "$(get_pw dev_migrate)"
} > "$SEC_DIR/SQL_DSN_MIGRATE"
{
  printf 'host=%s port=5432 dbname=%s user=newapi password=%s sslmode=require' "$RDS_HOST" "$DB_MAIN" "$(get_pw dev_app)"
} > "$SEC_DIR/SQL_DSN"
{
  printf 'host=%s port=5432 dbname=%s user=newapi password=%s sslmode=require' "$RDS_HOST" "$DB_LOG" "$(get_pw dev_app)"
} > "$SEC_DIR/LOG_SQL_DSN"
printf '%s' "$(get_pw dev_session_secret)" > "$SEC_DIR/SESSION_SECRET"; chmod 600 "$SEC_DIR"/*
for F in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET; do
  echo "  $F → $SEC_DIR/$F  len=$(wc -c < "$SEC_DIR/$F")  指纹=$(fp "$(cat "$SEC_DIR/$F")")"
done
echo
echo "说明：dev 无 Tair ⇒ REDIS_CONN_STRING 留空（common/redis.go:25 → RedisEnabled=false，限流退化进程内）"
echo "      dev RDS 实测无 6432 托管池（见台账 §12）⇒ DSN 一律 5432 直连，不带池端口"
echo "下一步：权限 SQL 的执行位（DMS 雅加达可用性）→ 见 deploy/jakarta_dev_ledger.md"
