package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_outbound_detail")
public class OutboundDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long outboundOrderId;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private LocalDateTime createTime;
}
