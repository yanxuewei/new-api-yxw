#!/usr/bin/env python3
import re, os

BASE_WH  = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"
BASE_INV = "/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory"

# ── 1. WavePicking.java: 删除 package-private WavePickingDetail 内部类 ───────
p1 = f"{BASE_WH}/entity/WavePicking.java"
content = open(p1).read()
cut = content.find('\n/**\n * 波次明细')
if cut == -1:
    cut = content.find('\nclass WavePickingDetail')
if cut != -1:
    content = content[:cut] + '\n'
    open(p1, 'w').write(content)
    print(f"FIXED  {p1}  (removed inner class at offset {cut})")
else:
    print(f"SKIP   {p1}  (inner class not found, already clean)")

# ── 2. InventoryTrend.java: 字段名改为 inboundQty/outboundQty/netQty ─────────
p2 = f"{BASE_INV}/vo/InventoryTrend.java"
open(p2, 'w').write(
"""package com.crossborder.erp.inventory.vo;
import lombok.Data;
import java.time.LocalDate;
@Data
public class InventoryTrend {
    private LocalDate date;
    private Integer inboundQty;
    private Integer outboundQty;
    private Integer netQty;
}
""")
print(f"FIXED  {p2}")

# ── 3. InventoryService.java: getInventoryTrend 签名对齐 impl ────────────────
p3 = f"{BASE_INV}/service/InventoryService.java"
src = open(p3).read()
if 'import java.time.LocalDate' not in src:
    src = src.replace('import java.util.List;', 'import java.time.LocalDate;\nimport java.util.List;')
src = re.sub(
    r'List<InventoryTrend>\s+getInventoryTrend\s*\(\s*Long\s+productId\s*,\s*Long\s+warehouseId\s*,\s*Integer\s+days\s*\)\s*;',
    'List<InventoryTrend> getInventoryTrend(Long productId, Long warehouseId, LocalDate startDate, LocalDate endDate);',
    src
)
open(p3, 'w').write(src)
print(f"FIXED  {p3}")

# ── 4. InventoryServiceImpl.java: 修复 LambdaQueryWrapper 拷贝构造器 ─────────
p4 = f"{BASE_INV}/service/impl/InventoryServiceImpl.java"
src = open(p4).read()

old_block = (
    "        // 待处理预警\n"
    "        LambdaQueryWrapper<InventoryAlert> pendingWrapper = new LambdaQueryWrapper<>(wrapper);\n"
    "        pendingWrapper.eq(InventoryAlert::getAlertStatus, AlertStatus.PENDING);\n"
    "        stats.setPendingCount(alertMapper.selectCount(pendingWrapper));\n"
    "        \n"
    "        // 已处理预警\n"
    "        LambdaQueryWrapper<InventoryAlert> processedWrapper = new LambdaQueryWrapper<>(wrapper);\n"
    "        processedWrapper.eq(InventoryAlert::getAlertStatus, AlertStatus.PROCESSED);\n"
    "        stats.setProcessedCount(alertMapper.selectCount(processedWrapper));\n"
    "        \n"
    "        // 低库存预警\n"
    "        LambdaQueryWrapper<InventoryAlert> lowWrapper = new LambdaQueryWrapper<>(wrapper);\n"
    "        lowWrapper.eq(InventoryAlert::getAlertType, AlertType.LOW_STOCK);\n"
    "        stats.setLowStockCount(alertMapper.selectCount(lowWrapper));\n"
    "        \n"
    "        // 缺货预警\n"
    "        LambdaQueryWrapper<InventoryAlert> outWrapper = new LambdaQueryWrapper<>(wrapper);\n"
    "        outWrapper.eq(InventoryAlert::getAlertType, AlertType.OUT_OF_STOCK);\n"
    "        stats.setOutOfStockCount(alertMapper.selectCount(outWrapper));\n"
    "        \n"
    "        // 滞销预警\n"
    "        LambdaQueryWrapper<InventoryAlert> slowWrapper = new LambdaQueryWrapper<>(wrapper);\n"
    "        slowWrapper.eq(InventoryAlert::getAlertType, AlertType.SLOW_MOVING);\n"
    "        stats.setSlowMovingCount(alertMapper.selectCount(slowWrapper));"
)

