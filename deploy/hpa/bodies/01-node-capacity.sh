#!/usr/bin/env bash
# 取节点可分配资源（判断 maxReplicas=13 × requests 2C 是否装得下）
set -uo pipefail
for n in $(kubectl get nodes -o name 2>/dev/null); do
  echo "########## $n"
  kubectl get "$n" -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
st = d.get('status', {})
cap = st.get('capacity', {}) or {}
al  = st.get('allocatable', {}) or {}
labels = d.get('metadata', {}).get('labels', {}) or {}
print('  instance-type =', labels.get('node.kubernetes.io/instance-type'))
print('  capacity      : cpu=%s memory=%s pods=%s' % (cap.get('cpu'), cap.get('memory'), cap.get('pods')))
print('  allocatable   : cpu=%s memory=%s pods=%s' % (al.get('cpu'), al.get('memory'), al.get('pods')))
"
  echo "  --- Allocated resources ---"
  kubectl describe "$n" 2>/dev/null | sed -n '/Allocated resources/,/^Events/p' | sed 's/^/  /' | head -12
done

echo
echo "########## 全集群 requests 汇总 ##########"
kubectl describe nodes 2>/dev/null | grep -E "cpu  |memory  " | sed 's/^ */  /'
