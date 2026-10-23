#!/usr/bin/env python3
import os

BASE_DTO = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/dto"
BASE_VO  = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/vo"
BASE_MAP = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/mapper"
BASE_ENT = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/entity"
PKG_DTO  = "com.crossborder.erp.warehouse.dto"
PKG_VO   = "com.crossborder.erp.warehouse.vo"
PKG_MAP  = "com.crossborder.erp.warehouse.mapper"

files = {}

HDR_DTO = f"package {PKG_DTO};\nimport lombok.Data;\nimport java.math.BigDecimal;\nimport java.time.LocalDateTime;\nimport java.util.List;\n\n"
HDR_VO  = f"package {PKG_VO};\nimport lombok.Data;\nimport java.math.BigDecimal;\nimport java.time.LocalDateTime;\nimport java.util.List;\nimport java.util.Map;\n\n"

# ── DTOs ───────────────────────────────────────────────────────────────────
files[f"{BASE_DTO}/WarehouseQueryDTO.java"] = HDR_DTO + """@Data
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
"""

files[f"{BASE_DTO}/LocationQueryDTO.java"] = HDR_DTO + """@Data
public class LocationQueryDTO {
    private Long warehouseId;
    private String locationCode;
    private String locationType;
    private String zone;
    private String status;
    private Boolean isPickable;
    private Boolean isStorable;
    private Integer page = 1;
    private Integer size = 20;
}
"""

files[f"{BASE_DTO}/InboundOrderDTO.java"] = HDR_DTO + """@Data
public class InboundOrderDTO {
    private Long id;
    private Long warehouseId;
    private String inboundType;
    private String supplierCode;
    private String supplierName;
    private String purchaseOrderNo;
    private String expectedArrivalDate;
    private String remark;
    private List<InboundDetailDTO> details;
}
"""

files[f"{BASE_DTO}/InboundDetailDTO.java"] = HDR_DTO + """@Data
public class InboundDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private String batchNo;
    private String productionDate;
    private BigDecimal unitCost;
    private String remark;
}
"""

files[f"{BASE_DTO}/OutboundOrderDTO.java"] = HDR_DTO + """@Data
public class OutboundOrderDTO {
    private Long id;
    private Long warehouseId;
    private String outboundType;
    private String orderNo;
    private String customerName;
    private String shippingAddress;
    private String shippingMethod;
    private String remark;
    private List<OutboundDetailDTO> details;
}
"""

files[f"{BASE_DTO}/OutboundDetailDTO.java"] = HDR_DTO + """@Data
public class OutboundDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private String batchNo;
    private String remark;
}
"""

files[f"{BASE_DTO}/TransferOrderDTO.java"] = HDR_DTO + """@Data
public class TransferOrderDTO {
    private Long id;
    private Long fromWarehouseId;
    private Long toWarehouseId;
    private String transferType;
    private String expectedArrivalDate;
    private String remark;
    private List<TransferDetailDTO> details;
}
"""

files[f"{BASE_DTO}/TransferDetailDTO.java"] = HDR_DTO + """@Data
public class TransferDetailDTO {
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String fromLocationCode;
    private String toLocationCode;
    private String batchNo;
}
"""

files[f"{BASE_DTO}/WaveCreateDTO.java"] = HDR_DTO + """@Data
public class WaveCreateDTO {
    private String waveType;
    private String priority;
    private List<Long> orderIds;
    private String remark;
}
"""

files[f"{BASE_DTO}/PackingMaterialDTO.java"] = HDR_DTO + """@Data
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
"""

# ── VOs ────────────────────────────────────────────────────────────────────
files[f"{BASE_VO}/WarehouseStatisticsVO.java"] = HDR_VO + """@Data
public class WarehouseStatisticsVO {
    private Long warehouseId;
    private String warehouseName;
    private Integer totalSku;
    private Integer totalQuantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private BigDecimal totalValue;
    private Integer totalLocations;
    private Integer usedLocations;
    private Integer idleLocations;
    private BigDecimal utilizationRate;
    private Integer todayInbound;
    private Integer todayOutbound;
    private Integer pendingInbound;
    private Integer pendingOutbound;
    private Integer lowStockAlert;
    private Integer outOfStockAlert;
    private Integer expiringAlert;
}
"""

