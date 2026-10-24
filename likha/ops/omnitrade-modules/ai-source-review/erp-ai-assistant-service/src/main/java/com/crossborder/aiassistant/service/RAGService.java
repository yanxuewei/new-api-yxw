package com.crossborder.aiassistant.service;

import com.crossborder.aiassistant.dto.KnowledgeStats;
import com.crossborder.aiassistant.dto.RAGAnswer;
import com.crossborder.aiassistant.dto.RetrievalResult;
import com.crossborder.aiassistant.entity.KnowledgeDocument;
import com.crossborder.aiassistant.repository.KnowledgeDocumentRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * RAG 服务 - 主入口
 * <p>
 * 负责：
 * <ul>
 *   <li>文档入库（自动算 embedding）</li>
 *   <li>检索 + 回答生成</li>
 *   <li>软删除 + 统计</li>
 * </ul>
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class RAGService {

    private final KnowledgeDocumentRepository repository;
    private final EmbeddingService embeddingService;
    private final VectorSearchService vectorSearchService;

    /** 默认检索 topK */
    private static final int DEFAULT_TOPK = 3;
    /** 默认相似度阈值 */
    private static final double DEFAULT_THRESHOLD = 0.5;

    /**
     * 入库单个文档，自动计算 embedding
     */
    @Transactional
    public KnowledgeDocument addDocument(KnowledgeDocument doc) {
        if (doc == null || doc.getContent() == null || doc.getContent().isBlank()) {
            throw new IllegalArgumentException("文档内容不能为空");
        }
        if (doc.getActive() == null) doc.setActive(true);
        if (doc.getLanguage() == null) doc.setLanguage("zh");

        // 算 embedding — 标题+内容 拼接喂给模型
        String textToEmbed = (doc.getTitle() == null ? "" : doc.getTitle()) + "\n" + doc.getContent();
        List<Double> vec = embeddingService.embed(textToEmbed);
        doc.setEmbedding(serializeEmbedding(vec));

        KnowledgeDocument saved = repository.save(doc);
        log.info("文档入库 id={} title='{}' category={}", saved.getId(), saved.getTitle(), saved.getCategory());
        return saved;
    }

    /**
     * 批量入库
     */
    @Transactional
    public List<KnowledgeDocument> addDocumentsBatch(List<KnowledgeDocument> docs) {
        if (docs == null || docs.isEmpty()) return new ArrayList<>();
        List<KnowledgeDocument> saved = new ArrayList<>(docs.size());
        for (KnowledgeDocument d : docs) {
            saved.add(addDocument(d));
        }
        log.info("批量入库完成 数量={}", saved.size());
        return saved;
    }

    /**
     * 检索（不生成回答）
     */
    public List<RetrievalResult> retrieve(String query, int topK) {
        List<VectorSearchService.SearchResult> raw =
                vectorSearchService.search(query, topK > 0 ? topK : DEFAULT_TOPK, DEFAULT_THRESHOLD);
        List<RetrievalResult> out = new ArrayList<>(raw.size());
        for (VectorSearchService.SearchResult r : raw) {
            KnowledgeDocument d = r.getDocument();
            out.add(RetrievalResult.builder()
                    .documentId(d.getId())
                    .title(d.getTitle())
                    .content(d.getContent())
                    .category(d.getCategory())
                    .language(d.getLanguage())
                    .score(r.getScore())
                    .build());
        }
        return out;
    }

    /**
     * RAG 主入口：检索 + 回答生成
     * <p>
     * 当检索到上下文时，把上下文拼到系统提示里，让 LLM 基于上下文回答；
     * 没检索到时返回通用兜底回答，标记 hasContext=false。
     */
    public RAGAnswer answer(String query, int topK) {
        long start = System.currentTimeMillis();
        log.info("RAG answer 入口 query='{}' topK={}", query, topK);

        List<RetrievalResult> retrieved = retrieve(query, topK);
        boolean hasContext = !retrieved.isEmpty();

        String answer;
        if (hasContext) {
            answer = composeAnswerWithContext(query, retrieved);
        } else {
            answer = "未找到与问题相关的知识库内容。请尝试换个问法，或联系客服。";
        }

        return RAGAnswer.builder()
                .query(query)
                .answer(answer)
                .retrievedDocs(retrieved)
                .hasContext(hasContext)
                .responseTime(System.currentTimeMillis() - start)
                .build();
    }

    /** 拼接上下文，给 LLM 用 */
    private String composeAnswerWithContext(String query, List<RetrievalResult> retrieved) {
        StringBuilder sb = new StringBuilder();
        sb.append("根据以下知识库内容回答用户问题：\n\n");
        for (int i = 0; i < retrieved.size(); i++) {
            RetrievalResult r = retrieved.get(i);
            sb.append("【").append(i + 1).append("】")
              .append(r.getTitle()).append("\n")
              .append(r.getContent()).append("\n\n");
        }
        sb.append("用户问题：").append(query);
        return sb.toString();
    }

    /**
     * 软删除
     */
    @Transactional
    public boolean softDelete(Long id) {
        return repository.findById(id).map(d -> {
            d.setActive(false);
            repository.save(d);
            log.info("软删除文档 id={}", id);
            return true;
        }).orElse(false);
    }

    /**
     * 统计
     */
    public KnowledgeStats stats() {
        List<KnowledgeDocument> all = repository.findAll();
        long total = all.size();
        long active = all.stream().filter(d -> Boolean.TRUE.equals(d.getActive())).count();
        Map<String, Long> catCount = all.stream()
                .filter(d -> Boolean.TRUE.equals(d.getActive()))
                .filter(d -> d.getCategory() != null)
                .collect(Collectors.groupingBy(KnowledgeDocument::getCategory, Collectors.counting()));
        Map<String, Long> langCount = all.stream()
                .filter(d -> Boolean.TRUE.equals(d.getActive()))
                .filter(d -> d.getLanguage() != null)
                .collect(Collectors.groupingBy(KnowledgeDocument::getLanguage, Collectors.counting()));

        return KnowledgeStats.builder()
                .totalCount(total)
                .activeCount(active)
                .categoryCount(catCount)
                .languageCount(langCount)
                .build();
    }

    /** 把 List<Double> 序列化成 JSON 数组字符串（不依赖 Jackson，手写避免循环依赖） */
    static String serializeEmbedding(List<Double> vec) {
        if (vec == null || vec.isEmpty()) return "[]";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < vec.size(); i++) {
            if (i > 0) sb.append(",");
            sb.append(vec.get(i));
        }
        sb.append("]");
        return sb.toString();
    }
}
