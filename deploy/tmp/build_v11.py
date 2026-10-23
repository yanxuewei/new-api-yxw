#!/usr/bin/env python3
"""build_v11.py - 重建 4 个服务镜像"""
import subprocess, time, os

os.chdir("/opt/OmniTradeERP")
status = "/tmp/build-v11.status"
with open(status, "w") as f:
    f.write(f"[{time.strftime('%c')}] Starting v11 build...\n")

targets = [
    ("warehouse-service",  "docker/Dockerfile.warehouse-service",  "omnitradeerp-warehouse-service:latest",  "/tmp/build-wh-v11.log"),
    ("inventory-service",  "docker/Dockerfile.inventory-service",  "omnitradeerp-inventory-service:latest",  "/tmp/build-inv-v11.log"),
    ("customer-service",   "docker/Dockerfile.customer-service",   "omnitradeerp-customer-service:latest",   "/tmp/build-cu-v11.log"),
    ("supplier-service",   "docker/Dockerfile.supplier-service",   "omnitradeerp-supplier-service:latest",   "/tmp/build-su-v11.log"),
]

for name, dockerfile, tag, logf in targets:
    with open(status, "a") as f:
        f.write(f"[{time.strftime('%c')}] Building {name}...\n")
    with open(logf, "w") as log:
        r = subprocess.run(["/usr/bin/docker", "build", "-f", dockerfile, "-t", tag, "."],
                           stdout=log, stderr=subprocess.STDOUT)
    with open(status, "a") as f:
        result = "BUILD SUCCESS" if r.returncode == 0 else f"BUILD FAILURE (rc={r.returncode})"
        f.write(f"[{time.strftime('%c')}] {name} {result}\n")

with open(status, "a") as f:
    f.write(f"[{time.strftime('%c')}] ALL DONE\n")
