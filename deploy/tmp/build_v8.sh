#!/bin/bash
# build_v8.sh - 重建 warehouse + inventory，结果写状态文件
cd /opt/OmniTradeERP
rm -f /tmp/build-v8-status.txt

echo "$(date '+%H:%M:%S') START warehouse-service"
docker build --no-cache -f docker/Dockerfile.warehouse-service -t omnitradeerp-warehouse-service:latest . \
  > /tmp/build-wh-v8.log 2>&1
if [ $? -eq 0 ]; then
  echo "PASS_WH" >> /tmp/build-v8-status.txt
  echo "$(date '+%H:%M:%S') PASS warehouse-service"
else
  echo "FAIL_WH" >> /tmp/build-v8-status.txt
  echo "$(date '+%H:%M:%S') FAIL warehouse-service"
fi

echo "$(date '+%H:%M:%S') START inventory-service"
docker build --no-cache -f docker/Dockerfile.inventory-service -t omnitradeerp-inventory-service:latest . \
  > /tmp/build-inv-v8.log 2>&1
if [ $? -eq 0 ]; then
  echo "PASS_INV" >> /tmp/build-v8-status.txt
  echo "$(date '+%H:%M:%S') PASS inventory-service"
else
  echo "FAIL_INV" >> /tmp/build-v8-status.txt
  echo "$(date '+%H:%M:%S') FAIL inventory-service"
fi

echo "ALL_DONE" >> /tmp/build-v8-status.txt
