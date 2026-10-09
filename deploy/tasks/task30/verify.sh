#!/usr/bin/env bash
# 任务 30 只读核查：备站（新加坡）→ 马尼拉 RDS 公网读写链路的"配置面"取证。
# 数据面（Pod/ECS 内 psql/pgbench/ping 实测）不在本脚本范围——需要集群或 VPC 内执行位。
# 用法：bash deploy/tasks/task30/verify.sh
set -uo pipefail

MNL=ap-southeast-6
RDS=pgm-5tstdhko64x2c01w
SG=ap-southeast-1
SG_VPC=vpc-t4nimmwvruexbnene0a3r
ACK_SG=ca75829e3492d491d9d434de087913798

OUTDIR="deploy/logs/task30_verify_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR" || exit 1
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# ap-southeast-6 网关会整片间歇超时（任务 13 坑 15）⇒ 只读调用统一带重试
apic() {
  local name=$1 product=$2 api=$3 region=$4
  shift 4
  local i
  for i in 1 2 3 4 5; do
    if aliyun "$product" "$api" --RegionId "$region" "$@" >"$OUTDIR/$name.json" 2>"$OUTDIR/$name.err"; then
      # 白名单/凭据剥敏：RDS 与 CS 的响应可能带口令字段（含已脱敏的占位），一律删掉再落盘
      jq 'del(.parameters.Password, .parameters.WorkerLoginPassword, .ServerKey, .ServerCert)' \
        "$OUTDIR/$name.json" > "$OUTDIR/$name.tmp" 2>/dev/null && mv "$OUTDIR/$name.tmp" "$OUTDIR/$name.json"
      return 0
    fi
    sleep 3
  done
  log "FAIL $product/$api（5 次重试后）：$(tr '\n' ' ' <"$OUTDIR/$name.err" | cut -c1-200)"
  return 1
}

log "输出目录 $OUTDIR"

