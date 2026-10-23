package com.crossborder.erp.inventory.vo;
import lombok.Data;
@Data public class InventoryBatchOperation {
    private Long productId;
    private Long warehouseId;
    private Integer quantity;
    private String remark;
}
