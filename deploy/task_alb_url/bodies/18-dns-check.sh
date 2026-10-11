#!/bin/bash
# 18-dns-check.sh — 验证删 Pod ingress UDP 后集群 DNS 是否仍正常
say() { printf '\n===== %s =====\n' "$*"; }

say "CoreDNS Pod 分布"
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide 2>&1

say "new-api Pod → DNS 查询（sh/nslookup 可用性 + 解析）"
kubectl -n new-api exec deploy/new-api-stable -- sh -c '
  echo "shell=ok"
  command -v nslookup >/dev/null 2>&1 && echo "nslookup=yes" || echo "nslookup=no"
  echo "--- kubernetes.default ---"
  nslookup kubernetes.default.svc.cluster.local 2>&1 | head -8
  echo "--- 外网域名 ---"
  nslookup api.openai.com 2>&1 | head -8
' 2>&1 | head -30

say "CoreDNS 最近日志（找 error/refused/timeout）"
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200 --prefix 2>&1 | grep -iE "error|refused|timeout|fail|SERVFAIL" | tail -15
echo "(以上为空 = 无 DNS 错误)"

say "CoreDNS 最近 200 行原始尾部（看是否有请求进来）"
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=8 --prefix 2>&1 | tail -12

say "跨节点 Pod→Pod TCP:3000（佐证东西向未受影响）"
kubectl -n new-api exec deploy/new-api-stable -- sh -c '
  for ip in 10.0.22.205 10.0.22.218 10.0.43.202 10.0.43.215; do
    printf "  %s: " "$ip"
    curl --noproxy "*" -s -o /dev/null -w "%{http_code} " -m 4 "http://$ip:3000/api/status" 2>/dev/null || printf "curl-missing "
  done; echo
' 2>&1 | head -12
echo; echo "done"
