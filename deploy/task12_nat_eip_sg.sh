#!/usr/bin/env bash
# =============================================================================
# Day 1 · 任务 12｜新加坡 VPC + vSwitch + NAT 网关 + 上游出口 EIP 池 4 个
# 参考：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md (L408-503)
# 同构参照：deploy/task6_nat_eip.sh（马尼拉，已实测通过）
#
# 幂等：可重复执行；已存在的资源自动复用，不重复创建。
# 用法：
#   bash deploy/task12_nat_eip_sg.sh
#   DRY_RUN=1 bash deploy/task12_nat_eip_sg.sh      # 只打印动作，不调用写 API
#
# 前置（已实测核实，2026-09-28）：
#   VPC vpc-t4nimmwvruexbnene0a3r = vpc-newapi-sg-prod / 10.1.0.0/16 / RG=rg-sg
#   ⚠️ 该 ID 曾被误判为「深圳残留」（t4n 前缀），实测确认它就是新加坡 VPC。
#      阿里云资源 ID 前缀（t4n/5ts）是 ID 池分配、**不代表地域**。
#   4 个 vSwitch 齐全（pub-a/b /24、app-a/b /20），系统路由表 vtb-t4n7be2ip07nuflfyppux 全挂。
#
# 沿用任务 6 校正（任务 12 卡片已同步修正）：
#   ① CreateNatGateway 必须带 --NatType（必填，唯一合法值 Enhanced）
#   ② AssociateEipAddress 的 InstanceType 必须是 Nat（不是 NatGateway）
#   ③ 0.0.0.0/0 → NAT 路由由系统自动创建，脚本仅校验
#   ④ 补 --ResourceGroupId rg-aek4zvb3ldoiyua（项目约定：默认组禁放 new-api 资源）
#
# 实现注意：日志走 fd 3，API 原始输出一律落文件（避免「+ 命令」污染 JSON）。
# =============================================================================
set -uo pipefail
exec 3>&2                     # fd3 = 真实 stderr，专用于日志

REGION=ap-southeast-1
VPC=vpc-t4nimmwvruexbnene0a3r
RG=rg-aek4zvb3ldoiyua                      # rg-sg
NAT_NAME=nat-sg-prod
RTB=vtb-t4n7be2ip07nuflfyppux              # 系统路由表（4 vSwitch 全挂）
PUB_A=vsw-t4ncxa4gqgamhl0o8e6yq            # 1a 10.1.0.0/24
PUB_B=vsw-t4nhtsfk2z79e1ggvlhdz            # 1b 10.1.1.0/24
APP_A=vsw-t4nbvsnvo4z52sumr9sck            # 1a 10.1.16.0/20
APP_B=vsw-t4n3dthz1ma6tp7bqor6h            # 1b 10.1.32.0/20
EIP_NAMES=(eip-sg-upstream-01 eip-sg-upstream-02 eip-sg-upstream-03 eip-sg-upstream-04)
EIP_BW=100
DRY_RUN="${DRY_RUN:-0}"

TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$(dirname "$0")/logs/task12_${TS}"
mkdir -p "$OUTDIR"
LEDGER="$(dirname "$0")/eip_ledger.md"

say() { printf '%s\n' "$*" >&3; }
hr()  { say "------------------------------------------------------------"; }
step(){ say ""; say ">>> $*"; hr; }

# api <outfile> <cmd...>   —— 日志到 fd3，API 输出落 outfile；失败自动重试 3 次
api() {
  local out="$1"; shift
  printf '+ %s\n' "$*" >&3
  if [[ "$DRY_RUN" == "1" ]]; then printf '{"_dry_run":true}\n' > "$out"; return 0; fi
  local i
  for i in 1 2 3; do
    if "$@" > "$out" 2>&1 && jq -e . "$out" >/dev/null 2>&1; then return 0; fi
    say "  !! 第 ${i} 次调用失败，2s 后重试：$(head -c 160 "$out" | tr '\n' ' ')"
    sleep 2
  done
  say "  !! 已重试 3 次仍失败：$*"
  return 1
}

# apiget <cmd...>  —— 只回传 stdout（带重试），用于命令替换
apiget() {
  local out="" i
  for i in 1 2 3; do
    out=$("$@" 2>&1) && printf '%s' "$out" && return 0
    sleep 2
  done
  printf '%s' "$out"; return 1
}

