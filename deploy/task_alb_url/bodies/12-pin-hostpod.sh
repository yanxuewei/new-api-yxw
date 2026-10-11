#!/bin/bash
say() { printf '\n===== %s =====\n' "$*"; }
cat > /tmp/newapi-direct.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: new-api-direct
  namespace: new-api
  labels:
    app: new-api-direct
    project: new-api
    site: ph-mnl
    track: direct
    purpose: pre-cert-direct-access
spec:
  replicas: 1
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: new-api-direct
      track: direct
  template:
    metadata:
      labels:
        app: new-api-direct
        project: new-api
        site: ph-mnl
        track: direct
        purpose: pre-cert-direct-access
    spec:
      nodeName: ap-southeast-6.10.0.22.194
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: new-api-app
      terminationGracePeriodSeconds: 30
      containers:
      - name: new-api
        image: acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20260928-26ac63233
        imagePullPolicy: IfNotPresent
        env:
        - name: NODE_TYPE
          value: slave
        - name: GOMAXPROCS
          value: "2"
        envFrom:
        - configMapRef:
            name: new-api-config
        - secretRef:
            name: new-api-secrets
        ports:
        - containerPort: 3000
          name: http
          protocol: TCP
        readinessProbe:
          httpGet: {path: /api/status, port: 3000, scheme: HTTP}
          periodSeconds: 5
          failureThreshold: 3
          timeoutSeconds: 3
        livenessProbe:
          httpGet: {path: /api/status, port: 3000, scheme: HTTP}
          periodSeconds: 15
          failureThreshold: 5
          timeoutSeconds: 5
        startupProbe:
          httpGet: {path: /api/status, port: 3000, scheme: HTTP}
          periodSeconds: 5
          failureThreshold: 30
          timeoutSeconds: 1
        resources:
          requests: {cpu: "500m", memory: 1Gi}
          limits: {cpu: "2", memory: 4Gi}
YAML
kubectl apply -f /tmp/newapi-direct.yaml 2>&1

say "等待 ready（最多 90s）"
for i in $(seq 1 18); do
  r=$(kubectl -n new-api get deploy new-api-direct -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  p=$(kubectl -n new-api get pods -l app=new-api-direct -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  ip=$(kubectl -n new-api get pods -l app=new-api-direct -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
  echo "  try$i ready=$r phase=$p podIP=$ip"
  [ "$r" = "1" ] && break
  sleep 5
done
kubectl -n new-api get pods -l app=new-api-direct -o wide 2>&1

say "节点 10.0.22.194 / 本机 :3000 自测"
for t in 1 2 3; do
  c=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -m 5 "http://10.0.22.194:3000/api/status"); printf ' %s' "$c"
done; echo
echo; echo "done"
