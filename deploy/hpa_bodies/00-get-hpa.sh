#!/usr/bin/env bash
# 取 hpa-new-api-stable 全量实况（供 HPA 文档使用）
set -uo pipefail
NS=new-api

echo "########## 1. HPA 完整 spec ##########"
kubectl -n "$NS" get hpa hpa-new-api-stable -o yaml 2>&1

echo
echo "########## 2. HPA columns ##########"
kubectl -n "$NS" get hpa hpa-new-api-stable 2>&1
kubectl -n "$NS" get hpa hpa-new-api-stable -o custom-columns='MIN:.spec.minReplicas,MAX:.spec.maxReplicas,CUR:.status.currentReplicas,DESIRED:.status.desiredReplicas,TARGETS:.status.currentMetrics[*].resource.current.averageUtilization' 2>&1

echo
echo "########## 3. deployment 副本 + resources ##########"
kubectl -n "$NS" get deploy new-api-stable -o json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('parse fail', e); raise SystemExit
print('spec.replicas =', d['spec'].get('replicas'))
print('status.replicas =', d.get('status', {}).get('replicas'), '| ready =', d.get('status', {}).get('readyReplicas'))
for c in d['spec']['template']['spec']['containers']:
    r = c.get('resources', {}) or {}
    print('container %-20s requests=%s limits=%s' % (c.get('name'), r.get('requests'), r.get('limits')))
"

echo
echo "########## 4. 实时用量 ##########"
kubectl -n "$NS" top pods 2>&1 | head -20

echo
echo "########## 5. 节点 ##########"
kubectl get nodes 2>&1 | head -15

echo
echo "########## 6. HPA 事件（近）##########"
kubectl -n "$NS" describe hpa hpa-new-api-stable 2>&1 | sed -n '/Events:/,$p' | head -30
