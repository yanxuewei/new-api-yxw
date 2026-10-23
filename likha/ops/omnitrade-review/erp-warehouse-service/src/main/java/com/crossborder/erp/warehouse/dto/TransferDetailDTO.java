package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class TransferDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String fromLocationCode;
    private String toLocationCode;
    private String batchNo;
}
