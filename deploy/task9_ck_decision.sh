#!/usr/bin/env bash
# =============================================================================
# 任务 9 · 日志库 ClickHouse 决策（马尼拉企业版单 AZ）—— 复核 / 探针 / 成本 / 创建
# -----------------------------------------------------------------------------
# 依据：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md 任务 9（F9）
# 2026-09-29 实测加固：马尼拉 CK 可用区只有 6a · 存储只有 OSS · 计费只有按量
#
# 用法：
#   ./deploy/task9_ck_decision.sh verify      # 只读复核（默认）：地域/AZ/存量/余额
#   ./deploy/task9_ck_decision.sh probe       # 零风险参数探针（服务端必失败，跑完复核未创建）
#   ./deploy/task9_ck_decision.sh cost [CCU]  # 成本换算（默认 4 CCU，另算 8 CCU）
#   ./deploy/task9_ck_decision.sh check       # 实例建成后核对（未建亦可用，回 TotalCount=0）
#   ./deploy/task9_ck_decision.sh create --yes  # ⚠ 真实创建企业版集群：创建即按 CCU 计费，无 DryRun
#   ./deploy/task9_ck_decision.sh all         # verify + probe + cost
# =============================================================================
set -uo pipefail

# ---- PATH 自愈（此前直接 ./deploy/xxx.sh 会 aliyun: command not found）----
case ":$PATH:" in
  *":$HOME/.workbuddy/binaries/aliyun-cli:"*) ;;
  *) export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH" ;;
esac

REGION="ap-southeast-6"
ZONE="ap-southeast-6a"
VPC="vpc-5tst1tgeessxn1azwasg2"
VSW="vsw-5tswufq2pi26l4ahoiu84"          # vsw-mnl-data-a 10.0.48.0/20 @6a（CK 唯一可用区）
VSW_B="vsw-5tsxa8fupaf8xeyln0o7a"       # vsw-mnl-data-b 10.0.64.0/20 @6b（探针用，CK 不可用）
RG="rg-aek4nyivmmsb6iy"                 # rg-ph-mnl
CK_NAME="ck-mnl-newapi-log"
OSSM="ck-mnl-newapi-logs"               # 桶名占位，本卡不创建
CCU_MIN=4
CCU_MAX=8
NODE_COUNT=2
PRICE_CCU_H="0.185350"                  # USD/CCU·h（马尼拉，官方 2026-09）
PRICE_OSS_GB_H="0.000044"               # USD/GB·h（马尼拉单 AZ OSS）
PRICE_PLAN_CCU_H="0.03611"              # USD/CCU·H（计算资源包全国统一价）
FACTOR_MNL="1.45"                       # 马尼拉地域抵扣因子
HOURS_MONTH=730

LOG_DIR="$(cd "$(dirname "$0")" && pwd)/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/task9_ck_$(date +%Y%m%d-%H%M%S).log"
exec 3>&2

hr()   { printf '%s\n' "------------------------------------------------------------------" >&3; }
say()  { printf '%s\n' "$*" >&3; }
ok()   { printf '  [OK] %s\n' "$*" >&3; }
warn() { printf '  [!!] %s\n' "$*" >&3; }
die()  { printf '  [XX] %s\n' "$*" >&3; exit 1; }
logline() { printf '%s\n' "$*" >>"$LOG"; }

api() { # 所有 API 调用落日志；stdout 只出 JSON
  logline "+ aliyun $*"
  aliyun "$@" 2>&1 | tee -a "$LOG"
}
api_quiet() {
  logline "+ aliyun $* (quiet)"
  aliyun "$@" 2>&1 | tee -a "$LOG" >/dev/null
}

need_cli() {
  command -v aliyun >/dev/null 2>&1 || die "aliyun CLI 不在 PATH（期望 ~/.workbuddy/binaries/aliyun-cli）"
  command -v jq     >/dev/null 2>&1 || die "jq 未安装"
}
say "日志：${LOG}"

