package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class OutboundDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private String batchNo;
    private String remark;
}
