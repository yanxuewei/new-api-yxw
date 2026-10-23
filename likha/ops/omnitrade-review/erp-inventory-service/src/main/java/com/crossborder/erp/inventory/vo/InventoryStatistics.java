package com.crossborder.erp.inventory.vo;
import lombok.Data;
import java.math.BigDecimal;
@Data public class InventoryStatistics {
    private Integer totalSku;
    private Integer totalQuantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private Integer normalCount;
    private Integer warningCount;
    private Integer dangerCount;
    private BigDecimal totalAmount;
    private Integer inboundQuantity;
    private Integer outboundQuantity;
    private Integer netQuantity;
}
