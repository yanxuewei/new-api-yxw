package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_wave_picking_detail")
public class WavePickingDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long waveId;
    private Long orderId;
    private String orderNo;
    private Long productId;
    private String skuCode;
    private Integer pickQuantity;
    private Integer pickedQuantity;
    private Long locationId;
    private String fromLocationCode;
    private String pickStatus;
    private LocalDateTime pickTime;
    private String picker;
    private String remark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
