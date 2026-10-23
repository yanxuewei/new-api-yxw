#!/usr/bin/env python3
"""读取 Restarting 容器的启动日志 (python3.6 兼容)"""
import subprocess

containers = [
    "erp-warehouse-service",
    "erp-inventory-service",
    "erp-customer-service",
    "erp-supplier-service",
]

for c in containers:
    print("\n" + "="*60)
    print("=== " + c + " ===")
    r = subprocess.run(["/usr/bin/docker", "logs", "--tail", "60", c],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode("utf-8", errors="replace").strip()
    if out:
        print(out[-3000:])
    else:
        print("(no output)")
