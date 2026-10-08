#!/usr/bin/env bash
# 任务 45 方案 A —— 雅加达 dev 环境「零成本网络层」provision（幂等，可重复执行）
# 依据：deploy/任务45环境隔离修订_2026-09-29.md §5.3 / §7
# 只创建不计费资源：VPC / vSwitch / 安全组 / 出方向 deny 规则。
# 计费资源（NAT+EIP、ACK 节点池、RDS）需单独授权，见文末「Phase 2 待办」。
set -euo pipefail

REGION=ap-southeast-5
VPC_CIDR=10.2.0.0/16
VPC_NAME=vpc-jkt-dev
SG_NAME=sg-jkt-dev-app

# 需要硬隔离的目标（实测坐标见修订文档 E1 / §5.1 A2-3）
PROD_CIDRS=(10.0.0.0/16 10.1.0.0/16)
PROD_RDS_PUBLIC_IP=43.118.96.65
PROD_RDS_PORT=5432

# vSwitch 规划：Terway ENIIP 下 Pod IP 取自节点 vSwitch，故按 AZ 切段
VSWITCHES=(
  "10.2.0.0/20|ap-southeast-5a|vsw-jkt-dev-app-5a"
  "10.2.16.0/20|ap-southeast-5b|vsw-jkt-dev-app-5b"
  "10.2.32.0/20|ap-southeast-5c|vsw-jkt-dev-app-5c"
)

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
  fi
  VSW_IDS+=("$FOUND")
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
EOF
echo
echo "下一步（计费，需授权）：NAT+EIP → ACK 集群/节点池 → RDS PG 17.0 → 工作负载 → 隔离验收 V1-V11"
