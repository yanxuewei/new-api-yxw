package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class OutboundOrderDTO {
    private Long id;
    private Long warehouseId;
    private String outboundType;
    private String orderNo;
    private String customerName;
    private String shippingAddress;
    private String shippingMethod;
    private String remark;
    private List<OutboundDetailDTO> details;
}
