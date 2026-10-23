package com.crossborder.erp.inventory.entity;
import com.crossborder.erp.inventory.enums.CheckStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_check")
public class InventoryCheck {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String checkNo;
    private Long warehouseId;
    private CheckStatus checkStatus;
    private BigDecimal totalProfit;
    private BigDecimal totalLoss;
    private BigDecimal netProfit;
    private LocalDateTime completeTime;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
