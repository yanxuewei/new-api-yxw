#!/usr/bin/env bash
# =============================================================================
# Day 1 · 任务 6｜马尼拉 NAT 网关 + 上游出口 EIP 池 4 个
# 参考：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md (L499-571)
#
# 幂等：可重复执行；已存在的资源自动复用，不重复创建。
# 用法：
#   bash deploy/task6_nat_eip.sh            # 执行
#   DRY_RUN=1 bash deploy/task6_nat_eip.sh  # 只打印将要执行的动作
#
# 相对文档原文的三处必要修正（均已实测确认）：
#   1) CreateNatGateway 缺 --NatType（该参数「必填」，唯一合法值 Enhanced）
#   2) 需补路由表条目 0.0.0.0/0 → NAT（文档通篇无此步骤；缺它 app 段不走 NAT）
#   3) 补 --ResourceGroupId rg-aek4nyivmmsb6iy（项目约定：默认组禁放 new-api 资源）
# =============================================================================
set -uo pipefail

REGION=ap-southeast-6
VPC=vpc-5tst1tgeessxn1azwasg2
RG=rg-aek4nyivmmsb6iy                      # rg-ph-mnl
NAT_NAME=nat-mnl-prod
RTB=vtb-5tssitwhswg00n3i8kih0              # 系统路由表（6 vSwitch 全挂它）
PUB_A=vsw-5ts9tgdq1xz3picjgoqyu            # 6a 10.0.0.0/24
PUB_B=vsw-5ts1dygyh2x0daspwny2r            # 6b 10.0.1.0/24
APP_A=vsw-5tswpyzfa8od6je95td1h            # 6a 10.0.16.0/20
APP_B=vsw-5tshuvvtrqm97tnwe1ddm            # 6b 10.0.32.0/20
EIP_NAMES=(eip-mnl-upstream-01 eip-mnl-upstream-02 eip-mnl-upstream-03 eip-mnl-upstream-04)
EIP_BW=100
DRY_RUN="${DRY_RUN:-0}"

TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$(dirname "$0")/logs/task6_${TS}"
mkdir -p "$OUTDIR"
LEDGER="$(dirname "$0")/eip_ledger.md"

say()  { printf '%s\n' "$*" >&2; }
hr()   { say "------------------------------------------------------------"; }
step() { say ""; say ">>> $*"; hr; }
run() {
  if [[ "$DRY_RUN" == "1" ]]; then say "[DRY] $*"; return 0; fi
  say "+ $*"
  "$@"
}

# ---------------------------------------------------------------------------
step "0. 前置：身份 / 地域 / 现有资源"
run aliyun sts get-caller-identity > "$OUTDIR/00-identity.json" 2>&1
jq -r '"AccountId=\(.AccountId)  Arn=\(.Arn)"' "$OUTDIR/00-identity.json" 2>/dev/null || cat "$OUTDIR/00-identity.json"

# ---- 1. NAT 网关 -----------------------------------------------------------
step "1. 公网 NAT 网关 ${NAT_NAME}（Enhanced / internet / PostPaid）"
run aliyun vpc DescribeNatGateways --RegionId "$REGION" --PageSize 50 > "$OUTDIR/01-nat-before.json" 2>&1
NAT_ID=$(jq -r --arg n "$NAT_NAME" '[.NatGateways.NatGateway[]?|select(.Name==$n)|.NatGatewayId]|first // empty' "$OUTDIR/01-nat-before.json")
NAT_ID="${NAT_ID%$'\r'}"

if [[ -n "$NAT_ID" && "$NAT_ID" != "null" ]]; then
  say "已存在 NAT 网关，复用：$NAT_ID"
