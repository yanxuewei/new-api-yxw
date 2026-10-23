#!/usr/bin/env python3
import os

# Fix WavePickingDetail - illegal escape from heredoc
content = '''package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_wave_picking_detail")
public class WavePickingDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long waveId;
    private Long orderId;
    private String orderNo;
    private Long productId;
    private String skuCode;
    private Integer pickQuantity;
    private Integer pickedQuantity;
    private Long locationId;
    private String fromLocationCode;
    private String pickStatus;
    private LocalDateTime pickTime;
    private String picker;
    private String remark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
'''
p = '/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/entity/WavePickingDetail.java'
open(p, 'w').write(content)
print(f"FIXED {p}")

# Add InventoryStatistics VO for inventory-service
stats = '''package com.crossborder.erp.inventory.vo;
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
'''
p2 = '/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory/vo/InventoryStatistics.java'
open(p2, 'w').write(stats)
print(f"FIXED {p2}")

# Fix InventoryStatus enum - add WARNING and DANGER
enum_content = '''package com.crossborder.erp.inventory.enums;
public enum InventoryStatus { NORMAL, LOW_STOCK, OUT_OF_STOCK, FROZEN, WARNING, DANGER }
'''
p3 = '/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory/enums/InventoryStatus.java'
open(p3, 'w').write(enum_content)
print(f"FIXED {p3}")

print("ALL FIXED")
