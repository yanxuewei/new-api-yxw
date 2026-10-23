#!/usr/bin/env python3
"""只读诊断：抓取反复重启的容器的关键错误日志"""
import subprocess, re

CONTAINERS = ["erp-gateway", "erp-customer-service", "erp-inventory-service", "erp-supplier-service"]
PATTERN = re.compile(r"ERROR|Caused by|APPLICATION FAILED|Description:|Action:|Error:|Unrecognized|Invalid|Exception:")

def run(cmd):
    r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8", errors="replace")

out_lines = []
for c in CONTAINERS:
    out_lines.append(f"===== {c} =====")
    state = run(f"docker inspect --format '{{{{.State.Status}}}} exit={{{{.State.ExitCode}}}} restarts={{{{.RestartCount}}}}' {c}").strip()
    out_lines.append(f"state: {state}")
    logs = run(f"docker logs {c} --tail 300 2>&1").splitlines()
    hits = [l for l in logs if PATTERN.search(l)]
    out_lines.extend(hits[-10:] if hits else logs[-15:])
    out_lines.append("")

out_lines.append("===== healthy-path services (last 3 lines) =====")
for c in ["erp-order-service", "erp-product-service", "erp-warehouse-service"]:
    out_lines.append(f"--- {c} ---")
    out_lines.extend(run(f"docker logs {c} --tail 3 2>&1").splitlines())

print("\n".join(out_lines))
