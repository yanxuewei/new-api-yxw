#!/usr/bin/env bash
# 任务 45 方案 A —— 雅加达 dev 环境「零成本网络层」provision（幂等，可重复执行）
# 依据：deploy/docs/任务45环境隔离修订_2026-09-29.md §5.3 / §7
# 只创建不计费资源：VPC / vSwitch / 安全组 / 出方向 deny 规则。
# 计费资源（NAT+EIP、ACK 节点池、RDS）需单独授权，见文末「Phase 2 待办」。
set -euo pipefail

# 结构体已按 2026-09-30「删 7 建 7」偏移对齐后的实际状态回写；
# 现在重跑 = 只读校验 + 补齐（幂等），不会再创建新资源。
REGION=ap-southeast-5
VPC_CIDR=10.2.0.0/16
VPC_NAME=vpc-newapi-jkt-dev
SG_NAME=sg-jkt-dev-app

# 需要硬隔离的目标（实测坐标见修订文档 E1 / §5.1 A2-3）
PROD_CIDRS=(10.0.0.0/16 10.1.0.0/16)
PROD_RDS_PUBLIC_IP=43.118.96.65
PROD_RDS_PORT=5432

# vSwitch 规划：与马尼拉/新加坡「逐槽同构」—— pub=.0/.1(/24)、app=16/32(/20)、data=48/64(/20)，
# 雅加达多出的第 3 可用区（5c）追加在末尾 10.2.80.0/20，不插在中间，避免偏移错位。
# Terway ENIIP 下 Pod IP 直接取自节点所在 AZ 的 vSwitch（没有独立 Pod 交换机），因此三段统一用 app 角色名。
# dev RDS 白名单只放 app 三段，pub / data 段不进白名单。
VSWITCHES=(
  "10.2.0.0/24|ap-southeast-5a|vsw-jkt-dev-pub-5a"
  "10.2.1.0/24|ap-southeast-5b|vsw-jkt-dev-pub-5b"
  "10.2.16.0/20|ap-southeast-5a|vsw-jkt-dev-app-5a"
  "10.2.32.0/20|ap-southeast-5b|vsw-jkt-dev-app-5b"
  "10.2.48.0/20|ap-southeast-5a|vsw-jkt-dev-data-5a"
  "10.2.64.0/20|ap-southeast-5b|vsw-jkt-dev-data-5b"
  "10.2.80.0/20|ap-southeast-5c|vsw-jkt-dev-app-5c"
)
APP_CIDRS=(10.2.16.0/20 10.2.32.0/20 10.2.80.0/20)   # Phase 2 RDS --SecurityIPList 的唯一来源

say() { printf '\n=== %s ===\n' "$*"; }

say "0. 现状核对"
echo "existing vpcs in $REGION = $(aliyun vpc DescribeVpcs --region "$REGION" --PageSize 50 | jq '.Vpcs.Vpc | length')"

say "1. VPC"
VPC_ID=$(aliyun vpc DescribeVpcs --region "$REGION" --PageSize 50 \
  | jq -r --arg n "$VPC_NAME" '[.Vpcs.Vpc[]|select(.VpcName==$n)|.VpcId][0] // empty')
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aliyun vpc CreateVpc --region "$REGION" --CidrBlock "$VPC_CIDR" \
    --VpcName "$VPC_NAME" --Description "new-api dev/test, structurally isolated from prod" \
  | jq -r '.VpcId')
  echo "created VPC_ID=$VPC_ID"; sleep 8
else
  echo "reuse   VPC_ID=$VPC_ID"
fi
for _ in $(seq 1 20); do
  ST=$(aliyun vpc DescribeVpcAttribute --region "$REGION" --VpcId "$VPC_ID" | jq -r '.Status')
  [ "$ST" = "Available" ] && break
  sleep 3
done
echo "VPC status=$ST cidr=$(aliyun vpc DescribeVpcAttribute --region "$REGION" --VpcId "$VPC_ID" | jq -r '.CidrBlock')"

say "2. vSwitch"
VSW_IDS=()
for spec in "${VSWITCHES[@]}"; do
  IFS='|' read -r CIDR AZ NAME <<< "$spec"
  FOUND=$(aliyun vpc DescribeVSwitches --region "$REGION" --VpcId "$VPC_ID" --PageSize 50 \
    | jq -r --arg n "$NAME" '[.VSwitches.VSwitch[]|select(.VSwitchName==$n)|.VSwitchId][0] // empty')
  if [ -z "$FOUND" ]; then
    FOUND=$(aliyun vpc CreateVSwitch --region "$REGION" --VpcId "$VPC_ID" --CidrBlock "$CIDR" \
      --ZoneId "$AZ" --VSwitchName "$NAME" | jq -r '.VSwitchId')
    echo "created $NAME $CIDR $AZ -> $FOUND"
    sleep 5
  else
    echo "reuse   $NAME $CIDR $AZ -> $FOUND"
    # CIDR / AZ 不可改（只能删建），此处只做漂移检测，不回写
    READ=$(aliyun vpc DescribeVSwitches --region "$REGION" --VSwitchId "$FOUND" \
      | jq -r '.VSwitches.VSwitch[0] | [.CidrBlock, .ZoneId] | join(" ")')
    if [ "$READ" != "$CIDR $AZ" ]; then
      echo "DRIFT   $NAME 期望 '$CIDR $AZ' 实际 '$READ' —— 偏移对齐已失效，需重跑 deploy/ops/realign_jakarta_dev_cidrs.sh" >&2
    fi
  fi
  VSW_IDS+=("$FOUND")
done

