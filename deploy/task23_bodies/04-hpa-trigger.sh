#!/bin/bash
# V4 HPA 触发实测（已核准 2026-10-06）。有界方案：
#   真实流量压 stable Service（8 路 wget）→ 临时 max=6 / target=1% 触发扩容 → 取证 → 立即还原 15/65%
# 卡片原方法（独立 stress Pod 烧 CPU）动不了 HPA 指标（HPA 只统计 scaleTargetRef 选中的 Pod），故改法，见报告 坑 8。
NS=new-api
IMG=acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20260928-26ac63233

hpa() { kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='{.spec.minReplicas}{"|"}{.spec.maxReplicas}{"|"}{.spec.metrics[0].resource.target.averageUtilization}{"|cur="}{.status.currentReplicas}{"|des="}{.status.desiredReplicas}{"|cond="}{.status.conditions[0].type}{"|reason="}{.status.conditions[0].reason}{"\n"}' 2>/dev/null; }
tops() { kubectl -n $NS top pods -l track=stable --no-headers 2>/dev/null | awk '{printf "    %-38s cpu=%-8s mem=%s\n",$1,$2,$3}'; }

echo "=== 0) 配额是否限 Pod 数（决定压测 Pod 能不能起）==="
kubectl -n $NS get resourcequota -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for q in d.get('items',[]):
    print('  ',q['metadata']['name'])
    for k,v in (q.get('status',{}).get('used',{}) or {}).items():
        h=(q.get('spec',{}).get('hard',{}) or {}).get(k,'-')
        print('     %-18s used=%-10s hard=%s' % (k,v,h))
"

echo "=== 1) 基线 ==="
echo "  hpa(min|max|target%)=$(hpa)"
kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "  deploy ready=%s avail=%s\n",$2,$4}'
tops

echo "=== 2) 起压测 Pod（8 路 × 500 次 wget 打 new-api-stable:3000/api/status）==="
cat > /tmp/load.yaml <<'YEOF'
apiVersion: v1
kind: Pod
metadata:
  name: t23-cpu-load
  namespace: new-api
  labels:
    app: t23-cpu-load
    purpose: task23-v4
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  terminationGracePeriodSeconds: 5
  containers:
  - name: load
    image: __IMG__
    command: ["sh","-c","for k in 1 2 3 4 5 6 7 8; do ( i=0; while [ $i -lt 500 ]; do wget -q -O /dev/null --timeout=2 http://new-api-stable:3000/api/status; i=$((i+1)); done ) & done; wait; echo LOAD_DONE"]
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits: {cpu: "1", memory: 256Mi}
YEOF
sed -i "s#__IMG__#$IMG#" /tmp/load.yaml
kubectl -n $NS apply -f /tmp/load.yaml
sleep 25
kubectl -n $NS get pod t23-cpu-load --no-headers | awk '{printf "  load pod: phase=%s node=%s\n",$3,$7}'

echo "=== 3) 负载下的 stable CPU（确认指标真的被流量抬起来）==="
sleep 20; tops

echo "=== 4) 临时把触发门槛降到 1% / 上限 6（有界，避免撞配额与节点容量）==="
kubectl -n $NS patch hpa hpa-new-api-stable --type merge -p '{"spec":{"maxReplicas":6}}'
kubectl -n $NS patch hpa hpa-new-api-stable --type json -p '[{"op":"replace","path":"/spec/metrics/0/resource/target/averageUtilization","value":1}]'
echo "  patched: $(hpa)"

echo "=== 5) 轮询扩容（每 15s × 14）==="
for i in $(seq 1 14); do
  printf "  [%2s] %s  deploy=%s  load=%s\n" "$i" "$(hpa)" \
    "$(kubectl -n $NS get deploy new-api-stable --no-headers | awk '{print $2}')" \
    "$(kubectl -n $NS get pod t23-cpu-load --no-headers 2>/dev/null | awk '{print $3}')"
  sleep 15
done

echo "=== 6) 扩容结果取证 ==="
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-38s %-8s r=%-3s node=%s\n",$1,$3,$4,$7}'
echo "  AZ 分布："
kubectl -n $NS get pods -l track=stable -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
  | sort | uniq -c | sed 's/^/    /'
kubectl -n $NS get endpoints new-api-stable --no-headers 2>/dev/null | sed 's/^/  /'
tops
echo "  HPA 事件："
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei "hpa-new-api-stable|ScalingButtons|SuccessfulScaleUp|scale" | tail -10 | sed 's/^/    /'
echo "  配额复核："
kubectl -n $NS top pods --no-headers 2>/dev/null | awk '{print $2}' | sort | uniq -c | sed 's/^/    /'

echo "=== 7) ⚠ 立即还原：删压测 Pod + max=15 / target=65% ==="
kubectl -n $NS delete pod t23-cpu-load --ignore-not-found --wait=false
kubectl -n $NS patch hpa hpa-new-api-stable --type json -p '[{"op":"replace","path":"/spec/metrics/0/resource/target/averageUtilization","value":65}]'
kubectl -n $NS patch hpa hpa-new-api-stable --type merge -p '{"spec":{"maxReplicas":15}}'
echo "  restored: $(hpa)"
echo "  （缩容需等 stabilizationWindow 300s，由下一轮 body 观察）"
