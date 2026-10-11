#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
say "改成 hostPort（保留 pod 网络，避免 hostNetwork 侧效应）"
kubectl -n new-api patch deploy new-api-direct --type=json -p '[
 {"op":"remove","path":"/spec/template/spec/hostNetwork"},
 {"op":"remove","path":"/spec/template/spec/dnsPolicy"},
 {"op":"replace","path":"/spec/template/spec/containers/0/ports/0","value":{"containerPort":3000,"hostPort":3000,"name":"http","protocol":"TCP"}}
]' 2>&1
kubectl -n new-api rollout status deploy/new-api-direct --timeout=120s 2>&1
kubectl -n new-api get pods -l app=new-api-direct -o wide 2>&1
say "节点 :3000 自测"
for t in 1 2 3 4 5; do
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://10.0.22.194:3000/api/status"); printf ' %s' "$c"
done; echo
say "监听核对"
ss -lntp 2>/dev/null | grep -E ':3000' | head -5
echo; echo "done"
