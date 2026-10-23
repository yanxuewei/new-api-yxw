package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@Data
public class PackingMaterialVO {
    private Long id;
    private String materialCode;
    private String materialName;
    private String materialType;
    private String specifications;
    private Double weight;
    private Double length;
    private Double width;
    private Double height;
    private String unit;
    private Integer stockQuantity;
    private Integer minStock;
    private Integer maxStock;
    private String stockStatus;
    private BigDecimal unitPrice;
    private BigDecimal totalValue;
    private String supplierCode;
    private String supplierName;
    private String status;
    private String statusName;
    private String remark;
}
