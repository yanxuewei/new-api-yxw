package com.crossborder.erp.inventory.entity;
import com.crossborder.erp.inventory.enums.AlertType;
import com.crossborder.erp.inventory.enums.AlertStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_alert")
public class InventoryAlert {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private AlertType alertType;
    private Integer currentQty;
    private Integer safetyStock;
    private AlertStatus alertStatus;
    private String handler;
    private LocalDateTime handleTime;
    private String handleRemark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
