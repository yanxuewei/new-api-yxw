#!/usr/bin/env bash
# 步骤1（修正）：gatekeeper 保留 1 副本（namespaces webhook 为 failurePolicy=Fail，全下线会阻断 namespace 创建）
set -uo pipefail

echo "########## scale ##########"
kubectl -n kube-system scale deploy ack-cost-exporter --replicas=0 2>&1
kubectl -n kube-system scale deploy ack-koord-manager --replicas=0 2>&1
kubectl -n kube-system scale deploy gatekeeper --replicas=1 2>&1

echo
echo "########## 等 45s ##########"
sleep 45
kubectl -n kube-system get deploy 2>&1 | grep -E 'NAME|gatekeeper|koord-manager|cost-exporter'
echo
echo "--- Pod 数 / 节点 ---"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin); c = collections.Counter()
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    c[p['spec'].get('nodeName')] += 1
for n, v in sorted(c.items()): print('  %-32s %d/15' % (n, v))
"
echo
echo "--- 各节点 req.cpu 合计 ---"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
per = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    n = p['spec'].get('nodeName')
    for c in p['spec'].get('containers', []):
        per[n] += cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu'))
for n in sorted(per): print('  %-32s %6.0fm / 1930m  (%.1f%%)' % (n, per[n], per[n]/1930*100))
"
