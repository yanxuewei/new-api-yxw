package com.crossborder.recommend.engine;

import com.crossborder.recommend.dto.CandidateFeatures;
import com.crossborder.recommend.dto.WeightTuneResult;
import com.crossborder.recommend.entity.RecommendFeedback;
import com.crossborder.recommend.entity.RecommendWeightSnapshot;
import com.crossborder.recommend.repository.RecommendFeedbackRepository;
import com.crossborder.recommend.repository.RecommendWeightSnapshotRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 权重自适应调优器 - v1.9.0 Feedback 闭环核心
 *
 * 原理：基于历史反馈数据，计算每个评分维度（demand/trend/profit/competition/quality）
 *       与"采纳后真实成功（accuracy_score > 0）"的相关性，按相关性调整权重。
 *
 * 算法：
 *   1. 对每个维度的分数（0~1）和 accuracy_score（-1~1）做皮尔逊相关系数近似
 *   2. 相关系数为正的维度 → 权重上调
 *   3. 相关系数为负的维度 → 权重下调
 *   4. 归一化使 5 维权重和 = 1.0
 *   5. 每个权重钳制到 [0.05, 0.50] 防塌缩
 *
 * 触发条件：样本数 >= MIN_SAMPLE_FOR_TUNE (默认 5)
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class WeightTuner {

    /** 调优所需最少样本数 */
    public static final int MIN_SAMPLE_FOR_TUNE = 5;

    /** 权重下限 (防止某维度完全失去影响力) */
    public static final double W_MIN = 0.05;

    /** 权重上限 (防止某维度过度主导) */
    public static final double W_MAX = 0.50;

    /** 学习率 (单次调优的步长上限) */
    public static final double LEARNING_RATE = 0.08;

    private final RecommendFeedbackRepository feedbackRepository;
    private final RecommendWeightSnapshotRepository snapshotRepository;
    private final ScoringEngine scoringEngine;

    /**
     * 计算每个维度对"推荐成功"的相关系数
     *
     * @param feedbacks 历史反馈列表（已包含 accuracy_score）
     * @return key=维度名 (demand/trend/profit/competition/quality), value=相关系数 (-1~1)
     */
    public Map<String, Double> computeDimensionCorrelations(List<RecommendFeedback> feedbacks) {
        Map<String, Double> corr = new HashMap<>();
        if (feedbacks == null || feedbacks.size() < 2) {
            corr.put("demand", 0.0);
            corr.put("trend", 0.0);
            corr.put("profit", 0.0);
            corr.put("competition", 0.0);
            corr.put("quality", 0.0);
            return corr;
        }

        // 重新计算每个反馈对应的 5 维分数
        double[] accuracy = new double[feedbacks.size()];
        double[][] dims = new double[feedbacks.size()][5];

        for (int i = 0; i < feedbacks.size(); i++) {
            RecommendFeedback fb = feedbacks.get(i);
            // 我们没有 candidate 完整数据，从 accuracy_score 推断各维贡献：
            // 这里采用启发式：根据 feedback_type 反推每维度的相对得分
            double[] dimScores = inferDimensionScores(fb);
            dims[i] = dimScores;
            accuracy[i] = fb.getAccuracyScore() == null ? 0.0 : fb.getAccuracyScore();
        }

        String[] names = {"demand", "trend", "profit", "competition", "quality"};
        for (int d = 0; d < 5; d++) {
            corr.put(names[d], pearson(dims, accuracy, d));
        }
        return corr;
    }

    /**
     * 根据反馈反推 5 维分数（启发式）
     *
     * 因为 recommend_feedback 没有冗余存储当时的 5 维分数，
     * 这里使用规则：ADOPTED+高评分 → 各维均匀高分；REJECTED+低评分 → 各维不均（带 noise）
     * 真实生产环境建议在 RecommendResult 上冗余存储 5 维分数。
     */
    double[] inferDimensionScores(RecommendFeedback fb) {
        double base = 0.5;
        String type = fb.getFeedbackType() == null ? "IGNORED" : fb.getFeedbackType();
        Integer rating = fb.getSellerRating();
        double accuracy = fb.getAccuracyScore() == null ? 0.0 : fb.getAccuracyScore();

        // 基础分由 accuracy_score 决定 (0 accuracy → 0.5, +1 → 1.0, -1 → 0.0)
        double center = 0.5 + accuracy * 0.5;

        // 卖家评分影响整体水平
        if (rating != null) {
            center = 0.2 + (rating / 5.0) * 0.8;
        }

        // 每个维度加一点抖动（模拟各候选真实特征差异）
        // hash based on sku 让结果稳定可复现
        long seed = fb.getSku() == null ? 0L : fb.getSku().hashCode();
        java.util.Random rng = new java.util.Random(seed);

        double[] dim = new double[5];
        for (int i = 0; i < 5; i++) {
            // 在中心点附近 ±0.25 抖动
            double jitter = (rng.nextDouble() - 0.5) * 0.5;
            dim[i] = clamp01(center + jitter);
        }

        // ADOPTED 但低 accuracy → 至少有一维是低的（错配维度）
        if ("ADOPTED".equals(type) && accuracy < 0) {
            dim[rng.nextInt(5)] = Math.min(dim[rng.nextInt(5)], 0.2);
        }
        // REJECTED 高 accuracy → 至少有一维是高的（漏判）
        if ("REJECTED".equals(type) && accuracy > 0.3) {
            dim[rng.nextInt(5)] = Math.max(dim[rng.nextInt(5)], 0.8);
        }

        return dim;
    }

    /**
     * 计算单维分数序列与 accuracy 序列的皮尔逊相关系数
     */
    double pearson(double[][] dims, double[] y, int dimIndex) {
        int n = y.length;
        if (n < 2) return 0.0;

        double sumX = 0, sumY = 0;
        for (int i = 0; i < n; i++) {
            sumX += dims[i][dimIndex];
            sumY += y[i];
        }
        double meanX = sumX / n;
        double meanY = sumY / n;

        double cov = 0, varX = 0, varY = 0;
        for (int i = 0; i < n; i++) {
            double dx = dims[i][dimIndex] - meanX;
            double dy = y[i] - meanY;
            cov += dx * dy;
            varX += dx * dx;
            varY += dy * dy;
        }
        if (varX < 1e-9 || varY < 1e-9) return 0.0;
        double r = cov / Math.sqrt(varX * varY);
        return clamp(r, -1.0, 1.0);
    }

    /**
     * 执行权重调优
     *
     * @return 调优结果 (含 before/after 权重)
     */
    public WeightTuneResult tune() {
        double[] before = currentWeights();
        List<RecommendFeedback> all = feedbackRepository.selectList(null);

        WeightTuneResult.ScoringWeights beforeDto = toDto(before);

        if (all == null || all.size() < MIN_SAMPLE_FOR_TUNE) {
            log.info("样本不足 {} < {}，跳过权重调优", all == null ? 0 : all.size(), MIN_SAMPLE_FOR_TUNE);
            return WeightTuneResult.builder()
                .tuned(false)
                .reason("INSUFFICIENT_SAMPLES")
                .sampleCount(all == null ? 0 : all.size())
                .beforeWeights(beforeDto)
                .afterWeights(beforeDto)
                .tunedAt(LocalDateTime.now())
                .build();
        }

        Map<String, Double> corr = computeDimensionCorrelations(all);
        double[] after = applyAdjustment(before, corr);

        // 计算统计信息
        double avgAccuracy = all.stream()
            .mapToDouble(f -> f.getAccuracyScore() == null ? 0.0 : f.getAccuracyScore())
            .average().orElse(0.0);
        double adoptRate = all.stream()
            .filter(f -> "ADOPTED".equals(f.getFeedbackType()))
            .count() / (double) all.size();

        // 持久化快照
        persistSnapshot(after, all.size(), avgAccuracy, adoptRate);

        // 同步给 ScoringEngine 让后续推荐立即生效
        scoringEngine.setActiveWeights(after);

        log.info("权重调优完成: {} 样本, avgAccuracy={}, adoptRate={}, 维度相关性={}",
            all.size(), String.format("%.3f", avgAccuracy), String.format("%.3f", adoptRate), corr);

        return WeightTuneResult.builder()
            .tuned(true)
            .reason("AUTO_TUNE")
            .sampleCount(all.size())
            .beforeWeights(beforeDto)
            .afterWeights(toDto(after))
            .tunedAt(LocalDateTime.now())
            .build();
    }

    /**
     * 根据相关性调整权重
     *
     * 规则：
     *   r > 0 → 权重 += LEARNING_RATE * r
     *   r < 0 → 权重 -= LEARNING_RATE * |r|
     *   然后归一化到 [0.05, 0.50] 且总和 = 1.0
     */
    double[] applyAdjustment(double[] current, Map<String, Double> corr) {
        double[] next = new double[5];
        next[0] = current[0] + LEARNING_RATE * corr.get("demand");
        next[1] = current[1] + LEARNING_RATE * corr.get("trend");
        next[2] = current[2] + LEARNING_RATE * corr.get("profit");
        next[3] = current[3] + LEARNING_RATE * corr.get("competition");
        next[4] = current[4] + LEARNING_RATE * corr.get("quality");

        // 钳制
        for (int i = 0; i < 5; i++) {
            next[i] = clamp(next[i], W_MIN, W_MAX);
        }

        // 归一化到总和 = 1.0
        double sum = next[0] + next[1] + next[2] + next[3] + next[4];
        if (sum <= 0) return current; // 安全保护

        for (int i = 0; i < 5; i++) {
            next[i] = next[i] / sum;
            // 归一化后再钳制一次 (防止浮点溢出)
            next[i] = clamp(next[i], W_MIN, W_MAX);
        }
        return next;
    }

    /**
     * 公开的权重读取方法（无副作用）
     */
    public WeightTuneResult.ScoringWeights peekCurrentWeights() {
        return toDto(currentWeights());
    }

    /**
     * 计算 accuracy_score (用于 FeedbackService 持久化时)
     *
     * 规则：
     *   ADOPTED + 高实际利润 → 高分 (>= 0.6)
     *   ADOPTED + 低实际利润 → 中性偏低 (0.0~0.4)
     *   REJECTED + 有真实 outcome → 负分 (< 0)
     *   IGNORED → 0 (中性)
     */
    public double computeAccuracyScore(String feedbackType, Integer sellerRating,
                                        Integer actual30dSales, java.math.BigDecimal actual30dProfit) {
        if (feedbackType == null) return 0.0;

        switch (feedbackType) {
            case "ADOPTED":
                double base = 0.3; // 采纳本身就 +0.3
                if (sellerRating != null) {
                    base += (sellerRating / 5.0) * 0.4; // 评分贡献 ±0.4
                }
                if (actual30dProfit != null) {
                    double profit = actual30dProfit.doubleValue();
                    if (profit > 5000) base += 0.3;
                    else if (profit > 1000) base += 0.15;
                    else if (profit < 0) base -= 0.2;
                }
                if (actual30dSales != null && actual30dSales > 1000) {
                    base += 0.1;
                }
                return clamp(base, -1.0, 1.0);

            case "REJECTED":
                double neg = -0.2;
                if (sellerRating != null && sellerRating <= 2) {
                    neg -= 0.3;
                }
                // 如果拒绝但实际数据很好 → 负分（漏判）
                if (actual30dProfit != null && actual30dProfit.doubleValue() > 3000) {
                    neg = -0.5;
                }
                return clamp(neg, -1.0, 1.0);

            case "IGNORED":
            default:
                return 0.0;
        }
    }

    /**
     * 获取当前权重（从最近一份快照读，没有就用 ScoringEngine 默认值）
     */
    double[] currentWeights() {
        com.baomidou.mybatisplus.core.conditions.query.QueryWrapper<RecommendWeightSnapshot> q =
            new com.baomidou.mybatisplus.core.conditions.query.QueryWrapper<>();
        q.orderByDesc("created_at").last("LIMIT 1");
        List<RecommendWeightSnapshot> latest = snapshotRepository.selectList(q);
        if (latest != null && !latest.isEmpty()) {
            RecommendWeightSnapshot s = latest.get(0);
            return new double[]{
                s.getWDemand() == null ? ScoringEngine.W_DEMAND : s.getWDemand(),
                s.getWTrend() == null ? ScoringEngine.W_TREND : s.getWTrend(),
                s.getWProfit() == null ? ScoringEngine.W_PROFIT : s.getWProfit(),
                s.getWCompetition() == null ? ScoringEngine.W_COMPETITION : s.getWCompetition(),
                s.getWQuality() == null ? ScoringEngine.W_QUALITY : s.getWQuality(),
            };
        }
        return new double[]{
            ScoringEngine.W_DEMAND,
            ScoringEngine.W_TREND,
            ScoringEngine.W_PROFIT,
            ScoringEngine.W_COMPETITION,
            ScoringEngine.W_QUALITY
        };
    }

    void persistSnapshot(double[] weights, int sampleCount, double avgAccuracy, double adoptRate) {
        RecommendWeightSnapshot snap = RecommendWeightSnapshot.builder()
            .wDemand(round4(weights[0]))
            .wTrend(round4(weights[1]))
            .wProfit(round4(weights[2]))
            .wCompetition(round4(weights[3]))
            .wQuality(round4(weights[4]))
            .sampleCount(sampleCount)
            .avgAccuracy(round4(avgAccuracy))
            .adoptRate(round4(adoptRate))
            .triggerReason("AUTO_TUNE")
            .createdAt(LocalDateTime.now())
            .build();
        snapshotRepository.insert(snap);
    }

    WeightTuneResult.ScoringWeights toDto(double[] w) {
        return WeightTuneResult.ScoringWeights.builder()
            .wDemand(round4(w[0]))
            .wTrend(round4(w[1]))
            .wProfit(round4(w[2]))
            .wCompetition(round4(w[3]))
            .wQuality(round4(w[4]))
            .build();
    }

    static double clamp(double v, double min, double max) {
        if (Double.isNaN(v)) return min;
        return Math.max(min, Math.min(max, v));
    }

    static double clamp01(double v) {
        return clamp(v, 0.0, 1.0);
    }

    static double round4(double v) {
        return Math.round(v * 10000.0) / 10000.0;
    }
}