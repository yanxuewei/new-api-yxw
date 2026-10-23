#!/usr/bin/env python3
# diag_v9.py - 导出 warehouse 完整编译错误（带 symbol/location）+ 相关实体 + Dockerfile
import os, re

def section(t):
    print("\n" + "=" * 20 + " " + t + " " + "=" * 20)

# 1. warehouse 最后一次编译的完整错误块（最后一个 BUILD FAILURE 之前的 [ERROR] 行）
log = "/tmp/build-wh-v7.log"
lines = open(log).readlines()
errs = []
for l in lines:
    m = re.search(r"\[ERROR\]\s*(.*)$", l)
    if m:
        errs.append(m.group(1).rstrip())
# 去重并只保留源码相关的
seen, out = set(), []
for e in errs:
    if e in seen or "Help 1" in e or "re-run Maven" in e or "mvn <args>" in e or not e.strip():
        continue
    seen.add(e)
    out.append(e)
section("WAREHOUSE ERRORS (%d)" % len(out))
for e in out:
    print(e.replace("/app/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/", ""))

# 2. inventory 错误
log2 = "/tmp/build-inv-v7.log"
section("INVENTORY ERRORS")
if os.path.exists(log2):
    seen2 = set()
    for l in open(log2).readlines():
        m = re.search(r"\[ERROR\]\s*(.*)$", l)
        if m:
            e = m.group(1).rstrip()
            if e and e not in seen2 and "Help 1" not in e and "Maven" not in e and "mvn <args>" not in e:
                seen2.add(e)
                print(e.replace("/app/erp-inventory-service/src/main/java/com/crossborder/erp/inventory/", ""))

# 3. 相关实体
BASE = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"
for f in ["entity/OutboundOrder.java", "entity/OutboundDetail.java", "entity/StockTransfer.java",
          "entity/StockTransferDetail.java", "entity/InboundOrder.java", "entity/InboundDetail.java"]:
    p = os.path.join(BASE, f)
    section(f)
    print(open(p).read() if os.path.exists(p) else "MISSING")

# 4. impl 第 815-830 行
section("WarehouseServiceImpl 815-830")
impl = open(os.path.join(BASE, "service/impl/WarehouseServiceImpl.java")).readlines()
for i in range(814, min(830, len(impl))):
    print("%d: %s" % (i + 1, impl[i].rstrip()))

# 5. Dockerfile 和 maven 本地缓存
section("Dockerfile.warehouse-service")
print(open("/opt/OmniTradeERP/docker/Dockerfile.warehouse-service").read())
section("~/.m2")
print("exists" if os.path.isdir("/root/.m2/repository") else "none")
