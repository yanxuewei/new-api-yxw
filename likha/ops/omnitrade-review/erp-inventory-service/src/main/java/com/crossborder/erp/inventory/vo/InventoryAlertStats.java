package com.crossborder.erp.inventory.vo;
import lombok.Data;
@Data public class InventoryAlertStats {
    private Long pendingCount;
    private Long processedCount;
    private Long lowStockCount;
    private Long outOfStockCount;
    private Long slowMovingCount;
}
