#!/bin/bash
# 任务 23 §十三-③/⑤ 追加取证（只读）：
#  1) kube-system lease 全名单里出现 ack-goatscaler ⇒ ACK 托管弹性组件的实名可能不是 cluster-autoscaler
#  2) 把它和 alb 一样按 holder/renewTime 三级判据核一遍
#  3) 顺手修正 05 body 第 6 段的字段误取（endpoints 列 / ingress 后端 jsonpath 未打印）
set -o pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}

echo "=== A) ack-goatscaler lease（弹性组件是否在托管侧活着）==="
kubectl -n kube-system get lease ack-goatscaler -o jsonpath='{"  name="}{.metadata.name}{"\n  holder="}{.spec.holderIdentity}{"\n  renew="}{.spec.renewTime}{"\n  created="}{.metadata.creationTimestamp}{"\n"}' 2>&1
echo "  --- 同 ns 其他疑似弹性/调度类 lease ---"
kubectl -n kube-system get lease --no-headers 2>/dev/null | grep -iE 'goat|scaler|autoscal|provisioner|nodescale' | sed 's/^/    /'

echo "=== B) goatscaler 的用户面痕迹（deploy/cm/events）==="
echo -n "  deploy/sts/ds 含 goat: "; kubectl get deploy,sts,ds -A --no-headers 2>/dev/null | grep -ci goat || true
kubectl get deploy,sts,ds -A --no-headers 2>/dev/null | grep -i goat | sed 's/^/    /'
echo -n "  cm 含 goat/scaler: "; kubectl get cm -A --no-headers 2>/dev/null | grep -icE 'goat|scaler' || true
kubectl get cm -A --no-headers 2>/dev/null | grep -iE 'goat|scaler' | sed 's/^/    /'
echo "  --- 最近 events（含 goatscaler/provisioning）---"
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'goat|scaler|provision|scaledup|node.*creat' | tail -8 | sed 's/^/    /' || echo "    （无匹配 events）"

echo "=== C) alb lease 复核（同一时刻的 renewTime = 存活铁证）==="
for L in alb alb-gateway; do
  kubectl -n kube-system get lease "$L" -o jsonpath='{"  "}{.metadata.name}{" holder="}{.spec.holderIdentity}{" renew="}{.spec.renewTime}{"\n"}' 2>/dev/null
done
echo "  节点侧 UTC 现在: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "=== D) Ingress 后端与 endpoints（修正 05 body 第 6 段）==="
kubectl -n new-api get ingest.networking.k8s.io new-api-verify -o jsonpath='{range .spec.rules[*]}{.host}{"  "}{range .http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"  "}{end}{"\n"}{end}' 2>&1
echo -n "  svc/new-api-stable selector: "; kubectl -n new-api get svc new-api-stable -o jsonpath='{.spec.selector}{"\n"}' 2>&1
echo -n "  endpoints/new-api-stable ready: "; kubectl -n new-api get endpoints new-api-stable -o jsonpath='{range .subsets[*]}{.addresses[*].ip}{":"}{.ports[*].port}{" "}{end}{"\n"}' 2>&1
echo -n "  endpoints/new-api-master ready: "; kubectl -n new-api get endpoints new-api-master -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}' 2>&1
echo "  --- HPA 现值（裁定 15 落地状态）---"
kubectl -n new-api get hpa hpa-new-api-stable -o jsonpath='{"  min="}{.spec.minReplicas}{" max="}{.spec.maxReplicas}{" target="}{.spec.metrics[0].resource.target.averageUtilization}{" cur="}{.status.currentReplicas}{" des="}{.status.desiredReplicas}{"\n"}' 2>&1
