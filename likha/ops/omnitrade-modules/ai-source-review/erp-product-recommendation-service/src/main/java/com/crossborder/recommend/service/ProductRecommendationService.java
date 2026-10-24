package com.crossborder.recommend.service;

import com.crossborder.recommend.dto.CandidateFeatures;
import com.crossborder.recommend.dto.RecommendRequest;
import com.crossborder.recommend.dto.RecommendResponse;
import com.crossborder.recommend.dto.RecommendationScore;
import com.crossborder.recommend.dto.StrategySummary;
import com.crossborder.recommend.entity.RecommendCandidate;
import com.crossborder.recommend.entity.RecommendResult;
import com.crossborder.recommend.engine.ScoringEngine;
import com.crossborder.recommend.repository.RecommendCandidateRepository;
import com.crossborder.recommend.repository.RecommendResultRepository;
import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

/**
 * 选品推荐核心服务
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class ProductRecommendationService {

    private final RecommendCandidateRepository candidateRepository;
    private final RecommendResultRepository resultRepository;
    private final ScoringEngine scoringEngine;

    /**
     * 执行选品推荐
     */
    @Transactional
    public RecommendResponse recommend(RecommendRequest request) {
        long start = System.currentTimeMillis();
        log.info("开始选品推荐: platform={}, category={}, topK={}",
            request.getPlatform(), request.getCategory(), request.getTopK());

        // 1. 加载候选商品
        List<RecommendCandidate> candidates = loadCandidates(request);
        log.info("加载候选商品 {} 条", candidates.size());

        // 2. 转 features + 评分
        List<RecommendationScore> scores = new ArrayList<>();
        for (RecommendCandidate c : candidates) {
            RecommendationScore s = scoringEngine.score(toFeatures(c));
            scores.add(s);
        }

        // 3. 排序
        scores.sort(Comparator.comparingDouble(RecommendationScore::getScore).reversed());

        // 4. topK 截断
        int topK = request.getTopK() == null ? 10 : request.getTopK();
        if (topK > 0 && scores.size() > topK) {
            scores = new ArrayList<>(scores.subList(0, topK));
        }

        // 5. 持久化（如 regenerate=true 或首次）
        if (Boolean.TRUE.equals(request.getRegenerate())) {
            saveResults(scores);
        }

        // 6. 计算策略摘要
        StrategySummary summary = buildSummary(scores);

        long latency = System.currentTimeMillis() - start;
        log.info("选品推荐完成: 共评估 {} 条, 推荐 topK={}, 耗时 {}ms", candidates.size(), scores.size(), latency);

        return RecommendResponse.builder()
            .totalCandidates(candidates.size())
            .recommendedCount(scores.size())
            .detectionLatencyMs(latency)
            .recommendations(scores)
            .strategy(summary)
            .build();
    }

    /**
     * 根据 ID 查询已保存的推荐结果
     */
    public List<RecommendResult> findSavedResults(Integer limit) {
        QueryWrapper<RecommendResult> q = new QueryWrapper<>();
        q.orderByDesc("score").last("LIMIT " + (limit == null ? 50 : limit));
        return resultRepository.selectList(q);
    }

    /**
     * 更新采纳状态
     */
    @Transactional
    public RecommendResult updateAdoptionStatus(Long id, String status) {
        RecommendResult r = resultRepository.selectById(id);
        if (r == null) return null;
        r.setAdoptionStatus(status);
        r.setUpdatedAt(LocalDateTime.now());
        resultRepository.updateById(r);
        log.info("更新推荐 {} 采纳状态为 {}", id, status);
        return r;
    }

    /**
     * 加载候选商品，按 request 过滤
     */
    List<RecommendCandidate> loadCandidates(RecommendRequest request) {
        QueryWrapper<RecommendCandidate> q = new QueryWrapper<>();
        if (request.getPlatform() != null && !request.getPlatform().isBlank()) {
            q.eq("platform", request.getPlatform());
        }
        if (request.getCategory() != null && !request.getCategory().isBlank()) {
            q.eq("category", request.getCategory());
        }
        if (request.getMinMonthlySearches() != null) {
            q.ge("monthly_searches", request.getMinMonthlySearches());
        }
        if (request.getMinGrossMargin() != null) {
            q.ge("gross_margin", request.getMinGrossMargin());
        }
        if (request.getCandidateIds() != null && !request.getCandidateIds().isEmpty()) {
            q.in("id", request.getCandidateIds());
        }
        return candidateRepository.selectList(q);
    }

    /**
     * 持久化推荐结果
     */
    void saveResults(List<RecommendationScore> scores) {
        LocalDateTime now = LocalDateTime.now();
        int rank = 1;
        for (RecommendationScore s : scores) {
            RecommendResult r = RecommendResult.builder()
                .candidateId(s.getCandidateId())
                .sku(s.getSku())
                .score(s.getScore())
                .recommendLevel(s.getRecommendLevel())
                .rankPosition(rank++)
                .expectedMonthlyProfit(s.getExpectedMonthlyProfit())
                .expectedMonthlySales(s.getExpectedMonthlySales())
                .riskScore(s.getRiskScore())
                .triggeredRules(s.getTriggeredRules() == null ? "" :
                    String.join(",", s.getTriggeredRules()))
                .keyStrengths(s.getKeyStrengths() == null ? "" :
                    String.join("|", s.getKeyStrengths()))
                .keyRisks(s.getKeyRisks() == null ? "" :
                    String.join("|", s.getKeyRisks()))
                .adoptionStatus("PENDING")
                .createdAt(now)
                .updatedAt(now)
                .build();
            resultRepository.insert(r);
        }
    }

    /**
     * 计算策略摘要
     */
    StrategySummary buildSummary(List<RecommendationScore> scores) {
        if (scores.isEmpty()) {
            return StrategySummary.builder()
                .avgScore(0.0)
                .strongBuyCount(0L)
                .buyCount(0L)
                .holdCount(0L)
                .skipCount(0L)
                .totalExpectedProfit(0.0)
                .overallRiskLevel("LOW")
                .build();
        }

        long strongBuy = scores.stream().filter(s -> "STRONG_BUY".equals(s.getRecommendLevel())).count();
        long buy = scores.stream().filter(s -> "BUY".equals(s.getRecommendLevel())).count();
        long hold = scores.stream().filter(s -> "HOLD".equals(s.getRecommendLevel())).count();
        long skip = scores.stream().filter(s -> "SKIP".equals(s.getRecommendLevel())).count();
        double avg = scores.stream().mapToDouble(RecommendationScore::getScore).average().orElse(0);
        double totalProfit = scores.stream().mapToDouble(RecommendationScore::getExpectedMonthlyProfit).sum();
        double avgRisk = scores.stream().mapToDouble(RecommendationScore::getRiskScore).average().orElse(0);
        String overallRisk = avgRisk >= 60 ? "HIGH" : avgRisk >= 40 ? "MEDIUM" : "LOW";

        return StrategySummary.builder()
            .avgScore(Math.round(avg * 100) / 100.0)
            .strongBuyCount(strongBuy)
            .buyCount(buy)
            .holdCount(hold)
            .skipCount(skip)
            .totalExpectedProfit(Math.round(totalProfit * 100) / 100.0)
            .overallRiskLevel(overallRisk)
            .build();
    }

    CandidateFeatures toFeatures(RecommendCandidate c) {
        return CandidateFeatures.builder()
            .candidateId(c.getId())
            .sku(c.getSku())
            .category(c.getCategory())
            .platform(c.getPlatform())
            .monthlySearches(c.getMonthlySearches())
            .last30dSales(c.getLast30dSales())
            .bsrRank(c.getBsrRank())
            .reviewCount(c.getReviewCount())
            .avgRating(c.getAvgRating())
            .grossMargin(c.getGrossMargin())
            .trendScore(c.getTrendScore())
            .seasonality(c.getSeasonality())
            .competitionIntensity(c.getCompetitionIntensity())
            .categoryAvgPrice(c.getCategoryAvgPrice() == null ? null : c.getCategoryAvgPrice().doubleValue())
            .suggestPrice(c.getSuggestPrice() == null ? null : c.getSuggestPrice().doubleValue())
            .costPrice(c.getCostPrice() == null ? null : c.getCostPrice().doubleValue())
            .build();
    }
}