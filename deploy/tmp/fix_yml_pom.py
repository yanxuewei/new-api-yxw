#!/usr/bin/env python3
"""fix_yml_and_check.py - 修复 include: * 问题 + 检查 customer/supplier pom"""
import os, re

BASE = "/opt/OmniTradeERP"

# 1. 修复所有服务的 application.yml 中 include: * -> include: "*"
services = [
    "erp-warehouse-service",
    "erp-inventory-service",
    "erp-customer-service",
    "erp-supplier-service",
    "erp-order-service",
    "erp-product-service",
]

for svc in services:
    yml = os.path.join(BASE, svc, "src/main/resources/application.yml")
    if not os.path.exists(yml):
        print(f"NO YML: {svc}")
        continue
    content = open(yml).read()
    if "include: *\n" in content or "include: *\r" in content or content.rstrip().endswith("include: *"):
        fixed = re.sub(r'include:\s*\*\s*$', 'include: "*"', content, flags=re.MULTILINE)
        open(yml, 'w').write(fixed)
        print(f"FIXED  {svc}/application.yml include: * -> include: \"*\"")
    else:
        print(f"OK     {svc}/application.yml (no bare * found)")

# 2. 检查 customer/supplier pom.xml 是否有 spring-boot-maven-plugin
print("\n=== pom spring-boot-maven-plugin check ===")
for svc in ["erp-customer-service", "erp-supplier-service"]:
    pom = os.path.join(BASE, svc, "pom.xml")
    if os.path.exists(pom):
        content = open(pom).read()
        if "spring-boot-maven-plugin" in content:
            print(f"OK     {svc}/pom.xml has spring-boot-maven-plugin")
        else:
            print(f"MISS   {svc}/pom.xml MISSING spring-boot-maven-plugin!")
            # 打印 build 段
            m = re.search(r'<build>.*?</build>', content, re.DOTALL)
            if m:
                print(m.group(0)[:500])
    else:
        print(f"NO POM: {svc}")

print("\nALL DONE")
