#!/usr/bin/env bash
# 节点资源画像：谁占了 requests/limits，为什么 used 这么低
set -uo pipefail

echo "########## 1. 节点容量 ##########"
kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU_ALLOC:.status.allocatable.cpu,MEM_ALLOC:.status.allocatable.memory,PODS_ALLOC:.status.allocatable.pods,CPU_CAP:.status.capacity.cpu,MEM_CAP:.status.capacity.memory,TAINTS:.spec.taints[*].key' 2>&1

echo
echo "########## 2. 各节点 Pod 数 ##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
c = collections.Counter()
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    c[p['spec'].get('nodeName')] += 1
for n, v in sorted(c.items()):
    print('  %-32s %d pods' % (n, v))
"

echo
echo "########## 3. 每节点 requests/limits 汇总（按 namespace 拆）##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v=str(v)
    if v.endswith('m'): return int(v[:-1])
    return float(v)*1000
def mem(v):
    if not v: return 0
    v=str(v); u={'Ki':1/1024/1024,'Mi':1/1024,'Gi':1}.get(v[-2:],None)
    if u: return float(v[:-2])*u
    try: return float(v)/1024/1024/1024
    except: return 0
per = collections.defaultdict(lambda: collections.defaultdict(lambda: [0.0,0.0,0.0,0.0,0]))
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    n = p['spec'].get('nodeName') or '(未调度)'
    r = per[n][p['metadata'].get('namespace')]
    r[4] += 1
    for c in p['spec'].get('containers', []):
        res = c.get('resources') or {}
        r[0] += cpu((res.get('requests') or {}).get('cpu'))
        r[1] += cpu((res.get('limits') or {}).get('cpu'))
        r[2] += mem((res.get('requests') or {}).get('memory'))
        r[3] += mem((res.get('limits') or {}).get('memory'))
for n in sorted(per):
    print('== %s' % n)
    t=[0,0,0,0,0]
    for ns, r in sorted(per[n].items()):
        print('   %-22s pods=%-3d req.cpu=%-6.0fm lim.cpu=%-6.0fm req.mem=%-5.2fGi lim.mem=%-5.2fGi' % (ns, r[4], r[0], r[1], r[2], r[3]))
        for i in range(5): t[i]+=r[i]
    print('   %-22s pods=%-3d req.cpu=%-6.0fm lim.cpu=%-6.0fm req.mem=%-5.2fGi lim.mem=%-5.2fGi' % ('-- 合计 --', t[4], t[0], t[1], t[2], t[3]))
"

echo
echo "########## 4. 全部 Pod 明细 ##########"
kubectl get pods -A -o wide 2>&1 | head -40

echo
echo "########## 5. 实际用量 top ##########"
kubectl top nodes 2>&1
echo "--- top pods ---"
kubectl top pods -A 2>&1 | head -25