# 标签归口（实测：vpc MoveResourceGroup 的 ResourceType 不含 VSwitch，非法参数；成本归口以 tag 为准）
# 注：云上现网值来自 realign 执行（managed-by=realign_jakarta_dev_cidrs.sh），重跑本脚本会把该值归一为自身。
for V in "${VSW_IDS[@]}"; do
  aliyun vpc TagResources --region "$REGION" --RegionId="$REGION" --ResourceType=VSWITCH --ResourceId.1="$V" \
    --Tag.1.Key=env --Tag.1.Value=dev --Tag.2.Key=project --Tag.2.Value=new-api \
    --Tag.3.Key=managed-by --Tag.3.Value=provision_jakarta_dev_net.sh \
    --Tag.4.Key=isolation --Tag.4.Value=structural-vpc >/dev/null \
    && echo "tagged $V"
done

say "3. 安全组"
SG_ID=$(aliyun ecs DescribeSecurityGroups --region "$REGION" --VpcId "$VPC_ID" \
  | jq -r --arg n "$SG_NAME" '[.SecurityGroups.SecurityGroup[]|select(.SecurityGroupName==$n)|.SecurityGroupId][0] // empty')
if [ -z "$SG_ID" ]; then
  SG_ID=$(aliyun ecs CreateSecurityGroup --region "$REGION" --VpcId "$VPC_ID" \
    --SecurityGroupName "$SG_NAME" --SecurityGroupType normal \
    --Description "dev egress: hard deny toward prod cidrs and prod RDS public endpoint" \
  | jq -r '.SecurityGroupId')
  echo "created SG_ID=$SG_ID"
else
  echo "reuse   SG_ID=$SG_ID"
fi

dump_egress() {
  aliyun ecs DescribeSecurityGroupAttribute --region "$REGION" --SecurityGroupId "$SG_ID" --Direction egress \
    | jq -r '.Permissions.Permission[] | [( .Policy|ascii_downcase ), .IpProtocol, .PortRange, .DestCidrIp, (.Priority|tostring)] | join(" ")'
}
has_drop() { # <destCidr> <portRange> <proto>
  dump_egress | awk -v d="$1" -v p="$2" -v pr="$3" '$1=="drop" && $2==pr && $3==p && $4==d {f=1} END{exit !f}'
}
add_egress() { # <policy> <proto> <portRange> <destCidr> <priority> <desc>
  # 注意：PortRange 可能是 "-1/-1"，CLI 会把以 "-" 开头的值当成选项名，必须用 --k=v 形式
  aliyun ecs AuthorizeSecurityGroupEgress --region "$REGION" --RegionId="$REGION" --SecurityGroupId="$SG_ID" \
    --Permissions.1.Policy="$1" --Permissions.1.IpProtocol="$2" --Permissions.1.PortRange="$3" \
    --Permissions.1.DestCidrIp="$4" --Permissions.1.Priority="$5" --Permissions.1.Description="$6" >/dev/null
}

for C in "${PROD_CIDRS[@]}"; do
  if has_drop "$C" "-1/-1" "ALL"; then echo "already drop  $C"
  else
    add_egress drop ALL "-1/-1" "$C" 1 "isolation no reachability to prod VPC"
    echo "added drop  $C (all traffic)"
  fi
done

if has_drop "$PROD_RDS_PUBLIC_IP/32" "$PROD_RDS_PORT/$PROD_RDS_PORT" "TCP"; then
  echo "already drop  $PROD_RDS_PUBLIC_IP:$PROD_RDS_PORT"
else
  add_egress drop TCP "$PROD_RDS_PORT/$PROD_RDS_PORT" "$PROD_RDS_PUBLIC_IP/32" 1 \
    "isolation prod RDS public endpoint unreachable from dev"
  echo "added drop  $PROD_RDS_PUBLIC_IP:$PROD_RDS_PORT"
fi

# 放行：HTTPS 出站（拉马尼拉 EE 公网端点 / 上游调用）+ 阿里云内部 DNS
add_egress accept TCP 443/443 0.0.0.0/0 10 "pull images from Manila ACR EE internet endpoint" || true
for NS in 100.100.2.136 100.100.2.138; do
  add_egress accept UDP 53/53 "$NS/32" 10 "aliyun internal dns" || true
done
add_egress accept UDP 53/53 0.0.0.0/0 20 "dns fallback" || true

say "4. 出方向规则回读（drop 必须在位；deny 优先于 allow）"
dump_egress | sort -k5,5n | sed 's/^/  /'

say "5. 台账输出"
cat <<EOF
REGION=$REGION
VPC_ID=$VPC_ID
VPC_CIDR=$VPC_CIDR
SG_ID=$SG_ID
VSWITCH_IDS=${VSW_IDS[*]}
RDS_SECURITY_IP_LIST=${APP_CIDRS[*]}   # 只放 app 三段；pub / data 段不进白名单
EOF
echo
echo "Phase 2 RDS 零成本预检（DryRun，不产生费用）—— 用 data-5a 的 VSwitchId 替换 <VSW_DATA_A>："
echo "  aliyun rds CreateDBInstance --region $REGION --DryRun=true --Engine=PostgreSQL --EngineVersion=17.0 \\"
echo "    --DBInstanceClass=pg.n2.2c.1m --DBInstanceStorage=20 --DBInstanceStorageType=generic \\"
echo "    --Category=Basic --InstanceNetworkType=VPC --VpcId=$VPC_ID --VSwitchId=<VSW_DATA_A> \\"
echo "    --SecurityIPList=\"$(IFS=,; echo "${APP_CIDRS[*]}")\" --ZoneId=ap-southeast-5a"
echo "下一步（计费，需授权）：NAT+EIP → ACK 集群/节点池 → RDS PG 17.0 → 工作负载 → 隔离验收 V1-V11"
