#!/usr/bin/env bash
# =============================================================================
# Day 1 · 任务 6｜马尼拉 NAT 网关 + 上游出口 EIP 池 4 个
# 参考：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md (L499-571)
#
# 幂等：可重复执行；已存在的资源自动复用，不重复创建。
# 用法：
#   bash deploy/task6_nat_eip.sh
#   DRY_RUN=1 bash deploy/task6_nat_eip.sh      # 只打印动作，不调用写 API
#
# 相对文档原文的必要修正（均已实测确认）：
#   1) CreateNatGateway 缺 --NatType（该参数「必填」，唯一合法值 Enhanced）
#   2) AssociateEipAddress 的 InstanceType 必须是 Nat，文档写的 NatGateway 非法
#      （非法值会返回误导性的 Invalid.DirectEip.BindType，极易误判为 EIP 类型问题）
#   3) 补 --ResourceGroupId rg-aek4nyivmmsb6iy（项目约定：默认组禁放 new-api 资源）
#
# 实测澄清（与文档表述相反，勿再手工加）：
#   - 创建 Enhanced 公网 NAT 网关时，系统**自动**在路由表加 `0.0.0.0/0 → NatGateway`，
#     Description 为 "Created with NAT gateway(<id>) by system."。故路由条目无需手工创建；
#     本脚本保留一个只读校验（存在即跳过），仅用于发现异常情况。
#
# 实现注意：日志走 fd 3（原始 stderr），API 原始输出一律落文件，
#           避免「+ 命令」行污染 JSON 导致 jq 解析失败（前一版踩过）。
# =============================================================================
set -uo pipefail
exec 3>&2                     # fd3 = 真实 stderr，专用于日志

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

say() { printf '%s\n' "$*" >&3; }
hr()  { say "------------------------------------------------------------"; }
step(){ say ""; say ">>> $*"; hr; }

# api <outfile> <cmd...>   —— 日志到 fd3，API 输出落 outfile；失败自动重试 3 次
# ⚠️ ap-southeast-6 端点实测存在偶发 Client.Timeout / context deadline exceeded；
#    不加重试会**静默漏建资源**（EIP-02 绑定、SNAT 表查询各踩过一次）。
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
say "NAT_MNL=$NAT_ID"
if [[ "$DRY_RUN" == "1" ]]; then say "(DRY_RUN 结束 — 后续为写操作，已跳过)"; exit 0; fi

# ---- 1b. 等待 Available ----------------------------------------------------
step "1b. 等待 NAT 网关 Available（最长 5 分钟）"
ST=Unknown
for i in $(seq 1 30); do
  ST=$(aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID" 2>/dev/null \
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
step "3. 绑定 4 个 EIP 到 NAT 网关"
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
    --SnatIp "$EIP_POOL_CSV" --SnatEntryName "snat-mnl-${vsw}"
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
    --RouteEntryName rt-mnl-default-nat
  cat "$OUTDIR/05-route-create.json" >&3
fi

# ---- 6. 验证 ---------------------------------------------------------------
step "6. 验证"
api "$OUTDIR/06-nat.json" aliyun vpc DescribeNatGateways --RegionId "$REGION" --NatGatewayId "$NAT_ID"
jq -r '.NatGateways.NatGateway[0]|"NAT \(.NatGatewayId)  name=\(.Name)  status=\(.Status)  natType=\(.NatType)  chargeType=\(.InstanceChargeType)\n    snatTable=\(.SnatTableIds.SnatTableId|join(","))  boundEip=\(.IpLists.IpList|length)  rg=\(.ResourceGroupId // "-")"' "$OUTDIR/06-nat.json" 2>/dev/null \
  || cat "$OUTDIR/06-nat.json" >&3

api "$OUTDIR/06-eip.json" aliyun vpc DescribeEipAddresses --RegionId "$REGION" --PageSize 100
jq -r '.EipAddresses.EipAddress[]?|select(.Name|test("eip-mnl-upstream"))|"EIP \(.AllocationId)  \(.IpAddress)  \(.Name)  \(.Status)  bound=\(.InstanceType // "-"):\(.InstanceId // "-")  bw=\(.Bandwidth)  rg=\(.ResourceGroupId // "-")"' "$OUTDIR/06-eip.json" 2>/dev/null

api "$OUTDIR/06-snat.json" aliyun vpc DescribeSnatTableEntries --RegionId "$REGION" --SnatTableId "$SNAT_TABLE" --PageSize 50
jq -r '.SnatTableEntries.SnatTableEntry[]?|"SNAT \(.SnatEntryId)  vsw=\(.SourceVSwitchId)  ips=\(.SnatIp)  \(.Status)"' "$OUTDIR/06-snat.json" 2>/dev/null

api "$OUTDIR/06-route.json" aliyun vpc DescribeRouteEntryList --RegionId "$REGION" --RouteTableId "$RTB" --MaxResult 50
# 注意：NextHopType/NextHopId 位于 .NextHops.NextHop[0]，非顶层（顶层取会得到 null）
jq -r '.RouteEntrys.RouteEntry[]?|"ROUTE \(.DestinationCidrBlock) → \(.NextHops.NextHop[0].NextHopType // "local"):\(.NextHops.NextHop[0].NextHopId // "-")  \(.Status)  \(.Description // "")"' "$OUTDIR/06-route.json" 2>/dev/null

# ---- 7. EIP 台账（8 EIP 一张表，坑 1） -------------------------------------
step "7. 写 EIP 台账 ${LEDGER}"
{
  echo "# 上游出口 EIP 台账（任务 6 / 任务 12 合并）"
  echo
  echo "> 生成时间：${TS} · 账号 \`5108890064395960\` · 来源：\`deploy/task6_nat_eip.sh\`"
  echo "> 坑 1：任一 EIP 新增/替换未同步供应商 → 偶发 403，失败率 ≈ 1/N。**上线前 8 个 EIP 必须全部取得供应商书面生效确认**。"
  echo
  echo "| # | EIP 名称 | AllocationId | 公网 IP | Region | 绑定对象 | 状态 | 已进 RDS 白名单? | 已交供应商? | 生效确认时间 |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  i=0
  for idx in "${!ALLOC_IDS[@]}"; do
    i=$((i+1))
    printf '| %d | %s | %s | %s | ap-southeast-6 | %s | InUse | ☐ | ☐ | — |\n' \
      "$i" "${EIP_NAMES[$idx]}" "${ALLOC_IDS[$idx]}" "${EIP_IPS[$idx]}" "$NAT_NAME"
  done
  for k in 01 02 03 04; do
    i=$((i+1))
    printf '| %d | eip-sg-upstream-%s | （任务 12 填写） | — | ap-southeast-1 | nat-sg-prod | 未建 | ☐ | ☐ | — |\n' "$i" "$k"
  done
  echo
  echo "## 待办"
  echo
  echo "- [ ] 8 个 EIP 提交给各上游供应商，取得书面生效确认（任务 56 的外部等待项）"
  echo "- [ ] 马尼拉 4 EIP 加入马尼拉 RDS 公网白名单（§6.1；否则新加坡备站连不上主库 → M4 挂）"
  echo "- [ ] 配置余额/到期双告警（坑 2：欠费导致 EIP 被回收后重新分配他人 → 白名单失效）"
} > "$LEDGER"
say "已写入：$LEDGER"

step "完成"
say "证据目录：$OUTDIR"
say "NAT_MNL=$NAT_ID"
say "EIP_POOL=$EIP_POOL_CSV"
