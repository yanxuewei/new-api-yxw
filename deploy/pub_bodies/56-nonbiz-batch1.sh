#!/usr/bin/env bash
# 批1：非业务 Deployment/StatefulSet 降 requests/limits + 下线冗余副本
set -uo pipefail

echo "########## 改前合计 ##########"
kubectl get pods -A -o json 2>/dev/null > /tmp/p0.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/p0.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
r = l = 0.0
for p in d.get('items', []):
    if p['metadata']['namespace'] == 'new-api': continue
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    for c in p['spec'].get('containers', []):
        x = c.get('resources') or {}
        r += cpu((x.get('requests') or {}).get('cpu')); l += cpu((x.get('limits') or {}).get('cpu'))
print('  req=%.0fm  limits=%.0fm' % (r, l))
PY

echo
echo "########## 执行 ##########"
python3 - <<'PY'
import subprocess, json

def kc(*a):
    p = subprocess.run(['kubectl'] + list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    return (p.stdout or p.stderr).strip()

# (kind, ns, name, req, limit)   container 自动取第一个
JOBS = [
    ('deploy',      'arms-prom',  'arms-prometheus-ack-arms-prometheus', '200m',  '1000m'),
    ('deploy',      'kube-system','metrics-server',                      '50m',   '500m'),
    ('deploy',      'kube-system','gatekeeper',                          '20m',   '300m'),
    ('deploy',      'kube-system','storage-operator',                    '20m',   '200m'),
    ('deploy',      'kube-system','policy-template-controller',          '20m',   '100m'),
    ('deploy',      'kube-system','ack-kubernetes-cronhpa-controller',   '20m',   '100m'),
    ('deploy',      'kube-system','ack-node-problem-detector-eventer',   '20m',   '200m'),
    ('deploy',      'kube-system','ack-pod-identity-webhook',            '50m',   '200m'),
    ('deploy',      'kube-system','coredns',                             '50m',   '0'),
    ('statefulset', 'kube-system','logtail-statefulset',                 '50m',   '500m'),
    ('deploy',      'arms-prom',  'o11y-addon-controller',               '10m',   '200m'),
    ('deploy',      'arms-prom',  'kube-state-metrics',                  '10m',   '200m'),
    ('deploy',      'kube-system','alicloud-monitor-controller',         '10m',   '200m'),
]
for kind, ns, name, req, lim in JOBS:
    if not kc('-n', ns, 'get', kind, name):
        print('  [skip] %s/%s/%s' % (kind, ns, name)); continue
    c = kc('-n', ns, 'get', kind, name, '-o', 'jsonpath={.spec.template.spec.containers[0].name}')
    args = ['-n', ns, 'set', 'resources', '%s/%s' % (kind, name), '-c', c, '--requests=cpu=' + req]
    if lim != '0':
        args.append('--limits=cpu=' + lim)
    out = kc(*args)
    print('  %-13s %-38s -> req=%-5s lim=%-6s %s' % (kind, name, req, lim, '' if 'updated' in out else out[:40]))

print()
# csi-provisioner 全容器
c = kc('-n','kube-system','get','deploy','csi-provisioner','-o','jsonpath={range .spec.template.spec.containers[*]}{.name}{"\\n"}{end}').split('\n')
for x in c:
    x = x.strip()
    if not x: continue
    lim = '500m' if x == 'csi-provisioner' else '100m'
    out = kc('-n','kube-system','set','resources','deploy/csi-provisioner','-c',x,'--limits=cpu=' + lim)
    print('  csi-provisioner[%-30s] lim=%s' % (x, lim))

print()
# 副本缩减
for ns, name, rep in (('kube-system','ack-koord-manager',0), ('kube-system','ack-cost-exporter',0),
                      ('kube-system','gatekeeper',1), ('kube-system','ack-pod-identity-webhook',2)):
    print('  scale %-32s -> %d : %s' % (name, rep, kc('-n', ns, 'scale', 'deploy', name, '--replicas=%d' % rep)[:60]))
PY

echo
echo "########## 等 90s ##########"
sleep 90
echo "--- 非 Running ---"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -8
echo "(空=正常)"
echo
echo "########## 改后合计 ##########"
kubectl get pods -A -o json 2>/dev/null > /tmp/p1.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/p1.json'))
def cpu(v):
    if not v: return 0
    v = str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
r = l = 0.0; n = 0
for p in d.get('items', []):
    if p['metadata']['namespace'] == 'new-api': continue
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    n += 1
    for c in p['spec'].get('containers', []):
        x = c.get('resources') or {}
        r += cpu((x.get('requests') or {}).get('cpu')); l += cpu((x.get('limits') or {}).get('cpu'))
print('  pods=%d req=%.0fm  limits=%.0fm' % (n, r, l))
PY
