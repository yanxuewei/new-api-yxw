#!/bin/bash
# bodies/readback_perf_resources.sh —— 800 档 883m 到底是"接近上限"还是"很宽裕"（只读）
# 用途：给容量判读定性。若 883m ≈ limits.cpu ⇒ 单副本 CPU 是拐点主因，"800 档 277 rps"是**单 Pod** 上限，
#       不是网关架构上限（现网又被运维从 2 副本缩到 1 副本）；若 limits 远大于 883m ⇒ 拐点在别处。
set -uo pipefail
NS=new-api-perf
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "=== V1 网关 Pod 的 requests/limits + 当前实时用量"
kubectl -n $NS get pod "$POD" -o jsonpath='{range .spec.containers[*]}      limits={.resources.limits}{"\n"}      requests={.resources.requests}{"\n"}{end}' 2>/dev/null
echo "      --- 稳态（负载已停，应当很低）"
kubectl -n $NS top pod "$POD" --no-headers 2>/dev/null | tr -s ' ' | sed 's/^/      /'
echo "=== V2 部署副本数（对照：08:18:25Z 被 console 从 2 缩到 1）"
kubectl -n $NS get deploy new-api-perf -o jsonpath='      spec={.spec.replicas} ready={.status.readyReplicas} 节点={.spec.template.spec.nodeSelector}{"\n"}' 2>/dev/null
kubectl -n $NS get hpa 2>/dev/null | sed 's/^/      /' || true
echo "=== V3 mock 侧 limits（6 副本，排除上游是瓶颈）"
kubectl -n $NS get deploy mock-upstream -o jsonpath='{range .spec.template.spec.containers[*]}      limits={.resources.limits} requests={.resources.requests}{"\n"}{end}' 2>/dev/null
kubectl -n $NS top pod -l app=mock-upstream --no-headers 2>/dev/null | tr -s ' ' | sed 's/^/      /' | head -8
echo "=== V4 两台节点剩余可分配（共池安全边界）"
kubectl get nodes -o custom-columns=N:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory --no-headers 2>/dev/null | sed 's/^/      /'
kubectl top nodes 2>/dev/null | sed 's/^/      /'
echo "--- V1–V4 结束（只读）"
exit 0
