#!/usr/bin/env python3
"""
Fix datasource URLs:
1. Create missing databases: erp_customer, erp_supplier
2. Add SPRING_DATASOURCE_URL env vars to each service in docker-compose.yml
3. Restart services
"""
import subprocess, time, re

COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
RESULT  = "/tmp/fix_ds.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Fix datasource URLs + missing DBs ===")

# 1. Create missing databases
missing_dbs = ["erp_customer", "erp_supplier"]
log("[MySQL] Creating missing databases...")
for db in missing_dbs:
    out, rc = run(f"docker exec erp-mysql mysql -uroot -proot -e "
                  f"\"CREATE DATABASE IF NOT EXISTS {db} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\" 2>&1")
    log(f"  CREATE {db}: rc={rc} {out.replace('mysql: [Warning] Using a password on the command line interface can be insecure.', '').strip()}")

# Verify
out, _ = run("docker exec erp-mysql mysql -uroot -proot -e \"SHOW DATABASES LIKE 'erp%';\" 2>&1")
log(f"[MySQL] erp* databases: {out}")

# 2. Read compose
with open(COMPOSE) as f:
    content = f.read()

# Service -> database mapping
SVC_DB = {
    "order-service":     ("order-service",    "erp_order"),
    "product-service":   ("product-service",  "erp_product"),
    "warehouse-service": ("warehouse-service","erp_warehouse"),
    "inventory-service": ("inventory-service","erp_inventory"),
    "customer-service":  ("customer-service", "erp_customer"),
    "supplier-service":  ("supplier-service", "erp_supplier"),
}

BASE_PARAMS = "useUnicode=true&characterEncoding=utf8&serverTimezone=Asia%2FShanghai&useSSL=false&allowPublicKeyRetrieval=true"

for svc_key, (svc_name, db_name) in SVC_DB.items():
    # Build SPRING_DATASOURCE_URL line
    ds_url = f"jdbc:mysql://mysql:3306/{db_name}?{BASE_PARAMS}"
    ds_line = f"      SPRING_DATASOURCE_URL: \"{ds_url}\""
    ds_user = "      SPRING_DATASOURCE_USERNAME: root"
    ds_pass = "      SPRING_DATASOURCE_PASSWORD: root"

    # Insert after NACOS_PORT line for this service
    # Find the service block and add env vars after NACOS_PORT
    anchor = f"      NACOS_PORT: 8848\n"

    # Only insert if not already present
    if f"SPRING_DATASOURCE_URL" not in content:
        # Will do bulk replace below
        pass

# Do bulk insert: find each occurrence of NACOS_PORT: 8848 and add datasource vars
# But each service has different DB name, so must do per-service

# Split compose into service blocks and patch each
for svc_key, (svc_name, db_name) in SVC_DB.items():
    ds_url = f"jdbc:mysql://mysql:3306/{db_name}?{BASE_PARAMS}"
    ds_block = (f"      SPRING_DATASOURCE_URL: \"{ds_url}\"\n"
                f"      SPRING_DATASOURCE_USERNAME: root\n"
                f"      SPRING_DATASOURCE_PASSWORD: root\n")

    # Find this service's block: look for container_name: erp-<svc_key minus -service>
    container_anchor = f"    container_name: erp-{svc_key}"
    if container_anchor not in content:
        log(f"  WARNING: container_name for {svc_key} not found")
        continue

    # Find the NACOS_PORT line after this container_name
    idx = content.find(container_anchor)
    nacos_port_idx = content.find("      NACOS_PORT: 8848", idx)
    if nacos_port_idx == -1:
        log(f"  WARNING: NACOS_PORT not found for {svc_key}")
        continue

    insert_pos = nacos_port_idx + len("      NACOS_PORT: 8848\n")

    # Check not already inserted
    check_region = content[nacos_port_idx:nacos_port_idx+300]
    if "SPRING_DATASOURCE_URL" in check_region:
        log(f"  {svc_key}: SPRING_DATASOURCE_URL already present, skip")
        continue

    content = content[:insert_pos] + ds_block + content[insert_pos:]
    log(f"  {svc_key}: added SPRING_DATASOURCE_URL -> {db_name}")

with open(COMPOSE, "w") as f:
    f.write(content)
log("[COMPOSE] docker-compose.yml saved")

# 3. Restart Java services
log("[DOCKER] Restarting Java services with new env vars...")
java_services = ["order-service", "product-service", "warehouse-service",
                 "inventory-service", "customer-service", "supplier-service", "gateway"]
for svc in java_services:
    out, rc = run(f"cd /opt/OmniTradeERP && docker compose rm -sf {svc} 2>&1")
    log(f"  rm {svc}: rc={rc}")

time.sleep(2)
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
log(f"[DOCKER] up all: rc={rc} {out[-400:]}")

# 4. Monitor 120s
log("[MONITOR] Waiting 120s...")
for i in range(12):
    time.sleep(10)
    out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1 | grep -v 'WARNING\\|obsolete'")
    log(f"[{(i+1)*10}s]\n{out}")
    if "Restarting" not in out and "starting" not in out and "unhealthy" not in out:
        log("All services stable!")
        break

# Final status
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[FINAL] docker compose ps:")
log(out)

# Test actuator health on all services
log("\n[HEALTH] actuator health checks:")
for svc, port in [("gateway",8080),("order",8081),("product",8083),
                  ("warehouse",8085),("inventory",8086),("customer",8087),("supplier",8088)]:
    out, rc = run(f"curl -sf --max-time 5 http://localhost:{port}/actuator/health 2>/dev/null")
    status = "OK" if rc == 0 else "FAIL"
    log(f"  {svc}:{port} {status} {out[:100]}")

out, _ = run("free -m")
log(f"\n[MEM] {out}")
log("\n=== Done ===")
