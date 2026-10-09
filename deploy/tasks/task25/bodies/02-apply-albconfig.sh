echo "=== 是否存在同名 AlbConfig ==="
kubectl get albconfig sg-alb 2>&1
echo
echo "=== 集群 VPC（核对 vSwitch 归属）==="
kubectl get nodes -o jsonpath='{.items[0].spec.providerID}{"\n"}' 2>&1
echo
echo "=== apply AlbConfig sg-alb ==="
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
      logStore: alb-access
    tags:
      - { key: project, value: new-api }
      - { key: site, value: ph-sg }
      - { key: env, value: prod }
  listeners:
    - port: 80
      protocol: HTTP
YAML
echo
echo "=== 立即回读 ==="
kubectl get albconfig sg-alb 2>&1
echo
echo "=== status / events ==="
kubectl get albconfig sg-alb -o jsonpath='{.status}{"\n"}' 2>&1
kubectl get events -A --field-selector involvedObject.kind=AlbConfig 2>&1 | head -10
