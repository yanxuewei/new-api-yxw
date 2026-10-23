#!/usr/bin/env python3
"""restart_containers.py - 重启所有容器并显示状态"""
import subprocess, time, os

os.chdir("/opt/OmniTradeERP")

print(f"[{time.strftime('%c')}] Running docker compose up -d...")
r = subprocess.run(
    ["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "up", "-d", "--remove-orphans"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT
)
out = r.stdout.decode("utf-8", errors="replace")
print(out[-2000:])
print(f"rc={r.returncode}")

print(f"\n[{time.strftime('%c')}] Container status:")
r2 = subprocess.run(
    ["/usr/bin/docker", "compose", "-f", "docker-compose.standalone.yml", "ps"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT
)
print(r2.stdout.decode("utf-8", errors="replace"))
