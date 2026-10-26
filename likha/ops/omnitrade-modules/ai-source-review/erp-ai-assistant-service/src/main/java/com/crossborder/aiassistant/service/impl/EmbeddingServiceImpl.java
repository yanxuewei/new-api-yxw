package com.crossborder.aiassistant.service.impl;

import com.crossborder.aiassistant.service.EmbeddingService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.List;

/**
 * EmbeddingService 实现：确定性伪向量
 * <p>
 * 算法：
 * <ol>
 *   <li>用 SHA-256(text + 维度下标) 拿到 32 字节种子</li>
 *   <li>取前 8 字节当 long，再用 sin/cos 映射到 [-1, 1] 之间</li>
 *   <li>整个向量 L2 归一化（cosine 相似度 = 点积）</li>
 * </ol>
 * 真实 MiniMax embedding API 接入时直接换实现，接口契约不变。
 *
 * @author OmniTrade AI Team
 * @since 1.8.0
 */
@Slf4j
@Service
public class EmbeddingServiceImpl implements EmbeddingService {

    /** 默认 384 维 — 平衡精度与性能 */
    private static final int DEFAULT_DIM = 384;

    @Override
    public List<Double> embed(String text) {
        if (text == null) text = "";
        List<Double> vec = new ArrayList<>(DEFAULT_DIM);
        for (int i = 0; i < DEFAULT_DIM; i++) {
            vec.add(generate(text, i));
        }
        return normalize(vec);
    }

    @Override
    public List<List<Double>> embedBatch(List<String> texts) {
        if (texts == null || texts.isEmpty()) return new ArrayList<>();
        List<List<Double>> result = new ArrayList<>(texts.size());
        for (String t : texts) {
            result.add(embed(t));
        }
        return result;
    }

    @Override
    public int getDimension() {
        return DEFAULT_DIM;
    }

    /**
     * 用 SHA-256(text + ":" + idx) 产生一个 [-1, 1] 的伪随机数
     */
    private double generate(String text, int idx) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest((text + ":" + idx).getBytes(StandardCharsets.UTF_8));
            // 取前 8 字节当 long
            long seed = 0L;
            for (int i = 0; i < 8; i++) {
                seed = (seed << 8) | (hash[i] & 0xFFL);
            }
            // sin 把 long 映射到 [-1, 1]
            return Math.sin(seed) * 0.5 + 0.5; // [0, 1] 之间，更适合稀疏分布
        } catch (NoSuchAlgorithmException e) {
            // SHA-256 永远存在
            log.error("SHA-256 不可用", e);
            return 0.0;
        }
    }

    /**
     * L2 归一化
     */
    private List<Double> normalize(List<Double> vec) {
        double sumSq = 0.0;
        for (double v : vec) sumSq += v * v;
        double norm = Math.sqrt(sumSq);
        if (norm < 1e-12) {
            // 全零向量，原样返回（极少见，hash 全部凑成 0）
            return vec;
        }
        List<Double> out = new ArrayList<>(vec.size());
        for (double v : vec) out.add(v / norm);
        return out;
    }
}
