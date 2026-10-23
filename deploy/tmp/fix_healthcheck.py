#!/usr/bin/env python3
"""Replace curl-based healthchecks with wget in docker-compose.yml."""
import re

path = "/opt/OmniTradeERP/docker-compose.yml"

with open(path, "r") as f:
    content = f.read()

original = content

# Replace: ["CMD", "curl", "-f", "http://localhost:PORT/actuator/health"]
# With:    ["CMD-SHELL", "wget -qO- http://localhost:PORT/actuator/health || exit 1"]
def replace_curl_hc(m):
    port_path = m.group(1)
    return f'["CMD-SHELL", "wget -qO- http://localhost{port_path} || exit 1"]'

content = re.sub(
    r'\["CMD",\s*"curl",\s*"-f",\s*"http://localhost([^"]+)"\]',
    replace_curl_hc,
    content
)

with open(path, "w") as f:
    f.write(content)

# Verify
matches = re.findall(r'test:.*', content)
for m in matches:
    print(m)

changed = content != original
print(f"\nFile modified: {changed}")
