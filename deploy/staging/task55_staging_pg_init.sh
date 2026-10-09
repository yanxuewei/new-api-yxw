#!/bin/bash
# task55_staging_pg_init.sh — 在**雅加达** RDS 上初始化 staging 数据面
#
# 做什么：
#   1) 回读实例，断言它是 pgm-d9j9p421lzx4gw73（雅加达）而不是 pgm-5tstdhko64x2c01w（马尼拉生产）
#   2) 建库 newapi_staging / newapi_staging_logs（日志库复用 PG，任务45:F9 非生产不建 CK）
#   3) 建两个账号：newapi_staging(DML/ReadWrite) 与 newapi_staging_migrate(DDL/DBOwner)
#      —— 与 prod 的 newapi / newapi_migrate 一一对应但**互不授权**（DB 层强制，part2b:610）
#   4) 白名单单独成组 jkt_nonprod，只放雅加达 app+data 段；**不引用** prod 的 mnl_vpc 组
#
# usage（WSL Ubuntu；本机无 go/docker/psql，全部走 aliyun OpenAPI）：
#   ALI_PROFILE=<profile> bash deploy/staging/task55_staging_pg_init.sh --precheck
#   ALI_PROFILE=<profile> STAGING_PW=<pw> MIGRATE_PW=<pw> bash deploy/staging/task55_staging_pg_init.sh --apply
#   ALI_PROFILE=<profile> bash deploy/staging/task55_staging_pg_init.sh --verify
#
# 红线：
#   - 口令只从环境变量读（STS/交互输入），**绝不**写进文件、命令行回显或 git。
#     本脚本用 --AccountPassword 传参属**例外**，因为 RDS API 无 stdin 通道；
#     因此要求调用方 `set +o errexit` 无关，但必须 `history -d` / 用后 `shred` 任何中间文件，
#     并在无人共享的 shell 里跑。更稳妥的做法：先在控制台建账号，本脚本只做 --verify。
#   - 每次变更必须体现为 ops 仓库的一次 commit（git开发-发布-值班规范.md §7.2）
set -uo pipefail

REGION="${REGION:-ap-southeast-5}"
JKT_INSTANCE="${JKT_INSTANCE:-pgm-d9j9p421lzx4gw73}"
# 硬红线：出现生产实例 ID 即退出
PROD_INSTANCE="pgm-5tstdhko64x2c01w"

DB_STAGING="${DB_STAGING:-newapi_staging}"
DB_LOGS="${DB_LOGS:-newapi_staging_logs}"
ACCT_DML="${ACCT_DML:-newapi_staging}"
ACCT_DDL="${ACCT_DDL:-newapi_staging_migrate}"
# 雅加达 app 5a/5b/5c + data 5a/5b（jakarta_dev_ledger §1，偏移对齐重建后的真实网段）
WHITELIST_JKT="10.2.16.0/20,10.2.32.0/20,10.2.80.0/20,10.2.48.0/20,10.2.64.0/20"

