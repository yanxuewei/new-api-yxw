#!/usr/bin/env bash
# deploy/jakarta_dev/dev_rds_finalize.sh —— 2d 前置：dev RDS 口令轮换 + 账号授权 + 回读
#
# 为什么有这一步（两条独立原因）：
#   ① 口令轮换：2026-10-12 预检时，脱敏用的 sed 按 `user:pw@host` URL 格式写，而本项目
#      PG DSN 是 `key=value` 格式 ⇒ newapi / newapi_migrate 的明文口令进了执行记录。
#      此刻 Secret 还没建、口令还没进集群 ⇒ **轮换是零成本的止血**（旧值立刻作废）。
#   ② 授权：`CreateAccount` 不绑权限（任务 13 坑 6），建库时也没做账号绑定 ⇒ 实测
#      `DatabasePrivilege` 数量为 0，应用连上也无法建表。
#
# ②的口径偏差（有意为之，写进台账）：卡片 G8/任务 13 的最小权限是在库内跑
#   `GRANT USAGE/CREATE ON SCHEMA public` + `ALTER DEFAULT PRIVILEGES`。dev 侧本轮改用
#   RDS 控制台的 `GrantAccountPrivilege --AccountPrivilege DBOwner`（PG 云盘只接受这一个值），粒度更粗
#   （PG 上等价于把账号设为该库的 owner 级权限）。理由：dev 是单工作负载 +
#   NODE_TYPE=master（自带 AutoMigrate），本来就需要 DDL；且库内跑 SQL 需要先把口令
#   送进集群（云助手命令体会留痕），代价大于收益。生产口径不变。
#
# 纪律：本脚本**绝不**打印任何明文口令或完整 DSN（只打印长度 / 指纹 / user 与 host 字段）。
# 幂等：口令只在"文件不存在"时生成；授权 API 可重复调用。
#
# usage: bash deploy/jakarta_dev/dev_rds_finalize.sh [--rotate] [--grant] [--verify]
set -uo pipefail

REGION=ap-southeast-5
RDS=pgm-d9j9p421lzx4gw73
SEC_DIR=/root/.deploy_secrets_dev
DBS=(newapi newapi_logs)
# 授权对象见 grant()：newapi（应用）优先，newapi_migrate 视 owner 冲突而定
ACTION="${1:---grant}"

fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }
notice() { echo "[dev-rds-finalize] $*"; }

