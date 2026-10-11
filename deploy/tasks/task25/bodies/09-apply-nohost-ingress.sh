echo "===== apply 无 Host Ingress ====="
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api-ph-standby-ip
  namespace: new-api
  labels:
    app: new-api
    site: ph-sg
    env: prod
    purpose: ip-direct-access
  annotations:
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-enabled: "true"
    alb.ingress.kubernetes.io/healthcheck-path: /api/status
    alb.ingress.kubernetes.io/healthcheck-method: GET
    alb.ingress.kubernetes.io/healthcheck-httpcode: http_2xx
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "6"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "3"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
    alb.ingress.kubernetes.io/connection-drain-enabled: "true"
    alb.ingress.kubernetes.io/connection-drain-timeout: "120"
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: new-api-ph-standby
                port:
                  number: 80
YAML
echo
echo "===== 回读 Ingress（确认 spec 无 host）====="
kubectl -n new-api get ingress 2>&1
echo "--- 无 host 校验 ---"
kubectl -n new-api get ingress new-api-ph-standby-ip -o jsonpath='{.spec.rules[0].host}{\"\n\"}' 2>&1
echo "(空 = 正确，无 host)"
echo
for i in 1 2 3 4 5; do sleep 22; echo "[$i] wait reconcile"; done
echo
echo "===== events ====="
kubectl -n new-api get events --sort-by=.lastTimestamp 2>&1 | tail -8
