package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@Data
public class DailyTrendVO {
    private String date;
    private Integer inboundQuantity;
    private Integer outboundQuantity;
    private Integer netQuantity;
}
