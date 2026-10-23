package com.crossborder.erp.inventory.alert.entity;

import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDate;
import java.time.LocalDateTime;

/**
 * 滞销商品记录
 */
@Data
@TableName("t_slow_moving_inventory")
public class SlowMovingInventory {
    @TableId(type = IdType.ASSIGN_ID)
    private Long id;
    
    private String tenantId;
    
    private Long productId;
    
    private String sku;
    
    private String productName;
    
    private String warehouseId;
    
    private String warehouseName;
    
    private Integer currentStock;
    
    private Integer salesLast30Days;
    
    private Integer salesLast60Days;
    
    private Integer salesLast90Days;
    
    private Double turnoverRate;
    
    private LocalDate lastSaleDate;
    
    private Integer stagnantDays;
    
    private String alertLevel;
    
    private String status;
    
    private Boolean notified;
    
    @TableField(fill = FieldFill.INSERT)
    private LocalDateTime createTime;
    
    @TableField(fill = FieldFill.INSERT_UPDATE)
    private LocalDateTime updateTime;
}