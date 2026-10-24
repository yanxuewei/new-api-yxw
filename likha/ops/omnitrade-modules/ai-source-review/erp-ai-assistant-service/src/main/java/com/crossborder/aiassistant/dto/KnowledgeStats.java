package com.crossborder.aiassistant.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.Map;

/**
 * 知识库统计 DTO
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class KnowledgeStats {
    private long totalCount;
    private long activeCount;
    private Map<String, Long> categoryCount;
    private Map<String, Long> languageCount;
}
