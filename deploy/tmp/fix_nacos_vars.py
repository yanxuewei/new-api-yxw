#!/usr/bin/env python3
"""
Fix:
1. Add NACOS_HOST/NACOS_PORT to all Java services in docker-compose.yml
2. Create erp-dev namespace in Nacos
3. Restart all Java services
"""
import subprocess, time, re

COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
RESULT  = "/tmp/fix_nacos_vars.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Fix NACOS_HOST/NACOS_PORT + erp-dev namespace ===")

# 1. Patch docker-compose.yml
with open(COMPOSE) as f:
    content = f.read()

# Replace NACOS_SERVER_ADDR with NACOS_HOST + NACOS_PORT in all services
old_var = "      NACOS_SERVER_ADDR: nacos:8848"
new_vars = "      NACOS_HOST: nacos\n      NACOS_PORT: 8848"

if old_var in content:
    count = content.count(old_var)
    content = content.replace(old_var, new_vars)
    log(f"[COMPOSE] Replaced NACOS_SERVER_ADDR with NACOS_HOST/NACOS_PORT in {count} places")
else:
    # Already replaced or different format
    log("[COMPOSE] NACOS_SERVER_ADDR not found, checking current state...")
    if "NACOS_HOST: nacos" in content:
        log("[COMPOSE] NACOS_HOST already set, skip")
    else:
        log("[COMPOSE] WARNING: could not find NACOS_SERVER_ADDR pattern")

with open(COMPOSE, "w") as f:
    f.write(content)
log("[COMPOSE] docker-compose.yml saved")

# 2. Wait for Nacos healthy
log("[NACOS] Waiting for Nacos healthy...")
for i in range(20):
    out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
    if out.strip() == "healthy":
        log(f"[NACOS] healthy at {i*3}s")
        break
    time.sleep(3)
else:
    log("[NACOS] WARNING: not healthy after 60s")

# 3. Create erp-dev namespace in Nacos
log("[NACOS] Creating erp-dev namespace...")
time.sleep(2)
out, rc = run(
    "curl -sf -X POST 'http://localhost:8848/nacos/v1/console/namespaces' "
    "-d 'customNamespaceId=erp-dev&namespaceName=erp-dev&namespaceDesc=ERP+Dev+Namespace'"
)
log(f"  create namespace: rc={rc} response={out}")

# Verify namespace
out, rc = run("curl -sf 'http://localhost:8848/nacos/v1/console/namespaces' 2>/dev/null")
log(f"  list namespaces: {out[:300]}")

# 4. Restart all Java services (not infra)
log("[DOCKER] Restarting all Java services...")
java_services = ["gateway", "order-service", "product-service", "warehouse-service",
                 "inventory-service", "customer-service", "supplier-service"]
for svc in java_services:
    out, rc = run(f"cd /opt/OmniTradeERP && docker compose rm -sf {svc} 2>&1")
    log(f"  rm {svc}: rc={rc}")

time.sleep(2)

out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
log(f"[DOCKER] up all: rc={rc} {out[-500:]}")

# 5. Monitor for 90s
log("[MONITOR] Waiting 90s for services to start...")
for i in range(9):
    time.sleep(10)
    out, _ = run("cd /opt/OmniTradeERP && docker compose ps --format '{{.Name}} {{.Status}}' 2>/dev/null || docker compose ps 2>&1 | tail -20")
    log(f"[{(i+1)*10}s] {out}")

# Final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] Final docker compose ps:")
log(out)

out, _ = run("free -m")
log("\n[MEM] free -m:")
log(out)

log("\n=== Done ===")