# ============================== Step 1 verify ==============================
do_verify() {
  hr; say "STEP verify | 任务 9 · 地域与可用区硬证据（只读）"
  need_cli

  say "1) 马尼拉 CK 支持的可用区（期望：只有 ap-southeast-6a 一行）"
  api clickhouse DescribeRegions > "/tmp/ck_regions_$$.json"
  local z
  z="$(jq -r --arg r "$REGION" '.Regions.Region[]|select(.RegionId==$r)|.Zones.Zone[]|.ZoneId' "/tmp/ck_regions_$$.json")"
  printf '%s\n' "$z" | sed 's/^/     /' >&3
  local nz; nz="$(printf '%s\n' "$z" | grep -c . || true)"
  [ "$nz" = "1" ] && ok "马尼拉仅 1 个可用区 => 单 AZ 是产品事实，非我们的取舍" \
                  || warn "可用区数=${nz}，与 2026-09-29 实测（1）不同，请复核后再定口径"

  say "2) 对照：新加坡可用区（期望 3 行，证明上一步不是接口缺陷）"
  jq -r '.Regions.Region[]|select(.RegionId=="ap-southeast-1")|.Zones.Zone[]|.ZoneId' "/tmp/ck_regions_$$.json" | sed 's/^/     /' >&3

  say "3) 存量实例（本卡不创建；期望 TotalCount=0）"
  api clickhouse DescribeDBInstances --RegionId "$REGION" \
    | jq -c '.Data|{TotalCount,List:(.DBInstances//[]|map({DBInstanceId,DBInstanceDescription,Category,DBInstanceStatus,ZoneId,StorageType,EngineVersion}))}' >&3

  say "4) 账户余额（0.00 会阻塞后续购买/开通）"
  api bssopenapi QueryAccountBalance --region ap-southeast-1 | jq -c '.Data' >&3

  say "5) 目标 vSwitch（CK 只能落 6a，因此只能用 data-a）"
  api vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC" \
    | jq -r --arg v "$VSW" --arg b "$VSW_B" '.VSwitches.VSwitch[]|select(.VSwitchId==$v or .VSwitchId==$b)|[.VSwitchId,.VSwitchName,.CidrBlock,.ZoneId]|@tsv' | sed 's/^/     /' >&3

  ok "verify 完成（只读，无资源创建）"
}

# ============================== Step 2 probe ==============================
# 原理：故意踩服务端校验点，看错误落在哪一层。落在「商品校验 / 多AZ数量」= 参数层已通过。
# 红线：任何一次落到「创建成功」都是事故 => 跑完必须复核 TotalCount 仍为 0。
do_probe() {
  hr; say "STEP probe | 零风险参数探针（每个探针都必然失败于服务端）"
  need_cli

  local common=(--RegionId "$REGION" --ZoneId "$ZONE" --Category enterprise --Engine clickhouse
                --VpcId "$VPC" --VswitchId "$VSW"
                --NodeScaleMin "$CCU_MIN" --NodeScaleMax "$CCU_MAX" --NodeCount "$NODE_COUNT"
                --StorageType oss)

  say "P1 DeploySchema 非法值 => 期望 InvalidDeploySchema.Malformed"
  api clickhouse CreateDBInstance "${common[@]}" --DeploySchema bogus_value \
      --DBInstanceDescription probe-ck-deployschema-9 | head -c 400 >&3; echo >&3

  say "P2 DeploySchema=single_az（合法）+ EngineVersion=99.9（必失败）=> 期望越过参数层，报 COMMODITY.INVALID_COMPONENT"
  api clickhouse CreateDBInstance "${common[@]}" --DeploySchema single_az --EngineVersion 99.9 \
      --DBInstanceDescription probe-ck-singleaz-9 | head -c 400 >&3; echo >&3

  say "P3 多 AZ 在马尼拉不可用：multi_az + 只给 1 个 AZ => 期望 relevantInspectionException: The number of zones is not multi."
  api clickhouse CreateDBInstance "${common[@]}" --DeploySchema multi_az \
      --DBInstanceDescription probe-ck-multiaz-9 | head -c 400 >&3; echo >&3

  say "P4 非法可用区（ap-southeast-6x）=> 期望落在 VPC/vSwitch 或 AZ 校验层"
  api clickhouse CreateDBInstance --RegionId "$REGION" --Category enterprise --Engine clickhouse \
      --ZoneId ap-southeast-6x --VpcId "$VPC" --VswitchId "$VSW" \
      --NodeScaleMin "$CCU_MIN" --NodeScaleMax "$CCU_MAX" --NodeCount "$NODE_COUNT" \
      --StorageType oss --DBInstanceDescription probe-ck-az-9 | head -c 400 >&3; echo >&3

  say "P5 不存在的地域（ap-southeast-9）=> 期望 InvalidRegion.NotFound（证明列表有判别力）"
  api clickhouse CreateDBInstance --RegionId ap-southeast-9 --Category enterprise --Engine clickhouse \
      --NodeScaleMin "$CCU_MIN" --NodeScaleMax "$CCU_MAX" --NodeCount "$NODE_COUNT" \
      --StorageType oss --DBInstanceDescription probe-ck-region-9 | head -c 300 >&3; echo >&3

  say "复核：探针之后实例数必须仍为 0"
  local tc
  tc="$(api clickhouse DescribeDBInstances --RegionId "$REGION" | jq -r '.Data.TotalCount')"
  [ "$tc" = "0" ] && ok "TotalCount=0，探针零副作用" \
                  || die "TotalCount=${tc} —— 探针疑似创建了实例，立即核查控制台"
}

# ============================== Step 3 cost ==============================
do_cost() {
  hr; say "STEP cost | CK 企业版成本换算（官方单价，马尼拉）"
  local ccu="${1:-$CCU_MIN}"
  python3 - "$ccu" "$CCU_MAX" "$PRICE_CCU_H" "$PRICE_OSS_GB_H" "$PRICE_PLAN_CCU_H" "$FACTOR_MNL" "$HOURS_MONTH" >&3 <<'PY'
import sys
ccu, ccu_max, p_ccu, p_oss, p_plan, factor, hours = (
    float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]),
    float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7]))
