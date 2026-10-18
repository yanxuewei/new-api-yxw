#!/usr/bin/env bash
#"非业务 Pod 资源盘点：requests / limits / 实际用量
set -uo pipefail
echo "########## 非 new-api Pod 资源（按 requests.cpu 降序）##########"
kubectl get pods -A -o json 2>/dev/null > /tmp/p.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
def mem(v):
    if not v: return 0
    v = str(v); u = {'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:])
    return float(v[:-2])*u if u else float(v)/1024/1024/1024
rows = []
for p in d.get('items', []):
    ns = p['metadata']['namespace']
    if ns == 'new-api':
        continue
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    o = (p['metadata'].get('ownerReferences') or [{}])[0]
    kind = o.get('kind', '?'); oname = o.get('name', '')
    rc = rl = rm = lm = 0.0
    multi = len(p['spec'].get('containers', []))
    for c in p['spec'].get('containers', []):
        r = c.get('resources') or {}
        rc += cpu((r.get('requests') or {}).get('cpu'))
        rl += cpu((r.get('limits') or {}).get('cpu'))
        rm += mem((r.get('requests') or {}).get('memory'))
        lm += mem((r.get('limits') or {}).get('memory'))
    rows.append((rc, rl, rm, lm, ns, kind, oname, p['metadata']['name'], multi))
rows.sort(reverse=True)
print('%-6s %-7s %-13s %-40s %-4s' % ('req', 'limit', 'NS', 'OWNER', '容器'))
for rc, rl, rm, lm, ns, kind, on, pn, mc in rows:
    print('%-6.0f %-7.0f %-13s %-40s %d' % (rc, rl, ns, (kind[:8] + '/' + on)[:40], mc))
print()
print('合计 requests.cpu = %.0fm' % sum(r[0] for r in rows))
print('合计 limits.cpu   = %.0fm' % sum(r[1] for r in rows))
PY
echo
echo "########## 实际用量 top 15 ##########"
kubectl top pods -A --sort-by=cpu 2>&1 | head -16
