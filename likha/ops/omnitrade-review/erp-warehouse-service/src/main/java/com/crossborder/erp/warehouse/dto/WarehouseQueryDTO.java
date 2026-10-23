package com.crossborder.erp.warehouse.dto;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

@Data
public class WarehouseQueryDTO {
    private Long id;
    private String warehouseCode;
    private String name;
    private String country;
    private String city;
    private Integer status;
    private String warehouseType;
    private Integer page = 1;
    private Integer size = 20;
}
