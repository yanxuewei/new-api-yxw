#!/usr/bin/env python3
"""诊断并修复 warehouse/inventory yml + 检查 customer/supplier 主类"""
import os

BASE = "/opt/OmniTradeERP"

# 1. 读 warehouse application.yml 第 40-55 行
for svc in ["erp-warehouse-service", "erp-inventory-service"]:
    yml = os.path.join(BASE, svc, "src/main/resources/application.yml")
    if os.path.exists(yml):
        lines = open(yml).readlines()
        print(f"\n=== {svc}/application.yml lines 40-55 ===")
        for i, l in enumerate(lines[39:55], start=40):
            print(f"  {i}: {l}", end="")
    else:
        print(f"\nNO YML: {yml}")
        # 列出 resources 目录
        rdir = os.path.join(BASE, svc, "src/main/resources")
        if os.path.exists(rdir):
            print("  Files:", os.listdir(rdir))

# 2. 检查 customer/supplier 主类
for svc in ["erp-customer-service", "erp-supplier-service"]:
    src = os.path.join(BASE, svc, "src/main/java")
    found = []
    for root, dirs, files in os.walk(src):
        for f in files:
            if f.endswith(".java"):
                p = os.path.join(root, f)
                if "@SpringBootApplication" in open(p).read():
                    found.append(p)
    print(f"\n=== {svc} @SpringBootApplication ===")
    if found:
        for p in found:
            print("  FOUND:", p)
    else:
        print("  NONE - needs main class")
        # 找 package name
        for root, dirs, files in os.walk(src):
            for f in files:
                if f.endswith(".java"):
                    p = os.path.join(root, f)
                    content = open(p).read()
                    for line in content.splitlines()[:3]:
                        if line.startswith("package "):
                            print("  package:", line.strip())
                            break
                    break
            break
