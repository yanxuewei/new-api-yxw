package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class PackingMaterialDTO {
    private Long id;
    private String materialCode;
    private String materialName;
    private String materialType;
    private String specifications;
    private Double weight;
    private Integer quantity;
    private String supplierName;
    private String remark;
}
