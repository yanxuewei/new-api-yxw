#!/usr/bin/env python3
import re, os

BASE_INV = "/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory"

# ── 1. InventoryService 接口：补三个缺失方法 ─────────────────────────────────
p = f"{BASE_INV}/service/InventoryService.java"
src = open(p).read()

# 确保 import LocalDateTime
if 'import java.time.LocalDateTime' not in src:
    src = src.replace('import java.time.LocalDate;',
                      'import java.time.LocalDate;\nimport java.time.LocalDateTime;')

missing_methods = ""

if 'getInventoryLogs(' not in src:
    missing_methods += "    List<InventoryLog> getInventoryLogs(Long inventoryId, int page, int size);\n"

if 'getInventoryLogsByProduct(' not in src:
    missing_methods += "    List<InventoryLog> getInventoryLogsByProduct(Long productId, LocalDateTime startTime, LocalDateTime endTime);\n"

if 'getStatistics(' not in src:
    missing_methods += "    InventoryStatistics getStatistics(Long warehouseId, LocalDateTime startTime, LocalDateTime endTime);\n"

if missing_methods:
    # 补充缺失的 import
    if 'import com.crossborder.erp.inventory.entity.InventoryLog' not in src and 'import com.crossborder.erp.inventory.entity.*' not in src:
        src = src.replace('import com.crossborder.erp.inventory.entity.*;', 
                          'import com.crossborder.erp.inventory.entity.*;')
    # 在接口末尾 } 前插入方法
    src = src.rstrip()
    if src.endswith('}'):
        src = src[:-1].rstrip() + '\n' + missing_methods + '}\n'
    open(p, 'w').write(src)
    print(f"FIXED  {p} -- added:\n{missing_methods}")
else:
    print(f"OK     {p} -- methods already present")

# ── 2. InventoryLog entity: 确保 inventoryId 字段存在 ────────────────────────
p2 = f"{BASE_INV}/entity/InventoryLog.java"
if os.path.exists(p2):
    log_src = open(p2).read()
    if 'inventoryId' not in log_src and 'private Long inventoryId' not in log_src:
        log_src = log_src.replace(
            '    private Long productId;',
            '    private Long inventoryId;\n    private Long productId;'
        )
        open(p2, 'w').write(log_src)
        print(f"FIXED  {p2} -- added inventoryId field")
    else:
        print(f"OK     {p2} -- inventoryId present")
else:
    print(f"MISSING {p2}")

print("\nALL DONE")
