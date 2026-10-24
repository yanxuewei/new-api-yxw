package com.crossborder.recommend.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * 反馈请求 DTO
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class FeedbackRequest {

    @NotNull(message = "resultId 不能为空")
    private Long resultId;

    @NotNull(message = "candidateId 不能为空")
    private Long candidateId;

    @NotBlank(message = "feedbackType 不能为空 (ADOPTED/REJECTED/IGNORED)")
    private String feedbackType;

    @Min(1) @Max(5)
    private Integer sellerRating;

    private Integer actual30dSales;

    private java.math.BigDecimal actual30dProfit;

    private Double actualConversionRate;

    /** 可选：卖家传入 SKU/category/platform 便于分组统计 */
    private String sku;
    private String category;
    private String platform;

    private String feedbackNote;

    private String feedbackBy;
}