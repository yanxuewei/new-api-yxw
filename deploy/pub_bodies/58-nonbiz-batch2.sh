#!/usr/bin/env bash
# 批2：DaemonSet 降 requests/limits（逐节点重建，terway 重建期间该节点新建 Pod 短暂无网络）
set -uo pipefail

python3 - <<'PY'
import subprocess

def kc(*a):
    p = subprocess.run(['kubectl'] + list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    return (p.stdout or p.stderr).strip()

JOBS = [
    # (ns, ds, container, req, limit)
    ('kube-system', 'terway-eniip',                          'policy',                    '50m', '500m'),
    ('kube-system', 'terway-eniip',                          'terway',                    '100m', '500m'),
    ('kube-system', 'ack-node-problem-detector-daemonset',   'ack-node-problem-detector', '20m', '200m'),
    ('kube-system', 'csi-plugin',                            'csi-plugin',                '50m', '500m'),
    ('kube-system', 'kube-proxy-worker',                     'kube-proxy-worker',         '50m', '0'),
    ('kube-system', 'logtail-ds',                            '',                          '50m', '500m'),
    ('arms-prom',   'node-exporter',                         'node-exporter',             '20m', '200m'),
]
for ns, ds, c, req, lim in JOBS:
    if not kc('-n', ns, 'get', 'ds', ds):
        print('  [skip] %s/%s' % (ns, ds)); continue
    cc = c or kc('-n', ns, 'get', 'ds', ds, '-o', 'jsonpath={.spec.template.spec.containers[0].name}')
    args = ['-n', ns, 'set', 'resources', 'ds/' + ds, '-c', cc, '--requests=cpu=' + req]
    if lim != '0':
        args.append('--limits=cpu=' + lim)
    out = kc(*args)
    print('  ds %-40s [%-26s] req=%-5s lim=%-6s %s' % (ds, cc, req, lim, '' if 'updated' in out else out[:40]))

# csi-plugin 其余 registrar
for x in ('disk-driver-registrar', 'nas-driver-registrar', 'oss-driver-registrar'):
    out = kc('-n', 'kube-system', 'set', 'resources', 'ds/csi-plugin', '-c', x, '--limits=cpu=100m')
    print('  csi-plugin[%-24s] lim=100m' % x)
PY

echo
echo "########## 等 150s（DaemonSet 逐节点滚动）##########"
sleep 150
kubectl get ds -A 2>&1 | grep -E 'NAME|terway|csi-plugin|kube-proxy|logtail-ds|node-problem|node-exporter'
echo
echo "--- 非 Running ---"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -6
echo "(空=正常)"
echo
echo "########## 非业务合计 ##########"
kubectl get pods -A -o json 2>/dev/null > /tmp/p.json
python3 - <<'PY'
import json, collections
d = json.load(open('/tmp/p.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
ds = collections.defaultdict(float); cnt = collections.Counter(); other = 0.0
for p in d.get('items', []):
    if p['metadata']['namespace'] == 'new-api': continue
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    o = (p['metadata'].get('ownerReferences') or [{}])[0]
    c = sum(cpu(((ct.get('resources') or {}).get('requests') or {}).get('cpu')) for ct in p['spec'].get('containers', []))
    if o.get('kind') == 'DaemonSet':
        ds[o.get('name')] += c; cnt[o.get('name')] += 1
    else: other += c
per = sum(v / cnt[k] for k, v in ds.items())
print('  每台 DaemonSet = %.0fm' % per)
print('  非 DaemonSet   = %.0fm' % other)
PY
