#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "patch newapi-np -> externalTrafficPolicy=Local"
kubectl -n new-api patch svc newapi-np -p '{"spec":{"externalTrafficPolicy":"Local"}}' 2>&1
sleep 3
kubectl -n new-api get svc newapi-np -o jsonpath='{.spec.type} {.spec.externalTrafficPolicy} {.spec.ports[0].nodePort}{"\n"}' 2>&1

say "各节点 NodePort 复测（Local 后应全 200；每节点 3 次）"
for ip in 10.0.22.194 10.0.22.195 10.0.43.200 10.0.43.201; do
  printf '  %-14s: ' "$ip"
  for t in 1 2 3; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:32656/api/status")
    printf '%s ' "$c"
  done
  echo
done
echo; echo "done"
