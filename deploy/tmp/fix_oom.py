#!/usr/bin/env python3
"""
OOM fix script:
1. Create 2GB swapfile
2. Patch docker-compose.yml - add JVM memory limits and MySQL tuning
3. docker compose up -d
"""
import subprocess, sys, os, re

RESULT = "/tmp/oom-fix.result"
COMPOSE = "/opt/OmniTradeERP/docker-compose.yml"
COMPOSE_BAK = "/opt/OmniTradeERP/docker-compose.yml.bak"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== OOM Fix Script ===")

# 1. Create swapfile if not exists
out, rc = run("swapon --show")
if "/swapfile" in out:
    log("[SWAP] /swapfile already active, skip")
else:
    log("[SWAP] Creating 2GB swapfile...")
    cmds = [
        "fallocate -l 2G /swapfile",
        "chmod 600 /swapfile",
        "mkswap /swapfile",
        "swapon /swapfile",
        "echo '/swapfile none swap sw 0 0' >> /etc/fstab",
    ]
    for c in cmds:
        out, rc = run(c)
        status = "OK" if rc == 0 else "FAIL"
        log(f"  [{status}] {c}: {out[:80]}")
    out, rc = run("free -m")
    log(f"[SWAP] free -m:\n{out}")

# 2. Read compose file
with open(COMPOSE, "r") as f:
    content = f.read()

# Backup
if not os.path.exists(COMPOSE_BAK):
    with open(COMPOSE_BAK, "w") as f:
        f.write(content)
    log("[COMPOSE] Backup created")

# 3. Patch Nacos JVM: 512m -> 192m
content = content.replace("JVM_XMS: 512m", "JVM_XMS: 192m")
content = content.replace("JVM_XMX: 512m", "JVM_XMX: 192m")
log("[COMPOSE] Nacos JVM patched to 192m")

# 4. Patch MySQL: add command for lower memory
mysql_old = """  mysql:
    image: mysql:8.0
    container_name: erp-mysql"""
mysql_new = """  mysql:
    image: mysql:8.0
    container_name: erp-mysql
    command: --innodb-buffer-pool-size=128M --performance-schema=OFF --max-connections=50"""
if mysql_old in content and mysql_new not in content:
    content = content.replace(mysql_old, mysql_new)
    log("[COMPOSE] MySQL command patched (innodb-buffer-pool-size=128M)")
else:
    log("[COMPOSE] MySQL command already patched or pattern not found, skip")

# 5. Add JAVA_OPTS to all Java services (those with NACOS_SERVER_ADDR env)
# Pattern: find each service environment block and insert JAVA_OPTS if missing
JAVA_OPTS_LINE = "      JAVA_OPTS: \"-Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:+UseSerialGC\""
ANCHOR = "      NACOS_SERVER_ADDR: nacos:8848"

if JAVA_OPTS_LINE not in content:
    # Insert JAVA_OPTS before NACOS_SERVER_ADDR in every service
    content = content.replace(
        ANCHOR,
        JAVA_OPTS_LINE + "\n" + ANCHOR
    )
    log("[COMPOSE] JAVA_OPTS added to all Java services")
else:
    log("[COMPOSE] JAVA_OPTS already present, skip")

# 6. Write patched compose
with open(COMPOSE, "w") as f:
    f.write(content)
log("[COMPOSE] docker-compose.yml written")

# 7. docker compose down then up
log("[DOCKER] Stopping containers...")
out, rc = run("cd /opt/OmniTradeERP && docker compose down --remove-orphans 2>&1")
log(f"  down: rc={rc} {out[-200:]}")

log("[DOCKER] Starting containers...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d 2>&1")
log(f"  up: rc={rc} {out[-400:]}")

# 8. Show final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] docker compose ps:")
log(out)

log("\n=== Done ===")
