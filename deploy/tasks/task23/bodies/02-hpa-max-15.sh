#!/bin/bash
# 裁定落地：HPA maxReplicas 16 -> 15（配额天花板，用户 2026-10-06 裁定）
NS=new-api
echo "=== before ==="
kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='  min={.spec.minReplicas} max={.spec.maxReplicas} target={.spec.metrics[0].resource.target.averageUtilization}% desired={.status.desiredReplicas} current={.status.currentReplicas}{"\n"}'
kubectl -n $NS patch hpa hpa-new-api-stable --type merge -p '{"spec":{"maxReplicas":15}}'
echo "=== after ==="
kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='  min={.spec.minReplicas} max={.spec.maxReplicas} target={.spec.metrics[0].resource.target.averageUtilization}% desired={.status.desiredReplicas} current={.status.currentReplicas}{"\n"}'
kubectl -n $NS get hpa hpa-new-api-stable

echo "=== ResourceQuota（配额口径复核）==="
kubectl -n $NS get resourcequota -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[]):
    print('  name=%s' % it['metadata']['name'])
    for k,v in sorted((it.get('status',{}) or {}).get('used',{}).items()):
        h=(it.get('spec',{}) or {}).get('hard',{}).get(k,'-')
        print('    %-28s used=%-10s hard=%s' % (k,v,h))
"

echo "=== cluster-autoscaler / 节点池伸缩位 ==="
kubectl get pods -A -o wide 2>/dev/null | grep -iE "autoscal|cluster-provisioner" | sed 's/^/  /' || echo "  (无 autoscaler Pod)"
kubectl get deploy -n kube-system 2>/dev/null | sed 's/^/  /' | head -20
echo "=== 节点调度状态 ==="
kubectl get nodes --no-headers | awk '{printf "  %-28s %s\n",$1,$2}'

