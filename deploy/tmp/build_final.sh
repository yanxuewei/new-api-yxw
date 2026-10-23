#!/bin/bash
cd /opt/OmniTradeERP
for svc in warehouse-service inventory-service; do
  TS=$(date '+%H:%M:%S')
  echo "$TS START $svc"
  docker build --no-cache -f docker/Dockerfile.$svc -t omnitradeerp-$svc:latest . > /tmp/build-$svc-final.log 2>&1
  rc=$?
  TS=$(date '+%H:%M:%S')
  if [ $rc -eq 0 ]; then
    echo "$TS PASS $svc"
  else
    echo "$TS FAIL $svc rc=$rc"
    grep -E 'ERROR|COMPILATION|cannot find' /tmp/build-$svc-final.log | tail -10
  fi
done
TS=$(date '+%H:%M:%S')
echo "$TS ALL_DONE"
