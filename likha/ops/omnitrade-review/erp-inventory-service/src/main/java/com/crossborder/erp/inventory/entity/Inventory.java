package com.crossborder.erp.inventory.entity;
import com.crossborder.erp.inventory.enums.InventoryStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory")
public class Inventory {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long productId;
    private Long warehouseId;
    private String skuCode;
    private Integer quantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private Integer safetyStock;
    private BigDecimal unitCost;
    private InventoryStatus status;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
