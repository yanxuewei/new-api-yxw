#!/usr/bin/env python3
"""读取所有服务的 application.yml，提取 nacos 相关配置"""
import os, re

SERVICES = ["order", "product", "warehouse", "inventory", "customer", "supplier", "gateway"]
BASE = "/opt/OmniTradeERP"

for svc in SERVICES:
    yml = f"{BASE}/erp-{svc}-service/src/main/resources/application.yml"
    if not os.path.exists(yml):
        print(f"=== {svc}: NO application.yml ===")
        continue
    with open(yml) as f:
        lines = f.readlines()
    print(f"=== {svc} ===")
    for i, line in enumerate(lines):
        if re.search(r'NACOS|server-addr|namespace|NACOS_HOST|NACOS_PORT|NACOS_SERVER', line):
            print(f"  {i+1}: {line.rstrip()}")
    print()
