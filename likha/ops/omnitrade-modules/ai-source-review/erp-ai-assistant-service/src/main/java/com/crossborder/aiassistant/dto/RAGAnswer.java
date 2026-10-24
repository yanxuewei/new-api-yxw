package com.crossborder.aiassistant.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.util.List;

/**
 * RAG 回答 DTO
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class RAGAnswer {
    private String query;
    private String answer;
    private List<RetrievalResult> retrievedDocs;
    private boolean hasContext;
    private long responseTime;
}
