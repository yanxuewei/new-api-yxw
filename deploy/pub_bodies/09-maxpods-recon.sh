#!/usr/bin/env bash
set -uo pipefail

echo "########## 1. 节点容量（含 maxPods 与机型）##########"
kubectl get nodes -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for n in d['items']:
    m = n['metadata']
    s = n.get('status', {})
    cap = s.get('capacity', {}); al = s.get('allocatable', {})
    lbl = m.get('labels', {})
    conds = [c['type'] for c in s.get('conditions', []) if c.get('status') == 'True']
    print('%-30s %-16s cpu=%s/%s mem=%s/%s pods=%s/%s  %s' % (
        m['name'], lbl.get('node.kubernetes.io/instance-type', '?'),
        al.get('cpu'), cap.get('cpu'), al.get('memory'), cap.get('memory'),
        al.get('pods'), cap.get('pods'), ','.join(conds)))
"

echo
echo "########## 2. 各节点 Pod 数 / requests ##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v)*1000
def mem(v):
    if not v: return 0
    v = str(v); u = {'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:])
    return float(v[:-2])*u if u else float(v)/1024/1024/1024
cnt = collections.Counter(); cr = collections.defaultdict(float); cm = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    n = p['spec'].get('nodeName'); cnt[n] += 1
    for c in p['spec'].get('containers', []):
        r = (c.get('resources') or {}).get('requests') or {}
        cr[n] += cpu(r.get('cpu')); cm[n] += mem(r.get('memory'))
for n in sorted(cnt):
    print('  %-30s pods=%2d  req.cpu=%6.0fm  req.mem=%.2fGi' % (n, cnt[n], cr[n], cm[n]))
"

echo
echo "########## 3. Terway 配置（决定 maxPods）##########"
kubectl -n kube-system get ds terway-eniip -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('  ds:', d['metadata']['name'])
for c in d['spec']['template']['spec']['containers']:
    print('  image:', c.get('image'))
    for e in (c.get('env') or []): print('    env %s=%s' % (e.get('name'), e.get('value')))
" 2>&1 | head -25
echo "--- terway cm ---"
kubectl -n kube-system get cm 2>&1 | grep -i terway
kubectl -n kube-system get cm eni-config -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k, v in (d.get('data') or {}).items():
    print('  %s = %s' % (k, v[:300]))
" 2>&1 | head -20

echo
echo "########## 4. 全部业务 Pod ##########"
kubectl get pods -A -o wide 2>&1 | grep -v -E 'kube-system|arms-prom' | head -20

echo
echo "########## 5. 节点实际用量 ##########"
kubectl top nodes 2>&1
