echo "===== AlbConfig 列表（含 status.id）====="
kubectl get albconfig -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ID:.status.loadBalancer.id,DNS:.status.loadBalancer.dnsName,STATUS:.status.loadBalancer.status' 2>&1
echo
echo "===== mnl-alb status 全字段 ====="
kubectl -n kube-system get albconfig mnl-alb -o jsonpath='{.status}' 2>&1 | python3 -m json.tool 2>/dev/null || kubectl -n kube-system get albconfig mnl-alb -o jsonpath='{.status}' 2>&1
echo
echo "===== mnl-alb 关键 spec 摘要 ====="
kubectl -n kube-system get albconfig mnl-alb -o jsonpath='{.spec}{"\n"}' 2>&1 | head -c 1500
echo
echo "===== 标签 / 注解 ====="
kubectl -n kube-system get albconfig mnl-alb -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}' 2>&1 | head -c 800
