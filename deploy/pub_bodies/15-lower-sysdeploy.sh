#!/usr/bin/env bash
# 批1：Deployment 类系统组件降 requests（不动 DaemonSet，无网络/存储中断）
set -uo pipefail

echo "########## 改前 ##########"
for x in kube-system/metrics-server kube-system/coredns arms-prom/arms-prometheus-ack-arms-prometheus; do
  ns="${x%%/*}"; d="${x##*/}"
  kubectl -n "$ns" get deploy "$d" -o json 2>/dev/null | python3 -c "
import sys, json
x = json.load(sys.stdin)
print('  %-52s replicas=%s' % (x['metadata']['name'], x['spec'].get('replicas')))
for c in x['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('     %-30s requests=%s limits=%s' % (c.get('name'), r.get('requests'), r.get('limits')))
"
done

echo
echo "########## 执行 ##########"
mc=$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].name}')
kubectl -n kube-system set resources deploy/metrics-server -c "$mc" --requests=cpu=50m,memory=64Mi 2>&1

cc=$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.template.spec.containers[0].name}')
kubectl -n kube-system set resources deploy/coredns -c "$cc" --requests=cpu=50m,memory=70Mi 2>&1

pc=$(kubectl -n arms-prom get deploy arms-prometheus-ack-arms-prometheus -o jsonpath='{.spec.template.spec.containers[0].name}')
kubectl -n arms-prom set resources deploy/arms-prometheus-ack-arms-prometheus -c "$pc" --requests=cpu=100m,memory=256Mi 2>&1

kubectl -n kube-system scale deploy/csi-provisioner --replicas=1 2>&1

echo
echo "########## rollout ##########"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=150s 2>&1
kubectl -n kube-system rollout status deploy/coredns --timeout=150s 2>&1
kubectl -n arms-prom rollout status deploy/arms-prometheus-ack-arms-prometheus --timeout=180s 2>&1

echo
echo "########## 异常自愈检查（若这次改动触发问题，此处暴露）##########"
kubectl -n kube-system get pods 2>&1 | grep -v -E 'Running|Completed' | head -10
echo "--- metrics 可用性 ---"
kubectl top nodes 2>&1 | head -6
echo "--- DNS 可用性 ---"
kubectl -n kube-system get svc kube-dns 2>&1
