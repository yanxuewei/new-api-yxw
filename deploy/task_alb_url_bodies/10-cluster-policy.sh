#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "回到 externalTrafficPolicy=Cluster"
kubectl -n new-api patch svc newapi-np -p '{"spec":{"externalTrafficPolicy":"Cluster"}}' 2>&1
sleep 3
kubectl -n new-api get svc newapi-np -o jsonpath='{.spec.type} {.spec.externalTrafficPolicy} {.spec.ports[0].nodePort}{"\n"}'
say "远端 pod 可达性（diag 规则已放行 3000 from VPC）"
for ip in 10.0.22.205 10.0.22.218 10.0.43.202 10.0.43.215; do
  printf '  %-14s: ' "$ip"
  for t in 1 2; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:3000/api/status"); printf '%s ' "$c"
  done; echo
done
say "本节点 NodePort"
for t in 1 2 3; do c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://10.0.22.194:32656/api/status"); printf ' %s' "$c"; done; echo
echo; echo "done"
