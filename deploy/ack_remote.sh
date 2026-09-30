#!/bin/bash
# ack_remote.sh — 在 ACK 集群节点内执行远端脚本（云助手 + admin 私网 kubeconfig）
#
# 为什么需要它：两集群均 endpoint_public_access=false，本机（深圳）不在 VPC 内，
# 无法直连 10.x 私网 VIP；而 ACK 节点在 VPC 内、且已具备 NAT 出网。
# 本脚本把 kubeconfig 注入到节点，在节点内执行 kubectl / curl。
#
# usage: ack_remote.sh <mnl|sg> <body.sh> [node_id] [loops]
#   body.sh 用 $KUBECONFIG 即可；可参考 K8S=/tmp/k8s/kubeconfig
set -uo pipefail

SITE="${1:?usage: ack_remote.sh <mnl|sg> <body.sh> [node_id] [loops]}"
BODY="${2:?body file required}"
NODE_ARG="${3:-}"
LOOPS="${4:-24}"

case "$SITE" in
  mnl) REGION=ap-southeast-6; CID=cd57e40ce9a634c1698c2f5c5e09bd93c ;;
  sg)  REGION=ap-southeast-1; CID=ca75829e3492d491d9d434de087913798 ;;
  *)   echo "site must be mnl|sg"; exit 2 ;;
esac

KCDIR="${ACKCTL_DIR:-/tmp/ackctl-$SITE}"
mkdir -p "$KCDIR"
[ -s "$KCDIR/kubeconfig" ] || chmod 700 "$KCDIR" 2>/dev/null || true

# 1) admin 私网 kubeconfig（缓存）
if [ ! -s "$KCDIR/kubeconfig" ]; then
  aliyun cs DescribeClusterUserKubeconfig --ClusterId "$CID" --region "$REGION" \
    --PrivateIpAddress true > "$KCDIR/kc.json" 2>&1
  if ! python3 -c "
import json,sys
d=json.load(open('$KCDIR/kc.json'))
open('$KCDIR/kubeconfig','w').write(d['config'])
" 2>/dev/null; then
    echo "[!] kubeconfig 拉取失败："; head -5 "$KCDIR/kc.json"; exit 1
  fi
  echo "[i] kubeconfig -> $KCDIR/kubeconfig (server=$(grep -m1 server: "$KCDIR/kubeconfig" | tr -d '\r'))"
fi

# 2) 选节点（不指定则取该集群第一台 worker）
if [ -z "$NODE_ARG" ]; then
  NODE_ARG=$(aliyun cs DescribeClusterNodes --ClusterId "$CID" --region "$REGION" --pageSize 100 2>/dev/null \
    | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for n in (d.get('nodes') or []):
    iid=n.get('instance_id')
    if iid: print(iid); break
" )
fi
if [ -z "${NODE_ARG:-}" ]; then echo "[!] 未能确定节点 ID"; exit 1; fi
echo "[i] site=$SITE region=$REGION cluster=$CID node=$NODE_ARG"

# 3) 组装远端脚本：注入证书 + kubeconfig + 用户 body
python3 - "$BODY" "$KCDIR/kubeconfig" <<'PY'
import sys, os
body = open(sys.argv[1], encoding='utf-8').read().replace('\r\n', '\n')
kc   = open(sys.argv[2], encoding='utf-8').read().replace('\r\n', '\n')
pre = """#!/bin/bash
mkdir -p /tmp/k8s
cat > /tmp/k8s/kubeconfig <<'KCEOF'
%s
KCEOF
chmod 600 /tmp/k8s/kubeconfig
export KUBECONFIG=/tmp/k8s/kubeconfig
export K8S=/tmp/k8s/kubeconfig
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[bootstrap] 安装 kubectl ..."
  (curl -sSL --max-time 120 -o /tmp/kubectl \\
     https://dl.k8s.io/release/v1.35.7/bin/linux/amd64/kubectl \\
   || curl -sSL --max-time 120 -o /tmp/kubectl \\
     https://mirrors.aliyun.com/kubernetes-release/release/v1.35.7/bin/linux/amd64/kubectl) \\
   && chmod +x /tmp/kubectl && mv /tmp/kubectl /usr/local/bin/kubectl
fi
command -v kubectl >/dev/null 2>&1 && echo "[bootstrap] kubectl $(kubectl version --client -o json 2>/dev/null | head -c 0; kubectl version --client 2>/dev/null | head -1)" || echo "[bootstrap] kubectl 不可用"
echo "================= BODY START ================="
""" % kc
open(os.path.dirname(sys.argv[2]) + '/remote_body.sh', 'w').write(pre + body)
PY

# 4) 下发
INV=$(aliyun ecs RunCommand --RegionId "$REGION" --region "$REGION" --Type RunShellScript \
  --InstanceId.1 "$NODE_ARG" --ContentEncoding Base64 --Name "ackctl-$SITE" --Timeout 900 \
  --CommandContent "$(base64 -w0 "$KCDIR/remote_body.sh")" 2>&1 | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('InvokeId',''))
except Exception: print('FAIL')")
echo "[i] InvokeId=$INV"
[ "$INV" = "FAIL" ] && { echo "[!] 下发失败"; exit 1; }

# 5) 轮询
for i in $(seq 1 "$LOOPS"); do
  sleep 5
  aliyun ecs DescribeInvocationResults --RegionId "$REGION" --region "$REGION" \
    --InvokeId "$INV" > "$KCDIR/ir.json" 2>&1
  R=$(python3 - "$KCDIR/ir.json" <<'PY'
import json,base64,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print('PARSE|'); raise SystemExit
res=((d.get('Invocation') or {}).get('InvocationResults') or {}).get('InvocationResult') or []
if not res: print('WAIT|'); raise SystemExit
r=res[0]; o=r.get('Output','') or ''
try: o=base64.b64decode(o).decode('utf-8','replace')
except Exception: pass
print('%s|%s' % (r.get('InvocationStatus'), o))
PY
)
  case "$R" in
    WAIT\|*|PARSE\|*|Running\|*|Pending\|*) : ;;
    *) echo "================= BODY END (第 $i 轮 · ${R%%|*}) ================="
       echo "${R#*|}"; exit 0 ;;
  esac
done
echo "[!] 超时未完成"
exit 1
