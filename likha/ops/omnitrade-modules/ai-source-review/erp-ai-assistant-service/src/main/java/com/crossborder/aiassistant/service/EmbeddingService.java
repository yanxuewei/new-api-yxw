package com.crossborder.aiassistant.service;

import java.util.List;

/**
 * 文本嵌入服务
 * <p>
 * 负责把文本转成定长浮点向量，用于后续相似度计算。
 *
 * <p>当前实现（v1.8.0）：使用基于 SHA-256 的确定性伪向量生成器，
 * 384 维、L2 归一化，保证：
 * <ul>
 *   <li>相同输入 → 完全相同输出（测试可重现）</li>
 *   <li>不同输入 → 高概率不同输出</li>
 *   <li>语义相似性 → 弱相关（占位实现，等真实 embedding API 接入后替换）</li>
 * </ul>
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
public interface EmbeddingService {

    /**
     * 把单段文本编码为向量
     */
    List<Double> embed(String text);

    /**
     * 批量编码
     */
    List<List<Double>> embedBatch(List<String> texts);

    /**
     * 向量维度
     */
    int getDimension();
}