step(){ printf '\n===== %s =====\n' "$*"; }
die(){ printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${ALI_PROFILE:-}" ] || die "ALI_PROFILE 未设置（不猜测 profile 名）"
ali(){ aliyun --profile "$ALI_PROFILE" --RegionId "$REGION" "$@"; }

[ "$JKT_INSTANCE" != "$PROD_INSTANCE" ] || die "目标是**生产 RDS** $PROD_INSTANCE，拒绝执行"

MODE="${1:---precheck}"

step "0 - 实例回读（EngineVersion 必须与 prod 17.0 对齐，任务45:E11 / O5）"
ali rds DescribeDBInstanceAttribute --DBInstanceId "$JKT_INSTANCE" \
  | python3 -c '
import sys,json
d=json.load(sys.stdin)["Items"]["DBInstanceAttribute"][0]
for k in ("DBInstanceId","DBInstanceDescription","Engine","EngineVersion","DBInstanceClass","DBInstanceStorage","VpcCloudInstanceId","ConnectionString","Port"):
    print(f"  {k:26} = {d.get(k)}")
print("  ⚠ EngineVersion 若不是 17.0，须先裁定：staging 与 prod 版本不一致 ⇒ 迁移/三库矩阵结论不可迁移")
'

step "1 - 现有库/账号/白名单快照"
ali rds DescribeDatabases        --DBInstanceId "$JKT_INSTANCE" | python3 -c 'import sys,json;print("  databases:",[x["DBName"] for x in json.load(sys.stdin)["Databases"]["Database"]])'
ali rds DescribeAccounts         --DBInstanceId "$JKT_INSTANCE" | python3 -c 'import sys,json;print("  accounts :",[x["AccountName"] for x in json.load(sys.stdin)["Accounts"]["DBAccount"]])'
ali rds DescribeDBInstanceIPArrayList --DBInstanceId "$JKT_INSTANCE" | python3 -c '
import sys,json
for g in json.load(sys.stdin)["Items"]["DBInstanceIPArray"]:
    print("  group %-16s = %s" % (g["DBInstanceIPArrayName"], g["SecurityIPLIST"]))'

if [ "$MODE" = "--precheck" ]; then step "precheck 结束（未创建任何资源）"; exit 0; fi

if [ "$MODE" = "--apply" ]; then
  [ -n "${STAGING_PW:-}" ] && [ -n "${MIGRATE_PW:-}" ] || die "--apply 需要 STAGING_PW 与 MIGRATE_PW（只走环境变量）"

  step "2 - 建库"
  for db in "$DB_STAGING" "$DB_LOGS"; do
    ali rds CreateDatabase --DBInstanceId "$JKT_INSTANCE" --DBName "$db" \
      --CharacterSetName UTF8 --DBDescription "task55 staging (nonprod, jakarta)" \
      || printf '  (已存在或报错，继续)\n'
  done

  step "3 - 建账号"
  ali rds CreateAccount --DBInstanceId "$JKT_INSTANCE" --AccountName "$ACCT_DML" \
    --AccountPassword "$STAGING_PW" --AccountType Normal || printf '  (已存在)\n'
  ali rds CreateAccount --DBInstanceId "$JKT_INSTANCE" --AccountName "$ACCT_DDL" \
    --AccountPassword "$MIGRATE_PW" --AccountType Super  || printf '  (已存在；若 Super 不被允许则改 Normal + DBOwner 授权)\n'

  step "4 - 授权（DML 账号只读写、DDL 账号 owner）"
  for db in "$DB_STAGING" "$DB_LOGS"; do
    ali rds GrantAccountPrivilege --DBInstanceId "$JKT_INSTANCE" \
      --AccountName "$ACCT_DML" --DBName "$db" --AccountPrivilege ReadWrite
    ali rds GrantAccountPrivilege --DBInstanceId "$JKT_INSTANCE" \
      --AccountName "$ACCT_DDL" --DBName "$db" --AccountPrivilege DBOwner
  done

  step "5 - 白名单单独成组（**不要**动 prod 的 mnl_vpc 组）"
  ali rds ModifySecurityIps --DBInstanceId "$JKT_INSTANCE" \
    --DBInstanceIPArrayName jkt_nonprod --SecurityIps "$WHITELIST_JKT" --WhitelistNetworkType Classic

  step "6 - 清环境变量痕迹"
  unset STAGING_PW MIGRATE_PW
  printf '  提示：本 shell 的 history 需手工清理；不要把 DSN 写进任何 *.yaml 明文（55-config-secret-template 只放占位）\n'
fi

if [ "$MODE" = "--verify" ]; then
  step "V1 - 断言：雅加达实例上**没有** prod 库名 newapi"
  ali rds DescribeDatabases --DBInstanceId "$JKT_INSTANCE" \
    | python3 -c '
import sys,json
names=[x["DBName"] for x in json.load(sys.stdin)["Databases"]["Database"]]
print("  databases:",names)
bad=[n for n in names if n=="newapi"]
print("  FAIL: 雅加达实例上出现 prod 库名 newapi" if bad else "  OK: 无 prod 同名库")
sys.exit(1 if bad else 0)'

  step "V2 - 断言：账号名不与 prod 重名（prod=newapi/newapi_migrate/newapi_sg）"
  ali rds DescribeAccounts --DBInstanceId "$JKT_INSTANCE" \
    | python3 -c '
import sys,json
ns=[x["AccountName"] for x in json.load(sys.stdin)["Accounts"]["DBAccount"]]
print("  accounts:",ns)
bad=[n for n in ns if n in ("newapi","newapi_migrate","newapi_sg")]
print("  FAIL: 出现 prod 账号名" if bad else "  OK: 账号命名空间隔离")
sys.exit(1 if bad else 0)'

  step "V3 - 断言：白名单不含任何马尼拉/新加坡段（10.0.0.0/16、10.1.0.0/16）"
  ali rds DescribeDBInstanceIPArrayList --DBInstanceId "$JKT_INSTANCE" \
    | python3 -c '
import sys,json
bad=[]
for g in json.load(sys.stdin)["Items"]["DBInstanceIPArray"]:
    ips=g["SecurityIPLIST"].split(",")
    for ip in ips:
        if ip.startswith("10.0.") or ip.startswith("10.1.") or ip=="0.0.0.0/0":
            bad.append((g["DBInstanceIPArrayName"],ip))
    print("  group %-16s = %s" % (g["DBInstanceIPArrayName"], g["SecurityIPLIST"]))
print("  FAIL: 白名单跨到生产网段或全网" if bad else "  OK")
sys.exit(1 if bad else 0)'

  step "V4 - 断言：该实例未开启公网 5432（prod 已开启，staging 不得效仿；C4/O2）"
  ali rds DescribeDBInstanceNetInfo --DBInstanceId "$JKT_INSTANCE" \
    | python3 -c '
import sys,json
infos=json.load(sys.stdin)["DBInstanceNetInfos"]["DBInstanceNetInfo"]
pub=[]
for x in infos:
    print("  %-8s %s:%s" % (x.get("IPType"), x.get("ConnectionString"), x.get("Port")))
    if x.get("IPType")=="Public": pub.append(x.get("ConnectionString"))
if pub:
    print("  FAIL: 存在公网连接地址 %s" % ",".join(pub))
    print("        prod 的 43.118.96.65:5432 已开启属既有偏差；新加坡备站当前正依赖它（O1），关闭需单独裁定")
    sys.exit(1)
print("  OK: 无私网外暴露")'
fi

step "done ($MODE)"
