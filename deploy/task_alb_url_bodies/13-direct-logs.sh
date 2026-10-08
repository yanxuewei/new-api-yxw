#!/bin/bash
P=$(kubectl -n new-api get pods -l app=new-api-direct -o jsonpath='{.items[0].metadata.name}')
echo "pod=$P"
echo "===== describe (Events) ====="
kubectl -n new-api describe pod "$P" 2>&1 | sed -n '/Events:/,$p' | head -25
echo "===== logs --previous ====="
kubectl -n new-api logs "$P" --previous --tail=40 2>&1 | tail -40
echo "===== logs (current) ====="
kubectl -n new-api logs "$P" --tail=40 2>&1 | tail -40
echo "===== 节点 3000 监听 ====="
ss -lntp 2>/dev/null | grep -E ':3000|:8080' | head
