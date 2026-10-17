#!/usr/bin/env bash
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
    k = (p['metadata'].get('ownerReferences') or [{}])[0].get('kind', '?')
    rc = rm = 0
    for c in p['spec'].get('containers', []):
        r = (c.get('resources') or {}).get('requests') or {}
        rc += cpu(r.get('cpu')); rm += mem(r.get('memory'))
    rows.append((rc, rm, p['metadata']['namespace'], p['metadata']['name'], k))
rows.sort(reverse=True)
print('=== TOP 14 (req.cpu) ===')
for rc, rm, ns, n, k in rows[:14]:
    print('%6.0fm %5.2fGi  %-22s %-44s %s' % (rc, rm, ns, n[:44], k))
"

echo
echo "=== 多容器 Pod 的容器的明细 ==="
for p in \
  "$(kubectl -n kube-system get pods -l k8s-app=csi-provisioner -o name 2>/dev/null | head -1)" ; do :; done
kubectl -n kube-system get pods -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v)*1000
for p in d['items']:
    cs = p['spec'].get('containers', [])
    if len(cs) < 2: continue
    n = p['metadata']['name']
    if not any(k in n for k in ('csi-plugin','csi-provisioner','terway','loongcollector','node-exporter','koordlet')):
        continue
    tot = sum(cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu')) for c in cs)
    print('%s  total=%dm  (%d 容器)' % (n, tot, len(cs)))
    for c in cs:
        r = (c.get('resources') or {}).get('requests') or {}
        print('    %-42s cpu=%-7s mem=%s' % (c.get('name'), r.get('cpu'), r.get('memory')))
" | head -60
