package com.crossborder.erp.inventory.vo;
import lombok.Data;
import java.time.LocalDate;
@Data
public class InventoryTrend {
    private LocalDate date;
    private Integer inboundQty;
    private Integer outboundQty;
    private Integer netQty;
}
