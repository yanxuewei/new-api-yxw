#!/usr/bin/env python3
"""读取 inventory v8 log 中 #35 的具体错误"""
import os

log = "/tmp/build-inv-v8.log"
if not os.path.exists(log):
    print("NO LOG")
    raise SystemExit

lines = open(log).readlines()
in35 = False
out = []
for l in lines:
    if "#35 " in l:
        in35 = True
    if in35:
        out.append(l.rstrip())
    if in35 and len(out) > 200:
        break

print("\n".join(out[:200]))
