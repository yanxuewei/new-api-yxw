#!/bin/bash
# 16-recon.sh — ALB 直连排查：命名空间现状 + NodePort 链路 + direct 残留
say() { printf '\n===== %s =====\n' "$*"; }

say "deploy / svc / endpoints"
kubectl -n new-api get deploy,svc -o wide 2>&1
echo "--- endpoints ---"
kubectl -n new-api get endpoints -o wide 2>&1

say "pods（-o wide）"
kubectl -n new-api get pods -o wide 2>&1

say "new-api-stable selector / pod labels"
kubectl -n new-api get deploy new-api-stable -o jsonpath='{.spec.selector.matchLabels}{"\n"}' 2>&1
kubectl -n new-api get pods -l app=new-api -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.labels.track}{"  "}{.status.podIP}{"  "}{.status.phase}{"  ready="}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>&1

say "newapi-np svc 详情"
kubectl -n new-api get svc newapi-np -o yaml 2>&1 | grep -vE '^\s*(creationTimestamp|resourceVersion|uid|managedFields|f:)' | head -40

say "new-api-direct 残留"
kubectl -n new-api get deploy new-api-direct -o wide 2>&1
kubectl -n new-api get rs,pods -l app=new-api-direct -o wide 2>&1

say "节点清单"
kubectl get nodes -o wide 2>&1

say "本节点 eth0 + NodePort 自测（本机 4 次）"
MYIP=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
echo "self=$MYIP"
for t in 1 2 3 4; do
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://$MYIP:32656/api/status"); printf '%s ' "$c"
done; echo

say "kube-proxy 模式"
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -E 'mode|clusterCIDR|strictARP' | head -10
echo; echo "done"
