#!/usr/bin/env python3
"""build_v9.py - 用 Python 直接调 docker build，绕开 shell CRLF/PATH 问题"""
import subprocess, time, os

os.chdir("/opt/OmniTradeERP")
status = "/tmp/build-v9.status"
with open(status, "w") as f:
    f.write(f"[{time.strftime('%c')}] Starting v9 build (python)...\n")

targets = [
    ("warehouse-service", "Dockerfile.warehouse-service", "erp-warehouse-service:latest", "/tmp/build-wh-v9.log"),
    ("inventory-service", "Dockerfile.inventory-service", "erp-inventory-service:latest", "/tmp/build-inv-v9.log"),
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
