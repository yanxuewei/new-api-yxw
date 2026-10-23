#!/usr/bin/env python3
"""Check actual service state: curl each port, grab crash logs for restarting containers"""
import subprocess, re

RESULT = "/tmp/svc_state.result"

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace").strip(), r.returncode

lines = []
def log(msg):
    lines.append(msg)
    with open(RESULT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(msg)

log("=== Service State Diagnosis ===")

# Direct curl on each service port
log("\n--- Direct port curl ---")
for svc, port in [("gateway",8080),("order",8081),("product",8083),
                  ("warehouse",8085),("inventory",8086),("customer",8087),("supplier",8088)]:
    out, rc = run(f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 5 http://localhost:{port}/actuator/health")
    log(f"  {svc}:{port} HTTP {out}")

# Actuator health detail for any that respond
log("\n--- Actuator health detail ---")
for svc, port in [("gateway",8080),("order",8081),("product",8083),
                  ("warehouse",8085),("inventory",8086),("customer",8087),("supplier",8088)]:
    out, rc = run(f"curl -sf --max-time 5 http://localhost:{port}/actuator/health")
    if rc == 0 and out:
        log(f"  {svc}: {out[:200]}")

# Logs for crashing services
log("\n--- Crash logs (customer, supplier) ---")
for c in ["erp-customer-service", "erp-supplier-service"]:
    state_out, _ = run(f"docker inspect --format '{{{{.State.Status}}}} exit={{{{.State.ExitCode}}}} restarts={{{{.RestartCount}}}}' {c}")
    log(f"\n{c}: {state_out}")
    log_out, _ = run(f"docker logs {c} --tail 30 2>&1")
    errors = [l for l in log_out.splitlines() 
              if re.search(r'ERROR|Caused by|APPLICATION FAILED|Exception|failed', l, re.IGNORECASE)]
    if errors:
        for e in errors[-10:]:
            log(f"  {e}")
    else:
        for l in log_out.splitlines()[-10:]:
            log(f"  {l}")

# Logs for unhealthy-but-running services
log("\n--- Unhealthy service logs (order, inventory) ---")
for c in ["erp-order-service", "erp-inventory-service"]:
    state_out, _ = run(f"docker inspect --format '{{{{.State.Status}}}} exit={{{{.State.ExitCode}}}}' {c}")
    log(f"\n{c}: {state_out}")
    log_out, _ = run(f"docker logs {c} --tail 15 2>&1")
    for l in log_out.splitlines()[-10:]:
        log(f"  {l}")

# RabbitMQ check - services may fail if vhost /erp doesn't exist
log("\n--- RabbitMQ vhost check ---")
out, rc = run("curl -sf -u guest:guest http://localhost:15672/api/vhosts")
log(f"  vhosts: {out[:300]}")

log("\n=== Done ===")
