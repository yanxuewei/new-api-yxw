package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.List;

/**
 * 单个候选商品的推荐评分结果
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class RecommendationScore implements Serializable {

    private static final long serialVersionUID = 1L;

    private Long candidateId;
    private String sku;

    /** 综合得分 0~100 */
    private Double score;

    /** 推荐等级 STRONG_BUY / BUY / HOLD / SKIP */
    private String recommendLevel;

    /** 预期月销量 */
    private Integer expectedMonthlySales;

    /** 预期月利润 (USD) */
    private Double expectedMonthlyProfit;

    /** 综合风险 0~100 */
    private Double riskScore;

    /** 命中规则列表 */
    private List<String> triggeredRules;

    /** 关键优势 */
    private List<String> keyStrengths;

    /** 主要风险 */
    private List<String> keyRisks;

    /** 各维度得分明细 */
    private DimensionBreakdown breakdown;

    @Data
    @Builder
    @NoArgsConstructor
    @AllArgsConstructor
    public static class DimensionBreakdown implements Serializable {
        private static final long serialVersionUID = 1L;
        private Double demandScore;       // 需求强度
        private Double trendScore;        // 趋势动能
        private Double profitScore;       // 利润空间
        private Double competitionScore;  // 竞争可行性（高分=蓝海）
        private Double qualityScore;      // 商品质量（评论+星级）
    }
}