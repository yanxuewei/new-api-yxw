#!/usr/bin/env bash
# 提额后静默观察：RS 失败重试有退避，等 180s 看是否自动放行
set -uo pipefail
NS=newapi-dev

sleep 180

echo "########## pods ##########"
kubectl -n "$NS" get pods -o wide 2>&1
echo
echo "########## deploy ##########"
kubectl -n "$NS" get deploy 2>&1
echo
echo "########## quota ##########"
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'
echo
echo "########## 最近 8 条事件（关注 limited 是否已变 6）##########"
kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -8
echo
echo "########## yxw RS 现状 ##########"
kubectl -n "$NS" get rs 2>&1 | grep yxw
