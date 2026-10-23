#!/usr/bin/env python3
import re, os

# ── 1. WarehouseLocation: 补 productId 和 lockedQuantity 字段 ────────────────
p1 = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/entity/WarehouseLocation.java"
src = open(p1).read()

# 在 stockQuantity 字段前插入 productId
if 'private Long productId;' not in src:
    src = src.replace(
        '    private Integer stockQuantity;',
        '    private Long productId;\n    private Integer stockQuantity;'
    )
    print("ADDED  productId to WarehouseLocation")
else:
    print("EXISTS productId in WarehouseLocation")

# 在 status 字段前插入 lockedQuantity
if 'private Integer lockedQuantity;' not in src:
    src = src.replace(
        '    private String status;',
        '    private Integer lockedQuantity;\n    private String status;'
    )
    print("ADDED  lockedQuantity to WarehouseLocation")
else:
    print("EXISTS lockedQuantity in WarehouseLocation")

open(p1, 'w').write(src)
print(f"SAVED  {p1}")

# ── 2. 检查 inventory build 状态 ─────────────────────────────────────────────
log = "/tmp/build-inventory-service-v6.log"
if os.path.exists(log):
    lines = open(log).readlines()
    print(f"\n=== inventory log tail ===")
    for l in lines[-5:]:
        print(l.rstrip())
    print(f"\n=== inventory errors ===")
    for l in lines:
        if any(k in l for k in ['BUILD SUCCESS', 'BUILD FAILURE', 'cannot find symbol',
                                  'does not override', 'is not abstract']):
            print(l.rstrip())
else:
    print(f"\nNO LOG: {log}")

print("\nALL DONE")
