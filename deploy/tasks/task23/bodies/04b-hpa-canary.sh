#!/bin/bash
# V4 补充：指标通路证明（有界 canary：容器内自烧 CPU，HPA 只看它自己）
# 依据：上一轮实测 stable Pod 在 4000 次真实 HTTP 下 cpu 仍 1m ⇒ /api/status 类流量抬不动 CPU 指标。
NS=new-api
IMG=acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20260928-26ac63233

echo "=== 1) 起 canary：Deployment 1 副本，容器内死循环烧 CPU，requests.cpu=100m ==="
cat > /tmp/canary.yaml <<'YEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t23-hpa-canary
  namespace: new-api
  labels: {app: t23-hpa-canary, purpose: task23-v4}
spec:
  replicas: 1
  selector: {matchLabels: {app: t23-hpa-canary}}
  template:
    metadata:
      labels: {app: t23-hpa-canary, purpose: task23-v4}
    spec:
      serviceAccountName: new-api-app
      terminationGracePeriodSeconds: 5
      containers:
      - name: burn
        image: __IMG__
        command: ["sh","-c","while :; do :; done"]
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits: {cpu: 200m, memory: 128Mi}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: t23-hpa-canary
  namespace: new-api
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: t23-hpa-canary}
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: {type: Utilization, averageUtilization: 65}
YEOF
sed -i "s#__IMG__#$IMG#" /tmp/canary.yaml
kubectl -n $NS apply -f /tmp/canary.yaml
sleep 30
kubectl -n $NS get deploy t23-hpa-canary --no-headers | awk '{printf "  canary deploy: ready=%s\n",$2}'
echo "  单副本 CPU（应为 ~200m ⇒ 利用率 200%）："
kubectl -n $NS top pods -l app=t23-hpa-canary --no-headers 2>/dev/null | awk '{printf "    %-30s cpu=%s mem=%s\n",$1,$2,$3}'

echo "=== 2) 轮询 canary HPA 扩容（每 20s × 9）==="
for i in $(seq 1 9); do
  printf "  [%2s] canary hpa min|max|target=%s|%s|%s cur=%s des=%s cond=%s  deploy=%s\n" "$i" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.spec.minReplicas}')" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.spec.maxReplicas}')" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}')" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.status.currentReplicas}')" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.status.desiredReplicas}')" \
    "$(kubectl -n $NS get hpa t23-hpa-canary -o jsonpath='{.status.conditions[-1].type}')" \
    "$(kubectl -n $NS get deploy t23-hpa-canary --no-headers | awk '{print $2}')"
  sleep 20
done

echo "=== 3) 终态取证 ==="
kubectl -n $NS get hpa t23-hpa-canary --no-headers | sed 's/^/  /'
kubectl -n $NS get pods -l app=t23-hpa-canary -o wide --no-headers | awk '{printf "  %-32s %-8s node=%s\n",$1,$3,$7}'
echo "  canary 事件："
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei "canary" | tail -12 | sed 's/^/    /'
echo "  真实 metrics-server 读数："
kubectl -n $NS top pods -l app=t23-hpa-canary --no-headers 2>/dev/null | awk '{printf "    %-30s cpu=%s\n",$1,$2}'

echo "=== 4) 清理 canary ==="
kubectl -n $NS delete hpa t23-hpa-canary --ignore-not-found
kubectl -n $NS delete deploy t23-hpa-canary --ignore-not-found --wait=false
sleep 10
kubectl -n $NS get deploy,hpa,pods 2>/dev/null | grep -Ei "canary|NAME|deployment" | head -12 | sed 's/^/  /'
echo "  残留 Pod："
kubectl -n $NS get pods -l app=t23-hpa-canary --no-headers 2>/dev/null | wc -l | awk '{printf "    %s 个\n",$1}'
