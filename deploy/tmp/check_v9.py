#!/usr/bin/env python3
import os

logs = [
    ("warehouse-v7", "/tmp/build-wh-v7.log"),
    ("warehouse-v8", "/tmp/build-wh-v8.log"),
    ("inventory-v7", "/tmp/build-inv-v7.log"),
    ("inventory-v8", "/tmp/build-inv-v8.log"),
]

for name, log in logs:
    if not os.path.exists(log):
        print(f"=== {name}: NO LOG ===")
        continue
    lines = open(log).readlines()
    success = any('BUILD SUCCESS' in l for l in lines)
    failure = any('BUILD FAILURE' in l for l in lines)
    errors = [l.rstrip() for l in lines if any(k in l for k in
              ['[ERROR] /app', 'cannot find symbol', 'does not override',
               'is not abstract', 'BUILD SUCCESS', 'BUILD FAILURE',
               'illegal escape', 'unclosed string'])]
    status = 'SUCCESS' if success else ('FAILURE' if failure else 'IN_PROGRESS')
    print(f"=== {name}: {status} ({len(lines)} lines) ===")
    for e in errors[-25:]:
        print(e)
    print()
