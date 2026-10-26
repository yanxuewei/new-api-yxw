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
 * 选品推荐反馈 - v1.9.0 Feedback 闭环核心表
 *
 * 记录卖家对推荐的真实态度和上架后的实际 outcome，
 * 用于 WeightTuner 动态调整评分权重。
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@TableName("recommend_feedback")
public class RecommendFeedback implements Serializable {

    private static final long serialVersionUID = 1L;

    @TableId(type = IdType.AUTO)
    private Long id;

    /** 关联的推荐结果 ID */
    @TableField("result_id")
    private Long resultId;

    /** 关联候选商品 ID */
    @TableField("candidate_id")
    private Long candidateId;

    /** SKU（冗余便于查询） */
    @TableField("sku")
    private String sku;

    /** 类目（用于分组统计） */
    @TableField("category")
    private String category;

    /** 平台 */
    @TableField("platform")
    private String platform;

    /**
     * 反馈类型
     * ADOPTED  - 卖家采纳并上架
     * REJECTED - 卖家明确拒绝
     * IGNORED  - 卖家未表态
     */
    @TableField("feedback_type")
    private String feedbackType;

    /** 卖家主观打分 1~5 */
    @TableField("seller_rating")
    private Integer sellerRating;

    /** 上架后 30 天真实销量 */
    @TableField("actual_30d_sales")
    private Integer actual30dSales;

    /** 上架后 30 天真实利润 (USD) */
    @TableField("actual_30d_profit")
    private BigDecimal actual30dProfit;

    /** 真实转化率 */
    @TableField("actual_conversion_rate")
    private Double actualConversionRate;

    /**
     * 算法计算的准确度分数 -1 ~ 1
     *  >0 推荐方向正确
     *  <0 推荐方向错误
     *  =0 中性
     */
    @TableField("accuracy_score")
    private Double accuracyScore;

    /** 卖家备注 */
    @TableField("feedback_note")
    private String feedbackNote;

    /** 反馈人标识 */
    @TableField("feedback_by")
    private String feedbackBy;

    @TableField("created_at")
    private LocalDateTime createdAt;

    @TableField("updated_at")
    private LocalDateTime updatedAt;
}