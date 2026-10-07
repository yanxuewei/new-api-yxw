echo "===== AlbConfig ====="
kubectl -n kube-system get albconfig mnl-alb -o yaml 2>&1 | grep -vE '^\s*(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)' | head -60
echo
echo "===== Ingress (all ns) ====="
kubectl get ingress -A -o wide 2>&1
echo
echo "===== Ingress new-api-verify yaml ====="
kubectl -n new-api get ingress new-api-verify -o yaml 2>&1 | grep -vE '^\s*(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)' | head -40
echo
echo "===== IngressClass ====="
kubectl get ingressclass alb -o yaml 2>&1 | grep -vE '^\s*(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)' | head -20
