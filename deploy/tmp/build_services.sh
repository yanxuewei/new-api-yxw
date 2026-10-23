#!/bin/bash
cd /opt/OmniTradeERP
SERVICES="order-service product-service warehouse-service inventory-service customer-service supplier-service"
for svc in $SERVICES; do
  TS=$(date '+%H:%M:%S')
  echo "$TS START $svc"
  docker build -f docker/Dockerfile.$svc -t omnitradeerp-$svc:latest . > /tmp/build-$svc.log 2>&1
  rc=$?
  TS=$(date '+%H:%M:%S')
  if [ $rc -eq 0 ]; then
    echo "$TS PASS $svc"
  else
    echo "$TS FAIL $svc rc=$rc"
  fi
done
TS=$(date '+%H:%M:%S')
echo "$TS ALL_DONE"
