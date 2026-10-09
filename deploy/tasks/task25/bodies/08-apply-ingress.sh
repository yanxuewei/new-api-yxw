kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api-ph-standby
  namespace: new-api
  labels:
    app: new-api
    site: ph-sg
    env: prod
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
    - host: sg-standby.internal.likha.hk
      http:
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
echo "=== 回读 Ingress ==="
kubectl -n new-api get ingress new-api-ph-standby -o wide 2>&1
echo
for i in 1 2 3 4; do sleep 25; echo "[$i] wait for reconcile"; done
kubectl get events -A --field-selector involvedObject.kind=AlbConfig --sort-by=.lastTimestamp 2>&1 | tail -3
echo
echo "=== 集群内直测 Service（基线）==="
kubectl -n new-api run t25-curl --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c 'curl -s -o /dev/null -w "svc:%{http_code}\n" -m 6 http://new-api-ph-standby/api/status; curl -s -m 6 http://new-api-ph-standby/api/status | head -c 300' 2>&1 | tail -8
