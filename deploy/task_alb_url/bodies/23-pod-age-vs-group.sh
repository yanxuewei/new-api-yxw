#!/bin/bash
# 23-pod-age-vs-group.sh — 精确时间线：Pod 创建时间 vs 服务器组
say() { printf '\n===== %s =====\n' "$*"; }

say "当前 stable Pod 精确创建时间 + IP"
kubectl -n new-api get pods -l app=new-api,track=stable \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  ip="}{.status.podIP}{"  created="}{.metadata.creationTimestamp}{"  startTime="}{.status.startTime}{"\n"}{end}' 2>&1

say "ReplicaSet 历史（看滚动更新）"
kubectl -n new-api get rs -l app=new-api -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,CREATED:.metadata.creationTimestamp' 2>&1

say "EndpointSlice 全部（含历史残留）"
kubectl -n new-api get endpointslice -l kubernetes.io/service-name=new-api-stable \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  created="}{.metadata.creationTimestamp}{"  ip="}{range .endpoints[*]}{.addresses[0]}{","}{end}{"\n"}{end}' 2>&1

say "HPA 现状（若存在）"
kubectl -n new-api get hpa 2>&1

say "Deployment replicas / 资源"
kubectl -n new-api get deploy new-api-stable -o jsonpath='replicas={.spec.replicas}  ready={.status.readyReplicas}  updated={.status.updatedReplicas}{"\n"}' 2>&1

say "Pod 事件（找 Created/Started 时间）"
kubectl -n new-api get events --sort-by=.lastTimestamp 2>&1 | grep -E "new-api-stable" | tail -12
echo; echo done
