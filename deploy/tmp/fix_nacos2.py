#!/usr/bin/env python3
"""Fix Nacos: switch to embedded Derby storage (remove MySQL datasource config), clear stale volume"""
import subprocess, time

COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
RESULT = "/tmp/fix_nacos2.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Fix Nacos: embedded Derby storage ===")

# Read compose
with open(COMPOSE) as f:
    content = f.read()

# Replace nacos service block to remove MySQL datasource env vars
old_nacos = """  nacos:
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
      retries: 10"""

new_nacos = """  nacos:
    image: nacos/nacos-server:v2.4.0
    container_name: erp-nacos
    environment:
      MODE: standalone
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
    networks:
      - erp-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8848/nacos/v1/console/health/readiness"]
      interval: 10s
      timeout: 5s
      retries: 10"""

if old_nacos in content:
    content = content.replace(old_nacos, new_nacos)
    log("[COMPOSE] Nacos MySQL datasource removed, using embedded Derby")
else:
    # Try to patch just the datasource lines
    import re
    content = re.sub(r'\s+SPRING_DATASOURCE_PLATFORM:.*\n', '\n', content)
    content = re.sub(r'\s+MYSQL_SERVICE_HOST:.*\n', '\n', content)
    content = re.sub(r'\s+MYSQL_SERVICE_DB_NAME:.*\n', '\n', content)
    content = re.sub(r'\s+MYSQL_SERVICE_PORT:.*\n', '\n', content)
    content = re.sub(r'\s+MYSQL_SERVICE_USER:.*\n', '\n', content)
    content = re.sub(r'\s+MYSQL_SERVICE_PASSWORD:.*\n', '\n', content)
    # Remove depends_on mysql from nacos
    content = re.sub(r'(  nacos:.*?)(\s+depends_on:.*?condition: service_healthy\n)', 
                     lambda m: m.group(1), content, flags=re.DOTALL)
    log("[COMPOSE] Nacos MySQL env vars removed via regex")

with open(COMPOSE, "w") as f:
    f.write(content)
log("[COMPOSE] docker-compose.yml saved")

# Stop and remove nacos container + volume
log("[DOCKER] Removing nacos container and volume...")
out, rc = run("docker stop erp-nacos 2>&1; docker rm erp-nacos 2>&1")
log(f"  stop/rm: {out[-200:]}")

out, rc = run("docker volume rm omnitradeerp_nacos-data omnitradeerp_nacos-logs 2>&1")
log(f"  volume rm: rc={rc} {out}")

# Start nacos
log("[DOCKER] Starting nacos (embedded Derby)...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build nacos 2>&1")
log(f"  nacos up: rc={rc} {out[-300:]}")

# Wait for nacos healthy
for i in range(36):
    time.sleep(5)
    out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
    status = out.strip()
    log(f"  [{i*5}s] nacos health: {status}")
    if status == "healthy":
        break
    out2, _ = run("docker inspect --format '{{.State.Status}}' erp-nacos 2>/dev/null")
    if "exited" in out2:
        log("  nacos exited! Logs:")
        out3, _ = run("docker logs erp-nacos --tail 15 2>&1")
        log(out3)
        break

# Start all services
out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
if out.strip() == "healthy":
    log("[DOCKER] Nacos healthy! Starting all services...")
    out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
    log(f"  up all: rc={rc} {out[-500:]}")
else:
    log("[DOCKER] Nacos not healthy yet, starting remaining services anyway...")
    out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
    log(f"  up all: rc={rc} {out[-300:]}")

# Final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] docker compose ps:")
log(out)

out, _ = run("free -m")
log("\n[MEM] free -m:")
log(out)

log("\n=== Done ===")
