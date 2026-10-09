#!/bin/bash
# 20-controller-trace.sh — 取证 ALB Ingress Controller 是否仍在 reconcile
say() { printf '\n===== %s =====\n' "$*"; }

say "Ingress new-api-verify 事件"
kubectl -n new-api describe ingress new-api-verify 2>&1 | tail -25

say "全集群事件（近 30 条，含 alb/ingress 关键字）"
kubectl get events -A --sort-by=.lastTimestamp 2>&1 | grep -iE "alb|ingress|servergroup" | tail -20
echo "(空 = 无近期控制器事件)"

say "Service new-api-stable 注解（控制器会加 lock/attached 注解）"
kubectl -n new-api get svc new-api-stable -o yaml 2>&1 | grep -A20 "annotations:" | head -25

say "Service new-api-stable 事件"
kubectl -n new-api describe svc new-api-stable 2>&1 | tail -15

say "EndpointSlice for new-api-stable（控制器 watch 的对象）"
kubectl -n new-api get endpointslice -l kubernetes.io/service-name=new-api-stable 2>&1
kubectl -n new-api get endpointslice -l kubernetes.io/service-name=new-api-stable -o jsonpath='{range .items[*]}{.metadata.name}{"  created="}{.metadata.creationTimestamp}{"  managedBy="}{.metadata.labels.endpointslice\.kubernetes\.io/managed-by}{"\n"}{range .endpoints[*]}    {.addresses[0]}  ready={.conditions.ready}{"\n"}{end}{end}' 2>&1

say "webhook 配置（控制器活着才有）"
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration 2>&1 | grep -i alb || echo "  (无 alb webhook)"

say "AlbConfig mnl-alb 详情"
kubectl -n new-api get albconfig mnl-alb -o yaml 2>&1 | grep -vE '^\s*(uid|resourceVersion|generation|managedFields|f:)' | head -45
echo; echo done