new_block = (
    "        // 待处理预警\n"
    "        LambdaQueryWrapper<InventoryAlert> pendingWrapper = new LambdaQueryWrapper<>();\n"
    "        if (warehouseId != null) { pendingWrapper.eq(InventoryAlert::getWarehouseId, warehouseId); }\n"
    "        pendingWrapper.eq(InventoryAlert::getAlertStatus, AlertStatus.PENDING);\n"
    "        stats.setPendingCount(alertMapper.selectCount(pendingWrapper));\n"
    "\n"
    "        // 已处理预警\n"
    "        LambdaQueryWrapper<InventoryAlert> processedWrapper = new LambdaQueryWrapper<>();\n"
    "        if (warehouseId != null) { processedWrapper.eq(InventoryAlert::getWarehouseId, warehouseId); }\n"
    "        processedWrapper.eq(InventoryAlert::getAlertStatus, AlertStatus.PROCESSED);\n"
    "        stats.setProcessedCount(alertMapper.selectCount(processedWrapper));\n"
    "\n"
    "        // 低库存预警\n"
    "        LambdaQueryWrapper<InventoryAlert> lowWrapper = new LambdaQueryWrapper<>();\n"
    "        if (warehouseId != null) { lowWrapper.eq(InventoryAlert::getWarehouseId, warehouseId); }\n"
    "        lowWrapper.eq(InventoryAlert::getAlertType, AlertType.LOW_STOCK);\n"
    "        stats.setLowStockCount(alertMapper.selectCount(lowWrapper));\n"
    "\n"
    "        // 缺货预警\n"
    "        LambdaQueryWrapper<InventoryAlert> outWrapper = new LambdaQueryWrapper<>();\n"
    "        if (warehouseId != null) { outWrapper.eq(InventoryAlert::getWarehouseId, warehouseId); }\n"
    "        outWrapper.eq(InventoryAlert::getAlertType, AlertType.OUT_OF_STOCK);\n"
    "        stats.setOutOfStockCount(alertMapper.selectCount(outWrapper));\n"
    "\n"
    "        // 滞销预警\n"
    "        LambdaQueryWrapper<InventoryAlert> slowWrapper = new LambdaQueryWrapper<>();\n"
    "        if (warehouseId != null) { slowWrapper.eq(InventoryAlert::getWarehouseId, warehouseId); }\n"
    "        slowWrapper.eq(InventoryAlert::getAlertType, AlertType.SLOW_MOVING);\n"
    "        stats.setSlowMovingCount(alertMapper.selectCount(slowWrapper));"
)

if old_block in src:
    src = src.replace(old_block, new_block)
    print("FIXED  InventoryServiceImpl.java: exact block replacement")
else:
    # 兜底：正则替换所有拷贝构造器调用
    count = len(re.findall(r'new LambdaQueryWrapper<>\(wrapper\)', src))
    src = re.sub(r'new LambdaQueryWrapper<>\(wrapper\)', 'new LambdaQueryWrapper<>()', src)
    print(f"FIXED  InventoryServiceImpl.java: fallback regex, replaced {count} occurrences")

open(p4, 'w').write(src)

# ── 5. InventoryAlertStats.java: 若不存在则新建 ─────────────────────────────
p5 = f"{BASE_INV}/vo/InventoryAlertStats.java"
if not os.path.exists(p5):
    open(p5, 'w').write(
"""package com.crossborder.erp.inventory.vo;
import lombok.Data;
@Data
public class InventoryAlertStats {
    private Long pendingCount;
    private Long processedCount;
    private Long lowStockCount;
    private Long outOfStockCount;
    private Long slowMovingCount;
}
""")
    print(f"CREATED {p5}")
else:
    print(f"EXISTS  {p5}")

print("\nALL FIXES DONE")
