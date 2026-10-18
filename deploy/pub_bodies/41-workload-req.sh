#!/usr/bin/env bash
set -uo pipefail
echo "########## Deployment 资源与副本 ##########"
kubectl get deploy -A -o json 2>/dev/null > /tmp/d.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/d.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
tot = 0
for x in d['items']:
    ns = x['metadata']['namespace']
    if ns in ('kube-system', 'arms-prom', 'kube-node-lease', 'kube-public'):
        continue
    rep = x['spec'].get('replicas')
    print('== %s/%s  replicas=%s  ready=%s' % (ns, x['metadata']['name'], rep, x.get('status', {}).get('readyReplicas')))
    for c in x['spec']['template']['spec']['containers']:
        r = c.get('resources') or {}
        q = r.get('requests') or {}
        l = r.get('limits') or {}
        n = cpu(q.get('cpu'))
        tot += n * (rep or 0)
        print('   %-24s req.cpu=%-6s req.mem=%-6s limits=%-6s/%s' % (
            c.get('name'), q.get('cpu'), q.get('memory'), l.get('cpu'), l.get('memory')))
        print('   nodeSelector=%s' % (x['spec']['template']['spec'].get('nodeSelector')))
print('\n业务 requests.cpu 合计（副本加权）= %.0fm' % tot)
PY
echo
echo "########## HPA ##########"
kubectl get hpa -A 2>&1 | head -8
echo
echo "########## PDB ##########"
kubectl get pdb -A 2>&1 | head -8
