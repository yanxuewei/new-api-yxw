#!/usr/bin/env bash
set -uo pipefail
NS=newapi-dev

echo "########## 各 deploy 资源配置（核实）##########"
kubectl -n "$NS" get deploy -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for x in d['items']:
    print('== %s  ready=%s/%s  rev=%s' % (x['metadata']['name'], x.get('status',{}).get('readyReplicas'), x['spec'].get('replicas'), (x['metadata'].get('annotations') or {}).get('deployment.kubernetes.io/revision')))
    for c in x['spec']['template']['spec']['containers']:
        r = c.get('resources') or {}
        print('     %-14s requests=%-34s limits=%s' % (c.get('name'), str(r.get('requests')), str(r.get('limits'))))
"

echo
echo "########## 节点 req.cpu / Pod 数 ##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v)*1000
per = collections.defaultdict(float); cnt = collections.Counter()
for p in d.get('items', []):
    if p.get('status',{}).get('phase') in ('Succeeded','Failed'): continue
    n = p['spec'].get('nodeName'); cnt[n] += 1
    for c in p['spec'].get('containers', []):
        per[n] += cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu'))
for n in sorted(per):
    print('  %-32s pods=%2d/15  req.cpu=%6.0fm (%.1f%%)' % (n, cnt[n], per[n], per[n]/1930*100))
"

echo
echo "########## quota ##########"
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'
