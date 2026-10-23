package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class WaveCreateDTO {
    private String waveType;
    private String priority;
    private List<Long> orderIds;
    private String remark;
}
