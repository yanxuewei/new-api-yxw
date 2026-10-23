package com.crossborder.erp.warehouse.vo;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

@Data
public class TransferOrderVO {
    private Long id;
    private String transferNo;
    private Long fromWarehouseId;
    private String fromWarehouseName;
    private Long toWarehouseId;
    private String toWarehouseName;
    private String transferType;
    private LocalDateTime expectedArrivalTime;
    private LocalDateTime actualArrivalTime;
    private LocalDateTime transferTime;
    private Integer totalQuantity;
    private Integer inTransitQuantity;
    private Integer receivedQuantity;
    private String status;
    private String statusName;
    private String remark;
    private String createBy;
    private LocalDateTime createTime;
    private List<TransferDetailVO> details;
}
