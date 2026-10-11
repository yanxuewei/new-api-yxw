#!/bin/bash
# 任务 23 追加（只读）：06 body 的两处遗留 —— ①`ingest` 短名在本集群不可用（需全名）②goatscaler holder Pod 在用户面是否可见
set -o pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}

echo "=== A) Ingress 后端（用全名 inresses.networking.k8s.io）==="
kubectl -n new-api get ingresses.networking.k8s.io new-api-verify -o jsonpath='{range .spec.rules[*]}{.host}{"  "}{range .http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"  "}{end}{"\n"}{end}' 2>&1
echo "  albclass/ingressclass: $(kubectl -n new-api get ingresses.networking.k8s.io new-api-verify -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)"
echo "  addresses: $(kubectl -n new-api get ingresses.networking.k8s.io new-api-verify -o jsonpath='{.status.loadBalancer.ingress[*].hostname}' 2>/dev/null)"

echo "=== B) goatscaler holder Pod 是否在用户面可见 ==="
echo -n "  pods -A 含 goat 计数: "; kubectl get pods -A --no-headers 2>/dev/null | grep -ci goat
kubectl get pods -A -o wide --no-headers 2>/dev/null | grep -i goat | sed 's/^/    /'
echo "  （0 = Pod 跑在 ACK 托管侧，用户面只有 lease/cm 痕迹，与 alb 同构）"

echo "=== C) kube-system/cm/autoscaler-meta（弹性组件的自有状态，替代 cluster-autoscaler-status）==="
kubectl -n kube-system get cm autoscaler-meta -o jsonpath='{.data}' 2>&1 | head -c 1200
echo
echo "  --- 节点池弹性配置（CS API 侧，只读）---"

echo "=== D) stable HPA/PDB 现状快照（本卡收口口径）==="
kubectl -n new-api get hpa hpa-new-api-stable -o jsonpath='{"  min="}{.spec.minReplicas}{" max="}{.spec.maxReplicas}{" target="}{.spec.metrics[0].resource.target.averageUtilization}{" cur="}{.status.currentReplicas}{" des="}{.status.desiredReplicas}{"\n"}' 2>&1
kubectl -n new-api get pdb pdb-new-api-stable -o jsonpath='{"  minAvailable="}{.spec.minAvailable}{"  status="}{.status}{"\n"}' 2>&1
echo -n "  pods(stable): "; kubectl -n new-api get pods -l app=new-api,track=stable --no-headers 2>/dev/null | awk '{printf "%s ",$7}'
echo
