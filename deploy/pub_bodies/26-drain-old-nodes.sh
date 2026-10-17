#!/usr/bin/env bash
# Phase 3+4：cordon 旧 4 台并逐台 drain（带新节点 CNI 就绪保护）
set -uo pipefail
OLD="ap-southeast-5.10.2.25.174 ap-southeast-5.10.2.36.199 ap-southeast-5.10.2.90.153 ap-southeast-5.10.2.90.163"
NEW=$(kubectl get nodes -l node.kubernetes.io/instance-type=ecs.g9i.xlarge -o jsonpath='{.items[*].metadata.name}')
echo "新节点: $NEW"

check_new() {
  ok=1
  for n in $NEW; do
    for k in terway csi-plugin kube-proxy; do
      c=$(kubectl -n kube-system get pods -o wide --field-selector spec.nodeName="$n" --no-headers 2>/dev/null | grep "$k" | grep -c Running)
      [ "$c" -lt 1 ] && { echo "  [x] $n 缺 $k Running"; ok=0; }
    done
  done
  return $((1-ok))
}

echo "########## 新节点 CNI 就绪检查 ##########"
if ! check_new; then
  echo "--- 等 60s 重试 ---"
  sleep 60
  if ! check_new; then
    echo "!! 新节点 CNI 未就绪，中止 drain（未做任何变更）"
    exit 9
  fi
fi
echo "  CNI OK"

echo
echo "########## 新节点容量 ##########"
kubectl get nodes -l node.kubernetes.io/instance-type=ecs.g9i.xlarge \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,PODS:.status.allocatable.pods,CPU:.status.allocatable.cpu,SITE:.metadata.labels.site' 2>&1

echo
echo "########## cordon 旧节点 ##########"
kubectl cordon $OLD 2>&1

echo
echo "########## 逐台 drain ##########"
for n in $OLD; do
  echo "=== drain $n ==="
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1 | tail -4
  echo "--- 非 Running 检查 ---"
  kubectl get pods -A -o wide 2>&1 | grep -vE 'Running|Completed|NAME' | head -6
  echo "(空=正常)"
  sleep 15
done

echo
echo "########## 终态 ##########"
kubectl get nodes -o wide 2>&1
echo
kubectl -n newapi-dev get pods -o wide 2>&1
echo
echo "--- 全集群非 Running ---"
kubectl get pods -A 2>&1 | grep -vE 'Running|Completed|NAME' | head -8
echo "(空=全部正常)"
