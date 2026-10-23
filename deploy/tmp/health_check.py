#!/usr/bin/env python3
"""health_check.py - 等待所有服务健康并测试前端 API"""
import subprocess, time, os, json

os.chdir("/opt/OmniTradeERP")

def compose_ps():
    r = subprocess.run(["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "ps", "--format", "json"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode("utf-8", errors="replace").strip()
    containers = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            containers.append(json.loads(line))
        except:
            pass
    return containers

def all_healthy(containers):
    """检查所有容器是否都 healthy 或 running"""
    for c in containers:
        state = c.get("Health", c.get("Status", ""))
        name = c.get("Service", c.get("Name", "?"))
        # running 且 (healthy 或 没有 health 检查)
        if "starting" in str(state).lower():
            return False
    return True

# 最多等 180 秒
print(f"[{time.strftime('%c')}] Waiting for services to become healthy (max 180s)...")
for attempt in range(36):
    containers = compose_ps()
    if not containers:
        # fallback to non-json
        r = subprocess.run(["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "ps"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(f"  attempt {attempt+1}: {r.stdout.decode(errors='replace').strip()[-500:]}")
    else:
        states = {}
        for c in containers:
            name = c.get("Service", c.get("Name", "?"))
            health = c.get("Health", "none")
            status = c.get("Status", "?")
            states[name] = f"{status}/{health}"
        starting = [k for k, v in states.items() if "starting" in v]
        if not starting:
            print(f"[{time.strftime('%c')}] All services stable!")
            for k, v in sorted(states.items()):
                print(f"  {k}: {v}")
            break
        if attempt % 6 == 0:
            print(f"[{time.strftime('%c')}] attempt {attempt+1}: {len(starting)} still starting: {starting}")
    time.sleep(5)

# 最终状态
print(f"\n[{time.strftime('%c')}] Final container status:")
r = subprocess.run(["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "ps"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode("utf-8", errors="replace"))

# 测试各服务 health endpoint
print(f"\n[{time.strftime('%c')}] Testing service health endpoints:")
services = [
    ("order-service", 8081),
    ("product-service", 8083),
    ("user-service", 8084),
    ("warehouse-service", 8085),
    ("inventory-service", 8086),
    ("customer-service", 8087),
    ("supplier-service", 8088),
    ("gateway", 8080),
]

for name, port in services:
    r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        f"http://127.0.0.1:{port}/actuator/health"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    code = r.stdout.decode("utf-8", errors="replace").strip()
    print(f"  {name} (:{port}): HTTP {code}")

# 测试前端
print(f"\n[{time.strftime('%c')}] Testing frontend:")
r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                    "http://127.0.0.1:3000/"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
print(f"  frontend (:3000): HTTP {r.stdout.decode().strip()}")

# 测试网关路由到后端
print(f"\n[{time.strftime('%c')}] Testing gateway API routes:")
for path in ["/api/order", "/api/product", "/api/user", "/api/warehouse", "/api/inventory", "/api/customer", "/api/supplier"]:
    r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        f"http://127.0.0.1:8080{path}"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    code = r.stdout.decode().strip()
    print(f"  {path}: HTTP {code}")

print(f"\n[{time.strftime('%c')}] DONE")
