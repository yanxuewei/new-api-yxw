#!/bin/bash
# 只读侦察：drain 选点 + HPA 现状 + 云助手执行位（providerID）
NS=new-api
echo "=== pods -n $NS -o wide ==="
kubectl -n $NS get pods -o wide --no-headers | awk '{printf "  %-52s %-9s r=%-3s %-8s ip=%-14s node=%s\n",$1,$3,$4,$5,$6,$7}'

echo "=== nodes: instance-type / zone / providerID / allocatable ==="
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels.node\.beta\.kubernetes\.io/instance-type}{"  "}{.metadata.labels.topology\.kubernetes\.io/zone}{"  "}{.spec.providerID}{"  "}{.status.allocatable.cpu}/{.status.allocatable.memory}{"\n"}{end}'

echo "=== 每节点已请求量 ==="
for N in $(kubectl get nodes -o name | sed 's#node/##'); do
  printf "  %-28s " "$N"
  kubectl describe node "$N" 2>/dev/null | awk '/Allocated resources/{f=1;next} f&&/^[[:space:]]*cpu[[:space:]]/{printf "cpu=%s(%s) ",$2,$3} f&&/^[[:space:]]*memory[[:space:]]/{printf "mem=%s(%s)\n",$2,$3}'
done

echo "=== HPA 现状 ==="
kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='  min={.spec.minReplicas} max={.spec.maxReplicas} target={.spec.metrics[0].resource.target.averageUtilization}% desired={.status.desiredReplicas} current={.status.currentReplicas}{"\n"}'

echo "=== PDB ==="
kubectl -n $NS get pdb pdb-new-api-stable -o wide --no-headers

echo "=== Ingress 后端 ==="
kubectl -n $NS get ingress new-api-verify -o jsonpath='  {range .spec.rules[*]}{.host}{" -> "}{range .http.paths[*]}{.path}{" = "}{.backend.service.name}{":"}{.backend.service.port.number}{"  "}{end}{"\n"}{end}'
echo "  events:"
kubectl -n $NS get events --field-selector involvedObject.name=new-api-verify --sort-by=.lastTimestamp 2>/dev/null | tail -4 | sed 's/^/    /'

echo "=== ResourceQuota ==="
kubectl -n $NS describe resourcequota new-api-quota 2>/dev/null | sed -n '/Usage/,+14p' | sed 's/^/  /'

echo "=== cluster-autoscaler ==="
kubectl get deploy -A 2>/dev/null | grep -i autoscal | sed 's/^/  /' || echo "  (未找到)"
kubectl -n kube-system get cm cluster-autoscaler-status -o yaml 2>/dev/null | grep -E "health:|scaleUpStatus|lastProcessedTime|nodeCount" | head -6 | sed 's/^/  /'

echo "=== 负载载体自检：stable Pod 内 sh/wget 可用性 ==="
SP=$(kubectl -n $NS get pods -l track=stable -o jsonpath='{.items[0].metadata.name}')
echo "  pod=$SP"
kubectl -n $NS exec "$SP" -- sh -c 'echo "    sh ok; wget=$(command -v wget || echo none); nproc=$(nproc)"' 2>&1 | sed 's/^/  /'
