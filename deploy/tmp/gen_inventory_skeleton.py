#!/usr/bin/env python3
import os

BASE = "/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory"
PKG  = "com.crossborder.erp.inventory"

files = {}

# ── enums ──────────────────────────────────────────────────────────────────
files[f"{BASE}/enums/InventoryStatus.java"] = f"""package {PKG}.enums;
public enum InventoryStatus {{ NORMAL, LOW_STOCK, OUT_OF_STOCK, FROZEN }}
"""

files[f"{BASE}/enums/OperationType.java"] = f"""package {PKG}.enums;
public enum OperationType {{ INBOUND, OUTBOUND, TRANSFER, ADJUST, LOCK, RELEASE }}
"""

files[f"{BASE}/enums/LockType.java"] = f"""package {PKG}.enums;
public enum LockType {{ ORDER, RESERVATION, TRANSFER, MANUAL }}
"""

files[f"{BASE}/enums/LockStatus.java"] = f"""package {PKG}.enums;
public enum LockStatus {{ LOCKED, RELEASED, EXPIRED }}
"""

files[f"{BASE}/enums/AlertType.java"] = f"""package {PKG}.enums;
public enum AlertType {{ LOW_STOCK, OUT_OF_STOCK, SLOW_MOVING, OVERSTOCK }}
"""

files[f"{BASE}/enums/AlertStatus.java"] = f"""package {PKG}.enums;
public enum AlertStatus {{ PENDING, PROCESSED, IGNORED }}
"""

files[f"{BASE}/enums/CheckStatus.java"] = f"""package {PKG}.enums;
public enum CheckStatus {{ PENDING, IN_PROGRESS, COMPLETED, CANCELLED }}
"""

# ── entity ─────────────────────────────────────────────────────────────────
files[f"{BASE}/entity/Inventory.java"] = f"""package {PKG}.entity;
import {PKG}.enums.InventoryStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory")
public class Inventory {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long productId;
    private Long warehouseId;
    private String skuCode;
    private Integer quantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private Integer safetyStock;
    private BigDecimal unitCost;
    private InventoryStatus status;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/InventoryLog.java"] = f"""package {PKG}.entity;
