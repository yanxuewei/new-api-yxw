package com.crossborder.aiassistant.entity;

import jakarta.persistence.*;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.LocalDateTime;

/**
 * 知识库文档 - RAG 持久化实体
 * <p>
 * 升级自 v1.7.0 的内存 ArrayList<Knowledge>，支持：
 * 1. 真实持久化 (JPA + MySQL)
 * 2. 向量嵌入存储 (embedding 字段)
 * 3. 多语言、多分类、多标签
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
@Entity
@Table(name = "knowledge_document", indexes = {
        @Index(name = "idx_category", columnList = "category"),
        @Index(name = "idx_language", columnList = "language"),
        @Index(name = "idx_active", columnList = "active")
})
public class KnowledgeDocument {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    /** 文档标题 */
    @Column(nullable = false, length = 200)
    private String title;

    /** 文档正文（用于检索和喂给 LLM） */
    @Lob
    @Column(nullable = false, columnDefinition = "TEXT")
    private String content;

    /** 分类，如 订单/物流/产品/退货 */
    @Column(length = 50)
    private String category;

    /** 标签，逗号分隔 */
    @Column(length = 500)
    private String tags;

    /** 语言代码，默认 zh */
    @Column(length = 10)
    @Builder.Default
    private String language = "zh";

    /**
     * 嵌入向量，JSON 数组形式存储。
     * 例: "[0.1,0.2,-0.3,...]"
     * 维度由 EmbeddingService.getDimension() 决定。
     */
    @Lob
    @Column(name = "embedding", columnDefinition = "TEXT")
    private String embedding;

    /** 是否启用（软删除标志） */
    @Column(nullable = false)
    @Builder.Default
    private Boolean active = true;

    @CreationTimestamp
    @Column(name = "create_time", updatable = false)
    private LocalDateTime createTime;

    @UpdateTimestamp
    @Column(name = "update_time")
    private LocalDateTime updateTime;
}