# ---------------------------------------------------------------------------
step "0. 前置：身份确认"
api "$OUTDIR/00-identity.json" aliyun sts get-caller-identity
jq -r '"AccountId=\(.AccountId)  Arn=\(.Arn)"' "$OUTDIR/00-identity.json" 2>/dev/null \
  || { say "!! 身份调用失败，终止"; cat "$OUTDIR/00-identity.json" >&3; exit 1; }

# ---- 0b. 复核 VPC 与 4 个 vSwitch（本卡以复核为主） ------------------------
step "0b. 复核 VPC ${VPC}（期望 10.1.0.0/16 / Available）"
api "$OUTDIR/00b-vpc.json" aliyun vpc DescribeVpcs --RegionId "$REGION" --VpcId "$VPC"
jq -r '.Vpcs.Vpc[0]|"VPC \(.VpcId)  name=\(.VpcName)  cidr=\(.CidrBlock)  status=\(.Status)  rg=\(.ResourceGroupId // "-")"' "$OUTDIR/00b-vpc.json" 2>/dev/null \
  || { say "!! VPC 查询失败，终止"; cat "$OUTDIR/00b-vpc.json" >&3; exit 1; }
VPC_CIDR=$(jq -r '.Vpcs.Vpc[0].CidrBlock // empty' "$OUTDIR/00b-vpc.json" 2>/dev/null | tr -d '\r')
[[ "$VPC_CIDR" == "10.1.0.0/16" ]] || say "!! VPC 网段为 ${VPC_CIDR}，与基线 10.1.0.0/16 不符，请复核"

api "$OUTDIR/00b-vsw.json" aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC" --PageSize 50
jq -r '.VSwitches.VSwitch[]?|"VSW \(.VSwitchId)  \(.VSwitchName)  \(.ZoneId)  \(.CidrBlock)  free=\(.AvailableIpAddressCount)  \(.Status)"' \
  "$OUTDIR/00b-vsw.json" 2>/dev/null
n_vsw=$(jq -r '[.VSwitches.VSwitch[]?]|length' "$OUTDIR/00b-vsw.json" 2>/dev/null | tr -d '\r')
say "vSwitch 数=$n_vsw（期望 4）"
[[ "${n_vsw:-0}" == "4" ]] || say "!! vSwitch 数不是 4，请先补齐（CreateVSwitch 参数同任务 5）"

# ---- 1. NAT 网关 -----------------------------------------------------------
step "1. 公网 NAT 网关 ${NAT_NAME}（Enhanced / internet / PostPaid）"
api "$OUTDIR/01-nat-before.json" aliyun vpc DescribeNatGateways --RegionId "$REGION" --VpcId "$VPC" --PageSize 50
jq -e . "$OUTDIR/01-nat-before.json" >/dev/null 2>&1 \
  || { say "!! DescribeNatGateways 未返回合法 JSON，拒绝继续（防止重复建 NAT）"; cat "$OUTDIR/01-nat-before.json" >&3; exit 1; }
NAT_ID=$(jq -r --arg n "$NAT_NAME" '[.NatGateways.NatGateway[]?|select(.Name==$n)|.NatGatewayId]|first // empty' \
         "$OUTDIR/01-nat-before.json" 2>/dev/null | tr -d '\r')

if [[ -n "$NAT_ID" ]]; then
  say "已存在 NAT 网关，复用：$NAT_ID"
else
  say "未发现 NAT 网关，开始创建…"
  api "$OUTDIR/01-nat-create.json" aliyun vpc CreateNatGateway --RegionId "$REGION" \
    --VpcId "$VPC" --VSwitchId "$PUB_A" \
    --NatType Enhanced --NetworkType internet --InstanceChargeType PostPaid \
    --Name "$NAT_NAME" \
    --Tag.1.Key Project  --Tag.1.Value new-api \
    --Tag.2.Key Env      --Tag.2.Value prod \
    --Tag.3.Key Owner    --Tag.3.Value backend \
    --Tag.4.Key ManagedBy --Tag.4.Value manual
  cat "$OUTDIR/01-nat-create.json" >&3
  NAT_ID=$(jq -r '.NatGatewayId // empty' "$OUTDIR/01-nat-create.json" 2>/dev/null | tr -d '\r')
