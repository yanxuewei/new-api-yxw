#!/bin/bash
# 任务19 收口 · 步骤2：新增无 Host Ingress new-api-stable-ip（IP 直访）
set -uo pipefail
say(){ printf '\n===== %s =====\n' "$1"; }

say "1. apply noHost Ingress"
cat > /tmp/ingress-mnl-ip.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api-stable-ip
  namespace: new-api
  labels:
    app: new-api
    project: new-api
    site: ph-mnl
    env: prod
    purpose: ip-direct-access
  annotations:
    alb.ingress.kubernetes.io/order: "50"
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
                name: new-api-stable
                port:
                  number: 80
YAML
kubectl apply -f /tmp/ingress-mnl-ip.yaml 2>&1 | tail -3

say "2. Ingress 列表"
kubectl -n new-api get ingress -o wide 2>&1

say "3. 等待 reconcile（30s）"
sleep 30
kubectl -n new-api get ingress new-api-stable-ip -o jsonpath='{.status}'; echo

say "4. 该 Ingress 生成的服务器组（应新增一个 new-api-new-api-stable-80）"
kubectl -n new-api get events --sort-by=.lastTimestamp 2>&1 | tail -10

echo
echo "===== STEP2 DONE ====="
