package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * 反馈统计摘要 DTO
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class FeedbackStats {

    /** 总反馈数 */
    private Long totalCount;

    /** 采纳数 (ADOPTED) */
    private Long adoptedCount;

    /** 拒绝数 (REJECTED) */
    private Long rejectedCount;

    /** 忽略数 (IGNORED) */
    private Long ignoredCount;

    /** 采纳率 (0~1) */
    private Double adoptRate;

    /** 有 outcome 的反馈数 */
    private Long outcomeCount;

    /** 平均卖家评分 (1~5) */
    private Double avgSellerRating;

    /** 平均 accuracy_score (-1~1) */
    private Double avgAccuracy;

    /** 平均 30 天实际利润 (USD) */
    private Double avgActualProfit;
}