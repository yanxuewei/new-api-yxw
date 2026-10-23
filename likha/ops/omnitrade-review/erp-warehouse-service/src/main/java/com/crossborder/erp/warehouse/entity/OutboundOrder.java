package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.OutboundType;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_outbound_order")
public class OutboundOrder {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private OutboundType outboundType;
    private OrderStatus orderStatus;
    private Integer status;
    private Integer totalQuantity;
    private String recipient;
    private String remark;
    private LocalDateTime outboundTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
