#!/usr/bin/env bash
# 第二轮：压 sidecar 容器的 limits.cpu（首轮只改了主容器）
set -uo pipefail

setc() {  # kind ns name container target
  echo "  $1/$2/$3 [$4] -> $5"
  kubectl -n "$2" set resources "$1/$3" -c "$4" --limits=cpu="$5" 2>&1 | grep -v '^Warning'
}

echo "########## csi-provisioner sidecar -> 100m ##########"
for c in external-disk-provisioner external-disk-attacher external-disk-resizer \
         external-csi-snapshotter external-snapshot-controller external-nas-provisioner \
         external-nas-resizer external-oss-provisioner external-oss-attacher; do
  setc deploy kube-system csi-provisioner "$c" 100m
done

echo
echo "########## csi-plugin registrar -> 100m ##########"
for c in disk-driver-registrar nas-driver-registrar oss-driver-registrar; do
  setc ds kube-system csi-plugin "$c" 100m
done

echo
echo "########## terway policy -> 200m ##########"
setc ds kube-system terway-eniip policy 200m

echo
echo "########## npd-eventer -> 200m ##########"
setc deploy kube-system ack-node-problem-detector-eventer eventer 200m

echo
echo "########## 等 150s ##########"
sleep 150
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
    if lc >= 800: rows.append((lc, p['metadata']['namespace'], p['metadata']['name']))
print('--- 每节点 limits.cpu ---')
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
print('\n--- 剩余 >=800m 的 Pod ---')
for r in sorted(rows, reverse=True): print('  %6.0fm  %-14s %s' % r)
PY
