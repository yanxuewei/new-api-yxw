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
 * 权重调优快照 - v1.9.0
 *
 * 每次 WeightTuner 调整权重后写一条记录，
 * 用于追踪权重漂移、回滚、A/B 评估。
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@TableName("recommend_weight_snapshot")
public class RecommendWeightSnapshot implements Serializable {

    private static final long serialVersionUID = 1L;

    @TableId(type = IdType.AUTO)
    private Long id;

    @TableField("w_demand")
    private Double wDemand;

    @TableField("w_trend")
    private Double wTrend;

    @TableField("w_profit")
    private Double wProfit;

    @TableField("w_competition")
    private Double wCompetition;

    @TableField("w_quality")
    private Double wQuality;

    /** 触发调优的样本数 */
    @TableField("sample_count")
    private Integer sampleCount;

    /** 当时样本的平均准确度 */
    @TableField("avg_accuracy")
    private Double avgAccuracy;

    /** 当时样本的采纳率 */
    @TableField("adopt_rate")
    private Double adoptRate;

    /** 触发原因 MANUAL / AUTO_TUNE / ROLLBACK */
    @TableField("trigger_reason")
    private String triggerReason;

    @TableField("created_at")
    private LocalDateTime createdAt;
}