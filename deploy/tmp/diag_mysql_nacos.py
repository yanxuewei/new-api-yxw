#!/usr/bin/env python3
"""diag_mysql_nacos.py - 读 MySQL/Nacos 日志 + 内存状态"""
import subprocess

# 1. MySQL 日志
print("=== erp-mysql logs ===")
r = subprocess.run(["/usr/bin/docker", "logs", "--tail", "30", "erp-mysql"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode("utf-8", errors="replace")[-2000:])

# 2. Nacos 日志
print("\n=== erp-nacos logs ===")
r = subprocess.run(["/usr/bin/docker", "logs", "--tail", "30", "erp-nacos"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode("utf-8", errors="replace")[-2000:])

# 3. 主机内存
print("\n=== free -m ===")
r = subprocess.run(["free", "-m"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode("utf-8", errors="replace"))

# 4. docker stats
print("\n=== docker stats (no-stream) ===")
r = subprocess.run(["/usr/bin/docker", "stats", "--no-stream", "--format",
                    "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode("utf-8", errors="replace"))
