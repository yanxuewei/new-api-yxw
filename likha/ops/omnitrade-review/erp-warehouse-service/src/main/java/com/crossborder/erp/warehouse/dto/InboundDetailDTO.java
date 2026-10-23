package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class InboundDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private String batchNo;
    private String productionDate;
    private BigDecimal unitCost;
    private String remark;
}
