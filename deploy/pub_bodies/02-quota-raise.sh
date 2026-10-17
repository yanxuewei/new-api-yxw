#!/usr/bin/env bash
# 提额 newapi-dev-quota limits.cpu 3 -> 6，随后观察 yxw-* 是否起得来
set -uo pipefail
NS=newapi-dev

echo "########## 0. 改前 hard ##########"
kubectl -n "$NS" get resourcequota newapi-dev-quota -o jsonpath='{.status.hard}{"\n"}{.status.used}{"\n"}' 2>&1

echo
echo "########## 1. patch limits.cpu -> 6 ##########"
kubectl -n "$NS" patch resourcequota newapi-dev-quota --type=merge \
  -p '{"spec":{"hard":{"limits.cpu":"6"}}}' 2>&1

echo
echo "########## 2. 回读 hard / used ##########"
kubectl -n "$NS" get resourcequota newapi-dev-quota -o jsonpath='{.status.hard}{"\n"}{.status.used}{"\n"}' 2>&1
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'

echo
echo "########## 3. 等 45s 看 RS 是否放行 ##########"
sleep 45
kubectl -n "$NS" get pods 2>&1
echo "--- deploy ---"
kubectl -n "$NS" get deploy 2>&1

echo
echo "########## 4. 再等 60s（滚动需要新旧并存，可能二次触顶）##########"
sleep 60
kubectl -n "$NS" get pods -o wide 2>&1
echo "--- used now ---"
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'
echo "--- 最近事件 ---"
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -12
