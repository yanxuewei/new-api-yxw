#!/bin/bash
# 任务 23 · 只读侦察（mnl）：容量 / 前置 / 现值 —— 不写任何资源
set -u
NS=new-api
echo "== 1) 节点：AZ / allocatable / 可调度 =="
kubectl get nodes -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,STATUS:.spec.unschedulable,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' 2>/dev/null
echo
echo "== 2) kube-system 关键组件（HPA 指标 / 弹性伸缩 / ALB）=="
kubectl -n kube-system get deploy,ds -o wide 2>/dev/null | awk 'NR==1 || /metrics-server|ack-arms|prometheus|autoscaler|alb|terway|credential-helper/'
echo "  --- kubectl top nodes（metrics-server 可用性判据）---"
kubectl top nodes 2>&1 | head -8
echo
echo "== 3) $NS 现状 =="
kubectl -n $NS get deploy,rs,pod,svc,endpoints,ingress,pdb,hpa,sa -o wide 2>/dev/null | sed 's/^/  /'
echo
echo "== 4) Ingress / ALB =="
kubectl -n $NS get ingress -o jsonpath='{range .items[*]}{.metadata.name}{" class="}{.spec.ingressClassName}{" rules="}{.spec.rules[*].host}{" backend="}{.spec.rules[*].http.paths[*].backend.service.name}{"\n"}{end}' 2>/dev/null
kubectl get ingressclass 2>/dev/null
kubectl -n $NS get albconfig 2>/dev/null
echo
echo "== 5) ResourceQuota 已用量 =="
kubectl -n $NS get resourcequota -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for it in d.get('items',[]):
    s=it.get('status',{})
    print(' ', it['metadata']['name'])
    for scope in ('hard','used'):
        print('   ', scope, json.dumps(s.get(scope,{}), sort_keys=True))
"
echo
echo "== 6) ConfigMap 现值（无密钥）/ Secret 键名 =="
kubectl -n $NS get cm new-api-config -o jsonpath='{.data}' 2>/dev/null | python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
for k in sorted(d): print('   %-28s = %s' % (k, d[k]))
print('   CM_KEYS=%d' % len(d))
"
kubectl -n $NS get secret new-api-secrets -o jsonpath='{.data}' 2>/dev/null | python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print('   SECRET_KEYS(%d) = %s' % (len(d), ' '.join(sorted(d))))
"
echo
echo "== 7) master Deployment：镜像 / 节点 / 资源 =="
kubectl -n $NS get deploy new-api-master -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['spec']['template']['spec']['containers'][0]
print('   image      =', c['image'])
print('   pullPolicy =', c.get('imagePullPolicy'))
print('   resources  =', json.dumps(c.get('resources',{})))
print('   replicas   =', d['spec']['replicas'], 'ready=', d['status'].get('readyReplicas'))
print('   labels     =', json.dumps(d['spec']['template']['metadata'].get('labels',{})))
print('   SA         =', d['spec']['template']['spec'].get('serviceAccountName'))
"
echo "  --- 实际落点 ---"
kubectl -n $NS get pod -o wide 2>/dev/null | awk 'NR==1 || /new-api-master/'
echo
echo "== 8) 探针路径校验：容器内 GET /api/status =="
POD=$(kubectl -n $NS get pod -l app=new-api-migrate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${POD:-}" ]; then
  kubectl -n $NS exec "$POD" -- sh -c 'command -v curl >/dev/null 2>&1 && curl -sS -m 5 -o /tmp/st.json -w "%{http_code}\n" http://127.0.0.1:3000/api/status || (wget -q -T 5 -O /tmp/st.json http://127.0.0.1:3000/api/status && echo "wget-OK")' 2>&1 | tail -3
  kubectl -n $NS exec "$POD" -- sh -c 'head -c 220 /tmp/st.json 2>/dev/null; echo' 2>&1 | tail -3
else
  echo "  (无 master Pod，跳过)"
fi
echo
echo "== 9) 每节点已请求 CPU/MEM（容量余量口径）=="
kubectl get pods -A -o json > /tmp/t23_pods.json 2>/dev/null
kubectl get nodes -o json > /tmp/t23_nodes.json 2>/dev/null
python3 - <<'PY'
import json


def n2v(x):
    if x in (None, ''):
        return 0.0
    x = str(x)
    if x.endswith('m'):
        return float(x[:-1]) / 1000
    for suf, f in (('Mi', 1.0), ('Gi', 1024.0), ('Ki', 1 / 1024)):
        if x.endswith(suf):
            return float(x[:-len(suf)]) * f
    for suf, f in (('M', 1e6 / 1048576), ('G', 1000 ** 3 / 1048576)):
        if x.endswith(suf):
            return float(x[:-len(suf)]) * f
    try:
        return float(x) / 1048576
    except ValueError:
        return 0.0


pods = json.load(open('/tmp/t23_pods.json'))
nodes = json.load(open('/tmp/t23_nodes.json'))
agg = {}
for p in pods.get('items', []):
    if p.get('status', {}).get('phase') not in ('Running', 'Pending'):
        continue
    nn = (p.get('spec') or {}).get('nodeName')
    if not nn:
        continue
    cs = (p['spec'].get('containers') or []) + (p['spec'].get('initContainers') or [])
    for c in cs:
        q = (c.get('resources') or {}).get('requests') or {}
        a = agg.setdefault(nn, [0.0, 0.0])
        a[0] += n2v(q.get('cpu'))
        a[1] += n2v(q.get('memory'))
for n in nodes.get('items', []):
    nn = n['metadata']['name']
    al = n.get('status', {}).get('allocatable', {})
    cpu, mem = n2v(al.get('cpu')), n2v(al.get('memory'))
    u = agg.get(nn, [0.0, 0.0])
    zone = n['metadata'].get('labels', {}).get('topology.kubernetes.io/zone', '?')
    print('  %-28s %s  cpu %6.2f/%6.2f free %6.2f | mem %5.0f/%5.0f MiB free %5.0f | 还能放 %d 个 2C Pod'
          % (nn, zone, u[0], cpu, cpu - u[0], u[1], mem, mem - u[1], int((cpu - u[0]) // 2)))
PY
rm -f /tmp/t23_pods.json /tmp/t23_nodes.json
echo "== 10) 事件（近 30 条，看调度/配额/镜像拉取异常）=="
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | tail -30
echo PRECHECK-DONE