fi
[[ -n "$NAT_ID" ]] || { say "!! NAT 网关 ID 获取失败，终止"; exit 1; }
say "NAT_SG=$NAT_ID"
if [[ "$DRY_RUN" == "1" ]]; then say "(DRY_RUN 结束 — 后续为写操作，已跳过)"; exit 0; fi

# ---- 1b. 等待 Available ----------------------------------------------------
step "1b. 等待 NAT 网关 Available（最长 5 分钟）"
ST=Unknown
for i in $(seq 1 30); do
  ST=$(apiget aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" \
       | jq -r '.NatGateways.NatGateway[0].Status // "Unknown"' | tr -d '\r')
  say "  [$i] Status=$ST"
  [[ "$ST" == "Available" ]] && break
  sleep 10
done
[[ "$ST" == "Available" ]] || say "!! 仍非 Available（Status=$ST），后续步骤可能失败"

# ---- 2. EIP ×4 -------------------------------------------------------------
step "2. 分配 4 个 EIP（PayByTraffic / 峰值 100Mbps / RG=${RG}）"
api "$OUTDIR/02-eip-before.json" aliyun vpc DescribeEipAddresses --RegionId "$REGION" --PageSize 100
jq -e . "$OUTDIR/02-eip-before.json" >/dev/null 2>&1 \
  || { say "!! DescribeEipAddresses 未返回合法 JSON，拒绝继续（防止重复分配 EIP）"; cat "$OUTDIR/02-eip-before.json" >&3; exit 1; }

ALLOC_IDS=(); EIP_IPS=()
for n in "${EIP_NAMES[@]}"; do
  rec=$(jq -c --arg n "$n" '[.EipAddresses.EipAddress[]?|select(.Name==$n)]|first // empty' \
        "$OUTDIR/02-eip-before.json" 2>/dev/null | tr -d '\r')
  if [[ -n "$rec" ]]; then
    aid=$(printf '%s' "$rec" | jq -r '.AllocationId' | tr -d '\r')
    ip=$(printf '%s'  "$rec" | jq -r '.IpAddress'    | tr -d '\r')
    say "  ${n}: 已存在 ${aid} ${ip}"
  else
    api "$OUTDIR/02-eip-${n}.json" aliyun vpc AllocateEipAddress --RegionId "$REGION" \
      --Name "$n" --Bandwidth "$EIP_BW" --InternetChargeType PayByTraffic \
      --InstanceChargeType PostPaid --ResourceGroupId "$RG" \
      --Tag.1.Key Project  --Tag.1.Value new-api \
      --Tag.2.Key Env      --Tag.2.Value prod \
      --Tag.3.Key Owner    --Tag.3.Value backend \
      --Tag.4.Key ManagedBy --Tag.4.Value manual
    cat "$OUTDIR/02-eip-${n}.json" >&3
    aid=$(jq -r '.AllocationId // empty' "$OUTDIR/02-eip-${n}.json" 2>/dev/null | tr -d '\r')
    ip=$(jq -r  '.EipAddress   // empty' "$OUTDIR/02-eip-${n}.json" 2>/dev/null | tr -d '\r')
    [[ -n "$aid" ]] || { say "  !! ${n} 分配失败，跳过"; continue; }
    say "  ${n}: 新建 ${aid} ${ip}"
  fi
  ALLOC_IDS+=("$aid"); EIP_IPS+=("$ip")
done
say "EIP_ALLOC_IDS=${ALLOC_IDS[*]:-<空>}"
say "EIP_IPS=${EIP_IPS[*]:-<空>}"
[[ ${#ALLOC_IDS[@]} -eq 4 ]] || { say "!! EIP 数量不是 4（实际 ${#ALLOC_IDS[@]}），终止"; exit 1; }
EIP_POOL_CSV=$(IFS=,; printf '%s' "${EIP_IPS[*]}")

# ---- 3. 绑定 NAT -----------------------------------------------------------
step "3. 绑定 4 个 EIP 到 NAT 网关（InstanceType=Nat）"
for aid in "${ALLOC_IDS[@]}"; do
  cur=$(apiget aliyun vpc DescribeEipAddresses --RegionId "$REGION" --AllocationId "$aid" \
        | jq -r '.EipAddresses.EipAddress[0]|"\(.Status)|\(.InstanceType // "-")|\(.InstanceId // "-")"' | tr -d '\r')
  if [[ "$cur" == InUse*"${NAT_ID}"* ]]; then
    say "  ${aid}: 已绑定且指向本 NAT，跳过（$cur）"
    continue
  fi
  api "$OUTDIR/03-assoc-${aid}.json" aliyun vpc AssociateEipAddress --RegionId "$REGION" \
    --AllocationId "$aid" --InstanceType Nat --InstanceId "$NAT_ID"
  cat "$OUTDIR/03-assoc-${aid}.json" >&3
done

# ---- 4. SNAT 条目（pub + app 共 4 个交换机，条目内 4 EIP 成池） ------------
step "4. SNAT 条目：pub-a / pub-b / app-a / app-b，条目内 4 EIP 成池"
SNAT_TABLE=$(apiget aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" \
  | jq -r '.NatGateways.NatGateway[0].SnatTableIds.SnatTableId[0] // empty' | tr -d '\r')
[[ -n "$SNAT_TABLE" && "$SNAT_TABLE" != "null" ]] \
  || { say "!! SNAT 表 ID 为空（查询失败），终止以免建出无主条目"; exit 1; }
say "SNAT_TABLE=$SNAT_TABLE"
api "$OUTDIR/04-snat-before.json" aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50

for vsw in "$PUB_A" "$PUB_B" "$APP_A" "$APP_B"; do
  has=$(jq -r --arg v "$vsw" '[.SnatTableEntries.SnatTableEntry[]?|select(.SourceVSwitchId==$v)]|length' \
        "$OUTDIR/04-snat-before.json" 2>/dev/null | tr -d '\r')
  if [[ "${has:-0}" != "0" ]]; then say "  ${vsw}: 已有 SNAT 条目，跳过"; continue; fi
  api "$OUTDIR/04-snat-${vsw}.json" aliyun vpc CreateSnatEntry --RegionId "$REGION" \
    --SnatTableId "$SNAT_TABLE" --SourceVSwitchId "$vsw" \
    --SnatIp "$EIP_POOL_CSV" --SnatEntryName "snat-sg-${vsw}"
  cat "$OUTDIR/04-snat-${vsw}.json" >&3
done

# 复核：SNAT 条目数必须 = 4（4 个交换机）
api "$OUTDIR/04-snat-after.json" aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50
n_snat=$(jq -r '[.SnatTableEntries.SnatTableEntry[]?]|length' "$OUTDIR/04-snat-after.json" 2>/dev/null | tr -d '\r')
say "SNAT 条目数=$n_snat（期望 4）"
[[ "${n_snat:-0}" == "4" ]] || say "!! SNAT 条目数不符，需人工复核"

# ---- 5. 路由表 0.0.0.0/0 → NAT（系统自动创建；此处仅校验） -----------------
step "5. 校验路由表 ${RTB} 的 0.0.0.0/0 → NAT（应为系统自动创建）"
api "$OUTDIR/05-route-before.json" aliyun vpc DescribeRouteEntryList --RegionId "$REGION" --RouteTableId "$RTB" --MaxResult 50
hasrt=$(jq -r '[.RouteEntrys.RouteEntry[]?|select(.DestinationCidrBlock=="0.0.0.0/0")]|length' \
        "$OUTDIR/05-route-before.json" 2>/dev/null | tr -d '\r')
if [[ "${hasrt:-0}" != "0" ]]; then
  say "  已存在 0.0.0.0/0 条目，跳过（先删旧条目再加，勿直接改）"
else
  api "$OUTDIR/05-route-create.json" aliyun vpc CreateRouteEntry --RegionId "$REGION" --RouteTableId "$RTB" \
    --DestinationCidrBlock 0.0.0.0/0 --NextHopType NatGateway --NextHopId "$NAT_ID" \
    --RouteEntryName rt-sg-default-nat
  cat "$OUTDIR/05-route-create.json" >&3
fi

# ---- 6. 验证 ---------------------------------------------------------------
step "6. 验证"
api "$OUTDIR/06-nat.json" aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID"
jq -r '.NatGateways.NatGateway[0]|"NAT \(.NatGatewayId)  name=\(.Name)  status=\(.Status)  natType=\(.NatType)  chargeType=\(.InstanceChargeType)\n    snatTable=\(.SnatTableIds.SnatTableId|join(","))  boundEip=\(.IpLists.IpList|length)  rg=\(.ResourceGroupId // "-")"' "$OUTDIR/06-nat.json" 2>/dev/null \
  || cat "$OUTDIR/06-nat.json" >&3

api "$OUTDIR/06-eip.json" aliyun vpc DescribeEipAddresses --RegionId "$REGION" --PageSize 100
jq -r '.EipAddresses.EipAddress[]?|select(.Name|test("eip-sg-upstream"))|"EIP \(.AllocationId)  \(.IpAddress)  \(.Name)  \(.Status)  bound=\(.InstanceType // "-"):\(.InstanceId // "-")  bw=\(.Bandwidth)  rg=\(.ResourceGroupId // "-")"' "$OUTDIR/06-eip.json" 2>/dev/null

api "$OUTDIR/06-snat.json" aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50
jq -r '.SnatTableEntries.SnatTableEntry[]?|"SNAT \(.SnatEntryId)  vsw=\(.SourceVSwitchId)  ips=\(.SnatIp)  \(.Status)"' "$OUTDIR/06-snat.json" 2>/dev/null

api "$OUTDIR/06-route.json" aliyun vpc DescribeRouteEntryList --RegionId "$REGION" --RouteTableId "$RTB" --MaxResult 50
# 注意：NextHopType/NextHopId 位于 .NextHops.NextHop[0]，非顶层（顶层取会得到 null）
jq -r '.RouteEntrys.RouteEntry[]?|"ROUTE \(.DestinationCidrBlock) → \(.NextHops.NextHop[0].NextHopType // "local"):\(.NextHops.NextHop[0].NextHopId // "-")  \(.Status)  \(.Description // "")"' "$OUTDIR/06-route.json" 2>/dev/null

# ---- 7. 更新 EIP 台账（8 EIP 一张表，坑 1） --------------------------------
step "7. 更新 EIP 台账 ${LEDGER}（仅替换 sg 4 行，保留 mnl 行）"
SG_ROWS="$OUTDIR/sg_rows.txt"
: > "$SG_ROWS"
for idx in "${!ALLOC_IDS[@]}"; do
  printf '| %d | %s | %s | %s | ap-southeast-1 | %s | InUse | ☐ | ☐ | — |\n' \
    "$((idx+5))" "${EIP_NAMES[$idx]}" "${ALLOC_IDS[$idx]}" "${EIP_IPS[$idx]}" "$NAT_NAME" >> "$SG_ROWS"
done

if [[ ! -f "$LEDGER" ]]; then
  say "!! 台账不存在：$LEDGER（跳过更新，sg 行已存 $SG_ROWS）"
elif ! grep -q '^| 5 | eip-sg-upstream-01' "$LEDGER"; then
  say "!! 台账中未找到 sg 行锚点（跳过更新，sg 行已存 $SG_ROWS）"
else
  awk -v rowsfile="$SG_ROWS" '
    BEGIN { while ((getline line < rowsfile) > 0) rows = rows line "\n" }
    /^\| 5 \| eip-sg-upstream-01/ { printf "%s", rows; skip=1; next }
    skip && /^\| 8 \| eip-sg-upstream-04/ { skip=0; next }
    skip { next }
    { print }
  ' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  # 更新时间戳行来源标注
  sed -i 's|· 来源：`deploy/task6_nat_eip.sh`|· 来源：`deploy/task6_nat_eip.sh` + `deploy/task12_nat_eip_sg.sh`|' "$LEDGER"
  say "已更新：$LEDGER"
  grep -n 'eip-sg-upstream' "$LEDGER" >&3
fi

step "完成"
say "证据目录：$OUTDIR"
say "NAT_SG=$NAT_ID"
say "EIP_POOL=$EIP_POOL_CSV"
say "SNAT_TABLE=$SNAT_TABLE"
