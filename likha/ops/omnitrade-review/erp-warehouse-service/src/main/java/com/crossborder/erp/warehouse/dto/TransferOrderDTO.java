package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class TransferOrderDTO {
    private Long id;
    private Long fromWarehouseId;
    private Long toWarehouseId;
    private String transferType;
    private String expectedArrivalDate;
    private String remark;
    private List<TransferDetailDTO> details;
}
