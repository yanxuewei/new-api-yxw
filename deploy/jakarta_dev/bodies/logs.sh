#!/bin/bash
# bodies/logs.sh —— 只看 new-api-dev 的启动日志与事件（只读，不投递任何凭据）
echo "--- pod / restart 计数"
kubectl -n newapi-dev get pod -l app=new-api,track=dev -o wide 2>&1 | sed 's/^/  /'
echo "--- state（waiting.reason / exitCode / 最后一次终止时间）"
kubectl -n newapi-dev get pod -l app=new-api,track=dev -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}ready={.ready} restarts={.restartCount} state={.state} last={.lastState}{"\n"}{end}}{end}' 2>&1 | sed 's/^/  /'
echo
echo "--- 当前容器日志（尾部 60 行）"
kubectl -n newapi-dev logs -l app=new-api,track=dev --tail=60 --prefix 2>&1 | sed 's/^/  /'
echo "--- 上一次容器日志（崩溃前，尾部 60 行）"
kubectl -n newapi-dev logs -l app=new-api,track=dev --previous --tail=60 --prefix 2>&1 | sed 's/^/  /'
echo "--- Warning 事件（镜像/探针/挂载类问题都在这里）"
kubectl -n newapi-dev get events --sort-by=.lastTimestamp 2>&1 \
  | grep -Ei 'warning|failed|unhealthy|backoff' | tail -15 | sed 's/^/  /'