def line(ccu_v):
    payg = ccu_v * p_ccu * hours
    plan = ccu_v * hours * factor * p_plan
    return payg, plan
print(f"  CCU 区间：{ccu:g}（最小预留）~ {ccu_max:g}（弹性上限）；1 CCU = 1 vCore + 4 GiB")
print(f"  单价：按量 {p_ccu} USD/CCU·h · 资源包 {p_plan} USD/CCU·H · 存储 OSS {p_oss} USD/GB·h")
print(f"  地域抵扣因子（马尼拉）：{factor}")
for label, v in (("最小常驻", ccu), ("弹性上限", ccu_max)):
    payg, plan = line(v)
    print(f"  [{label}] {v:g} CCU 常驻：按量 {payg:,.2f} USD/月 | 资源包等效 {plan:,.2f} USD/月"
          f"（={(plan/payg*100 if payg else 0):.1f}% 按量价，省 {(1-plan/payg)*100 if payg else 0:.1f}%）")
payg4, plan4 = line(ccu)
print(f"  存储：100 GB OSS = {100*p_oss*hours:,.2f} USD/月（相对计算费可忽略）")
print(f"  资源包最小 3000 CCU·H（预付 3 年、不可退订、可叠加）=> 以 {ccu:g} CCU 常驻计，可抵 "
      f"{3000/factor/ccu:,.0f} 小时 ≈ {3000/factor/ccu/24:,.1f} 天")
print(f"  判断规则：日志库若在 3 年内可能被裁撤/迁移，不买包；否则买包可把计算费压到按量的约 28%")
PY
  ok "cost 完成（单价来源：官方企业版按量计费页 + 计算资源包页，2026-09-29 取）"
}

# ============================== Step 4 create ==============================
do_create() {
  local yes="${1:-}"
  hr; say "STEP create | ⚠ 真实创建马尼拉 CK 企业版（创建即按 CCU 计费）"
  need_cli

  if [ "$yes" != "--yes" ]; then
    warn "未加 --yes，拒绝创建。该 API 无 DryRun、无 AutoPay=false，创建即计费且不可零成本回滚。"
    say  "    如要执行：./deploy/task9_ck_decision.sh create --yes"
    return 0
  fi

  local tc
  tc="$(api clickhouse DescribeDBInstances --RegionId "$REGION" | jq -r '.Data.TotalCount')"
  if [ "$tc" != "0" ]; then
    warn "已存在 ${tc} 个实例，跳过创建（幂等）"
    return 0
  fi

  say "参数：Category=enterprise · DeploySchema=single_az · Zone=${ZONE} · Storage=oss"
  say "      VPC=${VPC} · vSwitch=${VSW} · CCU ${CCU_MIN}-${CCU_MAX} · NodeCount=${NODE_COUNT}"
  local tok="task9-ck-${CK_NAME}-v1"
  api clickhouse CreateDBInstance \
      --RegionId "$REGION" --ZoneId "$ZONE" \
      --Category enterprise --Engine clickhouse --DeploySchema single_az \
      --VpcId "$VPC" --VswitchId "$VSW" \
      --NodeScaleMin "$CCU_MIN" --NodeScaleMax "$CCU_MAX" --NodeCount "$NODE_COUNT" \
      --StorageType oss --DBTimeZone Asia/Shanghai \
      --ResourceGroupId "$RG" --DBInstanceDescription "$CK_NAME" \
      --ClientToken "$tok" | head -c 600 >&3; echo >&3

  say "创建需 1~10 分钟；随后用 check 步骤验收"
}

# ============================== Step 5 check ==============================
do_check() {
  hr; say "STEP check | 实例态核对（未建时 TotalCount=0 属正常）"
  need_cli
  api clickhouse DescribeDBInstances --RegionId "$REGION" \
    | jq -c '.Data|{TotalCount,List:(.DBInstances//[]|map({DBInstanceId,DBInstanceDescription,DBInstanceStatus,ZoneId,StorageType,EngineVersion,ConnectionString}))}' >&3
  say "验收清单（实例就绪后逐项做）："
  say "  [ ] 白名单加入 10.0.16.0/20 + 10.0.32.0/20 + 新加坡出口 4 个 EIP"
  say "  [ ] curl http://<host>:8123/?query=SELECT+version()  取实际内核版本（企业版版本不可手选）"
  say "  [ ] 建 newapi_logs（普通 MergeTree + TTL 90 天，不带 ON CLUSTER）"
  say "  [ ] 降级验证：DSN 填错 → 应用仍正常返回（方案 R21，切流硬前置）"
  say "  [ ] 复查有无 CLB/ARMS 依赖服务被自动创建并计费（企业版未实测，写进任务 52）"
  ok "check 完成"
}

case "${1:-verify}" in
  verify) do_verify ;;
  probe)  do_probe ;;
  cost)   do_cost "${2:-}" ;;
  create) do_create "${2:-}" ;;
  check)  do_check ;;
  all)    do_verify; do_probe; do_cost ;;
  *)      die "未知 step：$1（verify|probe|cost|create --yes|check|all）" ;;
esac
