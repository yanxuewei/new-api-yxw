#!/usr/bin/env bash
# rm-5ts0ez22t67il9oz3 (newapi-logs-mysql) 供给：白名单组 + 公网端点 + 建库建号授权
# 幂等性：各步失败即停（set -e），重跑前先人工核对现状
set -euo pipefail
case ":${PATH}:" in
  *":/usr/local/bin:"*) ;;
  *) PATH="${PATH}:/usr/local/bin" ;;
esac
R="ap-southeast-6"
ID="rm-5ts0ez22t67il9oz3"
SECDIR="/root/.deploy_secrets"
LOG="/root/logs_mysql_provision.log"
exec 3>&2
exec > >(tee -a "$LOG") 2>&1

retry3() { # retry3 <desc> <cmd...>
  local desc="$1"; shift
  local n=1
  while :; do
    if "$@"; then echo "[ok] ${desc}"; return 0; fi
    echo "[!] ${desc} 第 ${n} 次失败"
    n=$((n+1))
    if [ "$n" -gt 3 ]; then echo "[X] ${desc} 重试 3 次仍失败"; return 1; fi
    sleep 5
  done
}

# 0) 前置：实例必须 Running
ST=$(aliyun rds DescribeDBInstanceAttribute --region ${R} --DBInstanceId ${ID} \
    --cli-query 'Items.DBInstanceAttribute[0].DBInstanceStatus' 2>/dev/null | tr -d '"\r')
echo "[i] instance status = ${ST}"
[ "${ST}" = "Running" ] || { echo "[X] 实例未 Running，终止"; exit 1; }

# 1) 白名单两组（照抄现役 PG：mnl VPC 网段 + sg 出口 EIP）
retry3 "whitelist mnl_vpc" aliyun rds ModifySecurityIps --region ${R} --DBInstanceId ${ID} \
  --DBInstanceIPArrayName mnl_vpc \
  --SecurityIps "10.0.16.0/20,10.0.32.0/20,10.0.48.0/20,10.0.64.0/20" \
  --WhitelistNetworkType MIX
retry3 "whitelist sg_standby_eip" aliyun rds ModifySecurityIps --region ${R} --DBInstanceId ${ID} \
  --DBInstanceIPArrayName sg_standby_eip \
  --SecurityIps "47.84.126.214/32,47.84.184.246/32,47.84.29.162/32,47.84.83.76/32" \
  --WhitelistNetworkType MIX

# 2) 公网端点（sg 跨区写日志用；幂等：已存在会报错，视为通过）
if ! aliyun rds AllocateInstancePublicConnection --region ${R} --DBInstanceId ${ID} \
     --ConnectionStringPrefix "${ID}-public" --Port 3306 2>&1 | grep -qiE 'error|fail'; then
  echo "[ok] public endpoint allocated"
else
  echo "[!] public endpoint allocate 失败（若已存在可忽略）"
fi

# 3) 建库（幂等：已存在报 InvalidDBName.Conn current connection exists 类错误则放行）
if retry3 "create database newapi_logs" aliyun rds CreateDatabase --region ${R} \
   --DBInstanceId ${ID} --DBName newapi_logs --CharacterSetName utf8mb4; then :; else
  echo "[!] create database 失败（若已存在请人工确认后继续）"
fi

# 4) 口令（保证 大写+小写+数字，纯字母数字，避免 DSN 转义问题）
if [ ! -s "${SECDIR}/RDS_PW_newapi_logs" ]; then
  PW="Nk$(openssl rand -hex 12)Q7x"
  umask 077; printf '%s' "${PW}" > "${SECDIR}/RDS_PW_newapi_logs"
  echo "[ok] password generated -> ${SECDIR}/RDS_PW_newapi_logs"
fi
PW=$(cat "${SECDIR}/RDS_PW_newapi_logs")

# 5) 建账号（幂等：已存在报错放行，密码不变）
if retry3 "create account newapi_logs" aliyun rds CreateAccount --region ${R} \
   --DBInstanceId ${ID} --AccountName newapi_logs --AccountPassword "${PW}" \
   --AccountType Normal; then :; else
  echo "[!] create account 失败（若已存在请人工确认后继续）"
fi

# 6) 授权 ReadWrite on newapi_logs
retry3 "grant ReadWrite" aliyun rds GrantAccountPrivilege --region ${R} \
  --DBInstanceId ${ID} --AccountName newapi_logs --DBName newapi_logs \
  --AccountPrivilege ReadWrite

# 7) 落 DSN（明文仅存 ${SECDIR}，不进仓库、不进日志）
MNL_HOST=$(aliyun rds DescribeDBInstanceNetInfo --region ${R} --DBInstanceId ${ID} \
  --cli-query 'Items.DBInstanceNetInfo[0].ConnectionString' | tr -d '"\r')
SG_HOST="${ID}-public.mysql.ap-southeast-6.rds.aliyuncs.com"
umask 077
printf '%s' "newapi_logs:${PW}@tcp(${MNL_HOST}:3306)/newapi_logs" > "${SECDIR}/MYSQL_LOG_DSN_MNL"
printf '%s' "newapi_logs:${PW}@tcp(${SG_HOST}:3306)/newapi_logs?tls=true" > "${SECDIR}/MYSQL_LOG_DSN_SG"
echo "[ok] DSN mnl : ${SECDIR}/MYSQL_LOG_DSN_MNL (host=${MNL_HOST})"
echo "[ok] DSN sg  : ${SECDIR}/MYSQL_LOG_DSN_SG  (host=${SG_HOST})"

# 8) 复核
echo "---- whitelist ----"
aliyun rds DescribeDBInstanceIPArrayList --region ${R} --DBInstanceId ${ID} \
  --cli-query 'Items.DBInstanceIPArray[].{name:DBInstanceIPArrayName,ips:SecurityIPList}'
echo "---- databases ----"
aliyun rds DescribeDatabases --region ${R} --DBInstanceId ${ID} \
  --cli-query 'Items.Databases[].DBName' 2>/dev/null || true
echo "---- accounts ----"
aliyun rds DescribeAccounts --region ${R} --DBInstanceId ${ID} \
  --cli-query 'Items.Accounts[].{name:AccountName,status:AccountStatus,type:AccountType}' 2>/dev/null || true
echo "PROVISION_DONE"
