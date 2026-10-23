package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_stock_transfer_detail")
public class StockTransferDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long transferId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String fromLocationCode;
    private String toLocationCode;
    private LocalDateTime createTime;
}
