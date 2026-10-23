#!/usr/bin/env python3
"""build_v10.py - 正确的 Dockerfile 路径和镜像名"""
import subprocess, time, os

os.chdir("/opt/OmniTradeERP")
status = "/tmp/build-v10.status"
with open(status, "w") as f:
    f.write(f"[{time.strftime('%c')}] Starting v10 build...\n")

targets = [
    ("warehouse-service", "docker/Dockerfile.warehouse-service", "omnitradeerp-warehouse-service:latest", "/tmp/build-wh-v10.log"),
    ("inventory-service", "docker/Dockerfile.inventory-service", "omnitradeerp-inventory-service:latest", "/tmp/build-inv-v10.log"),
]

for name, dockerfile, tag, logf in targets:
    with open(status, "a") as f:
        f.write(f"[{time.strftime('%c')}] Building {name} with {dockerfile} -> {tag}...\n")
    with open(logf, "w") as log:
        r = subprocess.run(["/usr/bin/docker", "build", "-f", dockerfile, "-t", tag, "."],
                           stdout=log, stderr=subprocess.STDOUT)
    with open(status, "a") as f:
        result = "BUILD SUCCESS" if r.returncode == 0 else f"BUILD FAILURE (rc={r.returncode})"
        f.write(f"[{time.strftime('%c')}] {name} {result}\n")

with open(status, "a") as f:
    f.write(f"[{time.strftime('%c')}] ALL DONE\n")
