#!/bin/bash
# task19_cleanup_residue.sh — 清理任务19 无证书直连实验残留
#
# 范围（用户 2026-10-06 09:50 批准）：
#   - ServerGroup sgp-1zdipho1kpupp43v4m（Ip 型，成员因 Pod 重建失效，无监听引用）
#   - 无效/诊断用 SG 规则（节点间 NodePort、节点:3000、全开 UDP）
#
# ⚠ 保留（当前 ALB 链路命脉，删了访问即断）：
#   节点 SG ingress: alb-to-nodeport-32656-newapi   (ALB → 节点 32656)
#   节点 SG egress : intra-vpc-tcp                  (节点 → Pod，kube-proxy DNAT 后)
#   Pod  SG ingress: intra-vpc-tcp-to-pods          (Pod 收节点转发流量)
#   Pod  SG ingress: alb-to-pod-3000-direct         (预留：Eni/Ip 直连型组配套)
set -uo pipefail
cd "$(dirname "$0")"
RPC="python3 lib/aliyun_rpc.py"
REG=ap-southeast-6
NODE_SG=sg-5tsil3ca5dfkqefks1g9
POD_SG=sg-5tsaatp5w68vyqszezja
IP_SG=sgp-1zdipho1kpupp43v4m

jq1() { python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print('  RAW:', raw[:300]); raise SystemExit
if d.get('Code'): print('  ERR:', d.get('Code'), d.get('Message'))
else: print('  OK:', json.dumps({k:v for k,v in d.items() if k in ('RequestId','ServerGroupId')}, ensure_ascii=False))
"; }

echo "=========== 1) 移除 Ip 组成员 ==========="
for S in 10.0.43.218 10.0.43.215 10.0.22.219 10.0.22.218; do
  printf '  remove %s: ' "$S"
  $RPC alb RemoveServersFromServerGroup --region $REG --version 2020-06-16 \
    ServerGroupId=$IP_SG Servers.1.ServerId=$S Servers.1.ServerIp=$S Servers.1.Port=3000 2>&1 | jq1
done

echo "=========== 2) 删除 Ip 型服务器组 $IP_SG ==========="
$RPC alb DeleteServerGroup --region $REG --version 2020-06-16 ServerGroupId=$IP_SG 2>&1 | jq1

echo "=========== 3) 删节点 SG 诊断规则（ingress）==========="
for P in 32656 3000; do
  printf '  revoke ingress %s from 10.0.0.0/16: ' "$P"
  $RPC ecs RevokeSecurityGroup --region $REG --version 2014-05-26 \
    SecurityGroupId=$NODE_SG \
    SecurityGroupRule.1.Direction=ingress \
    SecurityGroupRule.1.IpProtocol=TCP \
    SecurityGroupRule.1.PortRange=$P/$P \
    SecurityGroupRule.1.SourceCidrIp=10.0.0.0/16 \
    SecurityGroupRule.1.NicType=intranet \
    SecurityGroupRule.1.Policy=Accept \
    SecurityGroupRule.1.Priority=1 2>&1 | jq1
done

echo "=========== 4) 删节点 SG 全开 UDP 出站 ==========="
printf '  revoke egress UDP 1/65535 -> 10.0.0.0/16: '
$RPC ecs RevokeSecurityGroupEgress --region $REG --version 2014-05-26 \
  SecurityGroupId=$NODE_SG \
  SecurityGroupRule.1.Direction=egress \
  SecurityGroupRule.1.IpProtocol=UDP \
  SecurityGroupRule.1.PortRange=1/65535 \
  SecurityGroupRule.1.DestCidrIp=10.0.0.0/16 \
  SecurityGroupRule.1.NicType=intranet \
  SecurityGroupRule.1.Policy=Accept \
  SecurityGroupRule.1.Priority=1 2>&1 | jq1

echo "=========== 5) 删 Pod SG 全开 UDP 入站 ==========="
printf '  revoke ingress UDP 1/65535 from 10.0.0.0/16: '
$RPC ecs RevokeSecurityGroup --region $REG --version 2014-05-26 \
  SecurityGroupId=$POD_SG \
  SecurityGroupRule.1.Direction=ingress \
  SecurityGroupRule.1.IpProtocol=UDP \
  SecurityGroupRule.1.PortRange=1/65535 \
  SecurityGroupRule.1.SourceCidrIp=10.0.0.0/16 \
  SecurityGroupRule.1.NicType=intranet \
  SecurityGroupRule.1.Policy=Accept \
  SecurityGroupRule.1.Priority=1 2>&1 | jq1

echo
echo "=========== 6) 回读：节点 SG ==========="
$RPC ecs DescribeSecurityGroupAttribute --region $REG --version 2014-05-26 SecurityGroupId=$NODE_SG 2>&1 \
  | python3 /tmp/listsg.py
echo "=========== 7) 回读：Pod SG ==========="
$RPC ecs DescribeSecurityGroupAttribute --region $REG --version 2014-05-26 SecurityGroupId=$POD_SG 2>&1 \
  | python3 /tmp/listsg.py
echo "=========== 8) 回读：服务器组列表 ==========="
$RPC alb ListServerGroups --region $REG --version 2020-06-16 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
for g in d.get('ServerGroups') or []:
    print('  ', g.get('ServerGroupId'), g.get('ServerGroupName'), g.get('ServerGroupType'))
"
echo; echo "done"
