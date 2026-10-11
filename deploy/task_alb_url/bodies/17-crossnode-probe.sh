#!/bin/bash
# 17-crossnode-probe.sh — 跨节点 NodePort 稳定性复核（ALB 转发到任意节点都需通）
say() { printf '\n===== %s =====\n' "$*"; }
NODES="10.0.22.194 10.0.22.195 10.0.43.200 10.0.43.201"

say "节点自身 NodePort（本机 = 10.0.22.194）"
for t in 1 2 3; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://10.0.22.194:32656/api/status"); printf '%s ' "$c"; done; echo

say "跨节点 NodePort（每节点 5 次）"
for ip in $NODES; do
  printf '  %-14s: ' "$ip"
  for t in 1 2 3 4 5; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:32656/api/status")
    printf '%s ' "$c"
  done; echo
done

say "ClusterIP 直连（每 3 次）"
for t in 1 2 3; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://172.21.15.220:80/api/status"); printf '%s ' "$c"; done; echo

say "Pod IP 直连 :3000"
for ip in 10.0.22.205 10.0.22.218 10.0.43.202 10.0.43.215; do
  printf '  %-14s: ' "$ip"
  for t in 1 2; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:3000/api/status"); printf '%s ' "$c"; done; echo
done

say "当前 pod IP（供比对服务器组）"
kubectl -n new-api get pods -l app=new-api,track=stable -o jsonpath='{range .items[*]}{.status.podIP}{"  "}{.metadata.name}{"\n"}{end}' 2>&1
echo; echo "done"
