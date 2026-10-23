#!/usr/bin/env python3
"""检查 inventory-service 主类与 pom mainClass 配置"""
import os, glob

BASE = "/opt/OmniTradeERP/erp-inventory-service"

# 1. 找 @SpringBootApplication
print("=== @SpringBootApplication ===")
found = []
for root, dirs, files in os.walk(BASE + "/src/main/java"):
    for f in files:
        if f.endswith(".java"):
            p = os.path.join(root, f)
            content = open(p).read()
            if "@SpringBootApplication" in content:
                found.append(p)
                print(p)
                # 打印前 15 行
                for i, l in enumerate(content.splitlines()[:15]):
                    print(f"  {i+1}: {l}")
if not found:
    print("  NONE FOUND")

# 2. pom.xml spring-boot-maven-plugin 配置
print("\n=== pom.xml spring-boot-maven-plugin ===")
pom = BASE + "/pom.xml"
if os.path.exists(pom):
    lines = open(pom).readlines()
    in_plugin = False
    buf = []
    for l in lines:
        if "spring-boot-maven-plugin" in l:
            in_plugin = True
        if in_plugin:
            buf.append(l.rstrip())
            if "</plugin>" in l:
                break
    print("\n".join(buf[:30]))
else:
    print("NO POM")

# 3. 列出 src/main/java 下所有 .java 文件
print("\n=== java files in src/main/java ===")
for root, dirs, files in os.walk(BASE + "/src/main/java"):
    for f in files:
        if f.endswith(".java"):
            print(os.path.join(root, f).replace(BASE, ""))
