package com.crossborder.anomaly.service;

import com.crossborder.anomaly.dto.AnomalyDetectionResult;
import com.crossborder.anomaly.dto.OrderFeatures;

import java.util.List;

/**
 * 异常检测服务接口
 */
public interface AnomalyDetectionService {

    /**
     * 单订单异常检测
     */
    AnomalyDetectionResult detect(OrderFeatures features);

    /**
     * 批量检测
     */
    List<AnomalyDetectionResult> detectBatch(List<OrderFeatures> featuresList);

    /**
     * 综合风险评估（规则 + AI 融合）
     */
    AnomalyDetectionResult fuseAndAssess(int ruleScore, int aiScore, List<String> triggeredRules, String orderId);
}
