#!/usr/bin/env python3
"""启动所有容器并轮询健康状态"""
import subprocess, time, os

os.chdir("/opt/OmniTradeERP")
status = "/tmp/compose-up.status"

with open(status, "w") as f:
    f.write(f"[{time.strftime('%c')}] Starting docker-compose up...\n")

with open("/tmp/compose-up.log", "w") as log:
    r = subprocess.run(
        ["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "up", "-d", "--remove-orphans"],
        stdout=log, stderr=subprocess.STDOUT
    )

with open(status, "a") as f:
    if r.returncode == 0:
        f.write(f"[{time.strftime('%c')}] docker-compose up SUCCESS\n")
    else:
        f.write(f"[{time.strftime('%c')}] docker-compose up FAILURE rc={r.returncode}\n")

# 列出容器状态
with open("/tmp/compose-ps.log", "w") as log:
    subprocess.run(
        ["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "ps"],
        stdout=log, stderr=subprocess.STDOUT
    )

with open(status, "a") as f:
    f.write(f"[{time.strftime('%c')}] ALL DONE\n")
