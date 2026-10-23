#!/usr/bin/env python3
import os

BASE_WH = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"

# ── 1. InventoryCheckResult: 补 locationCode / productId / diffQty ───────────
p = f"{BASE_WH}/vo/InventoryCheckResult.java"
open(p, 'w').write(
"""package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
@Data
public class InventoryCheckResult {
    private Long warehouseId;
    private Long productId;
    private String locationCode;
    private Integer totalItems;
    private Integer matchCount;
    private Integer diffCount;
    private Integer diffQty;
    private BigDecimal totalProfit;
    private BigDecimal totalLoss;
}
""")
print(f"FIXED  {p}")

# ── 2. 检查 inventory 构建状态 ────────────────────────────────────────────────
log = "/tmp/build-inv-v7.log"
if os.path.exists(log):
    lines = open(log).readlines()
    print(f"\n=== inventory log ({len(lines)} lines) tail ===")
    for l in lines[-6:]:
        print(l.rstrip())
    errors = [l.rstrip() for l in lines if any(k in l for k in
              ['[ERROR]', 'BUILD SUCCESS', 'BUILD FAILURE', 'cannot find symbol',
               'does not override', 'is not abstract'])]
    if errors:
        print("\n=== inventory errors ===")
        for e in errors[-20:]:
            print(e)
    else:
        print("\n(no errors yet - still building or success)")
else:
    print(f"\nNO INV LOG at {log}")

print("\nALL DONE")
