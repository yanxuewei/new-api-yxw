package com.crossborder.erp.inventory.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_check_detail")
public class InventoryCheckDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long checkId;
    private Long inventoryId;
    private Integer beforeQty;
    private Integer checkQty;
    private Integer diffQty;
    private BigDecimal diffAmount;
    private LocalDateTime createTime;
}
