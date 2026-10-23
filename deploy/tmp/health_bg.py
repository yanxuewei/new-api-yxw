#!/usr/bin/env python3
"""后台健康检查：轮询 docker compose ps，等全部 healthy 后测试各服务 actuator/health 和网关路由"""
import subprocess, time, json

RESULT = "/tmp/health-check.result"
COMPOSE_DIR = "/opt/OmniTradeERP"
MAX_WAIT = 240  # 最多等 4 分钟

SERVICES = [
    ("erp-gateway",          8080),
    ("erp-order-service",    8081),
    ("erp-product-service",  8082),
    ("erp-warehouse-service",8083),
    ("erp-inventory-service",8084),
    ("erp-customer-service", 8085),
    ("erp-supplier-service", 8086),
]

GATEWAY_ROUTES = [
    "/api/order/orders",
    "/api/product/products",
    "/api/warehouse/inbound",
    "/api/inventory/list",
    "/api/customer/customers",
    "/api/supplier/suppliers",
]

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

def write(lines):
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")

lines = ["=== OmniTradeERP Health Check ===", f"started: {time.strftime('%Y-%m-%d %H:%M:%S')}"]
write(lines)

# 1. 等待所有容器离开 health: starting
deadline = time.time() + MAX_WAIT
while time.time() < deadline:
    out, _ = run(f"cd {COMPOSE_DIR} && docker compose ps --format json 2>/dev/null || docker compose ps")
    still_starting = "starting" in out
    if not still_starting:
        break
    lines.append(f"[{time.strftime('%H:%M:%S')}] still starting, waiting...")
    write(lines)
    time.sleep(10)

# 2. 记录当前 compose ps
ps_out, _ = run(f"cd {COMPOSE_DIR} && docker compose ps")
lines.append("\n--- docker compose ps ---")
lines.extend(ps_out.splitlines())
write(lines)

# 3. 逐服务测 actuator/health
lines.append("\n--- actuator/health ---")
for svc, port in SERVICES:
    url = f"http://localhost:{port}/actuator/health"
    out, rc = run(f"curl -sf --max-time 5 {url}")
    status = "OK" if rc == 0 else "FAIL"
    lines.append(f"  {svc}:{port}  {status}  {out[:120]}")
    write(lines)

# 4. 测网关路由（期望非 503）
lines.append("\n--- gateway routes ---")
for route in GATEWAY_ROUTES:
    url = f"http://localhost:8080{route}"
    out, rc = run(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 {url}")
    lines.append(f"  {route}  HTTP {out}")
    write(lines)

lines.append(f"\nfinished: {time.strftime('%Y-%m-%d %H:%M:%S')}")
write(lines)
print("done")
