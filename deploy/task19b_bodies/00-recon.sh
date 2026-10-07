#!/bin/bash
# 任务19 收口 · 马尼拉 ALB 对齐 SG 前的现状勘察（只读）
set -uo pipefail
say(){ printf '\n===== %s =====\n' "$1"; }

say "1. AlbConfig mnl-alb"
kubectl get albconfig mnl-alb -o yaml 2>&1

say "2. IngressClass alb"
kubectl get ingressclass alb -o yaml 2>&1

say "3. ns new-api Ingress (wide)"
kubectl -n new-api get ingress -o wide 2>&1

say "4. ns new-api Service (wide)"
kubectl -n new-api get svc -o wide 2>&1

say "5. Ingress 详情 (全部)"
for i in $(kubectl -n new-api get ingress -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "--- ingress/$i"
  kubectl -n new-api get ingress "$i" -o yaml 2>&1
done

say "6. newapi-np 与 new-api-stable endpoints"
kubectl -n new-api get endpoints -o wide 2>&1

say "7. 最近 AlbConfig/Ingress 相关事件"
kubectl get events -A --field-selector involvedObject.name=mnl-alb 2>&1 | tail -20
kubectl -n new-api get events --sort-by=.lastTimestamp 2>&1 | tail -20

say "8. webhook 判活（dry-run=server）"
kubectl -n new-api annotate ingress new-api-verify probe.t19b=1 --dry-run=server 2>&1
kubectl annotate albconfig mnl-alb probe.t19b=1 --dry-run=server 2>&1

echo
echo "===== RECON DONE ====="