files[f"{BASE_VO}/LocationVO.java"] = HDR_VO + """@Data
public class LocationVO {
    private Long id;
    private Long warehouseId;
    private String warehouseName;
    private String locationCode;
    private String locationName;
    private String locationType;
    private String zone;
    private String row;
    private String column;
    private String level;
    private Integer stockQuantity;
    private Integer maxCapacity;
    private Integer currentCapacity;
    private String status;
    private Boolean isPickable;
    private Boolean isStorable;
    private String remark;
}
"""

files[f"{BASE_VO}/InboundDetailVO.java"] = HDR_VO + """@Data
public class InboundDetailVO {
    private Long id;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private String productName;
    private Integer expectedQuantity;
    private Integer receivedQuantity;
    private Integer differenceQuantity;
    private String locationCode;
    private String batchNo;
    private LocalDateTime productionDate;
    private LocalDateTime expiryDate;
    private BigDecimal unitCost;
    private BigDecimal totalAmount;
    private String status;
    private String remark;
}
"""

files[f"{BASE_VO}/InboundOrderVO.java"] = HDR_VO + """@Data
public class InboundOrderVO {
    private Long id;
    private String orderNo;
    private Long warehouseId;
    private String warehouseName;
    private String inboundType;
    private String inboundTypeName;
    private String supplierCode;
    private String supplierName;
    private String purchaseOrderNo;
    private LocalDateTime expectedArrivalTime;
    private LocalDateTime actualArrivalTime;
    private LocalDateTime inboundTime;
    private Integer totalQuantity;
    private Integer receivedQuantity;
    private Integer differenceQuantity;
    private String status;
    private String statusName;
    private String remark;
    private String createBy;
    private LocalDateTime createTime;
    private List<InboundDetailVO> details;
}
"""

files[f"{BASE_VO}/OutboundDetailVO.java"] = HDR_VO + """@Data
public class OutboundDetailVO {
    private Long id;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private String productName;
    private Integer quantity;
    private Integer pickedQuantity;
    private String locationCode;
    private String batchNo;
    private String status;
    private String remark;
}
"""

files[f"{BASE_VO}/OutboundOrderVO.java"] = HDR_VO + """@Data
public class OutboundOrderVO {
    private Long id;
    private String orderNo;
    private Long warehouseId;
    private String warehouseName;
    private String outboundType;
    private String outboundTypeName;
    private String customerName;
    private String shippingAddress;
    private String shippingMethod;
    private String trackingNo;
    private LocalDateTime expectedShipTime;
    private LocalDateTime actualShipTime;
    private Integer totalQuantity;
    private Integer pickedQuantity;
    private Integer packedQuantity;
    private String status;
    private String statusName;
    private String remark;
    private String createBy;
    private LocalDateTime createTime;
    private List<OutboundDetailVO> details;
}
"""

files[f"{BASE_VO}/TransferDetailVO.java"] = HDR_VO + """@Data
public class TransferDetailVO {
    private Long id;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private String productName;
    private Integer quantity;
    private Integer inTransitQuantity;
    private Integer receivedQuantity;
    private String fromLocationCode;
    private String toLocationCode;
    private String batchNo;
    private String status;
}
"""

files[f"{BASE_VO}/TransferOrderVO.java"] = HDR_VO + """@Data
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
"""

files[f"{BASE_VO}/WavePickingDetailVO.java"] = HDR_VO + """@Data
public class WavePickingDetailVO {
    private Long id;
    private Long waveId;
    private Long orderId;
    private String orderNo;
    private Long productId;
    private String skuCode;
    private String productName;
    private Integer pickQuantity;
    private Integer pickedQuantity;
    private String fromLocationCode;
    private String fromLocationName;
    private String pickStatus;
    private String pickStatusName;
    private LocalDateTime pickTime;
    private String picker;
    private String remark;
}
"""

