#!/usr/bin/env bash
# 第五轮：csi-provisioner 主容器 500->200m，9 个 sidecar 100->50m
set -uo pipefail

echo "########## 改前 ##########"
kubectl -n kube-system get deploy csi-provisioner -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
t = 0
for c in d['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    l = (r.get('limits') or {}).get('cpu')
    print('  %-34s limits=%-6s requests=%s' % (c.get('name'), l, (r.get('requests') or {}).get('cpu')))
"

echo
echo "########## 执行 ##########"
kubectl -n kube-system set resources deploy/csi-provisioner -c csi-provisioner --limits=cpu=200m 2>&1 | grep -v '^Warning'
for c in external-disk-provisioner external-disk-attacher external-disk-resizer \
         external-csi-snapshotter external-snapshot-controller external-nas-provisioner \
         external-nas-resizer external-oss-provisioner external-oss-attacher; do
  kubectl -n kube-system set resources deploy/csi-provisioner -c "$c" --limits=cpu=50m 2>&1 | grep -v '^Warning'
done

echo
echo "########## 等 150s ##########"
sleep 150
kubectl -n kube-system get pods 2>&1 | grep -E 'csi-provisioner'
echo
echo "--- 全集群非 Running ---"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -6
echo "(空=正常)"

echo
echo "########## 终值 ##########"
kubectl get pods -A -o json > /tmp/p.json
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v) * 1000
per = collections.defaultdict(float)
rows = []
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName')
    lc = 0
    for c in p['spec'].get('containers', []):
        lc += cpu(((c.get('resources') or {}).get('limits') or {}).get('cpu'))
    per[n] += lc
    if lc >= 400: rows.append((lc, p['metadata']['namespace'], p['metadata']['name']))
print('--- 每节点 limits.cpu ---')
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
print('\n--- 剩余 >=400m 的 Pod ---')
for r in sorted(rows, reverse=True): print('  %6.0fm  %-14s %s' % r)
print('  (空=无)' if not rows else '')
PY
