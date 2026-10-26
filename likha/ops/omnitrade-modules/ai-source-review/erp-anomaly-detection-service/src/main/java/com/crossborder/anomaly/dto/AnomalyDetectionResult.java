package com.crossborder.anomaly.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.List;

/**
 * 异常检测结果 DTO
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class AnomalyDetectionResult implements Serializable {

    private static final long serialVersionUID = 1L;

    /** 订单ID */
    private String orderId;

    /** 综合风险评分（0-100，越高越可疑） */
    private Integer riskScore;

    /** 风险等级（LOW/MEDIUM/HIGH/CRITICAL） */
    private String riskLevel;

    /** 是否异常 */
    private Boolean isAnomaly;

    /** 检测到的异常类型列表 */
    private List<String> anomalyTypes;

    /** 命中的规则列表 */
    private List<String> triggeredRules;

    /** AI 模型评分（0-100） */
    private Integer aiScore;

    /** 规则引擎评分（0-100） */
    private Integer ruleScore;

    /** 处置建议（ALLOW/REVIEW/HOLD/REJECT） */
    private String recommendation;

    /** 详细说明 */
    private String explanation;

    /** 检测耗时（毫秒） */
    private Long detectionLatencyMs;
}
