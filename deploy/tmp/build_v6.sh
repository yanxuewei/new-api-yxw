#!/bin/bash
cd /opt/OmniTradeERP
for svc in warehouse-service inventory-service; do
  echo "$(date '+%H:%M:%S') START $svc"
  docker build --no-cache -f docker/Dockerfile.$svc -t omnitradeerp-$svc:latest . \
    > /tmp/build-$svc-v6.log 2>&1 && echo "$(date '+%H:%M:%S') PASS $svc" || {
    echo "$(date '+%H:%M:%S') FAIL $svc"
    echo "--- ERROR SUMMARY ---"
    grep -E "ERROR|COMPILATION|error:" /tmp/build-$svc-v6.log | grep -v "^\[INFO\]" | tail -30
    echo "--- CANNOT FIND SYMBOL ---"
    grep "cannot find symbol" /tmp/build-$svc-v6.log | sed 's/.*error://' | sort -u | head -20
  }
done
echo "$(date '+%H:%M:%S') ALL_DONE"
