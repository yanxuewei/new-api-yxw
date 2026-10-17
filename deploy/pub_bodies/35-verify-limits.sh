#!/usr/bin/env bash
set -uo pipefail
sleep 180
kubectl get pods -A -o json > /tmp/p.json
echo "########## 非 Running ##########"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -8
echo "(空=正常)"
echo
echo "########## 每节点 limits.cpu 合计 ##########"
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
per = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName')
    for c in p['spec'].get('containers', []):
        per[n] += cpu(((c.get('resources') or {}).get('limits') or {}).get('cpu'))
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
PY
echo
echo "########## 剩余 >=1000m 的 Pod ##########"
python3 - <<'PY'
import json
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
rows = []
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    lc = sum(cpu(((c.get('resources') or {}).get('limits') or {}).get('cpu')) for c in p['spec'].get('containers', []))
    if lc >= 1000:
        rows.append((lc, p['metadata']['namespace'], p['metadata']['name']))
rows.sort(reverse=True)
for r in rows: print('  %6.0fm  %-14s %s' % r)
print('  (空=全部 <1000m)' if not rows else '')
PY
echo
echo "########## csi-plugin limits 核对 ##########"
kubectl -n kube-system get ds csi-plugin -o jsonpath='{.spec.template.spec.containers[0].name} {.spec.template.spec.containers[0].resources.limits.cpu}{"\n"}' 2>&1
kubectl -n kube-system get pods -o wide 2>&1 | grep csi-plugin | head -3
