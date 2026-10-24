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
import java.time.LocalDateTime;

/**
 * 选品推荐结果 - 每次评估产出的推荐记录
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@TableName("recommend_result")
public class RecommendResult implements Serializable {

    private static final long serialVersionUID = 1L;

    @TableId(type = IdType.AUTO)
    private Long id;

    /** 关联候选商品 ID */
    @TableField("candidate_id")
    private Long candidateId;

    /** SKU（冗余便于查询） */
    @TableField("sku")
    private String sku;

    /** 综合得分 0~100 */
    @TableField("score")
    private Double score;

    /** 推荐等级 STRONG_BUY / BUY / HOLD / SKIP */
    @TableField("recommend_level")
    private String recommendLevel;

    /** 排名 */
    @TableField("rank_position")
    private Integer rankPosition;

    /** 预期月利润 (USD) */
    @TableField("expected_monthly_profit")
    private Double expectedMonthlyProfit;

    /** 预期月销量 */
    @TableField("expected_monthly_sales")
    private Integer expectedMonthlySales;

    /** 综合风险评分 0~100 */
    @TableField("risk_score")
    private Double riskScore;

    /** 命中规则，多个用逗号分隔 */
    @TableField("triggered_rules")
    private String triggeredRules;

    /** 关键优势 */
    @TableField("key_strengths")
    private String keyStrengths;

    /** 主要风险 */
    @TableField("key_risks")
    private String keyRisks;

    /** 卖家采纳状态 PENDING / ACCEPTED / REJECTED */
    @TableField("adoption_status")
    private String adoptionStatus;

    @TableField("created_at")
    private LocalDateTime createdAt;

    @TableField("updated_at")
    private LocalDateTime updatedAt;
}