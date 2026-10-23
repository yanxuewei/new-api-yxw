#!/usr/bin/env python3
"""Grab error logs for gateway and inventory-service"""
import subprocess, re

RESULT = "/tmp/svc_errors.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace")

lines = []

for c in ["erp-gateway", "erp-inventory-service"]:
    lines.append(f"\n===== {c} =====")
    state = run(f"docker inspect --format '{{{{.State.Status}}}} exit={{{{.State.ExitCode}}}}' {c}").strip()
    lines.append(f"state: {state}")
    log = run(f"docker logs {c} --tail 400 2>&1")
    # Extract error lines
    errors = [l for l in log.splitlines() if re.search(r'ERROR|Caused by|APPLICATION FAILED|Description:|Exception|failed to|Error creating', l, re.IGNORECASE)]
    if errors:
        lines.extend(errors[-15:])
    else:
        lines.extend(log.splitlines()[-20:])

# Also check actuator health directly
lines.append("\n===== gateway actuator health =====")
out = run("curl -sf --max-time 5 http://localhost:8080/actuator/health 2>&1")
lines.append(out[:500])

lines.append("\n===== order-service actuator health =====")
out = run("curl -sf --max-time 5 http://localhost:8081/actuator/health 2>&1")
lines.append(out[:300])

result = "\n".join(lines)
with open(RESULT, "w") as f:
    f.write(result + "\n")
print(result)
