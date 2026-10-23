package com.crossborder.erp.warehouse.vo;
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
