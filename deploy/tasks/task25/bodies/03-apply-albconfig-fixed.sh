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
YAML
echo
echo "=== 立即回读 ==="
kubectl get albconfig sg-alb 2>&1
echo
for i in 1 2 3 4 5 6; do
  sleep 20
  ST=$(kubectl get albconfig sg-alb -o jsonpath='{.status.loadBalancer.id}' 2>/dev/null)
  echo "[$i] status.id=${ST:-<空>}"
  if [ -n "$ST" ]; then break; fi
done
echo
echo "=== 最终 AlbConfig ==="
kubectl get albconfig sg-alb 2>&1
echo
echo "=== status 全量 ==="
kubectl get albconfig sg-alb -o jsonpath='{.status}{"\n"}' 2>&1
echo
echo "=== events ==="
kubectl get events -A --field-selector involvedObject.kind=AlbConfig 2>&1 | head -8
