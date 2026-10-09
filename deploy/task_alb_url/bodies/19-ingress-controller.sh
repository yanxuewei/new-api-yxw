#!/bin/bash
# 19-ingress-controller.sh — 查 Ingress 归属 + ALB Ingress Controller 实况
say() { printf '\n===== %s =====\n' "$*"; }

say "全集群 Ingress"
kubectl get ingress -A -o wide 2>&1

say "Ingress 详情（backend 指向哪个 svc）"
for NS in $(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u); do
  for N in $(kubectl -n "$NS" get ingress -o name 2>/dev/null); do
    echo "--- $NS/$N ---"
    kubectl -n "$NS" get "$N" -o jsonpath='{.spec.rules[*].host}{"  ->  "}{.spec.rules[*].http.paths[*].backend.service.name}{":"}{.spec.rules[*].http.paths[*].backend.service.port.number}{"\n"}' 2>&1
    kubectl -n "$NS" get "$N" -o jsonpath='  ingressClass={.spec.ingressClassName}{"\n"}  albconfig={.metadata.annotations.albconfig}{"\n"}' 2>&1
  done
done

say "ALB Ingress Controller 实况（Pod / Deploy / DaemonSet）"
kubectl get pods -A 2>&1 | grep -i alb || echo "  (无 alb pod)"
kubectl get deploy,ds -A 2>&1 | grep -i alb || echo "  (无 alb deploy/ds)"
echo "--- 残留 service/endpointslice ---"
kubectl get svc,ep -A 2>&1 | grep -i alb || echo "  (无)"
kubectl get endpointslice -A 2>&1 | grep -i alb || echo "  (无)"

say "AlbConfig"
kubectl get albconfig -A -o wide 2>&1

say "IngressClass"
kubectl get ingressclass 2>&1

say "当前 stable Pod IP（与服务器组比对）"
kubectl -n new-api get pods -l app=new-api,track=stable -o jsonpath='{range .items[*]}{.status.podIP}{"  "}{.status.podIPs[0].ip}{"  "}{.metadata.name}{"\n"}{end}' 2>&1
echo "--- 对应 ENI ---"
kubectl -n new-api get pods -l app=new-api,track=stable -o jsonpath='{range .items[*]}{.metadata.name}{"  anno-eni="}{.metadata.annotations.k8s\.aliyun\.com/allocated-eni-id}{"\n"}{end}' 2>&1
echo; echo done
