#!/usr/bin/env bash
# 第三轮：csi-provisioner 主容器 / arms-prometheus 各降到 500m
set -uo pipefail

echo "########## 改前 ##########"
for x in "kube-system csi-provisioner csi-provisioner" "arms-prom arms-prometheus-ack-arms-prometheus arms-prometheus-operator"; do
  set -- $x
  printf '  %s/%s [%s] limits=%s requests=%s\n' "$1" "$2" "$3" \
    "$(kubectl -n "$1" get deploy "$2" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$3\")].resources.limits.cpu}")" \
    "$(kubectl -n "$1" get deploy "$2" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$3\")].resources.requests.cpu}")"
done

echo
echo "########## 执行 ##########"
kubectl -n kube-system set resources deploy/csi-provisioner -c csi-provisioner --limits=cpu=500m 2>&1 | grep -v '^Warning'
kubectl -n arms-prom set resources deploy/arms-prometheus-ack-arms-prometheus -c arms-prometheus-operator --limits=cpu=500m 2>&1 | grep -v '^Warning'

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
    if lc >= 600: rows.append((lc, p['metadata']['namespace'], p['metadata']['name']))
print('--- 每节点 limits.cpu ---')
for n in sorted(per):
    print('  %-30s limits=%6.0fm (%3.0f%%)' % (n, per[n], per[n] / 3920 * 100))
print('\n--- 剩余 >=600m 的 Pod ---')
for r in sorted(rows, reverse=True): print('  %6.0fm  %-14s %s' % r)
print('  (空=无)' if not rows else '')
PY
