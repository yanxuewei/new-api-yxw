#!/usr/bin/env bash
# 诊断 newapi-dev 命名空间 ResourceQuota 超限（Pod 创建被拒）
set -uo pipefail
NS=newapi-dev

echo "########## 1. ResourceQuota 定义 ##########"
kubectl -n "$NS" get resourcequota -o yaml 2>&1 | head -80

echo
echo "########## 2. ResourceQuota 用量（describe）##########"
kubectl -n "$NS" describe resourcequota 2>&1 | head -60

echo
echo "########## 3. LimitRange（是否注入默认 requests/limits）##########"
kubectl -n "$NS" get limitrange -o yaml 2>&1 | head -60

echo
echo "########## 4. 全部 Pod（谁在占配额）##########"
kubectl -n "$NS" get pods -o wide 2>&1

echo
echo "########## 5. 逐 Pod 资源明细 + 汇总 ##########"
kubectl -n "$NS" get pods -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
def to_m(v):
    if not v: return 0
    v = str(v)
    if v.endswith('m'): return int(v[:-1])
    if v.endswith('Ki'): return int(v[:-2]) / 1024 / 1024
    if v.endswith('Mi'): return int(v[:-2]) / 1024
    if v.endswith('Gi'): return int(v[:-2])
    try: return float(v) * 1000
    except: return 0
tc = tl = tmcr = tmlr = 0.0
rows = []
for p in d.get('items', []):
    phase = p.get('status', {}).get('phase')
    cr = cl = mr = ml = 0.0
    for c in p['spec'].get('containers', []):
        r = c.get('resources') or {}
        cr += to_m((r.get('requests') or {}).get('cpu'))
        cl += to_m((r.get('limits') or {}).get('cpu'))
        mr += to_m((r.get('requests') or {}).get('memory'))
        ml += to_m((r.get('limits') or {}).get('memory'))
    rows.append((p['metadata']['name'], phase, cr, cl, mr, ml))
    if phase not in ('Succeeded', 'Failed'):
        tc += cr; tl += cl; tmcr += mr; tmlr += ml
for n, ph, cr, cl, mr, ml in rows:
    print('  %-46s %-10s req.cpu=%-6.0fm lim.cpu=%-6.0fm req.mem=%-6.2fGi lim.mem=%-6.2fGi' % (n, ph, cr, cl, mr, ml))
print()
print('  [计入配额的总和] requests.cpu=%dm  limits.cpu=%dm  requests.mem=%.2fGi  limits.mem=%.2fGi' % (tc, tl, tmcr, tmlr))
"

echo
echo "########## 6. Deployment / RS ##########"
kubectl -n "$NS" get deploy -o wide 2>&1
echo "--- rs ---"
kubectl -n "$NS" get rs -o wide 2>&1

echo
echo "########## 7. 当前失败 Deployment 的 spec ##########"
kubectl -n "$NS" get deploy yxw-new-api-master -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('replicas       =', d['spec'].get('replicas'), '| ready =', d.get('status', {}).get('readyReplicas'))
print('strategy       =', json.dumps(d['spec'].get('strategy'), ensure_ascii=False))
print('generation     =', d['metadata'].get('generation'))
for c in d['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('container %-12s image=%s' % (c.get('name'), c.get('image')))
    print('   requests=%s limits=%s' % (r.get('requests'), r.get('limits')))
print('revision =', (d['metadata'].get('annotations') or {}).get('deployment.kubernetes.io/revision'))
"

echo
echo "########## 8. 节点 allocatable ##########"
kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods' 2>&1

echo
echo "########## 9. 命名空间事件（近 20）##########"
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -20