import {PKG}.enums.OperationType;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_log")
public class InventoryLog {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private Integer quantity;
    private OperationType operationType;
    private Integer beforeQuantity;
    private Integer afterQuantity;
    private String remark;
    private LocalDateTime createTime;
}}
"""

files[f"{BASE}/entity/InventoryAlert.java"] = f"""package {PKG}.entity;
import {PKG}.enums.AlertType;
import {PKG}.enums.AlertStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_alert")
public class InventoryAlert {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private AlertType alertType;
    private Integer currentQty;
    private Integer safetyStock;
    private AlertStatus alertStatus;
    private String handler;
    private LocalDateTime handleTime;
    private String handleRemark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/InventoryLock.java"] = f"""package {PKG}.entity;
import {PKG}.enums.LockType;
import {PKG}.enums.LockStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_lock")
public class InventoryLock {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inventoryId;
    private Long productId;
    private Long warehouseId;
    private Integer lockQuantity;
    private Integer usedQuantity;
    private LockType lockType;
    private String orderNo;
    private LockStatus lockStatus;
    private String remark;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/InventoryCheck.java"] = f"""package {PKG}.entity;
import {PKG}.enums.CheckStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_check")
public class InventoryCheck {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String checkNo;
    private Long warehouseId;
    private CheckStatus checkStatus;
    private BigDecimal totalProfit;
    private BigDecimal totalLoss;
    private BigDecimal netProfit;
    private LocalDateTime completeTime;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/InventoryCheckDetail.java"] = f"""package {PKG}.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_inventory_check_detail")
public class InventoryCheckDetail {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long checkId;
    private Long inventoryId;
    private Integer beforeQty;
    private Integer checkQty;
    private Integer diffQty;
    private BigDecimal diffAmount;
    private LocalDateTime createTime;
}}
"""

# ── mapper ─────────────────────────────────────────────────────────────────
for entity in ["Inventory","InventoryLog","InventoryAlert","InventoryLock","InventoryCheck"]:
    files[f"{BASE}/mapper/{entity}Mapper.java"] = f"""package {PKG}.mapper;
import {PKG}.entity.{entity};
import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Mapper;
@Mapper public interface {entity}Mapper extends BaseMapper<{entity}> {{}}
"""

# ── service interface ──────────────────────────────────────────────────────
files[f"{BASE}/service/InventoryService.java"] = f"""package {PKG}.service;
import {PKG}.entity.*;
import {PKG}.enums.*;
import {PKG}.vo.*;
import java.util.List;
public interface InventoryService {{
    Inventory getInventory(Long productId, Long warehouseId);
    Inventory getInventoryById(Long id);
    List<Inventory> listInventories(InventoryQuery query);
    void increaseInventory(Long productId, Long warehouseId, Integer quantity, String remark);
    void decreaseInventory(Long productId, Long warehouseId, Integer quantity, String remark);
    void transferInventory(Long productId, Long fromWarehouseId, Long toWarehouseId, Integer quantity, String remark);
    void lockInventory(Long productId, Long warehouseId, Integer quantity, LockType lockType, String orderNo, String remark);
    void releaseInventory(Long productId, Long warehouseId, Integer quantity, String remark);
    void reserveInventory(Long productId, Long warehouseId, Integer quantity, String remark);
    List<InventoryAlert> getAlerts(Long warehouseId, AlertStatus status);
    void processAlert(Long alertId, String handler, String handleRemark);
    InventoryAlertStats getAlertStats(Long warehouseId);
    Long createCheck(InventoryCheck check);
    void executeCheck(Long checkId, List<InventoryCheckDetail> details);
    List<Inventory> getInventoryByWarehouse(Long warehouseId);
    List<Inventory> getLowStockInventory(Integer threshold);
    List<Inventory> getSlowMovingInventory(Integer days, Integer minSales);
    List<InventoryTrend> getInventoryTrend(Long productId, Long warehouseId, Integer days);
    BatchOperationResult batchIncreaseInventory(List<InventoryBatchOperation> operations);
    BatchOperationResult batchDecreaseInventory(List<InventoryBatchOperation> operations);
    void batchUpdateSafetyStock(List<SafetyStockUpdate> updates);
}}
"""

# ── vo ─────────────────────────────────────────────────────────────────────
files[f"{BASE}/vo/InventoryQuery.java"] = f"""package {PKG}.vo;
import lombok.Data;
@Data public class InventoryQuery {{
    private Long warehouseId;
    private Long productId;
    private String skuCode;
    private String status;
    private int page = 1;
    private int size = 20;
}}
"""

files[f"{BASE}/vo/InventoryAlertStats.java"] = f"""package {PKG}.vo;
import lombok.Data;
@Data public class InventoryAlertStats {{
    private Long pendingCount;
    private Long processedCount;
    private Long lowStockCount;
    private Long outOfStockCount;
    private Long slowMovingCount;
}}
"""

files[f"{BASE}/vo/InventoryBatchOperation.java"] = f"""package {PKG}.vo;
import lombok.Data;
@Data public class InventoryBatchOperation {{
    private Long productId;
    private Long warehouseId;
    private Integer quantity;
    private String remark;
}}
"""

files[f"{BASE}/vo/SafetyStockUpdate.java"] = f"""package {PKG}.vo;
import lombok.Data;
@Data public class SafetyStockUpdate {{
    private Long inventoryId;
    private Integer safetyStock;
}}
"""

files[f"{BASE}/vo/BatchOperationResult.java"] = f"""package {PKG}.vo;
import lombok.Data;
import java.util.List;
@Data public class BatchOperationResult {{
    private int successCount;
    private int failedCount;
    private List<String> successList;
    private List<String> failedList;
}}
"""

files[f"{BASE}/vo/InventoryTrend.java"] = f"""package {PKG}.vo;
import lombok.Data;
import java.time.LocalDate;
@Data public class InventoryTrend {{
    private LocalDate date;
    private Integer inbound;
    private Integer outbound;
    private Integer balance;
}}
"""

# ── write all files ────────────────────────────────────────────────────────
for path, content in files.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f"OK {path}")

# remove duplicate root-level InventoryServiceImpl
dup = f"{BASE}/InventoryServiceImpl.java"
if os.path.exists(dup):
    os.remove(dup)
    print(f"REMOVED {dup}")

print("ALL DONE")