# ---------------------------------------------------------------- 1. 公网地址
log "1/6 RDS 连接地址（公网串是否在位）"
apic netinfo rds DescribeDBInstanceNetInfo "$MNL" --DBInstanceId "$RDS" || exit 1
jq -r '.DBInstanceNetInfos.DBInstanceNetInfo[]
  | [.IPType, .ConnectionString, .Port, (.IPAddress // "-")] | @tsv' \
  "$OUTDIR/netinfo.json" | sed 's/^/     /'

# ------------------------------------------------- 1b. 托管池（乙路 = 公网串 6432 的前提）
log "1b/6 托管 PgBouncer 开关（备站 DSN 端口 6432 的前提）"
apic attr rds DescribeDBInstanceAttribute "$MNL" --DBInstanceId "$RDS" || exit 1
jq -r '.Items.DBInstanceAttribute[0]
  | "     PGBouncerEnabled=\(.PGBouncerEnabled // "?")  Engine=\(.Engine) \(.EngineVersion)  Conn=\(.ConnectionString)  MaxConns=\(.DBMaxConnections // "-")"' "$OUTDIR/attr.json"

# ---------------------------------------------------------------- 2. SSL
# ⚠ DescribeDBInstanceSSL 的响应明文回显服务器私钥（任务 15 安全事件）⇒ 落盘前剥敏
log "2/6 RDS SSL（证书绑哪个地址·TLS 下限）"
apic ssl rds DescribeDBInstanceSSL "$MNL" --DBInstanceId "$RDS" || exit 1
jq 'del(.ServerKey,.ServerCert)' "$OUTDIR/ssl.json" > "$OUTDIR/ssl.safe.json" && mv "$OUTDIR/ssl.safe.json" "$OUTDIR/ssl.json"
jq -r '"     RequireUpdate=\(.RequireUpdate // "-")  ConnectionString=\(.ConnectionString // "-")"' "$OUTDIR/ssl.json"

# ---------------------------------------------------------------- 3. 白名单
log "3/6 RDS 白名单（备站出口 EIP 组是否在位）"
apic ips rds DescribeDBInstanceIPArrayList "$MNL" --DBInstanceId "$RDS" || exit 1
jq -r '.Items.DBInstanceIPArray[]
  | [.DBInstanceIPArrayName, .SecurityIPList]
  | "\(.[0])\t\(.[1])"' "$OUTDIR/ips.json" | sed 's/^/     /'

# ------------------------------------------------- 4. 新加坡 NAT SNAT 实际出口
log "4/6 新加坡 NAT 网关 SNAT 出口 EIP（与白名单逐条比对）"
apic natvpc vpc DescribeNatGateways "$SG" --VpcId "$SG_VPC" || exit 1
jq -r '.NatGateways.NatGateway[]
  | [.NatGatewayId, .Status, (.IpList.IpAddress // [] | join(","))]
  | @tsv' "$OUTDIR/natvpc.json" | sed 's/^/     NAT /'
NAT=$(jq -r '.NatGateways.NatGateway[0].NatGatewayId // empty' "$OUTDIR/natvpc.json")
[[ -n "$NAT" ]] || { log "新加坡 VPC 没有 NAT 网关 ⇒ 备站无 SNAT 出口"; }
if [[ -n "$NAT" ]]; then
  apic snat vpc DescribeSnatTableEntries "$SG" --NatGatewayId "$NAT" || exit 1
  jq -r '.SnatTableEntries.SnatTableEntry[]
    | [.SourceVSwitchId // "-", .SourceCIDR // "-", .SnatIp, .Status]
    | @tsv' "$OUTDIR/snat.json" | sed 's/^/     SNAT /'
  jq -r '.SnatTableEntries.SnatTableEntry[].SnatIp' "$OUTDIR/snat.json" \
    | tr ',' '\n' | sed '/^$/d' | sort -u > "$OUTDIR/egress_ips.txt"
  log "   实测出口 EIP 去重：$(tr '\n' ' ' <"$OUTDIR/egress_ips.txt")"
fi

# ------------------------------------------------- 5. 新加坡 ACK / 节点池
log "5/6 新加坡 ACK 集群与节点（备站有没有可跑测量的 Pod）"
if aliyun cs DescribeClusterDetail --ClusterId "$ACK_SG" --region "$SG" \
     >"$OUTDIR/ack.json" 2>"$OUTDIR/ack.err"; then
  jq 'del(.parameters)' "$OUTDIR/ack.json" > "$OUTDIR/ack.tmp" && mv "$OUTDIR/ack.tmp" "$OUTDIR/ack.json"
  jq -r '"     name=\(.name)  state=\(.state)  profile=\(.profile // "-")  vpc=\(.vpc_id)  size=\(.size // "-")"' "$OUTDIR/ack.json"
else
  log "FAIL cs/DescribeClusterDetail：$(tr '\n' ' ' <"$OUTDIR/ack.err" | cut -c1-200)"
fi
aliyun cs DescribeClusterNodePools --ClusterId "$ACK_SG" --region "$SG" \
  >"$OUTDIR/nodepools.json" 2>"$OUTDIR/nodepools.err" \
  && jq -r '.nodepools[]? | [.nodepool_info.name, .status.state, (.scaling_group.instance_types[0] // "-"),
        (.status.total_nodes // 0 | tostring)] | @tsv' "$OUTDIR/nodepools.json" | sed 's/^/     NP  /' \
  || log "FAIL cs/DescribeClusterNodePools：$(tr '\n' ' ' <"$OUTDIR/nodepools.err" | cut -c1-200)"
aliyun cs DescribeClusterNodes --ClusterId "$ACK_SG" --region "$SG" --pageSize 100 \
  >"$OUTDIR/nodes.json" 2>"$OUTDIR/nodes.err" \
  && jq -r '.nodes[]? | [.instance_id, .state,
        (.ip_address | if type=="array" then join(",") else . end)] | @tsv' "$OUTDIR/nodes.json" | sed 's/^/     NODE /' \
  || log "FAIL cs/DescribeClusterNodes：$(tr '\n' ' ' <"$OUTDIR/nodes.err" | cut -c1-200)"

# ------------------------------------------------- 6. 新加坡 ECS（VPC 内执行位）
log "6/6 新加坡 VPC 内 ECS（可作为 psql/pgbench 执行位）"
apic ecs ecs DescribeInstances "$SG" --VpcId "$SG_VPC" --PageSize 50 || exit 1
jq -r '.Instances.Instance[]?
  | [.InstanceId, .Status, .InstanceType,
     (.VpcAttributes.PrivateIpAddress.IpAddress[0] // "-"),
     (.VpcAttributes.NatIpAddress // "-"), (.InstanceName // "-")]
  | @tsv' "$OUTDIR/ecs.json" | sed 's/^/     ECS /'
jq -r '"     TotalCount=\(.TotalCount)"' "$OUTDIR/ecs.json"

# ------------------------------------------------- 判定
log "判定（只看配置面，数据面另说）："
WLG=$(jq -r '.Items.DBInstanceIPArray[] | select(.DBInstanceIPArrayName=="sg_standby_eip") | .SecurityIPList' "$OUTDIR/ips.json")
if [[ -z "$WLG" ]]; then
  log "  ✘ 白名单里没有 sg_standby_eip 组 ⇒ 备站必然连不上"
elif [[ ! -s "$OUTDIR/egress_ips.txt" ]]; then
  log "  ？ 白名单组存在（$WLG），但新加坡无 SNAT 出口可比对"
else
  miss=""
  while read -r ip; do
    grep -qF "${ip}/32" "$OUTDIR/ips.json" || miss="$miss $ip"
  done < "$OUTDIR/egress_ips.txt"
  if [[ -z "$miss" ]]; then log "  ✔ 实测 SNAT 出口 EIP 全部在白名单内"; else log "  ✘ 白名单缺出口 EIP:${miss}"; fi
fi
grep -qE '"IPType"[[:space:]]*:[[:space:]]*"Public"' "$OUTDIR/netinfo.json" \
  && log "  ✔ RDS 公网地址在位" || log "  ✘ RDS 无公网地址"

# 扫敏：私钥 / 口令 / AK
if grep -rlniE 'PRIVATE KEY|"ServerKey"|"AccountPassword"|"Password"|LTAI' "$OUTDIR" >/dev/null 2>&1; then
  log "  ⚠ 目录内命中敏感字段，须先剥敏再提交：$(grep -rlEi 'PRIVATE KEY|"ServerKey"|"AccountPassword"|"Password"|LTAI' "$OUTDIR" | tr '\n' ' ')"
else
  log "  ✔ 证据目录无凭据字段"
fi
