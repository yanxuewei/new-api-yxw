package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@Data
public class WarehouseStatisticsVO {
    private Long warehouseId;
    private String warehouseName;
    private Integer totalSku;
    private Integer totalQuantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private BigDecimal totalValue;
    private Integer totalLocations;
    private Integer usedLocations;
    private Integer idleLocations;
    private BigDecimal utilizationRate;
    private Integer todayInbound;
    private Integer todayOutbound;
    private Integer pendingInbound;
    private Integer pendingOutbound;
    private Integer lowStockAlert;
    private Integer outOfStockAlert;
    private Integer expiringAlert;
}
