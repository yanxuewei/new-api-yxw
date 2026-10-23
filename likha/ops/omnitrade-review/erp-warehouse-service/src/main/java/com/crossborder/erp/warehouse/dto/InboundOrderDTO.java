package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class InboundOrderDTO {
    private Long id;
    private Long warehouseId;
    private String inboundType;
    private String supplierCode;
    private String supplierName;
    private String purchaseOrderNo;
    private String expectedArrivalDate;
    private String remark;
    private List<InboundDetailDTO> details;
}
