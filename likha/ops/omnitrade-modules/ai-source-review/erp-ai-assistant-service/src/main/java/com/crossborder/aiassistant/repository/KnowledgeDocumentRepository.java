package com.crossborder.aiassistant.repository;

import com.crossborder.aiassistant.entity.KnowledgeDocument;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * 知识库 Repository
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Repository
public interface KnowledgeDocumentRepository extends JpaRepository<KnowledgeDocument, Long> {

    /** 所有启用中的文档 */
    List<KnowledgeDocument> findByActiveTrue();

    /** 按分类查 */
    List<KnowledgeDocument> findByCategoryAndActiveTrue(String category);

    /** 按语言查 */
    List<KnowledgeDocument> findByLanguageAndActiveTrue(String language);

    /** 按分类 + 语言 */
    List<KnowledgeDocument> findByCategoryAndLanguageAndActiveTrue(String category, String language);
}
