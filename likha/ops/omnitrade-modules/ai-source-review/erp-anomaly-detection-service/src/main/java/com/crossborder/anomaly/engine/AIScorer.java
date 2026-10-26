package com.crossborder.anomaly.engine;

import com.crossborder.anomaly.dto.OrderFeatures;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.Map;

/**
 * AI 评分引擎 - 基于特征工程的轻量级机器学习评分
 *
 * 本实现使用**加权特征评分**（一种规则化的"AI"方法），
 * 在不依赖外部 LLM/ML 服务的前提下提供可解释的风险评分。
 * 后续可替换为：
 *  - 调用外部 ML 服务（scikit-learn / XGBoost 模型）
 *  - 调用 LLM 进行深度分析
 *  - 使用 ONNX Runtime 跑本地模型
 *
 * 特征工程维度（权重由历史欺诈数据归纳）：
 *  - 客户行为（40%）：订单历史、消费总额、等级
 *  - 订单特征（25%）：金额、数量
 *  - 地理风险（20%）：国家、IP 一致性
 *  - 行为模式（15%）：支付延迟、设备、优惠券
 */
@Slf4j
@Component
public class AIScorer {

    private static final BigDecimal HIGH_AMOUNT_THRESHOLD = new BigDecimal("1000");
    private static final BigDecimal MEDIUM_AMOUNT_THRESHOLD = new BigDecimal("300");

    /**
     * 对订单特征做 AI 评分，返回 0-100 的风险分
     */
    public int score(OrderFeatures f) {
        Map<String, Double> featureValues = extractFeatures(f);
        double weighted = applyWeights(featureValues);
        return normalize(weighted);
    }

    private Map<String, Double> extractFeatures(OrderFeatures f) {
        Map<String, Double> v = new HashMap<>();

        // 客户行为特征（值范围 0-1，越高越可疑）
        v.put("customerNewness", customerNewness(f));
        v.put("customerLowHistory", lowHistory(f));
        v.put("customerLevelMismatch", levelMismatch(f));

        // 订单特征
        v.put("amountRisk", amountRisk(f));
        v.put("itemCountRisk", itemCountRisk(f));

        // 地理特征
        v.put("geoMismatch", geoMismatch(f));
        v.put("highRiskGeo", highRiskGeo(f));

        // 行为特征
        v.put("paymentLatencyRisk", paymentLatencyRisk(f));
        v.put("deviceRisk", deviceRisk(f));
        v.put("couponAbuseRisk", couponAbuseRisk(f));

        return v;
    }

    private double customerNewness(OrderFeatures f) {
        Integer count = f.getCustomerOrderCount();
        if (count == null) return 0.5;
        if (count == 0) return 1.0;
        if (count == 1) return 0.7;
        if (count < 5) return 0.4;
        return 0.1;
    }

    private double lowHistory(OrderFeatures f) {
        BigDecimal spent = f.getCustomerTotalSpent();
        if (spent == null) return 0.5;
        if (spent.compareTo(BigDecimal.ZERO) == 0) return 1.0;
        if (spent.compareTo(new BigDecimal("50")) < 0) return 0.8;
        if (spent.compareTo(new BigDecimal("500")) < 0) return 0.4;
        return 0.1;
    }

    private double levelMismatch(OrderFeatures f) {
        return "NEW".equals(f.getCustomerLevel()) ? 0.7 : 0.2;
    }

    private double amountRisk(OrderFeatures f) {
        BigDecimal amount = f.getOrderAmount();
        if (amount == null) return 0.5;
        if (amount.compareTo(HIGH_AMOUNT_THRESHOLD) > 0) return 0.9;
        if (amount.compareTo(MEDIUM_AMOUNT_THRESHOLD) > 0) return 0.5;
        return 0.2;
    }

    private double itemCountRisk(OrderFeatures f) {
        Integer count = f.getItemCount();
        if (count == null) return 0.3;
        if (count == 1) return 0.1;  // 单件反而是正常用户
        if (count > 10) return 0.7;  // 大量购买可能异常
        return 0.3;
    }

    private double geoMismatch(OrderFeatures f) {
        if (f.getIpCountry() == null || f.getShippingCountry() == null) return 0.3;
        return f.getIpCountry().equalsIgnoreCase(f.getShippingCountry()) ? 0.1 : 0.9;
    }

    private double highRiskGeo(OrderFeatures f) {
        return Boolean.TRUE.equals(f.getHighRiskCountry()) ? 0.8 : 0.1;
    }

    private double paymentLatencyRisk(OrderFeatures f) {
        Long latency = f.getPaymentLatencySeconds();
        if (latency == null) return 0.3;
        if (latency < 5) return 0.9;       // 机器人特征
        if (latency < 60) return 0.3;      // 正常快速支付
        if (latency < 3600) return 0.1;    // 正常
        if (latency < 86400) return 0.4;   // 慢支付
        return 0.7;                         // 异常延迟
    }

    private double deviceRisk(OrderFeatures f) {
        return Boolean.TRUE.equals(f.getNewDevice()) ? 0.6 : 0.1;
    }

    private double couponAbuseRisk(OrderFeatures f) {
        if (!Boolean.TRUE.equals(f.getUsedCoupon())) return 0.1;
        if (f.getDiscountAmount() == null || f.getOrderAmount() == null) return 0.3;
        BigDecimal ratio = f.getDiscountAmount().divide(
            f.getOrderAmount().max(BigDecimal.ONE), 2, java.math.RoundingMode.HALF_UP);
        return ratio.compareTo(new BigDecimal("0.5")) > 0 ? 0.8 : 0.4;
    }

    private double applyWeights(Map<String, Double> features) {
        // 客户行为 40%
        double customer = avg(features, "customerNewness", "customerLowHistory", "customerLevelMismatch") * 0.40;
        // 订单特征 25%
        double order = avg(features, "amountRisk", "itemCountRisk") * 0.25;
        // 地理风险 20%
        double geo = avg(features, "geoMismatch", "highRiskGeo") * 0.20;
        // 行为模式 15%
        double behavior = avg(features, "paymentLatencyRisk", "deviceRisk", "couponAbuseRisk") * 0.15;

        return customer + order + geo + behavior;
    }

    private double avg(Map<String, Double> m, String... keys) {
        double sum = 0;
        for (String k : keys) sum += m.getOrDefault(k, 0.0);
        return sum / keys.length;
    }

    private int normalize(double weighted) {
        return (int) Math.round(Math.min(1.0, Math.max(0.0, weighted)) * 100);
    }
}
