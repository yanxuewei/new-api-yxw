#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "删除实验性 new-api-direct（hostNetwork/hostPort 方案作废）"
kubectl -n new-api delete deploy new-api-direct --wait=false 2>&1
kubectl -n new-api delete pods -l app=new-api-direct --force --grace-period=0 2>&1 | tail -3
say "pod SG 规则生效后：跨节点 Pod 可达性"
for ip in 10.0.22.205 10.0.22.218 10.0.43.202 10.0.43.215; do
  printf '  %-14s: ' "$ip"
  for t in 1 2; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:3000/api/status"); printf '%s ' "$c"; done; echo
done
say "各节点 NodePort 32656（每节点 4 次）"
for ip in 10.0.22.194 10.0.22.195 10.0.43.200 10.0.43.201; do
  printf '  %-14s: ' "$ip"
  for t in 1 2 3 4; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:32656/api/status"); printf '%s ' "$c"; done; echo
done
say "集群内 ClusterIP"
for t in 1 2 3; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://172.21.15.220:80/api/status"); printf ' %s' "$c"; done; echo
say "剩余 pod"
kubectl -n new-api get pods -o wide 2>&1
echo; echo "done"
