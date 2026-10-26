package com.crossborder.anomaly.engine;

import com.crossborder.anomaly.dto.OrderFeatures;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;

/**
 * 规则引擎 - 基于预定义业务规则检测异常
 *
 * 检测维度：
 *  1. 新客户大额订单（首单异常）
 *  2. 地址不一致（IP 国家 ≠ 收货国家）
 *  3. 高风险国家
 *  4. 异常支付延迟（机器人脚本特征）
 *  5. 优惠券滥用
 *  6. 客户等级与订单金额不匹配
 *  7. 设备指纹异常
 */
@Slf4j
@Component
public class RuleEngine {

    /** 高风险国家列表（简化版，实际应来自风控数据库） */
    private static final List<String> HIGH_RISK_COUNTRIES = List.of("XX", "YY", "ZZ");

    /** 规则权重（每条规则触发后的风险加分） */
    private static final int W_NEW_CUSTOMER_LARGE_ORDER = 35;
    private static final int W_ADDRESS_MISMATCH = 30;
    private static final int W_HIGH_RISK_COUNTRY = 25;
    private static final int W_PAYMENT_LATENCY_ANOMALY = 15;
    private static final int W_COUPON_ABUSE = 20;
    private static final int W_LEVEL_MISMATCH = 15;
    private static final int W_NEW_DEVICE = 10;
    private static final int W_HIGH_AMOUNT_NEW_CUSTOMER = 25;

    public RuleResult evaluate(OrderFeatures f) {
        List<String> triggered = new ArrayList<>();
        int score = 0;

        // 1. 新客户大额订单：客户累计订单 < 3 且 订单金额 > 500
        if (f.getCustomerOrderCount() != null
            && f.getCustomerOrderCount() < 3
            && f.getOrderAmount() != null
            && f.getOrderAmount().compareTo(new java.math.BigDecimal("500")) > 0) {
            score += W_NEW_CUSTOMER_LARGE_ORDER;
            triggered.add("R001: 新客户大额订单");
        }

        // 2. 地址不一致：IP 国家与收货国家不同
        if (f.getIpCountry() != null
            && f.getShippingCountry() != null
            && !f.getIpCountry().equalsIgnoreCase(f.getShippingCountry())) {
            score += W_ADDRESS_MISMATCH;
            triggered.add("R002: IP 与收货国家不一致");
        }

        // 3. 高风险国家
        if (Boolean.TRUE.equals(f.getHighRiskCountry())
            || (f.getShippingCountry() != null
                && HIGH_RISK_COUNTRIES.contains(f.getShippingCountry()))) {
            score += W_HIGH_RISK_COUNTRY;
            triggered.add("R003: 高风险国家");
        }

        // 4. 支付延迟异常：< 5 秒（机器人特征）或 > 24 小时（异常）
        if (f.getPaymentLatencySeconds() != null) {
            if (f.getPaymentLatencySeconds() < 5) {
                score += W_PAYMENT_LATENCY_ANOMALY;
                triggered.add("R004: 支付延迟过短（疑似脚本）");
            } else if (f.getPaymentLatencySeconds() > 86400) {
                score += W_PAYMENT_LATENCY_ANOMALY;
                triggered.add("R004: 支付延迟过长");
            }
        }

        // 5. 优惠券滥用：新客户 + 大额优惠
        if (Boolean.TRUE.equals(f.getUsedCoupon())
            && f.getCustomerOrderCount() != null
            && f.getCustomerOrderCount() < 2
            && f.getDiscountAmount() != null
            && f.getOrderAmount() != null
            && f.getDiscountAmount().compareTo(f.getOrderAmount().multiply(new java.math.BigDecimal("0.5"))) > 0) {
            score += W_COUPON_ABUSE;
            triggered.add("R005: 新客户大额优惠券");
        }

        // 6. 客户等级与订单金额不匹配：NEW 客户下 1000+ 订单
        if ("NEW".equals(f.getCustomerLevel())
            && f.getOrderAmount() != null
            && f.getOrderAmount().compareTo(new java.math.BigDecimal("1000")) > 0) {
            score += W_LEVEL_MISMATCH;
            triggered.add("R006: NEW 客户大额订单");
        }

        // 7. 新设备 + 大额订单
        if (Boolean.TRUE.equals(f.getNewDevice())
            && f.getOrderAmount() != null
            && f.getOrderAmount().compareTo(new java.math.BigDecimal("800")) > 0) {
            score += W_NEW_DEVICE;
            triggered.add("R007: 新设备大额订单");
        }

        // 8. 高额新客户组合：客户累计 < 100 且订单 > 2000
        if (f.getCustomerTotalSpent() != null
            && f.getCustomerTotalSpent().compareTo(new java.math.BigDecimal("100")) < 0
            && f.getOrderAmount() != null
            && f.getOrderAmount().compareTo(new java.math.BigDecimal("2000")) > 0) {
            score += W_HIGH_AMOUNT_NEW_CUSTOMER;
            triggered.add("R008: 极高金额新客户");
        }

        // 限制在 0-100
        score = Math.min(100, Math.max(0, score));

        return new RuleResult(score, triggered);
    }

    public record RuleResult(int score, List<String> triggeredRules) {}
}
