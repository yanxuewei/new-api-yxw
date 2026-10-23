package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_inbound_detail")
public class InboundDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inboundOrderId;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private Integer expectedQty;
    private Integer actualQty;
    private Integer receivedQuantity;
    private Integer totalQuantity;
    private String locationCode;
    private BigDecimal unitCost;
    private LocalDateTime createTime;
}
