#!/usr/bin/env python3
"""Check pom.xml mysql dep + application.yml actuator config for all services"""
import os, re, subprocess

BASE = "/opt/OmniTradeERP"
RESULT = "/tmp/check_pom_actuator.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip()

lines = []

# 1. Check mysql-connector in pom.xml for each service
lines.append("=== MySQL connector in pom.xml ===")
for svc in ["order", "product", "warehouse", "inventory", "customer", "supplier"]:
    pom = f"{BASE}/erp-{svc}-service/pom.xml"
    if not os.path.exists(pom):
        lines.append(f"  {svc}: NO pom.xml"); continue
    with open(pom) as f:
        content = f.read()
    has_mysql = "mysql-connector" in content or "mysql-connector-j" in content
    lines.append(f"  {svc}: mysql-connector={'YES' if has_mysql else 'NO'}")
    if not has_mysql:
        # Show dependencies section
        deps = re.findall(r'<artifactId>(.*?)</artifactId>', content)
        lines.append(f"    deps: {deps}")

# 2. Check actuator config in application.yml
lines.append("\n=== Actuator config in application.yml ===")
for svc in ["order", "product", "warehouse", "inventory", "customer", "supplier", "gateway"]:
    yml = f"{BASE}/erp-{svc}-service/src/main/resources/application.yml"
    if not os.path.exists(yml):
        lines.append(f"  {svc}: NO application.yml"); continue
    with open(yml) as f:
        content = f.read()
    actuator_lines = [l.strip() for l in content.splitlines() 
                      if re.search(r'actuator|management|health|endpoint', l, re.IGNORECASE)]
    if actuator_lines:
        lines.append(f"  {svc}: {actuator_lines}")
    else:
        lines.append(f"  {svc}: NO actuator config")

# 3. Actually test what paths exist on running services
lines.append("\n=== Path probing on running services ===")
for svc, port in [("inventory",8086),("order",8081),("product",8083),("warehouse",8085)]:
    for path in ["/actuator/health", "/actuator", "/health", "/"]:
        out = run(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 3 http://localhost:{port}{path}")
        if out not in ["000", "504"]:
            lines.append(f"  {svc}:{port}{path} -> HTTP {out}")

# 4. Check customer/supplier pom.xml full dependencies
lines.append("\n=== customer/supplier pom.xml dependencies ===")
for svc in ["customer", "supplier"]:
    pom = f"{BASE}/erp-{svc}-service/pom.xml"
    if not os.path.exists(pom): continue
    with open(pom) as f:
        content = f.read()
    # Extract all dependency artifactIds
    deps = re.findall(r'<dependency>.*?<artifactId>(.*?)</artifactId>.*?</dependency>', content, re.DOTALL)
    lines.append(f"  {svc} deps: {deps}")

result = "\n".join(lines)
with open(RESULT, "w") as f:
    f.write(result + "\n")
print(result)
