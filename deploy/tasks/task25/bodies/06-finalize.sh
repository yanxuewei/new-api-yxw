echo "=== 终态 apply（无 defaultActions，保留超时）==="
kubectl apply -f - <<'YAML'
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata:
  name: sg-alb
  labels:
    project: new-api
    site: ph-sg
    env: prod
spec:
  config:
    name: alb-newapi-sg
    addressType: Internet
    zoneMappings:
      - vSwitchId: vsw-t4ncxa4gqgamhl0o8e6yq
      - vSwitchId: vsw-t4nhtsfk2z79e1ggvlhdz
    accessLogConfig:
      logProject: sls-newapi-sg
      logStore: alb_access
    tags:
      - { key: project, value: new-api }
      - { key: site, value: ph-sg }
      - { key: env, value: prod }
  listeners:
    - port: 80
      protocol: HTTP
      idleTimeout: 60
      requestTimeout: 600
YAML
echo
echo "=== 终态回读 ==="
kubectl get albconfig sg-alb 2>&1
kubectl get albconfig sg-alb -o jsonpath='{.spec.listeners}{"\n"}' 2>&1
echo
echo "=== IngressClass ==="
kubectl get ingressclass 2>&1
echo
echo "=== ns new-api 现状（确认无 Ingress/Service）==="
kubectl -n new-api get svc,ingress 2>&1
