#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "当前 endpoints（可能已漂移）"
kubectl -n new-api get endpoints newapi-np -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in (d.get('subsets') or []):
    for a in (s.get('addresses') or []): print('  ready', a['ip'], a.get('nodeName'))
    for a in (s.get('notReadyAddresses') or []): print('  notready', a['ip'], a.get('nodeName'))
"
kubectl -n new-api get pods -l app=new-api,track=stable -o wide --no-headers 2>&1

say "Pod IP:3000 直连（规则已放行后复测）"
for ip in $(kubectl -n new-api get endpoints newapi-np -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in (d.get('subsets') or []):
    for a in (s.get('addresses') or []): print(a['ip'])
"); do
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:3000/api/status")
  printf '  %-14s -> %s\n' "$ip" "$c"
done

say "NodePort 32656 各节点复测（每节点 3 次）"
for ip in 10.0.22.194 10.0.22.195 10.0.43.200 10.0.43.201; do
  printf '  %-14s: ' "$ip"
  for t in 1 2 3; do
    c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$ip:32656/api/status")
    printf '%s ' "$c"
  done
  echo
done
echo; echo "done"
