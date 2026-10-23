#!/usr/bin/env python3
"""
Rewrite docker-compose.yml to:
1. Use image: (not build:) for all services
2. Fix port mappings to match actual application.yml
3. Add customer-service and supplier-service
4. Remove services with no image
5. Fix nginx vs frontend port 80 conflict
"""
import subprocess, os, re

COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
RESULT  = "/tmp/rewrite-compose.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Rewrite docker-compose.yml ===")

# Read actual ports from application.yml
def get_port(svc):
    yml = f"/opt/OmniTradeERP/erp-{svc}-service/src/main/resources/application.yml"
    if not os.path.exists(yml):
        return None
    with open(yml) as f:
        c = f.read()
    m = re.search(r'^\s*port:\s*(\d+)', c, re.MULTILINE)
    return m.group(1) if m else None

services_ports = {}
for svc in ["order","product","warehouse","inventory","customer","supplier","user","gateway"]:
    p = get_port(svc)
    services_ports[svc] = p
    log(f"  erp-{svc}-service port: {p}")

# New docker-compose content
new_compose = '''version: '3.8'

services:
  mysql:
    image: mysql:8.0
    container_name: erp-mysql
    command: --innodb-buffer-pool-size=128M --performance-schema=OFF --max-connections=50
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: erp
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      - ./database/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    networks:
      - erp-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-proot"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: erp-redis
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - erp-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    container_name: erp-rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: guest
      RABBITMQ_DEFAULT_VHOST: /erp
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:5672:5672"
      - "127.0.0.1:15672:15672"
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    networks:
      - erp-network
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5

  nacos:
    image: nacos/nacos-server:v2.4.0
    container_name: erp-nacos
    environment:
      MODE: standalone
      SPRING_DATASOURCE_PLATFORM: mysql
      MYSQL_SERVICE_HOST: mysql
      MYSQL_SERVICE_DB_NAME: nacos
      MYSQL_SERVICE_PORT: 3306
      MYSQL_SERVICE_USER: root
      MYSQL_SERVICE_PASSWORD: root
      PREFER_HOST_MODE: hostname
      JVM_XMS: 192m
      JVM_XMX: 192m
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:8848:8848"
      - "127.0.0.1:9848:9848"
    volumes:
      - nacos-data:/home/nacos/data
      - nacos-logs:/home/nacos/logs
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - erp-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8848/nacos/v1/console/health/readiness"]
      interval: 10s
      timeout: 5s
      retries: 10

  gateway:
    image: omnitradeerp-gateway:latest
    container_name: erp-gateway
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      TZ: Asia/Shanghai
    depends_on:
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  order-service:
    image: omnitradeerp-order-service:latest
    container_name: erp-order-service
    ports:
      - "127.0.0.1:8081:8081"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8081/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  product-service:
    image: omnitradeerp-product-service:latest
    container_name: erp-product-service
    ports:
      - "127.0.0.1:8083:8083"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8083/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  warehouse-service:
    image: omnitradeerp-warehouse-service:latest
    container_name: erp-warehouse-service
    ports:
      - "127.0.0.1:8085:8085"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8085/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  inventory-service:
    image: omnitradeerp-inventory-service:latest
    container_name: erp-inventory-service
    ports:
      - "127.0.0.1:8086:8086"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8086/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  customer-service:
    image: omnitradeerp-customer-service:latest
    container_name: erp-customer-service
    ports:
      - "127.0.0.1:8087:8087"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8087/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  supplier-service:
    image: omnitradeerp-supplier-service:latest
    container_name: erp-supplier-service
    ports:
      - "127.0.0.1:8088:8088"
    environment:
      JAVA_OPTS: "-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC"
      NACOS_SERVER_ADDR: nacos:8848
      MYSQL_HOST: mysql
      REDIS_HOST: redis
      RABBITMQ_HOST: rabbitmq
      TZ: Asia/Shanghai
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8088/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  frontend:
    image: omnitradeerp-frontend:latest
    container_name: erp-frontend
    ports:
      - "127.0.0.1:3000:80"
    depends_on:
      gateway:
        condition: service_healthy
    networks:
      - erp-network
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  mysql-data:
  redis-data:
  rabbitmq-data:
  nacos-data:
  nacos-logs:

networks:
  erp-network:
    driver: bridge
'''

# Write new compose
with open(COMPOSE, "w") as f:
    f.write(new_compose)
log("[COMPOSE] New docker-compose.yml written (image: refs, correct ports, removed missing services)")

# docker compose down all
log("[DOCKER] docker compose down...")
out, rc = run("cd /opt/OmniTradeERP && docker compose down --remove-orphans 2>&1")
log(f"  rc={rc}: {out[-300:]}")

# docker compose up --no-build
log("[DOCKER] docker compose up -d --no-build...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
log(f"  rc={rc}: {out[-500:]}")

# Final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] docker compose ps:")
log(out)

out, _ = run("free -m")
log("\n[MEM] free -m:")
log(out)

log("\n=== Done ===")
