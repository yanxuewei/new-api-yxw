#!/bin/bash
cd /opt/OmniTradeERP
echo "[$(date)] Starting v9 build..." > /tmp/build-v9.status

echo "[$(date)] Building warehouse-service..." >> /tmp/build-v9.status
/usr/bin/docker build -f Dockerfile.warehouse-service -t erp-warehouse-service:latest . > /tmp/build-wh-v9.log 2>&1
if [ $? -eq 0 ]; then
  echo "[$(date)] warehouse-service BUILD SUCCESS" >> /tmp/build-v9.status
else
  echo "[$(date)] warehouse-service BUILD FAILURE" >> /tmp/build-v9.status
fi

echo "[$(date)] Building inventory-service..." >> /tmp/build-v9.status
/usr/bin/docker build -f Dockerfile.inventory-service -t erp-inventory-service:latest . > /tmp/build-inv-v9.log 2>&1
if [ $? -eq 0 ]; then
  echo "[$(date)] inventory-service BUILD SUCCESS" >> /tmp/build-v9.status
else
  echo "[$(date)] inventory-service BUILD FAILURE" >> /tmp/build-v9.status
fi

echo "[$(date)] ALL DONE" >> /tmp/build-v9.status
