package com.crossborder.recommend.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * 选品候选商品 - 从外部采集或人工录入的待评估商品
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@TableName("recommend_candidate")
public class RecommendCandidate implements Serializable {

    private static final long serialVersionUID = 1L;

    @TableId(type = IdType.AUTO)
    private Long id;

    /** 候选 SKU（外部唯一标识） */
    @TableField("sku")
    private String sku;

    /** 商品标题 */
    @TableField("title")
    private String title;

    /** 类目 */
    @TableField("category")
    private String category;

    /** 平台 (amazon/shopify/tiktok 等) */
    @TableField("platform")
    private String platform;

    /** 采购成本 (USD) */
    @TableField("cost_price")
    private BigDecimal costPrice;

    /** 建议售价 (USD) */
    @TableField("suggest_price")
    private BigDecimal suggestPrice;

    /** 当前 BSR 排名 */
    @TableField("bsr_rank")
    private Integer bsrRank;

    /** 月搜索量 */
    @TableField("monthly_searches")
    private Long monthlySearches;

    /** 历史 30 天销量 */
    @TableField("last_30d_sales")
    private Long last30dSales;

    /** 评论数 */
    @TableField("review_count")
    private Integer reviewCount;

    /** 平均星级 0~5 */
    @TableField("avg_rating")
    private Double avgRating;

    /** 类目平均售价 */
    @TableField("category_avg_price")
    private BigDecimal categoryAvgPrice;

    /** 毛利率 (0~1) */
    @TableField("gross_margin")
    private Double grossMargin;

    /** 趋势分数 (-1~1) */
    @TableField("trend_score")
    private Double trendScore;

    /** 季节性因子 0~1 */
    @TableField("seasonality")
    private Double seasonality;

    /** 竞争强度 0~1 (越高越卷) */
    @TableField("competition_intensity")
    private Double competitionIntensity;

    /** 备注 */
    @TableField("remark")
    private String remark;

    @TableField("created_at")
    private LocalDateTime createdAt;

    @TableField("updated_at")
    private LocalDateTime updatedAt;
}