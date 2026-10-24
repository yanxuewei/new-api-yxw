package com.crossborder.recommend.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.List;

/**
 * 选品推荐请求 DTO
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class RecommendRequest implements Serializable {

    private static final long serialVersionUID = 1L;

    /** 平台过滤（amazon/shopify 等），可选 */
    private String platform;

    /** 类目过滤，可选 */
    private String category;

    /** 推荐数量上限 */
    private Integer topK;

    /** 是否覆盖已有推荐 (true=重新生成) */
    private Boolean regenerate;

    /** 最小月搜索量阈值 */
    private Long minMonthlySearches;

    /** 最低毛利率阈值 */
    private Double minGrossMargin;

    private List<Long> candidateIds;
}