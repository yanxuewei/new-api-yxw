#!/bin/bash
cd /opt/OmniTradeERP
for svc in warehouse-service inventory-service; do
  TS=$(date '+%H:%M:%S')
  echo "$TS START $svc"
  docker build --no-cache -f docker/Dockerfile.$svc -t omnitradeerp-$svc:latest . > /tmp/build-$svc-v5.log 2>&1
  rc=$?
  TS=$(date '+%H:%M:%S')
  if [ $rc -eq 0 ]; then
    echo "$TS PASS $svc"
  else
    echo "$TS FAIL $svc rc=$rc"
    grep "symbol:.*class" /tmp/build-$svc-v5.log | sed 's/.*class //' | sort -u
    grep "illegal escape\|unclosed string\|COMPILATION" /tmp/build-$svc-v5.log | head -5
  fi
done
echo "$(date '+%H:%M:%S') ALL_DONE"
