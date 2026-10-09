#!/usr/bin/env bash
# ==============================================================================
# 任务 4｜马尼拉 RDS PostgreSQL 高可用版（计费：包年包月）
#   指南：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md § Day1 任务 4
#   基线：pg.x4.2xlarge.2c（16C64G）· HA 主 6a/备 6b · 100G ESSD PL1 · PG 16.0
#         包年包月 12 个月 · env=prod / site=ph-mnl / project=new-api
#
# 用法:  ./deploy/task4_rds_mnl.sh [verify|price|create|check|tag|all]
#        默认 verify
#
# 幂等：create 前先按 DBInstanceDescription 查重；已存在则跳过。
# 安全：本脚本不创建任何非 Prepaid 资源；余额为 0 时由阿里云风控拦截，
#       不会静默下单成功（AutoPay=true 付款失败即整单失败）。
# ==============================================================================
set -uo pipefail

# ---- PATH 自愈（此前的坑：直接 ./deploy/xx.sh 时 aliyun 找不到）----
export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"
command -v aliyun >/dev/null 2>&1 || { echo "FATAL: aliyun CLI 未找到" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq 未找到" >&2; exit 127; }

# ---- 基线常量 ----
REGION="ap-southeast-6"
ZONE_A="ap-southeast-6a"
ZONE_B="ap-southeast-6b"
RG="rg-aek4nyivmmsb6iy"                       # rg-ph-mnl
VPC="vpc-5tst1tgeessxn1azwasg2"
VSW_A="vsw-5tswufq2pi26l4ahoiu84"             # vsw-mnl-data-a / 10.0.48.0/20 / 6a
VSW_B="vsw-5tsxa8fupaf8xeyln0o7a"             # vsw-mnl-data-b / 10.0.64.0/20 / 6b

DB_CLASS="pg.x4.2xlarge.2c"                   # 16C64G（高可用系列·独享型）
DB_STORAGE="100"                              # GB，步长 5
DB_STORAGE_TYPE="cloud_essd"                  # ESSD PL1
PG_VER="16.0"
DB_NAME="newapi-pg-mnl"                       # DBInstanceDescription
PAY_TYPE="Prepaid"                            # 包年包月（2026-09-28 修订）
USED_TIME="1"                                 # 1 年（= 12 个月；见下方 Order.PeriodInvalid 坑）
PERIOD="Year"
USED_TIME_YEAR="1"                            # 包年询价对照

LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/task4_rds_${TS}.log"

# ---- 日志：一律 stderr 带色，避免污染 $(...) 捕获 ----
_c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
say()  { printf '%s\n' "$(_c '1;36' '▸') $*" >&2; }
ok()   { printf '%s\n' "$(_c '1;32' '✅') $*" >&2; }
warn() { printf '%s\n' "$(_c '1;33' '⚠️ ') $*" >&2; }
die()  { printf '%s\n' "$(_c '1;31' '⛔') $*" >&2; exit 1; }
hr()   { printf '%s\n' "$(_c '2' '────────────────────────────────────────────────────────')" >&2; }

# 把每次 API 调用落盘（只记请求名与返回，便于事后取证）
api() {
  local name="$1"; shift
  printf '\n### %s :: aliyun %s %s\n' "$(date -u +%FT%TZ)" "$name" "$*" >>"$LOG"
  local out; out="$(aliyun "$name" "$@" 2>&1)"
  printf '%s\n' "$out" >>"$LOG"
  printf '%s' "$out"
}

# ============================== Step 1 verify ==============================
do_verify() {
  hr; say "STEP verify｜任务 4 · 可买性验证（P0，不做完不许下单）"

  say "1/5 账户余额"
  local bal; bal="$(api bssopenapi QueryAccountBalance --region ap-southeast-1)"
  printf '%s\n' "$bal" | jq -r '.Data|"  余额 AvailableAmount=\(.AvailableAmount) \(.Currency)  Cash=\(.AvailableCashAmount)"' >&2
  local amt; amt="$(printf '%s' "$bal" | jq -r '.Data.AvailableAmount // "0"')"
  if [ "$(printf '%.2f' "$amt" 2>/dev/null || echo 0)" = "0.00" ]; then
    warn "余额为 0.00 USD —— 包年包月下单会被拒（风控先于余额提示）"
  fi

  say "2/5 RDS 可用区（期望含 ${ZONE_A} / ${ZONE_B}）"
  api rds DescribeRegions | jq -r --arg r "$REGION" \
    '.Regions.RDSRegion[]|select(.RegionId==$r)|"  \(.RegionId)  \(.ZoneId)"' >&2

  say "3/5 RDS 配额口径"
  warn "阿里云配额中心 ProductCode=rds 不接受 CommonQuota（实测 PARAMETER.ILLEGALL，指南写的 CommonConfig 亦非法）"
  warn "→ RDS 无 vCPU 配额闸门，改用「可售规格 + 存量实例数」双验（见 4/5）"

  say "4/5 包年包月可售规格（InstanceChargeType=Prepaid，关键：与按量池不共享）"
  local ac; ac="$(api rds DescribeAvailableClasses --RegionId "$REGION" --ZoneId "$ZONE_A" \
    --Engine PostgreSQL --EngineVersion "$PG_VER" --DBInstanceStorageType "$DB_STORAGE_TYPE" \
    --InstanceChargeType Prepaid --Category HighAvailability)"
  local cnt; cnt="$(printf '%s' "$ac" | jq -r '.DBInstanceClasses|length // 0')"
  printf '%s\n' "  Prepaid 可售规格数 = $cnt" >&2
  [ "$cnt" -gt 0 ] || die "Prepaid 无货：换 EngineVersion / StorageType / 可用区"
  printf '%s' "$ac" | jq -r --arg c "$DB_CLASS" \
    '.DBInstanceClasses[]|select(.DBInstanceClass==$c)|"  ✅ 目标规格 \(.DBInstanceClass) 存储范围 \(.DBInstanceStorageRange.MinValue)-\(.DBInstanceStorageRange.MaxValue)G step=\(.DBInstanceStorageRange.Step)"' >&2
  printf '%s' "$ac" | jq -e --arg c "$DB_CLASS" '.DBInstanceClasses[]|select(.DBInstanceClass==$c)' >/dev/null \
    || die "目标规格 $DB_CLASS 在 Prepaid 口径不可售"
  # 6b 同步核对（备节点所在地）
  local cntb; cntb="$(api rds DescribeAvailableClasses --RegionId "$REGION" --ZoneId "$ZONE_B" \
    --Engine PostgreSQL --EngineVersion "$PG_VER" --DBInstanceStorageType "$DB_STORAGE_TYPE" \
    --InstanceChargeType Prepaid --Category HighAvailability | jq -r '.DBInstanceClasses|length // 0')"
  printf '%s\n' "  6b 可售规格数 = $cntb" >&2
  [ "$cntb" -gt 0 ] || die "备可用区 $ZONE_B 无货"

  say "5/5 存量实例查重 / 资源组"
  local exist; exist="$(api rds DescribeDBInstances --RegionId "$REGION" --PageSize 50)"
  printf '%s\n' "$exist" | jq -r '.Items.DBInstance[]?|"  已有: \(.DBInstanceId)  \(.DBInstanceDescription)  \(.PayType)  \(.DBInstanceStatus)"' >&2
  local n; n="$(printf '%s' "$exist" | jq -r '.Items.DBInstance[]?|select(.DBInstanceDescription=="'"$DB_NAME"'")|.DBInstanceId' | head -1)"
  if [ -n "$n" ]; then ok "目标实例已存在: ${n}（create 将幂等跳过）"; else say "目标实例不存在，可创建"; fi

  ok "verify 完成；日志 $LOG"
}

# ============================== Step 2 price ==============================
do_price() {
  hr; say "STEP price｜包年包月 vs 按量（ap-southeast-6 / $DB_CLASS / ${DB_STORAGE}G ESSD）"

  # 坑 A：Prepaid 不带 --CommodityCode 也能返回（自动 rds_intl）；
  #       但 Postpaid **必须** --CommodityCode bards，否则 PriceInfo 全为 null（静默 n/a）。
  # 坑 B：反过来给 Prepaid 传 bards 会强制按量计价并覆盖 PayType —— 表现为三档价全相同。
  _q() { # $1=PayType $2=TimeType(可空) $3=UsedTime(可空) $4=CommodityCode
    local out
    out="$(api rds DescribePrice --RegionId "$REGION" --Engine PostgreSQL --EngineVersion "$PG_VER" \
      --DBInstanceClass "$DB_CLASS" --DBInstanceStorage "$DB_STORAGE" --DBInstanceStorageType "$DB_STORAGE_TYPE" \
      --PayType "$1" ${2:+--TimeType "$2"} ${3:+--UsedTime "$3"} --OrderType BUY --Quantity 1 \
      --CommodityCode "$4")"
    printf '%s' "$out" | jq -c '{price:.PriceInfo.OriginalPrice, commodityCode:.PriceInfo.OrderLines."0".commodityCode, chargeType:.PriceInfo.OrderLines."0".chargeType}' >&2
    printf '%s' "$out" | jq -r '.PriceInfo.OriginalPrice // "n/a"'
  }
  local m1 m12 y1 h
  m1="$(_q Prepaid Month 1 rds)"              # 月单价（询价可用；下单不可用 Month）
  y1="$(_q Prepaid Year "$USED_TIME_YEAR" rds)"  # ★ 实际下单口径 = 1 年
  m9="$(_q Prepaid Month 9 rds)"               # 月付上限探针（对照，说明为何必须 Year）
  h="$(_q Postpaid "" "" bards)"                # 按量小时价
  printf '%s\n' "  包月单价（1 个月）        = $m1 USD" >&2
  printf '%s\n' "  ★ 实际下单口径 1 年(Period=Year,UsedTime=1) = $y1 USD（月均 $(python3 -c "print(f'{$y1/12:.2f}')" 2>/dev/null || echo '?')）" >&2
  printf '%s\n' "  月付 9 个月（上限对照）    = $m9 USD" >&2
  printf '%s\n' "  按量（对照）              = $h USD/小时 ⇒ 月约 $(python3 -c "print(f'{$h*730:.2f}')" 2>/dev/null || echo '?') USD" >&2
  python3 - "$m1" "$h" <<'PY' >&2 2>/dev/null || true
import sys
m, h = float(sys.argv[1]), float(sys.argv[2])
if m and h:
    print(f"  → 包月比按量省 {100*(1-m/(h*730)):.1f}%")
PY
  ok "price 完成（chargeType=1 即包年包月；commodityCode rds_intl vs bards_intl 可区分口径）"
  warn "下单期口径：月付上限 < 12 → 12 个月必须 Period=Year/UsedTime=1，写 Month/12 报 Order.PeriodInvalid（实测）"
}

# ============================== Step 3 create ==============================
# 安全默认：AutoPay=false → 只生成「未支付订单」，不扣费、不创建实例。
#           用于确证参数合法性 / 风控拦截 / 订单金额，零资金风险。
# 真实下单：AUTO_PAY=true（等价 ./task4_rds_mnl.sh create-pay），余额必须 > 0。
do_create() {   # $1 = AutoPay 值（false=只出未支付订单；true=真实付款下单）
  local AUTO_PAY="${1:-false}"
  hr; say "STEP create｜任务 4 · 创建 RDS PostgreSQL HA（包年包月 ${USED_TIME} ${PERIOD}，AutoPay=${AUTO_PAY}）"

  local id; id="$(api rds DescribeDBInstances --RegionId "$REGION" --PageSize 50 \
    | jq -r '.Items.DBInstance[]?|select(.DBInstanceDescription=="'"$DB_NAME"'")|.DBInstanceId' | head -1)"
  if [ -n "$id" ]; then ok "已存在 ${id}，跳过创建"; printf '%s' "$id" > /tmp/.task4_rds_id; return 0; fi

  # 幂等闸门 2：未支付订单存在则拒绝再下（ClientToken 只防同 token 重复；
  # 换了 token 或改了周期仍会新建订单 → 必须显式查一次）
  local po; po="$(api bssopenapi QueryOrders --region ap-southeast-1 --PageSize 50 --ProductCode rds \
    | jq -r '.Data.OrderList.Order[]?|select(.PaymentStatus=="Unpaid")|"\(.OrderId)\t\(.PretaxAmount)\t\(.CreateTime)"')"
  if [ -n "$po" ]; then
    local oid; oid="$(printf '%s' "$po" | head -1 | cut -f1)"
    printf '%s\n' "  未支付 RDS 订单：$po" >&2
    warn "已存在未支付订单 ${oid} → 拒绝重复下单（避免多张订单）"
    printf '%s' "$oid" > /tmp/.task4_rds_oid
    return 0
  fi

  say "参数：Category=HighAvailability 主 ${ZONE_A} / 备 ${ZONE_B} · ${DB_CLASS} · ${DB_STORAGE}G ${DB_STORAGE_TYPE} · PayType=${PAY_TYPE} Period=${PERIOD} UsedTime=${USED_TIME}"
  [ "$AUTO_PAY" = "true" ] || warn "AUTO_PAY=false：仅生成未支付订单（不扣费 / 不建实例）"
  # ClientToken 必须**跨调用稳定**，否则重复执行会生成多张未支付订单（幂等失效）
  local tok="task4-${DB_NAME}-${PERIOD}${USED_TIME}-v1"
  local out; out="$(api rds CreateDBInstance \
      --RegionId "$REGION" \
      --Engine PostgreSQL --EngineVersion "$PG_VER" \
      --DBInstanceClass "$DB_CLASS" --DBInstanceStorage "$DB_STORAGE" --DBInstanceStorageType "$DB_STORAGE_TYPE" \
      --Category HighAvailability --ZoneId "$ZONE_A" --ZoneIdSlave1 "$ZONE_B" \
      --VPCId "$VPC" --VSwitchId "$VSW_A" \
      --DBInstanceNetType Intranet --InstanceNetworkType VPC --ConnectionMode Standard \
      --SecurityIPList "127.0.0.1" \
      --PayType "$PAY_TYPE" --Period "$PERIOD" --UsedTime "$USED_TIME" \
      --AutoPay "$AUTO_PAY" --AutoRenew true \
      --DBInstanceDescription "$DB_NAME" \
      --ResourceGroupId "$RG" \
      --ClientToken "$tok")"

  id="$(printf '%s' "$out" | jq -r '.DBInstanceId // empty')"
  local oid; oid="$(printf '%s' "$out" | jq -r '.OrderId // empty')"
  if [ -n "$id" ]; then
    ok "已创建：${id}"
    [ -n "$oid" ] && say "OrderId=${oid}"
    printf '%s' "$id" > /tmp/.task4_rds_id
    return 0
  fi
  if [ -n "$oid" ]; then
    ok "已生成未支付订单 OrderId=${oid}（未扣费、实例尚未创建）"
    printf '%s' "$oid" > /tmp/.task4_rds_oid
    return 0
  fi
  local code; code="$(printf '%s' "$out" | jq -r '.error_code // .Code // "unknown"')"
  printf '%s\n' "$(_c '1;31' '原文：') $out" >&2
  die "创建失败：${code}（原文见 ${LOG}）"
}

# ============================== Step 4 check ==============================
do_check() {
  hr; say "STEP check｜属性核对 + 标签"
  local id="${1:-$(cat /tmp/.task4_rds_id 2>/dev/null || true)}"
  [ -n "$id" ] || id="$(api rds DescribeDBInstances --RegionId "$REGION" --PageSize 50 \
    | jq -r '.Items.DBInstance[]?|select(.DBInstanceDescription=="'"$DB_NAME"'")|.DBInstanceId' | head -1)"
  [ -n "$id" ] || {
    local oid; oid="$(cat /tmp/.task4_rds_oid 2>/dev/null || true)"
    warn "实例 $DB_NAME 尚不存在（未支付订单不会创建实例，属预期）"
    if [ -n "$oid" ]; then
      warn "存在未支付订单 OrderId=${oid}（${DB_NAME} · ${DB_CLASS} · ${DB_STORAGE}G · 1 年）"
      warn "完成路径：控制台「费用中心 → 订单管理 → 未支付订单」付款 → 实例自动创建（约 1–10 min）后重跑本 step"
    fi
    die "check 中止：无可核对实例"
  }

  api rds DescribeDBInstanceAttribute --DBInstanceId "$id" \
    | jq -r '.Items.DBInstanceAttribute[0]|"  Engine=\(.Engine) \(.EngineVersion)\n  Category=\(.Category)  PayType=\(.PayType)\n  MasterZone=\(.ZoneId)  SlaveZone=\(.SlaveZones.ZoneId[0] // "-")\n  Class=\(.DBInstanceClass)  Storage=\(.DBInstanceStorage)G \(.DBInstanceStorageType)\n  Status=\(.DBInstanceStatus)  Conn=\(.ConnectionString)  Port=\(.Port)\n  VPC=\(.VPCId) VSwitch=\(.VSwitchId)  RG=\(.ResourceGroupId)"' >&2

  # F11 复核提醒
  warn "务必在同 VPC 跳板机执行 SHOW max_connections; 回填——F11 记 800，但规格表 pg.x4.2xlarge.2c 标注 6400；两者不一致，实测为准"

  say "标签处置"
  api rds TagResources --RegionId "$REGION" --ResourceType INSTANCE --ResourceId "$id" \
    --Tag.1.Key project --Tag.1.Value new-api \
    --Tag.2.Key site --Tag.2.Value ph-mnl \
    --Tag.3.Key env --Tag.3.Value prod \
    --Tag.4.Key managed-by --Tag.4.Value cli >/dev/null
  ok "标签已打：project=new-api site=ph-mnl env=prod managed-by=cli"
}

# ============================== main ==============================
case "${1:-verify}" in
  verify)     do_verify ;;
  price)      do_price ;;
  create)     do_create false ;;
  create-pay) do_create true ;;
  check)      do_check ;;
  tag)        do_check ;;
  all)
    do_verify; do_price
    local_ap="${AUTO_PAY_MODE:-false}"
    if do_create "$local_ap"; then do_check; fi
    ;;
  *)          die "未知 step: $1（verify|price|create|create-pay|check|tag|all）" ;;
esac
