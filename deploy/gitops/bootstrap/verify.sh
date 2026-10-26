#!/bin/bash
# verify.sh —— ArgoCD 落地只读体检（云助手 body）
echo "===1. ArgoCD 组件"
kubectl -n argocd get pods -o wide 2>&1 | sed 's/^/  /'
echo "===2. Application 状态"
kubectl -n argocd get app jkt-dev 2>&1 | sed 's/^/  /'
echo "--- sync/health/revision"
kubectl -n argocd get app jkt-dev -o jsonpath='  sync={.status.sync.status} health={.status.health.status} rev={.status.sync.revision}{"\n"}' 2>&1
echo "--- conditions / 错误信息"
kubectl -n argocd get app jkt-dev -o jsonpath='{range .status.conditions[*]}  [{.type}] {.message}{"\n"}{end}' 2>&1
echo "--- 目标镜像（ArgoCD 认为该用哪个）"
kubectl -n argocd get app jkt-dev -o jsonpath='{range .status.summary.images[*]}  {.}{"\n"}{end}' 2>&1
echo "===3. 与集群差异（前 40 行；空 = 无差异）"
kubectl -n argocd get app jkt-dev -o jsonpath='{.status.resources}' 2>/dev/null | tr ',' '\n' | head -0
kubectl -n argocd get app jkt-dev -o json 2>/dev/null | grep -o '"status":"OutOfSync"' | head -1
echo "===4. 资源占用"
kubectl -n argocd get deploy,sts -o custom-columns='KIND:.kind,NAME:.metadata.name,REQ_CPU:.spec.template.spec.containers[0].resources.requests.cpu,REQ_MEM:.spec.template.spec.containers[0].resources.requests.memory' 2>&1 | sed 's/^/  /'
echo "===5. 节点"
kubectl get nodes --no-headers 2>&1 | wc -l | sed 's/^/  节点数=/'
kubectl describe node 2>/dev/null | grep -E "^  (cpu|memory) " | sed 's/^/  /'
