#!/usr/bin/env bash
# 雅加达 dev vSwitch 地址偏移对齐马尼拉/新加坡（2026-09-30）
# 背景：生产两站点的偏移表完全一致 —— pub=.0/.1 (/24)、app=16/32 (/20)、data=48/64 (/20)。
#      dev 现有 app 段占了 10.2.0.0/20（pub 槽位），pub/data 顺延到 48/49/64/80，偏移表与生产不同构。
# 本脚本：删除并重建全部 7 段，使前两可用区与生产逐槽同构，第 3 可用区统一追加在尾部。
# 前提（脚本内会再校验一次）：七段均为零绑定，删建零成本、零业务影响。
# ⚠ 破坏性操作：需项目负责人核准后才可执行。
# ✅ 已于 2026-09-30 经核准执行完毕（负责人原话「可以删 7 建 7」；七段全部重建，
#    新 ID 见 deploy/jakarta_dev_ledger.md §1 / §10.2，旧 ID 已销毁仅作审计线索）。
#    执行中曾在第 5 段遇到瞬时 `connection reset by peer` 而中止，改用「按 VSwitchName 查找、缺失才建」
#    续跑补齐 data-5a / data-5b / app-5c —— 若你重跑本脚本，请沿用这个幂等续跑方式，不要盲目重跑删除步。
#    重跑会在 Step 0 因旧 ID 已不存在而中止；如需再次核对偏移，请用下面的只读回读命令：
#      aliyun vpc DescribeVSwitches --region ap-southeast-5 --VpcId vpc-k1ano67avx98nr3n1bg5d --PageSize 30
set -euo pipefail

REGION=ap-southeast-5
VPC_ID=vpc-k1ano67avx98nr3n1bg5d
RG=rg-aek4hk3prqgqjcy

# 执行前现状（2026-09-30 已全部删除，此处仅作审计线索）
CURRENT=(
  vsw-k1aaxl1aqbc42ac7yb7ms vsw-k1a1ogs29dvgvqethz27g vsw-k1aj6eby0v5lpwrswov45
  vsw-k1asfd46ijq7dqurfhccb vsw-k1ax18mzbsodwlpy7j48v
  vsw-k1acp8av186m4e72y2lkt vsw-k1adi3avmtqx4c3th6h1g
)

# 目标偏移表：与马尼拉/新加坡同构，5c 追加在尾部
TARGET=(
  "10.2.0.0/24|ap-southeast-5a|vsw-jkt-dev-pub-5a"
  "10.2.1.0/24|ap-southeast-5b|vsw-jkt-dev-pub-5b"
  "10.2.16.0/20|ap-southeast-5a|vsw-jkt-dev-app-5a"
  "10.2.32.0/20|ap-southeast-5b|vsw-jkt-dev-app-5b"
  "10.2.48.0/20|ap-southeast-5a|vsw-jkt-dev-data-5a"
  "10.2.64.0/20|ap-southeast-5b|vsw-jkt-dev-data-5b"
  "10.2.80.0/20|ap-southeast-5c|vsw-jkt-dev-app-5c"
)

say() { printf '\n=== %s ===\n' "$*"; }

say "0. 删除前校验：每段必须零绑定（可用 IP = 该段满值）"
for V in "${CURRENT[@]}"; do
  read -r AVAIL CIDR <<< "$(aliyun vpc DescribeVSwitches --region "$REGION" --VSwitchId "$V" \
    | jq -r '.VSwitches.VSwitch[0] | [.AvailableIpAddressCount, .CidrBlock] | @tsv')"
  FULL=$(python3 -c "import ipaddress,sys;print(ipaddress.ip_network(sys.argv[1]).num_addresses - 4)" "$CIDR")
  if [ "$AVAIL" != "$FULL" ]; then
    echo "ABORT: $V ($CIDR) 已被占用（avail=$AVAIL / full=$FULL），先迁走资源再重排"; exit 1
  fi
  echo "  free  $V $CIDR ($AVAIL/$FULL)"
done

say "1. 删除旧七段"
for V in "${CURRENT[@]}"; do
  aliyun vpc DeleteVSwitch --region "$REGION" --VSwitchId "$V" >/dev/null && echo "  deleted $V"
  sleep 3
done

say "2. 按目标偏移表重建"
NEW_IDS=()
for spec in "${TARGET[@]}"; do
  IFS='|' read -r CIDR AZ NAME <<< "$spec"
  ID=$(aliyun vpc CreateVSwitch --region "$REGION" --VpcId "$VPC_ID" --CidrBlock "$CIDR" \
    --ZoneId "$AZ" --VSwitchName "$NAME" | jq -r '.VSwitchId')
  echo "  created $NAME $CIDR $AZ -> $ID"
  aliyun vpc TagResources --region "$REGION" --RegionId="$REGION" --ResourceType=VSWITCH --ResourceId.1="$ID" \
    --Tag.1.Key=env --Tag.1.Value=dev --Tag.2.Key=project --Tag.2.Value=new-api \
    --Tag.3.Key=managed-by --Tag.3.Value=realign_jakarta_dev_cidrs.sh \
    --Tag.4.Key=isolation --Tag.4.Value=structural-vpc >/dev/null
  NEW_IDS+=("$ID")
  sleep 3
done

say "3. 回读"
aliyun vpc DescribeVSwitches --region "$REGION" --VpcId "$VPC_ID" --PageSize 20 \
  | python3 -c "
import sys, json
for x in sorted(json.load(sys.stdin)['VSwitches']['VSwitch'], key=lambda i: i['CidrBlock']):
    print('  ' + x['VSwitchName'].ljust(22), x['CidrBlock'].ljust(14), x['ZoneId'].ljust(17), x['Status'].ljust(10), x['VSwitchId'])"

say "4. 下游需同步改口的三处（脚本不自动改）"
cat <<EOF
  RDS 白名单 SecurityIPList  = 10.2.16.0/20,10.2.32.0/20,10.2.80.0/20   （app 三段，新偏移）
  RDS --VSwitchId            = 新 vsw-jkt-dev-data-5a（10.2.48.0/20）
  ACK 节点池 vSwitch 选择     = app 三段 + pub 两段（ALB 需跨 2 AZ）
EOF
echo "重排后请重跑 rds CreateDBInstance --DryRun=true 复核白名单，并更新 jakarta_dev_ledger.md §1/§8 与方案表 R16–R23。"
