package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.time.LocalDateTime;

/**
 * 权重调优结果 DTO
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class WeightTuneResult {

    /** 调优前权重 */
    private ScoringWeights beforeWeights;

    /** 调优后权重 */
    private ScoringWeights afterWeights;

    /** 是否触发了调优 (false 表示样本不足) */
    private Boolean tuned;

    /** 触发原因 */
    private String reason;

    /** 当时样本数 */
    private Integer sampleCount;

    /** 调优时刻 */
    private LocalDateTime tunedAt;

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class ScoringWeights {
        private Double wDemand;
        private Double wTrend;
        private Double wProfit;
        private Double wCompetition;
        private Double wQuality;
    }
}