package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_stock_transfer")
public class StockTransfer {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String transferNo;
    private Long fromWarehouseId;
    private Long toWarehouseId;
    private Long productId;
    private Integer quantity;
    private String fromLocationCode;
    private OrderStatus orderStatus;
    private Integer status;
    private String remark;
    private LocalDateTime transferTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
