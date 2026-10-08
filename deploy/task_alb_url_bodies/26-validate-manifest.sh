#!/bin/bash
# 校验 manifests/newapi-np.yaml 语法（client dry-run，不触集群）
say() { printf '\n===== %s =====\n' "$*"; }

say "kubectl apply --dry-run=client"
cat > /tmp/newapi-np-validate.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: newapi-np
  namespace: new-api
  labels:
    purpose: pre-cert-direct-access
    managed-by: manual-task19
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: new-api
    track: stable
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 3000
      nodePort: 32656
YAML
kubectl apply --dry-run=client -f /tmp/newapi-np-validate.yaml 2>&1

say "server dry-run（真正过 API 校验）"
kubectl apply --dry-run=server -f /tmp/newapi-np-validate.yaml 2>&1

say "确认线上值与 manifest 一致"
kubectl -n new-api get svc newapi-np -o jsonpath='live: type={.spec.type} extPolicy={.spec.externalTrafficPolicy} nodePort={.spec.ports[0].nodePort}{"\n"}' 2>&1
echo "manifest: type=NodePort extPolicy=Cluster nodePort=32656"
