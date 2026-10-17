#!/usr/bin/env bash
# 批2：DaemonSet 类降 requests（会逐节点重建 Pod；terway 重建期间该节点新建 Pod 网络短暂不可用）
set -uo pipefail

show() {
  ns=$1; d=$2
  kubectl -n "$ns" get ds "$d" -o json 2>/dev/null | python3 -c "
import sys, json
x = json.load(sys.stdin)
print('  %s/%s' % ('$ns', x['metadata']['name']))
for c in x['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('     %-34s cpu=%-7s mem=%s' % (c.get('name'), (r.get('requests') or {}).get('cpu'), (r.get('requests') or {}).get('memory')))
"
}

echo "########## 改前 ##########"
show kube-system ack-node-problem-detector-daemonset
show kube-system csi-plugin
show kube-system kube-proxy-worker
show kube-system terway-eniip

echo
echo "########## 1. node-problem-detector 100m -> 20m ##########"
kubectl -n kube-system set resources ds/ack-node-problem-detector-daemonset \
  -c $(kubectl -n kube-system get ds ack-node-problem-detector-daemonset -o jsonpath='{.spec.template.spec.containers[0].name}') \
  --requests=cpu=20m 2>&1 | grep -v '^Warning'

echo
echo "########## 2. csi-plugin 100m -> 50m ##########"
kubectl -n kube-system set resources ds/csi-plugin -c csi-plugin --requests=cpu=50m 2>&1 | grep -v '^Warning'

echo
echo "########## 3. kube-proxy 100m -> 50m ##########"
kubectl -n kube-system set resources ds/kube-proxy-worker \
  -c $(kubectl -n kube-system get ds kube-proxy-worker -o jsonpath='{.spec.template.spec.containers[0].name}') \
  --requests=cpu=50m 2>&1 | grep -v '^Warning'

echo
echo "########## 等三组 DaemonSet 就绪（90s）##########"
sleep 90
kubectl -n kube-system get ds 2>&1 | grep -E 'NAME|node-problem|csi-plugin |kube-proxy-worker '

echo
echo "########## 4. terway policy 250m -> 50m ##########"
kubectl -n kube-system set resources ds/terway-eniip -c policy --requests=cpu=50m 2>&1 | grep -v '^Warning'
echo "--- 等 terway 滚动（120s）---"
sleep 120
kubectl -n kube-system get ds terway-eniip 2>&1
kubectl -n kube-system get pods 2>&1 | grep terway | head -6

echo
echo "########## 改后 ##########"
show kube-system ack-node-problem-detector-daemonset
show kube-system csi-plugin
show kube-system kube-proxy-worker
show kube-system terway-eniip

echo
echo "########## 网络连通性验证（起临时 Pod）##########"
kubectl -n kube-system run netcheck-$RANDOM --rm -i --restart=Never --image=busybox:1.36 --timeout=90s -- \
  sh -c 'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL' 2>&1 | tail -3

echo
echo "########## 节点 requests 终值 ##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d=json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v=str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
cnt=collections.Counter(); per=collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status',{}).get('phase') in ('Succeeded','Failed'): continue
    n=p['spec'].get('nodeName'); cnt[n]+=1
    for c in p['spec'].get('containers', []):
        per[n]+=cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu'))
for n in sorted(cnt): print('  %-30s pods=%2d/15 req=%6.0fm 余=%.0fm' % (n,cnt[n],per[n],1930-per[n]))
"
