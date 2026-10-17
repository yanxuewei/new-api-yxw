#!/usr/bin/env bash
set -uo pipefail
kubectl get pods -A -o json > /tmp/p.json
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
rows = []
per = collections.defaultdict(float)
perr = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName'); lc = lr = 0
    for c in p['spec'].get('containers', []):
        r = c.get('resources') or {}
        lc += cpu((r.get('limits') or {}).get('cpu'))
        lr += cpu((r.get('requests') or {}).get('cpu'))
    per[n] += lc
    perr[n] += lr
    if lc >= 500:
        rows.append((lc, lr, p['metadata']['namespace'], p['metadata']['name'], (n or '')[-6:]))
rows.sort(reverse=True)
print('=== limits.cpu >= 500m 的 Pod ===')
print('%-7s %-7s %-13s %-46s %s' % ('limit', 'req', 'NS', 'POD', 'NODE'))
for r in rows:
    print('%-7.0f %-7.0f %-13s %-46s %s' % r)
print()
print('=== 每节点 limits.cpu 合计（allocatable 3920m）===')
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)  requests=%5.0fm' % (n, per[n], per[n] / 3920 * 100, perr[n]))
PY
