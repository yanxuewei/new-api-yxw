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
echo "=== 回读 spec.listeners ==="
kubectl get albconfig sg-alb -o jsonpath='{.spec.listeners}{"\n"}' 2>&1
echo
echo "=== webhook 是否拒绝 / 字段是否被裁剪 ==="
kubectl get albconfig sg-alb -o yaml 2>&1 | sed -n '/listeners:/,/^status:/p'
echo
for i in 1 2 3; do
  sleep 25
  echo "[$i] reconciled=${i}"
done
kubectl get events -A --field-selector involvedObject.kind=AlbConfig --sort-by=.lastTimestamp 2>&1 | tail -4
