#!/bin/bash
# 任务 23 §十三-⑤：托管组件（ALB Ingress Controller）存活取证——只读
# 判据三级：lease holder/renewTime → EndpointSlice IP+AGE → 调谐产物（events / ALB 侧对象）
# 背景：任务 19 曾以"用户面无 alb workload"判定控制器未运行；本 body 证明该推断无效
set -o pipefail
K=${KUBECONFIG:-/tmp/k8s/kubeconfig}
export KUBECONFIG=$K

echo "=== 1) 用户面可见性（预期：全空，这不是缺失证据）==="
echo -n "  alb Pod 计数: "; kubectl get pods -A --no-headers 2>/dev/null | grep -ci 'alb'
echo -n "  alb deploy/ds/sts 计数: "; kubectl get deploy,ds,sts -A --no-headers 2>/dev/null | grep -ci 'alb'

echo "=== 2) lease（决定性：holder 是否为 controlplane-*）==="
for L in alb alb-gateway; do
  kubectl -n kube-system get lease "$L" -o jsonpath='{.metadata.name}{"\n  holder="}{.spec.holderIdentity}{"\n  renew="}{.spec.renewTime}{"\n  age="}{.metadata.creationTimestamp}{"\n"}' 2>/dev/null || echo "  lease/$L: NOT FOUND"
done
echo "  --- 顺带查 autoscaler 类 lease（任务 42 前置，同法）---"
kubectl get lease -A --no-headers 2>/dev/null | grep -iE 'autoscal|provision' | sed 's/^/    /' || echo "    （无 autoscaler lease）"
echo "    kube-system lease 全名单: $(kubectl -n kube-system get lease --no-headers 2>/dev/null | awk '{printf "%s ",$1}')"

echo "=== 3) EndpointSlice（IP + AGE 新鲜度）==="
kubectl -n kube-system get endpointslice -o wide --no-headers 2>/dev/null | grep -i alb | sed 's/^/  /'
for S in $(kubectl -n kube-system get endpointslice --no-headers 2>/dev/null | grep -i alb | awk '{print $1}'); do
  echo -n "  $S endpoints: "
  kubectl -n kube-system get endpointslice "$S" -o jsonpath='{range .endpoints[*]}{.addresses[*]}{" "}{.conditions.ready}{"; "}{end}' 2>/dev/null
  echo
done

echo "=== 4) cluster-autoscaler-status CM（§十三-③ 的补查项）==="
kubectl -n kube-system get cm cluster-autoscaler-status -o yaml 2>&1 | head -5 | sed 's/^/  /'

echo "=== 5) 调谐产物：最近 ingress/alb events ==="
kubectl -n new-api get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'ingress|alb|reconcil' | tail -6 | sed 's/^/  /'
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'albconfig|mnl-alb' | tail -4 | sed 's/^/  /'

echo "=== 6) 当前 Ingress 后端（切流结果留档）==="
kubectl -n new-api get ingest.networking.k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .spec.rules[*]}{.host}{" "}{range .http.paths[*]}{.backend.service.name}{":"}{.backend.service.port.number}{" "}{end}{end}{"\n"}{end}' 2>/dev/null | sed 's/^/  /'
echo "  endpoints/new-api-stable: $(kubectl -n new-api get endpoints new-api-stable --no-headers 2>/dev/null | awk '{print $3}')"
