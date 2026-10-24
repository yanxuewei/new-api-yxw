package com.crossborder.anomaly.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 订单特征 DTO - 异常检测输入
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class OrderFeatures implements Serializable {

    private static final long serialVersionUID = 1L;

    /** 订单ID */
    private String orderId;

    /** 平台（AMAZON/SHOPEE/EBAY/LAZADA/TIKTOK） */
    private String platform;

    /** 客户ID */
    private String customerId;

    /** 客户历史订单数 */
    private Integer customerOrderCount;

    /** 客户累计消费金额 */
    private BigDecimal customerTotalSpent;

    /** 客户等级（NEW/NORMAL/VIP） */
    private String customerLevel;

    /** 订单金额 */
    private BigDecimal orderAmount;

    /** 商品数量 */
    private Integer itemCount;

    /** 收货国家 */
    private String shippingCountry;

    /** 收货城市 */
    private String shippingCity;

    /** 收货邮编 */
    private String shippingPostal;

    /** 客户IP 国家（用于地址异常检测） */
    private String ipCountry;

    /** 支付方式 */
    private String paymentMethod;

    /** 下单到支付耗时（秒） */
    private Long paymentLatencySeconds;

    /** 优惠券使用情况 */
    private Boolean usedCoupon;

    /** 优惠金额 */
    private BigDecimal discountAmount;

    /** 是否高风险国家 */
    private Boolean highRiskCountry;

    /** 设备指纹 */
    private String deviceFingerprint;

    /** 下单时间 */
    private LocalDateTime orderTime;

    /** 是否新设备 */
    private Boolean newDevice;
}
