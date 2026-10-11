#!/bin/bash
# 21-webhook-probe.sh — 探 ALB Ingress Controller webhook 后端是否活
say() { printf '\n===== %s =====\n' "$*"; }

say "Ingress 描述（找 Events）"
kubectl -n new-api describe ingress new-api-verify 2>&1 | sed -n '1,200p'

say "webhook validatingwebhookconfiguration 详情"
kubectl get validatingwebhookconfiguration alb-ingress-controller -o yaml 2>&1 | grep -vE '^\s*(uid|resourceVersion|generation|managedFields|f:)' | head -50

say "webhook 后端 headless svc / endpointslice"
kubectl -n kube-system get svc alb-ingress-controller -o yaml 2>&1 | grep -vE '^\s*(uid|resourceVersion|managedFields|f:)' | head -30
kubectl -n kube-system get endpointslice -l kubernetes.io/service-name=alb-ingress-controller -o yaml 2>&1 | grep -E 'addresses|ready|creationTimestamp|name:|port:' | head -20

say "webhook 后端 IP 可达性（从节点探 9443）"
for ip in 7.8.229.211 7.8.72.26; do
  printf '  %-15s: ' "$ip"
  timeout 4 bash -c "cat < /dev/null > /dev/tcp/$ip/9443" 2>/dev/null && printf 'TCP-OPEN ' || printf 'TCP-FAIL '
  echo
done

say "若 webhook failurePolicy=Fail 且后端死 → 会阻塞 Ingress/AlbConfig 变更，验证："
kubectl -n new-api get ingress new-api-verify -o jsonpath='  ingress uid={.metadata.uid}{"\n"}' 2>&1

say "近期事件全量尾部（找 reconcile / alb）"
kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -25
echo; echo done
