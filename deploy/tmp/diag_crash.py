#!/usr/bin/env python3
"""读容器日志头部（根因）+ customer Dockerfile"""
import subprocess

# 1. warehouse/inventory 日志头部
for c in ["erp-warehouse-service", "erp-inventory-service"]:
    print("\n" + "="*60)
    print("=== " + c + " HEAD ===")
    r = subprocess.run(["/usr/bin/docker", "logs", "--tail", "200", c],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode("utf-8", errors="replace").strip()
    # 找第一个 ERROR/Exception/Caused by
    lines = out.splitlines()
    start = 0
    for i, l in enumerate(lines):
        if any(k in l for k in ["ERROR", "Exception", "Caused by", "Cannot", "Failed", "Error"]):
            start = max(0, i-2)
            break
    print("\n".join(lines[start:start+60]))

# 2. customer Dockerfile
print("\n" + "="*60)
print("=== docker/Dockerfile.customer-service ===")
try:
    with open("/opt/OmniTradeERP/docker/Dockerfile.customer-service") as f:
        print(f.read())
except Exception as e:
    print("ERROR:", e)
