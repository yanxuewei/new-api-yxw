echo "=== svc new-api-ph-standby 详情 ==="
kubectl -n new-api get svc new-api-ph-standby -o yaml 2>&1 | grep -vE '^\s+(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)'
echo
echo "=== endpoints / endpointslice ==="
kubectl -n new-api get endpointslice -o wide 2>&1
echo
echo "=== deploy / pods ==="
kubectl -n new-api get deploy,pods -o wide 2>&1
echo
echo "=== 近期事件 ==="
kubectl -n new-api get events --sort-by=.lastTimestamp 2>&1 | tail -20
