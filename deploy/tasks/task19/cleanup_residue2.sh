#!/bin/bash
# task19/cleanup_residue2.sh — 逐条删 SG 规则（扁平参数形态）+ 每步复测 ALB，异常回滚
#
# ★ 坑：ECS RevokeSecurityGroup 在 ap-southeast-6 用**扁平参数**（IpProtocol/PortRange/
#   SourceCidrIp/DestCidrIp），传 SecurityGroupRule.N.* 会报 InvalidIpProtocol.ValueNotSupported
#   （服务端读不到值），CLI 也直接拒 `--SecurityGroupRule.1.Direction` 不是有效参数。
set -uo pipefail
export PATH="$HOME/.workbuddy/binaries/aliyun-cli:$PATH"
cd "$(dirname "$0")/.."
REG=ap-southeast-6
NODE_SG=sg-5tsil3ca5dfkqefks1g9
POD_SG=sg-5tsaatp5w68vyqszezja
IP_PUB=8.212.161.49

probe() {
  local ok=0 c
  for t in 1 2 3 4 5 6; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 6 "http://$IP_PUB/api/status")
    [ "$c" = "200" ] && ok=$((ok+1))
  done
  echo "     probe -> 200x$ok/6"
  [ "$ok" -ge 6 ]
}

show() { aliyun ecs DescribeSecurityGroupAttribute --region $REG --SecurityGroupId "$1" \
           2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
ps=d.get('Permissions',{}).get('Permission',[])
print('     rules=%d' % len(ps))
for p in ps:
    print('      %s %-8s %-12s %s %s' % (p.get('Direction'), p.get('IpProtocol'),
        p.get('PortRange'), p.get('SourceCidrIp') or p.get('SourceGroupId') or p.get('DestCidrIp'),
        (p.get('Description') or '')[:60]))
"; }

echo "=========== 0) 基线复测 ==========="
probe || { echo "!! 基线不通，中止"; exit 1; }
show $NODE_SG; show $POD_SG

# ---- 删一条 + 复测，失败回滚 ----
revoke_and_check() {
  local sg="$1" dir="$2" proto="$3" port="$4" cidr="$5" label="$6"
  echo
  echo "=========== 删：$label ==========="
  if [ "$dir" = "egress" ]; then
    aliyun ecs RevokeSecurityGroupEgress --region $REG --SecurityGroupId "$sg" \
      --IpProtocol "$proto" --PortRange "$port" --DestCidrIp "$cidr" \
      --NicType intranet --Policy Accept --Priority 1 2>&1 | head -2
  else
    aliyun ecs RevokeSecurityGroup --region $REG --SecurityGroupId "$sg" \
      --IpProtocol "$proto" --PortRange "$port" --SourceCidrIp "$cidr" \
      --NicType intranet --Policy Accept --Priority 1 2>&1 | head -2
  fi
  sleep 4
  if probe; then
    echo "     ✅ ALB 链路仍通"
  else
    echo "     ❌ 链路断！立即回滚该规则"
    if [ "$dir" = "egress" ]; then
      aliyun ecs AuthorizeSecurityGroupEgress --region $REG --SecurityGroupId "$sg" \
        --IpProtocol "$proto" --PortRange "$port" --DestCidrIp "$cidr" \
        --NicType intranet --Policy Accept --Priority 1 \
        --Description "rollback-$label" 2>&1 | head -2
    else
      aliyun ecs AuthorizeSecurityGroup --region $REG --SecurityGroupId "$sg" \
        --IpProtocol "$proto" --PortRange "$port" --SourceCidrIp "$cidr" \
        --NicType intranet --Policy Accept --Priority 1 \
        --Description "rollback-$label" 2>&1 | head -2
    fi
    sleep 4; probe
    echo "     !! 已回滚，后续步骤中止"; exit 1
  fi
}

revoke_and_check "$NODE_SG" ingress TCP 32656/32656 10.0.0.0/16 "节点 ingress 32656 from VPC（diag-intra，节点间 NodePort 诊断用）"
revoke_and_check "$NODE_SG" ingress TCP 3000/3000   10.0.0.0/16 "节点 ingress 3000 from VPC（diag-intra，节点上无 3000 监听）"
revoke_and_check "$NODE_SG" egress  UDP 1/65535     10.0.0.0/16 "节点 egress UDP 全开（intra-vpc-udp 诊断用）"
revoke_and_check "$POD_SG"  ingress UDP 1/65535     10.0.0.0/16 "Pod ingress UDP 全开（intra-vpc-udp-to-pods 诊断用）"

echo
echo "=========== 9) 终态回读 ==========="
show $NODE_SG; show $POD_SG
echo
echo "=========== 10) 终态复测（两 IP 各 6 次）==========="
for ip in 8.212.161.49 8.212.183.7; do
  printf '  %-14s ' "$ip"
  for t in 1 2 3 4 5 6; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 6 "http://$ip/api/status"); printf '%s ' "$c"
  done; echo
done
echo; echo done
