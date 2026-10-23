#!/usr/bin/env python3
import os

for name, log in [("warehouse-v8", "/tmp/build-wh-v8.log"), ("inventory-v8", "/tmp/build-inv-v8.log")]:
    if not os.path.exists(log):
        print(name + ": NO LOG")
        continue
    lines = open(log).readlines()
    success = any("BUILD SUCCESS" in l for l in lines)
    failure = any("BUILD FAILURE" in l for l in lines)
    status = "SUCCESS" if success else ("FAILURE" if failure else "IN_PROGRESS")
    errs = []
    seen = set()
    for l in lines:
        for k in ["[ERROR] /app", "symbol:", "location:", "BUILD SUCCESS", "BUILD FAILURE"]:
            if k in l:
                e = l.rstrip()
                if e not in seen:
                    seen.add(e)
                    errs.append(e)
                break
    print("=== %s %s (%d lines) ===" % (name, status, len(lines)))
    for e in errs:
        print(e)
    print()
