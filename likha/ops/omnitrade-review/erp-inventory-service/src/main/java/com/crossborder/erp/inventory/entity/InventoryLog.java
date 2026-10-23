package com.crossborder.erp.inventory.entity;
import com.crossborder.erp.inventory.enums.OperationType;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_log")
public class InventoryLog {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private Integer quantity;
    private OperationType operationType;
    private Integer beforeQuantity;
    private Integer afterQuantity;
    private String remark;
    private LocalDateTime createTime;
}
