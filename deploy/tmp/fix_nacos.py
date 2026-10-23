#!/usr/bin/env python3
"""Fix: 1. ALTER USER root to mysql_native_password  2. CREATE nacos DB  3. Restart nacos"""
import subprocess, time

RESULT = "/tmp/fix_nacos.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Fix Nacos MySQL Connection ===")

# 1. Wait for MySQL healthy
for i in range(20):
    out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-mysql 2>/dev/null")
    if "healthy" in out:
        log(f"[MYSQL] healthy")
        break
    time.sleep(3)
else:
    log("[MYSQL] NOT healthy, abort")
    exit(1)

# 2. ALTER USER root to mysql_native_password + create nacos DB
sql = """
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS nacos DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
"""
log("[SQL] Executing ALTER USER + CREATE DATABASE nacos...")
out, rc = run(f"docker exec erp-mysql mysql -uroot -proot -e \"{sql}\" 2>&1")
log(f"  rc={rc}: {out}")

# Verify
out, _ = run("docker exec erp-mysql mysql -uroot -proot -e \"SELECT user, host, plugin FROM mysql.user WHERE user='root';\" 2>&1")
log(f"[VERIFY] root user plugin:\n{out}")

out, _ = run("docker exec erp-mysql mysql -uroot -proot -e \"SHOW DATABASES;\" 2>&1")
log(f"[VERIFY] databases:\n{out}")

# 3. Restart nacos
log("[NACOS] Restarting nacos...")
out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build nacos 2>&1")
log(f"  nacos up: rc={rc} {out[-300:]}")

# 4. Wait for nacos healthy
for i in range(30):
    time.sleep(5)
    out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
    log(f"  nacos health: {out}")
    if "healthy" in out:
        break
    # Check if exited
    out2, _ = run("docker inspect --format '{{.State.Status}}' erp-nacos 2>/dev/null")
    if "exited" in out2:
        log(f"  nacos exited! Checking logs...")
        out3, _ = run("docker logs erp-nacos --tail 10 2>&1")
        log(out3)
        break

# 5. If nacos healthy, start all services
out, _ = run("docker inspect --format '{{.State.Health.Status}}' erp-nacos 2>/dev/null")
if "healthy" in out:
    log("[DOCKER] Nacos healthy, starting all services...")
    out, rc = run("cd /opt/OmniTradeERP && docker compose up -d --no-build 2>&1")
    log(f"  up all: rc={rc} {out[-500:]}")
else:
    log("[DOCKER] Nacos not healthy, checking logs...")
    out, _ = run("docker logs erp-nacos --tail 20 2>&1")
    log(out)

# Final ps
out, _ = run("cd /opt/OmniTradeERP && docker compose ps 2>&1")
log("\n[DOCKER] docker compose ps:")
log(out)

out, _ = run("free -m")
log("\n[MEM] free -m:")
log(out)

log("\n=== Done ===")
