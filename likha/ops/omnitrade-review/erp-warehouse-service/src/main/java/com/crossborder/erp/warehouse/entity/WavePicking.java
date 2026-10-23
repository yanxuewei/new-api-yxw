package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("wms_wave_picking")
public class WavePicking {
    @TableId(type = IdType.AUTO) private Long id;
    private String waveNo;
    private String waveType;
    private String waveStatus;
    private Integer orderCount;
    private Integer skuCount;
    private Integer totalQuantity;
    private Integer pickedQuantity;
    private String priority;
    private String assignUser;
    private LocalDateTime assignTime;
    private LocalDateTime startTime;
    private LocalDateTime completeTime;
    private String remark;
    @TableField(fill = FieldFill.INSERT) private LocalDateTime createTime;
    @TableField(fill = FieldFill.INSERT_UPDATE) private LocalDateTime updateTime;
}
