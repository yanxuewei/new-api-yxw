#!/usr/bin/env python3
import os

for name, log in [("warehouse", "/tmp/build-wh-v7.log"), ("inventory", "/tmp/build-inv-v7.log")]:
    if not os.path.exists(log):
        print(f"=== {name}: NO LOG ===")
        continue
    lines = open(log).readlines()
    errors = [l.rstrip() for l in lines if any(k in l for k in
              ['[ERROR]', 'cannot find symbol', 'does not override',
               'BUILD SUCCESS', 'BUILD FAILURE', 'is not abstract',
               'illegal escape', 'unclosed string', 'error:'])]
    print(f"=== {name} ({len(lines)} lines) ===")
    for e in errors[-30:]:
        print(e)
    print()
