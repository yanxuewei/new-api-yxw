#!/usr/bin/env bash
set -uo pipefail
echo "########## 节点与容量 ##########"
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type' 2>&1
echo
echo "########## 每节点 Pod 数 / requests ##########"
kubectl get pods -A -o json > /tmp/p.json 2>/dev/null
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
cnt = collections.Counter(); cr = collections.defaultdict(float); cm = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded', 'Failed'): continue
    n = p['spec'].get('nodeName'); cnt[n] += 1
    for c in p['spec'].get('containers', []):
        r = (c.get('resources') or {}).get('requests') or {}
        cr[n] += cpu(r.get('cpu')); cm[n] += mem(r.get('memory'))
tot_c = tot_m = 0
for n in sorted(cnt):
    print('  %-30s pods=%2d  req.cpu=%5.0fm  req.mem=%5.2fGi' % (n, cnt[n], cr[n], cm[n]))
    tot_c += cr[n]; tot_m += cm[n]
print('  TOTAL req.cpu=%.0fm  req.mem=%.2fGi' % (tot_c, tot_m))
PY
echo
echo "########## 数据盘实际用量 ##########"
df -h /var/lib/container 2>/dev/null | tail -2
echo "--- 各挂载 ---"
df -h 2>/dev/null | grep -E 'Filesystem|/var/lib|/data|/dev/vd|/dev/nvme' | head -8
