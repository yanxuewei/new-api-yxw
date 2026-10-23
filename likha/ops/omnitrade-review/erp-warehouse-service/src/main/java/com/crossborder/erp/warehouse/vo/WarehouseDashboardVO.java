package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@Data
public class WarehouseDashboardVO {
    private Integer todayInboundOrders;
    private Integer todayOutboundOrders;
    private Integer todayInboundQuantity;
    private Integer todayOutboundQuantity;
    private Integer totalSku;
    private Integer totalQuantity;
    private Integer lowStockCount;
    private Integer outOfStockCount;
    private Integer pendingInbound;
    private Integer pendingOutbound;
    private Integer pendingTransfer;
    private Integer pendingPick;
    private BigDecimal locationUtilization;
    private List<Map<String, Object>> stockAlerts;
    private List<DailyTrendVO> weeklyTrend;
}
