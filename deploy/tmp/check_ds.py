#!/usr/bin/env python3
"""Check datasource config in all service application.yml files"""
import os, re

SERVICES = ["order", "product", "warehouse", "inventory", "customer", "supplier"]
BASE = "/opt/OmniTradeERP"

for svc in SERVICES:
    yml = f"{BASE}/erp-{svc}-service/src/main/resources/application.yml"
    if not os.path.exists(yml):
        print(f"=== {svc}: NO application.yml ===")
        continue
    with open(yml) as f:
        content = f.read()
    print(f"=== {svc} ===")
    # Find datasource section
    for i, line in enumerate(content.splitlines(), 1):
        if re.search(r'datasource|jdbc|url:|username:|password:|MYSQL_HOST|MYSQL_PORT|DB_HOST|DB_PORT|spring\.datasource', line, re.IGNORECASE):
            print(f"  {i}: {line.rstrip()}")
    # Also check for ${...} patterns
    for i, line in enumerate(content.splitlines(), 1):
        if '${' in line and 'NACOS' not in line:
            print(f"  {i}: {line.rstrip()}")
    print()
