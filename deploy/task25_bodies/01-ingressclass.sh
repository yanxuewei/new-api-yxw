echo "=== client dry-run ==="
kubectl apply --dry-run=client -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
  labels:
    project: new-api
    site: ph-sg
    env: prod
spec:
  controller: ingress.k8s.alibabacloud/alb
  parameters:
    apiGroup: alibabacloud.com
    kind: AlbConfig
    name: sg-alb
YAML
echo
echo "=== apply ==="
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
  labels:
    project: new-api
    site: ph-sg
    env: prod
spec:
  controller: ingress.k8s.alibabacloud/alb
  parameters:
    apiGroup: alibabacloud.com
    kind: AlbConfig
    name: sg-alb
YAML
echo
echo "=== 回读 ==="
kubectl get ingressclass alb -o yaml 2>&1 | grep -vE '^\s+(creationTimestamp|resourceVersion|uid|generation|managedFields|f:)'
echo
echo "=== 是否有 default 标记 / 其他 ingresclass ==="
kubectl get ingressclass 2>&1
