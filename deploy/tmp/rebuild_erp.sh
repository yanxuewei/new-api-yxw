#!/bin/bash
cd /opt/OmniTradeERP || { echo "dir not found"; exit 1; }

echo "[1/5] 重建镜像"
for entry in "customer:docker/Dockerfile.customer-service:omnitradeerp-customer-service" "supplier:docker/Dockerfile.supplier-service:omnitradeerp-supplier-service" "product:docker/Dockerfile.product-service:omnitradeerp-product-service" "warehouse:docker/Dockerfile.warehouse-service:omnitradeerp-warehouse-service" "inventory:docker/Dockerfile.inventory-service:omnitradeerp-inventory-service"; do
  svc="${entry%%:*}"; rest="${entry#*:}"; dockerfile="${rest%%:*}"; image="${rest##*:}"
  echo "--- $svc ---"
  [ -f "$dockerfile" ] || dockerfile=$(find . -name "Dockerfile*" | grep -i "$svc" | grep -v "prediction\|alert\|description\|recommendation\|social\|pricing\|analytics\|anomaly\|ai-assistant" | head -1)
  echo "  Dockerfile: $dockerfile"
  docker build -f "$dockerfile" -t "${image}:latest" . 2>&1 | tail -3
done

echo "[2/5] compose.yml RABBIT/REDIS 注入验证"
grep -E "RABBIT|REDIS|ELASTIC" docker-compose.yml | head -15

echo "[3/5] 重启服务"
docker compose -f docker-compose.yml up -d --no-build erp-customer-service erp-supplier-service erp-product-service erp-warehouse-service erp-inventory-service erp-order-service erp-gateway 2>&1 | tail -10

echo "[4/5] 等待 90s"
sleep 90

echo "[5/5] 状态检查"
docker ps --format "table {{.Names}}\t{{.Status}}" | grep erp-
for p in "8081" "8083" "8085" "8086" "8087" "8088"; do
  echo "  port $p: $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:${p}/actuator/health)"
done
echo "DONE"
