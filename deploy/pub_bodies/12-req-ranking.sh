#!/usr/bin/env bash
# 按 Pod 列 requests，找大头
set -uo pipefail

kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v)*1000
def mem(v):
    if not v: return 0
    v = str(v); u = {'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:])
    return float(v[:-2])*u if u else float(v)/1024/1024/1024
rows = []
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    kind = (p['metadata'].get('ownerReferences') or [{}])[0].get('kind', '?')
    rc = rm = 0
    for c in p['spec'].get('containers', []):
        r = (c.get('resources') or {}).get('requests') or {}
        rc += cpu(r.get('cpu')); rm += mem(r.get('memory'))
    rows.append((rc, rm, p['metadata']['namespace'], p['metadata']['name'], kind, p['spec'].get('nodeName','')[-6:]))
rows.sort(reverse=True)
print('%-8s %-46s %-14s %-8s %-7s %-8s' % ('req.cpu', 'POD', 'NS', 'KIND', 'req.mem', 'NODE'))
for rc, rm, ns, n, k, nd in rows:
    print('%-8.0f %-46s %-14s %-8s %-7.2f %-8s' % (rc, n[:46], ns, k, rm, nd))
print()
print('TOTAL req.cpu = %.0fm  req.mem = %.2fGi' % (sum(r[0] for r in rows), sum(r[1] for r in rows)))
"

echo
echo "########## DaemonSet 清单 ##########"
kubectl get ds -A 2>&1
echo
echo "########## kube-system Deployment ##########"
kubectl -n kube-system get deploy 2>&1
