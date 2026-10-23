#!/usr/bin/env python3
"""fix_entities.py - 重建 warehouse entity，对齐 impl 字段调用"""
import os

BASE = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"

files = {}

# InboundOrder: impl 调 getStatus/setStatus(int), setTotalQuantity, setInboundTime
files[f"{BASE}/entity/InboundOrder.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.InboundType;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_inbound_order")
public class InboundOrder {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private InboundType inboundType;
    private OrderStatus orderStatus;
    private Integer status;
    private Integer totalQuantity;
    private String supplier;
    private String remark;
    private LocalDateTime inboundTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
"""

# InboundDetail: impl 调 getInboundOrderId/setInboundOrderId, getQuantity, getLocationCode,
#                         getReceivedQuantity/setReceivedQuantity, getTotalQuantity
files[f"{BASE}/entity/InboundDetail.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_inbound_detail")
public class InboundDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long inboundOrderId;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private Integer expectedQty;
    private Integer actualQty;
    private Integer receivedQuantity;
    private Integer totalQuantity;
    private String locationCode;
    private BigDecimal unitCost;
    private LocalDateTime createTime;
}
"""

# OutboundOrder: impl 调 getStatus/setStatus(int), setOutboundTime; 现有字段是 orderStatus
files[f"{BASE}/entity/OutboundOrder.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.OutboundType;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_outbound_order")
public class OutboundOrder {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private OutboundType outboundType;
    private OrderStatus orderStatus;
    private Integer status;
    private String recipient;
    private String remark;
    private LocalDateTime outboundTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
"""

# OutboundDetail: impl 调 getOutboundOrderId/setOutboundOrderId, getProductId, getQuantity, getLocationCode
files[f"{BASE}/entity/OutboundDetail.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_outbound_detail")
public class OutboundDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long outboundOrderId;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String locationCode;
    private LocalDateTime createTime;
}
"""

# StockTransfer: impl 调 getStatus/setStatus(int), getProductId, getQuantity,
#                         getFromLocationCode, setTransferTime
files[f"{BASE}/entity/StockTransfer.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.crossborder.erp.warehouse.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_stock_transfer")
public class StockTransfer {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String transferNo;
    private Long fromWarehouseId;
    private Long toWarehouseId;
    private Long productId;
    private Integer quantity;
    private String fromLocationCode;
    private OrderStatus orderStatus;
    private Integer status;
    private String remark;
    private LocalDateTime transferTime;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}
"""

# StockTransferDetail: impl 调 getProductId, getQuantity, getToLocationCode
files[f"{BASE}/entity/StockTransferDetail.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("erp_wh_stock_transfer_detail")
public class StockTransferDetail {
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long transferId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private String fromLocationCode;
    private String toLocationCode;
    private LocalDateTime createTime;
}
"""

# WavePicking: impl 调 setPickedQuantity(int)
files[f"{BASE}/entity/WavePicking.java"] = """\
package com.crossborder.erp.warehouse.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data
@TableName("wms_wave_picking")
public class WavePicking {
    @TableId(type = IdType.AUTO) private Long id;
    private String waveNo;
    private String waveType;
    private String waveStatus;
    private Integer orderCount;
    private Integer skuCount;
    private Integer totalQuantity;
    private Integer pickedQuantity;
    private String priority;
    private String assignUser;
    private LocalDateTime assignTime;
    private LocalDateTime startTime;
    private LocalDateTime completeTime;
    private String remark;
    @TableField(fill = FieldFill.INSERT) private LocalDateTime createTime;
    @TableField(fill = FieldFill.INSERT_UPDATE) private LocalDateTime updateTime;
}
"""

for path, content in files.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'w').write(content)
    print(f"WROTE  {path.split('erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse/')[-1]}")

print("\nALL ENTITY FIXES DONE")
