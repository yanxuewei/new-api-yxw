#!/bin/bash
# task22_sg_10250_fix.sh — 任务 22 补漏：节点 SG 放行 kubelet 10250（源=VPC CIDR，**不开公网**）
#
# 为什么必须补：节点池把节点绑到自定义业务 SG（sg-mnl-app / sg-sg-app）后，
# ACK 原托管 SG 里"控制面→kubelet 10250"的放行**不再生效**（6 条规则里只有 3000/出向）。
# 后果：`kubectl logs / exec / port-forward`、APIServer 代理、metrics 抓取全部超时。
# 注意：节点之间因为"同一安全组内默认互通"仍能 10250 通，所以 curl 自测会**误判为正常**。
#
# usage: task22_sg_10250_fix.sh [--apply]
set -uo pipefail
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

run() { # region sg cidr site
  local region="$1" sg="$2" cidr="$3" site="$4"
  echo "======== [$site] $sg ← $cidr : TCP 10250 ========"
  aliyun ecs DescribeSecurityGroupAttribute --RegionId "$region" --region "$region" \
    --SecurityGroupId "$sg" > /tmp/sgq_$site.json 2>&1
  local exists
  exists=$(python3 - "$site" <<'PY'
import json,sys
s=sys.argv[1]
try: d=json.load(open('/tmp/sgq_%s.json'%s))
except Exception: print("PARSEFAIL"); raise SystemExit
for p in (d.get("Permissions") or {}).get("Permission") or []:
    if p.get("Direction")=="ingress" and (p.get("PortRange") or "")=="10250/10250":
        print("YES", p.get("SourceCidrIp"), p.get("SourceGroupId")); raise SystemExit
print("NO")
PY
)
  echo "  现有 10250 入向：$exists"
  if [ "${exists%% *}" = "YES" ]; then echo "  [skip] 已存在"; return; fi
  if [ "$APPLY" != "1" ]; then echo "  (dry-run) 将添加规则"; return; fi
  aliyun ecs AuthorizeSecurityGroup --RegionId "$region" --region "$region" \
    --SecurityGroupId "$sg" \
    --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 10250/10250 \
    --Permissions.1.SourceCidrIp "$cidr" --Permissions.1.NicType intranet \
    --Permissions.1.Policy accept --Permissions.1.Priority 1 \
    --Permissions.1.Description "kubelet-10250-from-vpc-allow-apiserver-logs-exec-metrics" \
    > /tmp/sgfix_$site.json 2>&1
  if grep -qi "ErrorCode\|ERROR" /tmp/sgfix_$site.json; then
    echo "  [FAIL]"; head -4 /tmp/sgfix_$site.json
  else
    echo "  [ok] 已添加"; cat /tmp/sgfix_$site.json | head -4
  fi
}

run ap-southeast-6 sg-5tsil3ca5dfkqefks1g9 10.0.0.0/16 mnl
run ap-southeast-1 sg-t4n0qnhy8mxq9g733r67 10.1.0.0/16 sg
