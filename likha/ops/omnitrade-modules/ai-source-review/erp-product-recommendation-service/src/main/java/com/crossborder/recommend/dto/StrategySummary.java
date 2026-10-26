package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;

/**
 * 策略摘要
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class StrategySummary implements Serializable {
    private static final long serialVersionUID = 1L;

    /** 平均得分 */
    private Double avgScore;

    /** STRONG_BUY 数量 */
    private Long strongBuyCount;

    /** BUY 数量 */
    private Long buyCount;

    /** HOLD 数量 */
    private Long holdCount;

    /** SKIP 数量 */
    private Long skipCount;

    /** 总预期月利润 (USD) */
    private Double totalExpectedProfit;

    /** 总体风险等级 LOW/MEDIUM/HIGH */
    private String overallRiskLevel;
}