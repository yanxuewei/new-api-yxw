#!/bin/bash
set -uo pipefail
NS=new-api
TAG=20261023-792480c2a

echo "=== D1 当前 mock-upstream 状态（有则显示，无则 NotFound 正常）"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy mock-upstream 2>&1 || true

echo "=== D2 apply mock-upstream（tag=$TAG）"
cat <<'YAML' | sed "s/__IMAGE_TAG__/$TAG/" | kubectl --kubeconfig "$KUBECONFIG" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mock-upstream
  namespace: new-api
  labels:
    app: mock-upstream
    purpose: perf-mock
    site: ph-mnl
spec:
  replicas: 6
  revisionHistoryLimit: 2
  selector:
    matchLabels: {app: mock-upstream}
  template:
    metadata:
      labels:
        app: mock-upstream
        purpose: perf-mock
        site: ph-mnl
    spec:
      serviceAccountName: new-api-app
      containers:
        - name: mock
          image: acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com/newapi-dev/mock-upstream:__IMAGE_TAG__
          imagePullPolicy: IfNotPresent
          ports:
            - {name: http, containerPort: 8080}
          env:
            - {name: FIRST_TOKEN_DELAY_MS, value: "300"}
            - {name: TOKEN_INTERVAL_MS, value: "30"}
            - {name: TOKENS_PER_RESPONSE, value: "50"}
            - {name: TOKEN_TEXT_BYTES, value: "12"}
            - {name: ERROR_RATE, value: "0"}
            - {name: ERROR_STATUS, value: "500"}
            - {name: EXTRA_LATENCY_MS, value: "0"}
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /healthz, port: http}
            periodSeconds: 20
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: "1", memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: mock-upstream
  namespace: new-api
  labels:
    app: mock-upstream
    purpose: perf-mock
spec:
  type: ClusterIP
  selector: {app: mock-upstream}
  ports:
    - {name: http, port: 80, targetPort: http}
YAML

echo "=== D3 等待 rollout 就绪（超时 120s）"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" rollout status deploy/mock-upstream --timeout=120s

echo "=== D4 最终副本状态"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy mock-upstream
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get pods -l app=mock-upstream -o wide
