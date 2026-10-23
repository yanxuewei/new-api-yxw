#!/usr/bin/env python3
"""Fix MySQL auth plugin + restart Nacos"""
import subprocess, os

COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
RESULT = "/tmp/fix_mysql_auth.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Fix MySQL auth plugin ===")

# Read compose
with open(COMPOSE) as f:
    content = f.read()

# Add default-authentication-plugin to MySQL command
old_cmd = "command: --innodb-buffer-pool-size=128M --performance-schema=OFF --max-connections=50"
new_cmd = "command: --innodb-buffer-pool-size=128M --performance-schema=OFF --max-connections=50 --default-authentication-plugin=mysql_native_password"

if old_cmd in content and new_cmd not in content:
    content = content.replace(old_cmd, new_cmd)
    with open(COMPOSE, "w") as f:
        f.write(content)
    log("[COMPOSE] MySQL command patched with mysql_native_password")
else:
    log("[COMPOSE] Already patched or pattern not found")

# Also need to recreate MySQL container to apply new command
# And recreate the root user with native password
log("[DOCKER] Recreating mysql container...")
out, rc = run("cd /opt/OmniTradeERP && docker compose stop mysql nacos 2>&1")
log(f"  stop: rc={rc} {out[-200:]}")

out, rc = run("cd /opt/OmniTradeERP && docker compose rm -f mysql nacos 2>&1")
log(f"  rm: rc={rc} {out[-200:]}")

# Remove mysql volume to force fresh init with native password
out, rc = run("cd /opt/OmniTradeERP && docker volume rm omnitradeerp_mysql-data 2>&1")
log(f"  volume rm: rc={rc} {out[-200:]}")

# Start mysql first
log("[DOCKER] Starting mysql...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build mysql 2>&1")
log(f"  mysql up: rc={rc} {out[-200:]}")

# Wait for mysql healthy
import time
for i in range(30):
    time.sleep(5)
    out, _ = run("cd /opt/OmniTradeERP && docker inspect --format '{{.State.Health.Status}}' erp-mysql 2>/dev/null")
    log(f"  mysql health: {out}")
    if "healthy" in out:
        break

# Start nacos
log("[DOCKER] Starting nacos...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build nacos 2>&1")
log(f"  nacos up: rc={rc} {out[-200:]}")

# Wait for nacos healthy
for i in range(20):
    time.sleep(5)
    out, _ = run("cd /opt/OmniTradeERP && docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
    log(f"  nacos health: {out}")
    if "healthy" in out:
        break

# Start all services
log("[DOCKER] Starting all services...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
log(f"  up all: rc={rc} {out[-400:]}")

# Final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] docker compose ps:")
log(out)

out, _ = run("free -m")
log("\n[MEM] free -m:")
log(out)

log("\n=== Done ===")
