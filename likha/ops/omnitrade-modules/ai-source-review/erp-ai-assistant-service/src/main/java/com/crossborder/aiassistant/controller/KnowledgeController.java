package com.crossborder.aiassistant.controller;

import com.crossborder.aiassistant.dto.KnowledgeStats;
import com.crossborder.aiassistant.dto.RAGAnswer;
import com.crossborder.aiassistant.dto.RetrievalResult;
import com.crossborder.aiassistant.entity.KnowledgeDocument;
import com.crossborder.aiassistant.service.RAGService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/**
 * 知识库 REST API
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Slf4j
@RestController
@RequestMapping("/api/ai/knowledge")
@RequiredArgsConstructor
public class KnowledgeController {

    private final RAGService ragService;

    /** 入库单个 */
    @PostMapping("/documents")
    public ResponseEntity<KnowledgeDocument> addDocument(@RequestBody KnowledgeDocument doc) {
        log.info("POST /api/ai/knowledge/documents title='{}'", doc.getTitle());
        return ResponseEntity.ok(ragService.addDocument(doc));
    }

    /** 批量入库 */
    @PostMapping("/documents/batch")
    public ResponseEntity<List<KnowledgeDocument>> addBatch(@RequestBody List<KnowledgeDocument> docs) {
        log.info("POST /api/ai/knowledge/documents/batch size={}", docs.size());
        return ResponseEntity.ok(ragService.addDocumentsBatch(docs));
    }

    /** 检索（不含生成） */
    @GetMapping("/search")
    public ResponseEntity<List<RetrievalResult>> search(
            @RequestParam("q") String query,
            @RequestParam(value = "topK", defaultValue = "5") int topK) {
        return ResponseEntity.ok(ragService.retrieve(query, topK));
    }

    /** RAG 问答 */
    @PostMapping("/ask")
    public ResponseEntity<RAGAnswer> ask(@RequestBody Map<String, Object> body) {
        String query = (String) body.get("query");
        Object tk = body.get("topK");
        int topK = tk instanceof Number ? ((Number) tk).intValue() : 3;
        return ResponseEntity.ok(ragService.answer(query, topK));
    }

    /** 软删除 */
    @DeleteMapping("/documents/{id}")
    public ResponseEntity<Boolean> delete(@PathVariable Long id) {
        return ResponseEntity.ok(ragService.softDelete(id));
    }

    /** 统计 */
    @GetMapping("/stats")
    public ResponseEntity<KnowledgeStats> stats() {
        return ResponseEntity.ok(ragService.stats());
    }
}