gen_pw() {  # 与 provision 脚本同款：保证大小写+数字，长度 19，无特殊字符
  local s up lo di
  s=$(head -c 2048 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
  up=$(printf '%s' "$s" | tr -dc 'A-Z' | cut -c1-6)
  lo=$(printf '%s' "$s" | tr -dc 'a-z' | cut -c1-8)
  di=$(printf '%s' "$s" | tr -dc '0-9' | cut -c1-4)
  printf '%s' "${up:-Dev}x${lo}${di}"
}

# ---- 只读回显：DSN 打码（两种格式都脱：key=value 与 URL）----
mask_dsn() {
  sed -E -e 's/(password=)[^ ]*/\1***/g' -e 's#://([^:/]+):[^@]*@#://\1:***@#g' <<<"$1"
}

rotate() {
  local A PWKEY F NEW
  for A in newapi newapi_migrate; do
    PWKEY=dev_app; [ "$A" = newapi_migrate ] && PWKEY=dev_migrate
    F="$SEC_DIR/$PWKEY"
    [ -s "$F" ] || { notice "缺少 $F，跳过轮换（应先跑 provision_jakarta_dev_rds.sh）"; continue; }
    NEW=$(gen_pw)
    # 先把新口令固化到 .pending（600）：这样"写接口超时但服务端已受理"时，重试用的还是同一个值，
    # 不会出现"库里是新口令、本地文件是旧口令"的错配（任务 13 的超时复核纪律）。
    printf '%s' "$NEW" > "$F.pending"; chmod 600 "$F.pending"
    notice "[$A] ResetAccountPassword …"
    aliyun rds ResetAccountPassword --RegionId "$REGION" --DBInstanceId "$RDS" \
      --AccountName "$A" --AccountPassword "$NEW" >/dev/null 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
      ST=$(aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" --AccountName "$A" 2>/dev/null \
           | jq -r '.Accounts.DBInstanceAccount[0].AccountStatus // "unknown"')
      notice "[$A] 首次调用 rc=$RC，账号状态=$ST ⇒ 用同一新值重试一次（幂等）"
      aliyun rds ResetAccountPassword --RegionId "$REGION" --DBInstanceId "$RDS" \
        --AccountName "$A" --AccountPassword "$NEW" >/dev/null 2>&1 || { notice "[$A] 重试仍失败，保留 .pending 待人工复核"; return 1; }
    fi
    mv -f "$F.pending" "$F"; chmod 600 "$F"
    notice "[$A] 新口令 len=${#NEW} fp=$(fp "$NEW")（旧值已作废）"
    unset NEW
  done
}

rebuild_dsn() {
  local APP MIG SESSION_NOTE
  APP=$(cat "$SEC_DIR/dev_app"); MIG=$(cat "$SEC_DIR/dev_migrate")
  local HOST=pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com
  # dev 无 PgBouncer（实测 6432 BLOCKED）⇒ 全部 5432；SSL 已绑定内网串 ⇒ 后续可升 verify-full
  printf 'host=%s port=5432 dbname=newapi user=newapi password=%s sslmode=require' "$HOST" "$APP" \
    > "$SEC_DIR/SQL_DSN"
  printf 'host=%s port=5432 dbname=newapi user=newapi_migrate password=%s sslmode=require' "$HOST" "$MIG" \
    > "$SEC_DIR/SQL_DSN_MIGRATE"
  printf 'host=%s port=5432 dbname=newapi_logs user=newapi password=%s sslmode=require' "$HOST" "$APP" \
    > "$SEC_DIR/LOG_SQL_DSN"
  chmod 600 "$SEC_DIR/SQL_DSN" "$SEC_DIR/SQL_DSN_MIGRATE" "$SEC_DIR/LOG_SQL_DSN"
  for f in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN; do
    V=$(cat "$SEC_DIR/$f")
    notice "$f => $(mask_dsn "$V")"
    unset V
  done
}

# 授权口径（实测确定，不是猜的）：RDS **PostgreSQL + 云盘** 的 GrantAccountPrivilege 只接受
#   `DBOwner`（`aliyun rds GrantAccountPrivilege --help` 原文："If the instance runs PostgreSQL
#   and uses cloud disks, you can set this parameter to DBOwner"）⇒ ReadWrite/DDLOnly/DMLOnly 会被拒。
#   参数名是 `--DBName`（逗号分隔多库），不是 `--DatabaseName`。
# PG 一个库只有一个 owner ⇒ 先给**应用账号 newapi**（dev 是 NODE_TYPE=master，应用自己跑
#   AutoMigrate，本来就需要 DDL）；再尝试给 newapi_migrate，成功与否都按实测写进台账。
has_priv() {  # 从 DescribeAccounts 读某账号在某库上的现有权限
  aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" --AccountName "$1" 2>/dev/null \
    | jq -r --arg db "$2" '[.Accounts.DBInstanceAccount[].DatabasePrivileges.DatabasePrivilege[]?
                            | select(.DBName==$db) | .AccountPrivilege] | join(",")'
}

do_grant() {  # $1=账号 $2=逗号分隔库
  local cur missing="" D
  IFS=',' read -ra DBARR <<<"$2"
  for D in "${DBARR[@]}"; do
    cur=$(has_priv "$1" "$D")
    if [ "$cur" = "DBOwner" ]; then notice "[$1/$D] 已是 DBOwner，跳过"; else missing="$missing${missing:+,}$D"; fi
  done
  [ -n "$missing" ] || { notice "[$1] 无需变更"; return 0; }
  # AccountPrivilege 的个数必须与 DBName 的个数一致（API 文档明确要求）⇒ 按缺失库数复制
  local n privs=""; n=$(awk -F, '{print NF}' <<<"$missing")
  for _ in $(seq 1 "$n"); do privs="$privs${privs:+,}DBOwner"; done
  notice "[$1] GrantAccountPrivilege DBOwner on $missing （privs=$privs）…"
  local out; out=$(aliyun rds GrantAccountPrivilege --RegionId "$REGION" --DBInstanceId "$RDS" \
    --AccountName "$1" --DBName "$missing" --AccountPrivilege "$privs" 2>&1)
  if [ -n "$out" ] && ! grep -q '"RequestId"' <<<"$out"; then
    notice "[$1] 返回异常：$(head -2 <<<"$out" | tr '\n' ' ')"
  fi
  for D in "${DBARR[@]}"; do notice "  回读 [$1/$D] = $(has_priv "$1" "$D")"; done
}

grant() {
  do_grant newapi "$(IFS=,; echo "${DBS[*]}")"
  do_grant newapi_migrate "$(IFS=,; echo "${DBS[*]}")"
}

verify() {
  notice "== 账号/授权回读 =="
  aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" 2>/dev/null \
    | jq -r '.Accounts.DBInstanceAccount[] | "  \(.AccountName)  type=\(.AccountType)  status=\(.AccountStatus)  privs=\([.DatabasePrivileges.DatabasePrivilege[]?.DBName] | join(","))"'
  aliyun rds DescribeAccounts --RegionId "$REGION" --DBInstanceId "$RDS" 2>/dev/null \
    | jq -c '[.Accounts.DBInstanceAccount[] | {a: .AccountName, p: [.DatabasePrivileges.DatabasePrivilege[]? | {d: .DBName, priv: .AccountPrivilege}]}]'
  notice "== 库回读 =="
  aliyun rds DescribeDatabases --RegionId "$REGION" --DBInstanceId "$RDS" 2>/dev/null \
    | jq -r '.Databases.Database[] | "  \(.DBName)  status=\(.DBStatus)  desc=\(.DBDescription // "-")"'
  notice "== DSN 打码回显 =="
  for f in SQL_DSN SQL_DSN_MIGRATE LOG_SQL_DSN SESSION_SECRET; do
    if [ ! -s "$SEC_DIR/$f" ]; then notice "  [MISS] $f"; continue; fi
    V=$(cat "$SEC_DIR/$f")
    if [ "${f%DSN}" != "$f" ]; then
      notice "  $f => $(mask_dsn "$V")"
    else
      notice "  $f => len=${#V} fp=$(fp "$V")"
    fi
    unset V
  done
  notice "== 实例付费/到期（台账需要）=="
  aliyun rds DescribeDBInstanceAttribute --RegionId "$REGION" --DBInstanceId "$RDS" 2>/dev/null \
    | jq -r '.Items.DBInstanceAttribute[0] | "  PayType=\(.PayType)  ExpireTime=\(.ExpireTime)  Status=\(.DBInstanceStatus)"'
  notice "== SSL（只取状态，证书正文一律删掉：DescribeDBInstanceSSL 会回显 ServerKey）=="
  aliyun rds DescribeDBInstanceSSL --RegionId "$REGION" --DBInstanceId "$RDS" 2>/dev/null \
    | jq 'del(.ServerKey,.ServerCert,.CaCert)' | head -12
}

case "$ACTION" in
  --rotate) rotate; rebuild_dsn; verify ;;
  --grant)  grant; verify ;;
  --verify) verify ;;
  *) notice "未知参数：$ACTION（可用 --rotate / --grant / --verify）"; exit 2 ;;
esac
