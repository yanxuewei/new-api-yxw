echo "===== CRD scope (Namespaced/Cluster) ====="
kubectl get crd albconfigs.alibabacloud.com -o jsonpath='{.spec.scope}{"\n"}' 2>&1
kubectl get crd ingressclasses.networking.k8s.io -o name 2>&1 | head -1
echo
echo "===== 直接按名取（不带 -n）====="
kubectl get albconfig mnl-alb 2>&1
echo
echo "===== AlbConfig 全量 YAML ====="
kubectl get albconfig mnl-alb -o yaml 2>&1 | grep -vE '^\s+(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)' 
echo
echo "===== Ingress new-api-verify 全量 ====="
kubectl -n new-api get ingress new-api-verify -o yaml 2>&1 | grep -vE '^\s+(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)'
