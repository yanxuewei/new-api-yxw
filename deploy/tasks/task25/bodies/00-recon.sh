echo "===== nodes ====="
kubectl get nodes -o wide 2>&1 | head -10
echo
echo "===== ns new-api ====="
kubectl get ns new-api 2>&1
echo
echo "===== 全部 workload / svc / ingress in new-api ====="
kubectl -n new-api get deploy,svc,ingress,endpoints 2>&1 | head -40
echo
echo "===== ingressclass ====="
kubectl get ingressclass 2>&1
echo
echo "===== albconfig ====="
kubectl get albconfig 2>&1
echo
echo "===== alb controller 相关 pod（全 ns）====="
kubectl get pods -A 2>&1 | grep -i "alb\|ingress" | head -10
echo
echo "===== storageclass / pvc ====="
kubectl -n new-api get pvc 2>&1 | head -10
echo
echo "===== secret ====="
kubectl -n new-api get secret 2>&1 | head -20
echo
echo "===== hpa ====="
kubectl -n new-api get hpa 2>&1
