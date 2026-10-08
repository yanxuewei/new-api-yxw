#!/bin/bash
# 22-webhook-live-test.sh — server-side dry-run 验 webhook 后端是否活（零副作用）
say() { printf '\n===== %s =====\n' "$*"; }

say "探针1：Ingress server-side dry-run（会走 admission webhook）"
timeout 40 kubectl -n new-api annotate ingress new-api-verify probe-20261006=1 --dry-run=server --overwrite 2>&1 | head -8

say "探针2：AlbConfig server-side dry-run"
timeout 40 kubectl -n new-api annotate albconfig mnl-alb probe-20261006=1 --dry-run=server --overwrite 2>&1 | head -8

say "探针3：真实只读 GET（对照，不走 webhook）"
kubectl -n new-api get ingress new-api-verify -o jsonpath='  ok name={.metadata.name}{"\n"}' 2>&1

say "kube-system 全部 deploy/ds（找 alb controller 任何形态）"
kubectl -n kube-system get deploy,ds,sts 2>&1

say "全集群按镜像名找 alb"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | grep -iE "alb|ingress" || echo "  (无任何 pod 用 alb/ingress 镜像)"

say "节点上有没有 hostNetwork 的 controller（进程级）"
ps -ef 2>/dev/null | grep -iE "alb|ingress-controller" | grep -v grep || echo "  (节点上无 alb 进程)"

say "kubelet 静态 pod / 其他 ns"
kubectl get ns 2>&1 | head -20
echo; echo done
