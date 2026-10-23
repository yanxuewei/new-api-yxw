package com.crossborder.erp.inventory.vo;
import lombok.Data;
import java.util.List;
@Data public class BatchOperationResult {
    private int successCount;
    private int failedCount;
    private List<String> successList;
    private List<String> failedList;
}
