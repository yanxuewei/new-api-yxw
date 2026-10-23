package com.crossborder.erp.inventory.vo;
import lombok.Data;
@Data public class InventoryQuery {
    private Long warehouseId;
    private Long productId;
    private String skuCode;
    private String status;
    private int page = 1;
    private int size = 20;
}
