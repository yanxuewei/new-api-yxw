#!/bin/bash
# 只读：核查 ALB Ingress Controller 相关资源（集群内实况）
say() { printf '\n===== %s =====\n' "$*"; }

say "全 ns 含 alb 关键字的 deploy/ds/sts"
kubectl get deploy,ds,sts -A 2>/dev/null | grep -i -E "alb|ingress" || echo "  (none)"

say "全 ns 含 alb 的 pod"
kubectl get pods -A -o wide 2>/dev/null | grep -i -E "alb|ingress" || echo "  (none)"

say "AlbConfig / AlbConfigClass CRD 实况"
kubectl get albconfigs -A 2>&1
echo "--- CRD 列表 ---"
kubectl get crd 2>/dev/null | grep -i -E "alb|alibaba" || echo "  (no alb crd)"

say "mnl-alb AlbConfig 全文"
kubectl -n kube-system get albconfig mnl-alb -o yaml 2>&1 | head -80

say "IngressClass alb 详情"
kubectl get ingressclass alb -o yaml 2>&1 | head -30

say "kube-system 里所有 deploy（找 controller 痕迹）"
kubectl -n kube-system get deploy -o wide 2>&1

say "事件：最近 alb 相关"
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -i alb | tail -15 || echo "  (none)"
echo; echo "done"
