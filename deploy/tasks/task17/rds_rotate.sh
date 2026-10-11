#!/usr/bin/env bash
# RDS 三业务账号密码轮换（应用未部署，零影响）+ 新值入保管目录
# 账号：newapi(主) newapi_migrate(迁移) newapi_sg(备站)
set -euo pipefail
R=ap-southeast-6
ID=pgm-5tstdhko64x2c01w
VAULT=/root/.deploy_secrets
mkdir -p "$VAULT" && chmod 700 "$VAULT"
LOG=/mnt/e/git_code/new-api-yxw/deploy/logs/task17_secret_$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOG"

genpw() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 21; }  # 22位纯字母数字，DSN-URL 安全

echo "===== 1. RDS 连接串 ====="
aliyun rds DescribeDBInstanceNetInfo --RegionId "$R" --region "$R" --DBInstanceId "$ID" > "$LOG/netinfo.json" 2>&1
python3 - "$LOG/netinfo.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for ni in d.get("Items",{}).get("DBInstanceNetInfo",[]):
    print(" -", ni.get("IPType"), ni.get("ConnectionString"), ni.get("Port"))
PY

echo "===== 2. 三账号轮换 ====="
for acct in newapi newapi_migrate newapi_sg; do
  PW="$(genpw)"
  aliyun rds ResetAccountPassword --RegionId "$R" --region "$R" \
    --DBInstanceId "$ID" --AccountName "$acct" --AccountPassword "$PW" \
    > "$LOG/reset_${acct}.json" 2> "$LOG/reset_${acct}.err" \
    && echo "[OK] $acct 已轮换" || { echo "[XX] $acct 失败"; cat "$LOG/reset_${acct}.err"; exit 1; }
  printf '%s\n' "$PW" > "$VAULT/RDS_PW_${acct}"
  chmod 600 "$VAULT/RDS_PW_${acct}"
  sleep 2
done
echo "[OK] 三个新口令已入 $VAULT/RDS_PW_*（600）"

echo "===== 3. 回读账号状态 ====="
aliyun rds DescribeAccounts --RegionId "$R" --region "$R" --DBInstanceId "$ID" 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('Items',{}).get('DBInstanceAccount',[]):
    print(' -', a.get('AccountName'), a.get('AccountStatus'), a.get('AccountType'))
" | tee "$LOG/accounts_after.txt"
echo "LOG=$LOG"
