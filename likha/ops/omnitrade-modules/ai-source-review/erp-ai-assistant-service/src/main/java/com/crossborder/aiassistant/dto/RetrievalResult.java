package com.crossborder.aiassistant.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * 检索结果 DTO
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class RetrievalResult {
    private Long documentId;
    private String title;
    private String content;
    private String category;
    private String language;
    private double score;
}
