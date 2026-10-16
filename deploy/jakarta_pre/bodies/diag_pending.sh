#!/bin/bash
# bodies/diag_pending.sh —— Pod Pending 的取数面诊断（只读）
set -uo pipefail
echo "=== X1 Pod 列表"
kubectl -n new-api-pre get pod -o wide 2>&1 | sed 's/^/  /'
echo "=== X2 每个 Pending Pod 的事件（FailedScheduling 的原文才有用）"
for p in $(kubectl -n new-api-pre get pod --no-headers -o custom-columns=N:.metadata.name 2>/dev/null); do
  echo "  --- $p"
  kubectl -n new-api-pre describe pod "$p" 2>&1 | sed -n '/^Events:/,$p' | tail -8 | sed 's/^/      /'
  kubectl -n new-api-pre get pod "$p" -o jsonpath='{.status.conditions}' 2>&1 | cut -c1-300 | sed 's/^/      cond=/'
  echo
done
echo "=== X3 节点可分配 vs 已请求（按节点统计 Pod requests）"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  cpu-cap="}{.status.allocatable.cpu}{"  mem-cap="}{.status.allocatable.memory}{"  pods="}{.status.allocatable.pods}{"\n"}{end}' 2>&1 | sed 's/^/  /'
kubectl get pod -A -o jsonpath='{range .items[?(@.spec.nodeName)]}{.spec.nodeName}{" "}{.metadata.namespace}{"/"}{.metadata.name}{" "}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{"\n"}{end}' 2>/dev/null \
  | awk '{n=$1; cpu=0; for(i=4;i<=NF;i++){c=$i; if(c ~ /m$/){sub("m","",c); cpu+=c/1000} else if(c ~ /^[0-9.]+$/){cpu+=c}} ; s[n]+=cpu} END{for(k in s) printf "    %s 已请求 requests.cpu≈%.2f\n", k, s[k]}'
echo "=== X4 pre 配额账目（quota 用满也会让 Pod 卡 Pending，而且不给事件）"
kubectl -n new-api-pre get quota -o jsonpath='{.status}' 2>&1 | tr ',' '\n' | sed 's/^/      /'
echo "=== X5 是否存在 unschedulable / 保留节点"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  unschedulable="}{.spec.unschedulable}{"  taints="}{.spec.taints}{"\n"}{end}' 2>&1 | sed 's/^/  /'
