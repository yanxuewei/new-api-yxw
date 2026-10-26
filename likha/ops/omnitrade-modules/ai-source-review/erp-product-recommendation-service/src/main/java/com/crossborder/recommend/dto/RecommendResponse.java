package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.List;

/**
 * 推荐响应 - 包含排序后的候选商品
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class RecommendResponse implements Serializable {

    private static final long serialVersionUID = 1L;

    private Integer totalCandidates;
    private Integer recommendedCount;
    private Long detectionLatencyMs;

    /** 排序后的推荐结果 */
    private List<RecommendationScore> recommendations;

    /** 整体策略摘要 */
    private StrategySummary strategy;
}