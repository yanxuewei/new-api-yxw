package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;

/**
 * 候选商品的输入特征 - 用于评分引擎评估
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class CandidateFeatures implements Serializable {

    private static final long serialVersionUID = 1L;

    private Long candidateId;
    private String sku;
    private String category;
    private String platform;

    /** 月搜索量 */
    private Long monthlySearches;

    /** 历史 30 天销量 */
    private Long last30dSales;

    /** BSR 排名（数值越小越畅销） */
    private Integer bsrRank;

    /** 评论数 */
    private Integer reviewCount;

    /** 平均星级 */
    private Double avgRating;

    /** 毛利率 0~1 */
    private Double grossMargin;

    /** 趋势分数 -1~1 */
    private Double trendScore;

    /** 季节性因子 0~1 */
    private Double seasonality;

    /** 竞争强度 0~1 (越高越卷) */
    private Double competitionIntensity;

    /** 类目平均售价 */
    private Double categoryAvgPrice;

    /** 建议售价 */
    private Double suggestPrice;

    /** 采购成本 */
    private Double costPrice;
}