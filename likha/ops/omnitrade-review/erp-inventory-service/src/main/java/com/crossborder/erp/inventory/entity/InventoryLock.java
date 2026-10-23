package com.crossborder.erp.inventory.entity;
import com.crossborder.erp.inventory.enums.LockType;
import com.crossborder.erp.inventory.enums.LockStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_lock")
public class InventoryLock {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private Integer lockQuantity;
    private Integer usedQuantity;
    private LockType lockType;
    private String orderNo;
    private LockStatus lockStatus;
    private String remark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
