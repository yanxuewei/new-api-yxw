#!/usr/bin/env python3
"""检查 compose 文件中各服务的端口配置，以及哪些服务有镜像、哪些没有"""
import subprocess, os, re, json

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []

# 1. List all omnitradeerp images
out, _ = run("docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep omnitradeerp")
lines.append("=== Docker Images ===")
lines.extend(out.splitlines())

# 2. Check compose file for service->image mapping and ports
compose = "/opt/OmniTradeERP/docker-compose.yml"
with open(compose) as f:
    content = f.read()

# Parse services: find each service block
services = re.findall(r'^  (\S+):\n(?:    (?:image|build|container_name|ports).*\n)+', content, re.MULTILINE)
lines.append("\n=== Services in compose ===")
for svc_block_match in re.finditer(r'^  (\w[\w-]*):\n((?:    .*\n)+)', content, re.MULTILINE):
    svc_name = svc_block_match.group(1)
    svc_body = svc_block_match.group(2)
    has_build = "build:" in svc_body
    has_image = "image:" in svc_body
    # Get container_name or ports
    cn_match = re.search(r'container_name:\s*(\S+)', svc_body)
    cn = cn_match.group(1) if cn_match else svc_name
    ports = re.findall(r'-\s*"(\d+):\d+"', svc_body)
    port_str = ",".join(ports) if ports else "none"
    lines.append(f"  {svc_name}: container={cn} ports={port_str} build={has_build} image={has_image}")

# 3. Check which images exist vs not
lines.append("\n=== Image availability ===")
image_names = [
    "omnitradeerp-gateway",
    "omnitradeerp-user-service",
    "omnitradeerp-product-service",
    "omnitradeerp-order-service",
    "omnitradeerp-platform-service",
    "omnitradeerp-inventory-service",
    "omnitradeerp-warehouse-service",
    "omnitradeerp-finance-service",
    "omnitradeerp-pricing-service",
    "omnitradeerp-inventory-prediction-service",
    "omnitradeerp-ai-assistant-service",
    "omnitradeerp-product-description-service",
    "omnitradeerp-customer-service",
    "omnitradeerp-supplier-service",
    "omnitradeerp-frontend",
    "omnitradeerp-nginx",
]
existing_images = out
for img in image_names:
    exists = img in existing_images
    lines.append(f"  {img}: {'EXISTS' if exists else 'MISSING'}")

# 4. Check application.yml ports for 6 core services
lines.append("\n=== application.yml server.port ===")
for svc in ["order", "product", "warehouse", "inventory", "customer", "supplier"]:
    yml = f"/opt/OmniTradeERP/erp-{svc}-service/src/main/resources/application.yml"
    if os.path.exists(yml):
        with open(yml) as f:
            yml_content = f.read()
        port_match = re.search(r'^\s*port:\s*(\d+)', yml_content, re.MULTILINE)
        port = port_match.group(1) if port_match else "unknown"
        lines.append(f"  erp-{svc}-service: port={port}")
    else:
        lines.append(f"  erp-{svc}-service: NO application.yml")

# 5. Current docker ps -a
out, _ = run("docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'")
lines.append("\n=== docker ps -a ===")
lines.extend(out.splitlines())

# 6. Free memory
out, _ = run("free -m")
lines.append("\n=== free -m ===")
lines.extend(out.splitlines())

result = "\n".join(lines)
with open("/tmp/diag.result", "w") as f:
    f.write(result + "\n")
print(result)