else
  say "未发现 NAT 网关，开始创建…"
  run aliyun vpc CreateNatGateway --RegionId "$REGION" \
    --VpcId "$VPC" --VSwitchId "$PUB_A" \
    --NatType Enhanced --NetworkType internet --InstanceChargeType PostPaid \
    --Name "$NAT_NAME" \
    --Tag.1.Key Project --Tag.1.Value new-api \
    --Tag.2.Key Env     --Tag.2.Value prod \
    --Tag.3.Key Owner   --Tag.3.Value backend \
    --Tag.4.Key ManagedBy --Tag.4.Value manual \
    > "$OUTDIR/01-nat-create.json" 2>&1
  cat "$OUTDIR/01-nat-create.json" >&2
  NAT_ID=$(jq -r '.NatGatewayId // empty' "$OUTDIR/01-nat-create.json" | tr -d '\r')
fi

if [[ -z "$NAT_ID" || "$NAT_ID" == "null" ]]; then
  say "!! NAT 网关 ID 获取失败，终止。"; exit 1
fi
say "NAT_MNL=$NAT_ID"
[[ "$DRY_RUN" == "1" ]] && { say "(DRY_RUN 结束)"; exit 0; }

# ---- 等待 Available ---------------------------------------------------------
step "1b. 等待 NAT 网关 Available（最长 5 分钟）"
for i in $(seq 1 30); do
  ST=$(aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" 2>/dev/null \
       | jq -r '.NatGateways.NatGateway[0].Status // "Unknown"' | tr -d '\r')
  say "  [$i] Status=$ST"
  [[ "$ST" == "Available" ]] && break
  sleep 10
done
[[ "$ST" == "Available" ]] || say "!! 仍非 Available（Status=$ST），后续步骤可能失败"

# ---- 2. EIP ×4 -------------------------------------------------------------
step "2. 分配 4 个 EIP（PayByTraffic / 峰值 100Mbps）"
run aliyun vpc DescribeEipAddresses --RegionId "$REGION" --PageSize 100 > "$OUTDIR/02-eip-before.json" 2>&1

ALLOC_IDS=(); EIP_IPS=()
for n in "${EIP_NAMES[@]}"; do
  existing=$(jq -r --arg n "$n" '[.EipAddresses.EipAddress[]?|select(.Name==$n)]|first // empty' "$OUTDIR/02-eip-before.json" | tr -d '\r')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    aid=$(printf '%s' "$existing" | jq -r '.AllocationId' | tr -d '\r')
    ip=$(printf '%s' "$existing" | jq -r '.IpAddress' | tr -d '\r')
    say "  ${n}: 已存在 ${aid} ${ip}"
  else
    out=$(run aliyun vpc AllocateEipAddress --RegionId "$REGION" \
      --Name "$n" --Bandwidth "$EIP_BW" --InternetChargeType PayByTraffic \
      --InstanceChargeType PostPaid --ResourceGroupId "$RG" \
      --Tag.1.Key Project --Tag.1.Value new-api \
      --Tag.2.Key Env     --Tag.2.Value prod \
      --Tag.3.Key Owner   --Tag.3.Value backend \
      --Tag.4.Key ManagedBy --Tag.4.Value manual 2>&1)
    printf '%s\n' "$out" >&2
    aid=$(printf '%s' "$out" | jq -r '.AllocationId // empty' | tr -d '\r')
    ip=$(printf '%s' "$out" | jq -r '.EipAddress // empty' | tr -d '\r')
    [[ -z "$aid" ]] && { say "  !! ${n} 分配失败"; continue; }
    say "  ${n}: 新建 ${aid} ${ip}"
  fi
  ALLOC_IDS+=("$aid"); EIP_IPS+=("$ip")
done
say "EIP_ALLOC_IDS=${ALLOC_IDS[*]}"
say "EIP_IPS=${EIP_IPS[*]}"
[[ ${#ALLOC_IDS[@]} -eq 4 ]] || { say "!! EIP 数量不是 4（实际 ${#ALLOC_IDS[@]}），终止。"; exit 1; }
EIP_POOL_CSV=$(IFS=,; printf '%s' "${EIP_IPS[*]}")

# ---- 3. 绑定 NAT -----------------------------------------------------------
step "3. 绑定 4 个 EIP 到 NAT 网关"
for aid in "${ALLOC_IDS[@]}"; do
  cur=$(aliyun vpc DescribeEipAddresses --RegionId "$REGION" --AllocationId "$aid" 2>/dev/null \
        | jq -r '.EipAddresses.EipAddress[0]|"\(.Status)\t\(.InstanceType // "-")\t\(.InstanceId // "-")"' | tr -d '\r')
  if [[ "$cur" == InUse*"NatGateway"*"$NAT_ID" ]]; then
    say "  ${aid}: 已绑定，跳过（$cur）"
    continue
  fi
  run aliyun vpc AssociateEipAddress --RegionId "$REGION" \
    --AllocationId "$aid" --InstanceType NatGateway --InstanceId "$NAT_ID" 2>&1 | tail -3 >&2
done

# ---- 4. SNAT 条目（覆盖 pub + app 共 4 个交换机） ---------------------------
step "4. SNAT 条目：pub-a / pub-b / app-a / app-b，条目内 4 EIP 成池"
SNAT_TABLE=$(aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" 2>/dev/null \
  | jq -r '.NatGateways.NatGateway[0].SnatTableIds.SnatTableId[0]' | tr -d '\r')
say "SNAT_TABLE=$SNAT_TABLE"
aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50 \
  > "$OUTDIR/04-snat-before.json" 2>&1

for vsw in "$PUB_A" "$PUB_B" "$APP_A" "$APP_B"; do
  nm="snat-mnl-${vsw}"
  has=$(jq -r --arg v "$vsw" '[.SnatTableEntries.SnatTableEntry[]?|select(.SourceVSwitchId==$v)]|length' "$OUTDIR/04-snat-before.json" 2>/dev/null | tr -d '\r')
  if [[ "${has:-0}" != "0" ]]; then say "  ${vsw}: 已有 SNAT 条目，跳过"; continue; fi
  run aliyun vpc CreateSnatEntry --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" \
    --SourceVSwitchId "$vsw" --SnatIp "$EIP_POOL_CSV" --SnatEntryName "$nm" 2>&1 | tail -3 >&2
done

# ---- 5. 路由表 0.0.0.0/0 → NAT（文档漏项，必须补） ------------------------
step "5. 路由表 ${RTB} 增加 0.0.0.0/0 → ${NAT_ID}"
aliyun vpc DescribeRouteEntryList --RegionId "$REGION" --RouteTableId "$RTB" --MaxResult 50 \
  > "$OUTDIR/05-route-before.json" 2>&1
hasrt=$(jq -r '[.RouteEntrys.RouteEntry[]?|select(.DestinationCidrBlock=="0.0.0.0/0")]|length' "$OUTDIR/05-route-before.json" 2>/dev/null | tr -d '\r')
if [[ "${hasrt:-0}" != "0" ]]; then
  say "  已存在 0.0.0.0/0 条目，跳过"
else
  run aliyun vpc CreateRouteEntry --RegionId "$REGION" --RouteTableId "$RTB" \
    --DestinationCidrBlock 0.0.0.0/0 --NextHopType NatGateway --NextHopId "$NAT_ID" \
    --RouteEntryName rt-mnl-default-nat 2>&1 | tail -3 >&2
fi

# ---- 6. 验证 ---------------------------------------------------------------
step "6. 验证"
aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" > "$OUTDIR/06-nat.json" 2>&1
jq -r '.NatGateways.NatGateway[0]|"NAT \(.NatGatewayId) name=\(.Name) status=\(.Status) nattype=\(.NatType) spec=\(.Spec)\n    snatTable=\(.SnatTableIds.SnatTableId[0])  eipCount=\(.IpLists.IpList|length)"' "$OUTDIR/06-nat.json"

aliyun vpc DescribeEipAddresses --RegionId "$REGION" --PageSize 100 > "$OUTDIR/06-eip.json" 2>&1
jq -r '.EipAddresses.EipAddress[]?|select(.Name|test("eip-mnl-upstream"))|"EIP \(.AllocationId)  \(.IpAddress)  \(.Name)  status=\(.Status)  bound=\(.InstanceType//"-"):\(.InstanceId//"-")  bw=\(.Bandwidth)"' "$OUTDIR/06-eip.json"

aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50 > "$OUTDIR/06-snat.json" 2>&1
jq -r '.SnatTableEntries.SnatTableEntry[]?|"SNAT \(.SnatEntryId)  vsw=\(.SourceVSwitchId)  ips=\(.SnatIp)  status=\(.Status)"' "$OUTDIR/06-snat.json"

aliyun vpc DescribeRouteEntryList --RegionId "$REGION" --RouteTableId "$RTB" --MaxResult 50 > "$OUTDIR/06-route.json" 2>&1
jq -r '.RouteEntrys.RouteEntry[]?|select(.DestinationCidrBlock=="0.0.0.0/0")|"ROUTE \(.DestinationCidrBlock) → \(.NextHopType):\(.NextHopId)  status=\(.Status)"' "$OUTDIR/06-route.json"

# ---- 7. EIP 台账（8 EIP 一张表，坑 1） -------------------------------------
step "7. 写 EIP 台账 ${LEDGER}"
{
  echo "# 上游出口 EIP 台账（任务 6 / 任务 12 合并）"
  echo
  echo "> 生成时间：${TS} · 账号 \`5108890064395960\` · 来源：\`deploy/task6_nat_eip.sh\`"
  echo "> 坑 1：任一 EIP 新增/替换未同步供应商 → 偶发 403，失败率 ≈ 1/N。**上线前 8 个 EIP 必须全部取得供应商书面生效确认**。"
  echo
  echo "| # | EIP 名称 | AllocationId | 公网 IP | Region | 绑定对象 | 绑定状态 | 已进 RDS 白名单? | 已交供应商? | 生效确认时间 |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  i=0
  for idx in "${!ALLOC_IDS[@]}"; do
    i=$((i+1))
    printf '| %d | %s | %s | %s | ap-southeast-6 | %s | InUse | ☐ | ☐ | — |\n' \
      "$i" "${EIP_NAMES[$idx]}" "${ALLOC_IDS[$idx]}" "${EIP_IPS[$idx]}" "$NAT_NAME"
  done
  echo "| 5 | eip-sg-upstream-01 | （任务 12 填写） | — | ap-southeast-1 | nat-sg-prod | — | ☐ | ☐ | — |"
  echo "| 6 | eip-sg-upstream-02 | （任务 12 填写） | — | ap-southeast-1 | nat-sg-prod | — | ☐ | ☐ | — |"
  echo "| 7 | eip-sg-upstream-03 | （任务 12 填写） | — | ap-southeast-1 | nat-sg-prod | — | ☐ | ☐ | — |"
  echo "| 8 | eip-sg-upstream-04 | （任务 12 填写） | — | ap-southeast-1 | nat-sg-prod | — | ☐ | ☐ | — |"
  echo
  echo "## 待办"
  echo
  echo "- [ ] 8 个 EIP 提交给各上游供应商，取得书面生效确认（任务 56 的外部等待项）"
  echo "- [ ] 马尼拉 4 EIP 加入马尼拉 RDS 公网白名单（§6.1，否则新加坡备站连不上主库 → M4 挂）"
  echo "- [ ] 配置余额/到期双告警（坑 2：欠费导致 EIP 被回收后重新分配给他人 → 白名单失效）"
} > "$LEDGER"
say "已写入：$LEDGER"

step "完成"
say "证据目录：$OUTDIR"
say "NAT_MNL=$NAT_ID"
say "EIP_POOL=$EIP_POOL_CSV"
