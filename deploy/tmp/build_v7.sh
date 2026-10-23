#!/bin/bash
# build_v7.sh - 串行构建 warehouse + inventory，结果写状态文件
cd /opt/OmniTradeERP
rm -f /tmp/build-v7-status.txt

echo "$(date '+%H:%M:%S') START warehouse-service"
docker build --no-cache -f docker/Dockerfile.warehouse-service -t omnitradeerp-warehouse-service:latest . \
  > /tmp/build-wh-v7.log 2>&1
if [ $? -eq 0 ]; then
  echo "PASS_WH" >> /tmp/build-v7-status.txt
  echo "$(date '+%H:%M:%S') PASS warehouse-service"
else
  echo "FAIL_WH" >> /tmp/build-v7-status.txt
  echo "$(date '+%H:%M:%S') FAIL warehouse-service"
fi

echo "$(date '+%H:%M:%S') START inventory-service"
docker build --no-cache -f docker/Dockerfile.inventory-service -t omnitradeerp-inventory-service:latest . \
  > /tmp/build-inv-v7.log 2>&1
if [ $? -eq 0 ]; then
  echo "PASS_INV" >> /tmp/build-v7-status.txt
  echo "$(date '+%H:%M:%S') PASS inventory-service"
else
  echo "FAIL_INV" >> /tmp/build-v7-status.txt
  echo "$(date '+%H:%M:%S') FAIL inventory-service"
fi

echo "$(date '+%H:%M:%S') ALL_DONE" >> /tmp/build-v7-status.txt