files[f"{BASE_VO}/WavePickingVO.java"] = HDR_VO + """@Data
public class WavePickingVO {
    private Long id;
    private String waveNo;
    private String waveType;
    private String waveTypeName;
    private String waveStatus;
    private String waveStatusName;
    private Integer orderCount;
    private Integer skuCount;
    private Integer totalQuantity;
    private Integer pickedQuantity;
    private BigDecimal progress;
    private String priority;
    private String priorityName;
    private String assignUser;
    private LocalDateTime assignTime;
    private LocalDateTime startTime;
    private LocalDateTime completeTime;
    private String remark;
    private String createBy;
    private LocalDateTime createTime;
    private List<WavePickingDetailVO> details;
}
"""

files[f"{BASE_VO}/PackingMaterialVO.java"] = HDR_VO + """@Data
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
"""

files[f"{BASE_VO}/InventoryBatchVO.java"] = HDR_VO + """@Data
public class InventoryBatchVO {
    private Long id;
    private String batchNo;
    private Long productId;
    private String skuCode;
    private String productName;
    private Long warehouseId;
    private String warehouseName;
    private Long locationId;
    private String locationCode;
    private Integer quantity;
    private Integer availableQuantity;
    private Integer lockedQuantity;
    private Integer damagedQuantity;
    private String batchStatus;
    private String batchStatusName;
    private LocalDateTime productionDate;
    private LocalDateTime expiryDate;
    private LocalDateTime inboundDate;
    private Integer remainingDays;
    private String supplierCode;
    private String supplierName;
    private String purchaseOrderNo;
    private BigDecimal unitCost;
    private BigDecimal totalAmount;
    private String remark;
}
"""

files[f"{BASE_VO}/DailyTrendVO.java"] = HDR_VO + """@Data
public class DailyTrendVO {
    private String date;
    private Integer inboundQuantity;
    private Integer outboundQuantity;
    private Integer netQuantity;
}
"""

files[f"{BASE_VO}/WarehouseDashboardVO.java"] = HDR_VO + """@Data
public class WarehouseDashboardVO {
    private Integer todayInboundOrders;
    private Integer todayOutboundOrders;
    private Integer todayInboundQuantity;
    private Integer todayOutboundQuantity;
    private Integer totalSku;
    private Integer totalQuantity;
    private Integer lowStockCount;
    private Integer outOfStockCount;
    private Integer pendingInbound;
    private Integer pendingOutbound;
    private Integer pendingTransfer;
    private Integer pendingPick;
    private BigDecimal locationUtilization;
    private List<Map<String, Object>> stockAlerts;
    private List<DailyTrendVO> weeklyTrend;
}
"""

# ── mappers split from OtherMappers.java ──────────────────────────────────
files[f"{BASE_MAP}/PackingMaterialMapper.java"] = f"""package {PKG_MAP};
import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.erp.warehouse.entity.PackingMaterial;
import org.apache.ibatis.annotations.Mapper;
@Mapper public interface PackingMaterialMapper extends BaseMapper<PackingMaterial> {{}}
"""

files[f"{BASE_MAP}/WavePickingMapper.java"] = f"""package {PKG_MAP};
import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.erp.warehouse.entity.WavePicking;
import org.apache.ibatis.annotations.Mapper;
@Mapper public interface WavePickingMapper extends BaseMapper<WavePicking> {{}}
"""

# ── write all ─────────────────────────────────────────────────────────────
for path, content in files.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f"OK {path}")

# delete monolithic files and my duplicate WavePickingDetail
for path in [
    f"{BASE_DTO}/WarehouseDTO.java",
    f"{BASE_VO}/WarehouseVO.java",
    f"{BASE_MAP}/OtherMappers.java",
    f"{BASE_ENT}/WavePickingDetail.java",  # my duplicate
]:
    if os.path.exists(path):
        os.remove(path)
        print(f"REMOVED {path}")

print("ALL DONE")
