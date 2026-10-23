#!/usr/bin/env python3
"""fix_v6.py - 补 InboundOrder.receivedQuantity + OutboundOrder.totalQuantity
              + 查 inventory v8 具体错误"""
import os, re

BASE = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"

# 1. InboundOrder 补 receivedQuantity
p1 = f"{BASE}/entity/InboundOrder.java"
s = open(p1).read()
if "receivedQuantity" not in s:
    s = s.replace("    private Integer totalQuantity;", "    private Integer totalQuantity;\n    private Integer receivedQuantity;")
    open(p1, 'w').write(s)
    print("FIXED  InboundOrder + receivedQuantity")
else:
    print("OK     InboundOrder already has receivedQuantity")

# 2. OutboundOrder 补 totalQuantity
p2 = f"{BASE}/entity/OutboundOrder.java"
s2 = open(p2).read()
if "totalQuantity" not in s2:
    s2 = s2.replace("    private Integer status;", "    private Integer status;\n    private Integer totalQuantity;")
    open(p2, 'w').write(s2)
    print("FIXED  OutboundOrder + totalQuantity")
else:
    print("OK     OutboundOrder already has totalQuantity")

# 3. inventory v8 错误
log = "/tmp/build-inv-v8.log"
if os.path.exists(log):
    lines = open(log).readlines()
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
    print("\n=== inventory-v8 (%d lines, %d errs) ===" % (len(lines), len(errs)))
    for e in errs[-30:]:
        print(e)
else:
    print("\nNO INV LOG")

print("\nALL DONE")
