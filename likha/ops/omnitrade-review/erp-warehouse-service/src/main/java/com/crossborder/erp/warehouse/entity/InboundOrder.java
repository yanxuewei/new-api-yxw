package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.InboundType;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_inbound_order")
public class InboundOrder {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private InboundType inboundType;
    private OrderStatus orderStatus;
    private Integer status;
    private Integer totalQuantity;
    private Integer receivedQuantity;
    private String supplier;
    private String remark;
    private LocalDateTime inboundTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
