#!/bin/bash
# 轮询等待 build_v6.sh 完成
for i in $(seq 1 55); do
  if ! pgrep -f "Dockerfile.warehouse-service" >/dev/null && ! pgrep -f "Dockerfile.inventory-service" >/dev/null; then
    break
  fi
  sleep 30
done

echo "=== warehouse-service ==="
if grep -q "BUILD SUCCESS" /tmp/build-warehouse-service-v6.log 2>/dev/null; then
  echo "PASS"
  docker images omnitradeerp-warehouse-service --format "{{.Repository}}:{{.Tag}}  {{.CreatedSince}}"
else
  echo "FAIL"
  grep -E "ERROR\]|cannot find symbol|error:" /tmp/build-warehouse-service-v6.log | grep -v "^\[INFO\]" | tail -20
fi

echo "=== inventory-service ==="
if grep -q "BUILD SUCCESS" /tmp/build-inventory-service-v6.log 2>/dev/null; then
  echo "PASS"
  docker images omnitradeerp-inventory-service --format "{{.Repository}}:{{.Tag}}  {{.CreatedSince}}"
else
  echo "FAIL"
  grep -E "ERROR\]|cannot find symbol|error:" /tmp/build-inventory-service-v6.log | grep -v "^\[INFO\]" | tail -20
fi

echo "=== DONE ==="
