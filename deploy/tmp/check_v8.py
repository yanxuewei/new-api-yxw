#!/usr/bin/env python3
import os, subprocess

logs = [
    ("warehouse-v7", "/tmp/build-wh-v7.log"),
    ("warehouse-v8", "/tmp/build-wh-v8.log"),
    ("inventory-v7", "/tmp/build-inv-v7.log"),
    ("inventory-v8", "/tmp/build-inv-v8.log"),
]

for name, log in logs:
    if not os.path.exists(log):
        continue
    lines = open(log).readlines()
    success = any('BUILD SUCCESS' in l for l in lines)
    failure = any('BUILD FAILURE' in l for l in lines)
    errors = [l.rstrip() for l in lines if any(k in l for k in
              ['[ERROR]', 'cannot find symbol', 'does not override', 'is not abstract',
               'BUILD SUCCESS', 'BUILD FAILURE'])]
    status = 'SUCCESS' if success else ('FAILURE' if failure else 'IN_PROGRESS')
    print(f"=== {name}: {status} ({len(lines)} lines) ===")
    for e in errors[-15:]:
        print(e)
    print()

print("=== STATUS FILES ===")
for f in ['/tmp/build-v7-status.txt', '/tmp/build-v8-status.txt']:
    if os.path.exists(f):
        print(f"{f}: {open(f).read().strip()}")
    else:
        print(f"{f}: NOT FOUND")

print("\n=== PROCS ===")
r = subprocess.run(['ps', '-ef'], capture_output=True, text=True)
for l in r.stdout.splitlines():
    if any(k in l for k in ['build_v', 'docker build']) and 'grep' not in l:
        print(l)

print("\n=== DOCKER IMAGES ===")
r2 = subprocess.run(['docker', 'images', '--format', '{{.Repository}}:{{.Tag}}  {{.CreatedSince}}'],
                    capture_output=True, text=True)
for l in r2.stdout.splitlines():
    if 'omnitradeerp' in l:
        print(l)
