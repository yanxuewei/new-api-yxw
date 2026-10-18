#!/usr/bin/env bash
set -uo pipefail
kubectl get pods -A -o json 2>/dev/null > /tmp/p.json
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
def mem(v):
    if not v: return 0
    v = str(v); u = {'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:])
    return float(v[:-2])*u if u else float(v)/1024/1024/1024
ds = collections.defaultdict(lambda: [0.0, 0.0, 0])   # name -> [cpu, mem, count]
other = [0.0, 0.0]
nodes = set()
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName')
    nodes.add(n)
    owner = (p['metadata'].get('ownerReferences') or [{}])[0]
    c = m = 0.0
    for ct in p['spec'].get('containers', []):
        r = (ct.get('resources') or {}).get('requests') or {}
        c += cpu(r.get('cpu')); m += mem(r.get('memory'))
    if owner.get('kind') == 'DaemonSet':
        key = owner.get('name')
        ds[key][0] += c; ds[key][1] += m; ds[key][2] += 1
    else:
        other[0] += c; other[1] += m
print('=== DaemonSet（每份，复制到每台节点）===')
tot_ds = 0.0
for k, v in sorted(ds.items(), key=lambda x: -x[1][0]):
    per = v[0] / v[2] if v[2] else 0
    tot_ds += per
    print('  %-46s 单份=%5.0fm  副本=%d  合计=%5.0fm' % (k, per, v[2], v[0]))
print('  >>> 每台节点 DaemonSet 开销 = %.0fm' % tot_ds)
print()
print('=== 非 DaemonSet（单实例/多副本，不随节点数变化）===')
print('  req.cpu=%.0fm  req.mem=%.2fGi' % (other[0], other[1]))
print()
for k in (2, 3, 4):
    print('  缩到 %d 台：需要 %.0fm（= %.0f×%d + %.0f），allocatable %dm' % (
        k, tot_ds * k + other[0], tot_ds, k, other[0], 7910 * k))
PY
