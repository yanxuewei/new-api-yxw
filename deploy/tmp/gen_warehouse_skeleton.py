#!/usr/bin/env python3
import os

BASE = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"
PKG  = "com.crossborder.erp.warehouse"
COMMON_BASE = "/opt/OmniTradeERP/erp-common/src/main/java/com/crossborder/erp/common"

files = {}

# ── erp-common: BusinessException ─────────────────────────────────────────
files[f"{COMMON_BASE}/exception/BusinessException.java"] = """package com.crossborder.erp.common.exception;
public class BusinessException extends RuntimeException {
    private Integer code;
    public BusinessException(String message) { super(message); this.code = 500; }
    public BusinessException(Integer code, String message) { super(message); this.code = code; }
    public Integer getCode() { return code; }
}
"""

# ── enums ──────────────────────────────────────────────────────────────────
files[f"{BASE}/enums/InboundType.java"] = f"""package {PKG}.enums;
public enum InboundType {{ PURCHASE, RETURN, TRANSFER, MANUAL }}
"""

files[f"{BASE}/enums/OutboundType.java"] = f"""package {PKG}.enums;
public enum OutboundType {{ SALE, TRANSFER, DAMAGE, MANUAL }}
"""

files[f"{BASE}/enums/OrderStatus.java"] = f"""package {PKG}.enums;
public enum OrderStatus {{ PENDING, IN_PROGRESS, COMPLETED, CANCELLED }}
"""

# ── entity (missing ones) ──────────────────────────────────────────────────
files[f"{BASE}/entity/InboundOrder.java"] = f"""package {PKG}.entity;
import {PKG}.enums.InboundType;
import {PKG}.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_inbound_order")
public class InboundOrder {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private InboundType inboundType;
    private OrderStatus orderStatus;
    private String supplier;
    private String remark;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/InboundDetail.java"] = f"""package {PKG}.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_inbound_detail")
public class InboundDetail {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer expectedQty;
    private Integer actualQty;
    private BigDecimal unitCost;
    private LocalDateTime createTime;
}}
"""

files[f"{BASE}/entity/OutboundOrder.java"] = f"""package {PKG}.entity;
import {PKG}.enums.OutboundType;
import {PKG}.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_outbound_order")
public class OutboundOrder {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String orderNo;
    private Long warehouseId;
    private OutboundType outboundType;
    private OrderStatus orderStatus;
    private String recipient;
    private String remark;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/OutboundDetail.java"] = f"""package {PKG}.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_outbound_detail")
public class OutboundDetail {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long orderId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private LocalDateTime createTime;
}}
"""

files[f"{BASE}/entity/StockTransfer.java"] = f"""package {PKG}.entity;
import {PKG}.enums.OrderStatus;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_stock_transfer")
public class StockTransfer {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private String transferNo;
    private Long fromWarehouseId;
    private Long toWarehouseId;
    private OrderStatus status;
    private String remark;
    @TableLogic private Integer deleted;
    private LocalDateTime createTime;
    private LocalDateTime updateTime;
}}
"""

files[f"{BASE}/entity/StockTransferDetail.java"] = f"""package {PKG}.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_stock_transfer_detail")
public class StockTransferDetail {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long transferId;
    private Long productId;
    private String skuCode;
    private Integer quantity;
    private LocalDateTime createTime;
}}
"""

files[f"{BASE}/entity/WavePickingDetail.java"] = f"""package {PKG}.entity;
import com.baomidou.mybatisplus.annotation.*;
import lombok.Data;
import java.time.LocalDateTime;
@Data @TableName("erp_wh_wave_picking_detail")
public class WavePickingDetail {{
    @TableId(type = IdType.ASSIGN_ID) private Long id;
    private Long waveId;
    private Long productId;
    private Long locationId;
    private Integer quantity;
    private Integer pickedQty;
    private LocalDateTime createTime;
}}
"""

# ── vo (missing ones) ──────────────────────────────────────────────────────
files[f"{BASE}/vo/InventoryCheckResult.java"] = f"""package {PKG}.vo;
import lombok.Data;
import java.math.BigDecimal;
@Data public class InventoryCheckResult {{
    private Long warehouseId;
    private Integer totalItems;
    private Integer matchCount;
    private Integer diffCount;
    private BigDecimal totalProfit;
    private BigDecimal totalLoss;
}}
"""

# ── mapper (missing ones) ──────────────────────────────────────────────────
for entity, tbl in [("InboundOrder","InboundOrder"),("InboundDetail","InboundDetail"),
                    ("OutboundOrder","OutboundOrder"),("OutboundDetail","OutboundDetail"),
                    ("StockTransfer","StockTransfer")]:
    files[f"{BASE}/mapper/{entity}Mapper.java"] = f"""package {PKG}.mapper;
import {PKG}.entity.{entity};
import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import org.apache.ibatis.annotations.Mapper;
@Mapper public interface {entity}Mapper extends BaseMapper<{entity}> {{}}
"""

# ── write all files ────────────────────────────────────────────────────────
for path, content in files.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f"OK {path}")

print("ALL DONE")
