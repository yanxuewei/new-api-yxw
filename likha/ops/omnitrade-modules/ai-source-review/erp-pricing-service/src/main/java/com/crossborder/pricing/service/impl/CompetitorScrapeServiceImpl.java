package com.crossborder.pricing.service.impl;

import com.crossborder.pricing.entity.CompetitorProduct;
import com.crossborder.pricing.service.CompetitorScrapeService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * 竞品数据抓取服务实现 (v2.0.0)
 *
 * v2.0.0 改进：
 * 1. 抽取 PriceRandomizer 接口，Random 默认实现 + 测试可注入 SeededRandomizer
 * 2. generateMockCompetitor 改为可重写 protected 方法，便于子类定制
 * 3. batchScrape 增加部分失败容错（单个产品失败不中断批次）
 * 4. 模拟数据生成逻辑提到独立方法，便于直接单元测试
 *
 * 模拟从Amazon、eBay、Shopee等平台抓取竞品数据。
 * 实际生产环境需要配置平台API或使用爬虫。
 */
@Slf4j
@Service
public class CompetitorScrapeServiceImpl implements CompetitorScrapeService {

    /** 模拟数据价格区间下限（含） */
    static final int PRICE_MIN = 120;
    /** 模拟数据价格区间上限（不含） */
    static final int PRICE_MAX_EXCLUSIVE = 180;
    /** 模拟评分下限（含） = 3.5 */
    static final int RATING_MIN_TENTH = 35;
    /** 模拟评分上限（不含） = 5.0 */
    static final int RATING_MAX_EXCLUSIVE_TENTH = 50;
    /** 评论数下限 */
    static final long REVIEW_MIN = 100L;
    /** 评论数上限（不含） */
    static final int REVIEW_MAX_EXCLUSIVE = 1100;
    /** 销量下限 */
    static final long SALES_MIN = 50L;
    /** 销量上限（不含） */
    static final int SALES_MAX_EXCLUSIVE = 550;

    private final PriceRandomizer randomizer;

    public CompetitorScrapeServiceImpl() {
        this(new DefaultPriceRandomizer());
    }

    /**
     * 构造器注入（v2.0.0 新增） - 允许测试注入确定性随机源
     */
    public CompetitorScrapeServiceImpl(PriceRandomizer randomizer) {
        this.randomizer = randomizer;
    }

    @Override
    public void scrapeCompetitorProducts(Long productId) {
        log.info("开始抓取产品 {} 的竞品数据...", productId);

        // 模拟抓取多个平台的数据
        scrapeFromPlatform("Amazon", "https://amazon.com/product/" + productId);
        scrapeFromPlatform("eBay", "https://ebay.com/itm/" + productId);
        scrapeFromPlatform("Shopee", "https://shopee.com/product/" + productId);
        scrapeFromPlatform("Lazada", "https://lazada.com/products/" + productId);

        log.info("竞品数据抓取完成 - 产品ID: {}", productId);
    }

    @Override
    public void scrapeFromPlatform(String platform, String productUrl) {
        log.info("从 {} 抓取竞品数据: {}", platform, productUrl);

        try {
            // 实际环境：使用Jsoup解析HTML或调用平台API
            // 这里使用模拟数据
            CompetitorProduct competitor = generateMockCompetitor(platform, productUrl);

            // TODO: 保存到数据库
            log.debug("竞品数据: {}", competitor);

        } catch (Exception e) {
            log.error("抓取失败 - 平台: {}, URL: {}", platform, productUrl, e);
        }
    }

    @Override
    public void batchScrape(List<Long> productIds) {
        log.info("批量抓取竞品数据 - 产品数量: {}", productIds.size());

        for (Long productId : productIds) {
            try {
                scrapeCompetitorProducts(productId);
                // 避免请求过快 - 实际生产环境应使用 RateLimiter
                Thread.sleep(50);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log.error("批量抓取被中断", e);
                return;
            } catch (Exception e) {
                // v2.0.0: 单个产品失败不影响整个批次
                log.error("产品 {} 抓取失败，继续下一个", productId, e);
            }
        }

        log.info("批量抓取完成");
    }

    @Override
    public List<CompetitorProduct> getCompetitorProducts(Long productId) {
        log.info("获取产品的竞品数据 - 产品ID: {}", productId);

        if (productId == null) {
            return List.of();
        }

        // 模拟：从数据库查询
        List<CompetitorProduct> competitors = new ArrayList<>();
        competitors.add(generateMockCompetitor("Amazon", "https://amazon.com/dp/" + productId));
        competitors.add(generateMockCompetitor("eBay", "https://ebay.com/itm/" + productId));
        competitors.add(generateMockCompetitor("Shopee", "https://shopee.com/product/" + productId));

        return competitors;
    }

    @Override
    public CompetitorPriceStats getCompetitorPriceStats(Long productId) {
        log.info("获取竞品价格统计 - 产品ID: {}", productId);

        List<CompetitorProduct> competitors = getCompetitorProducts(productId);

        if (competitors.isEmpty()) {
            log.warn("没有找到竞品数据 - 产品ID: {}", productId);
            return null;
        }

        // 计算统计数据
        BigDecimal sum = BigDecimal.ZERO;
        BigDecimal min = null;
        BigDecimal max = null;

        for (CompetitorProduct competitor : competitors) {
            BigDecimal price = competitor.getCurrentPrice();
            if (price == null) {
                continue;
            }
            sum = sum.add(price);

            if (min == null || price.compareTo(min) < 0) {
                min = price;
            }

            if (max == null || price.compareTo(max) > 0) {
                max = price;
            }
        }

        if (min == null || max == null) {
            log.warn("没有有效的竞品价格 - 产品ID: {}", productId);
            return null;
        }

        BigDecimal avg = sum.divide(new BigDecimal(competitors.size()), 2, RoundingMode.HALF_UP);

        CompetitorPriceStats stats = new CompetitorPriceStats();
        stats.setProductId(productId);
        stats.setAvgPrice(avg);
        stats.setMinPrice(min);
        stats.setMaxPrice(max);
        stats.setCompetitorCount((long) competitors.size());

        log.info("竞品价格统计 - 平均: {}, 最低: {}, 最高: {}, 数量: {}", avg, min, max, competitors.size());
        return stats;
    }

    @Override
    public void addCompetitor(Long productId, CompetitorProduct competitor) {
        log.info("手动添加竞品 - 产品ID: {}, 竞品: {}", productId, competitor.getCompetitorName());

        competitor.setCreateTime(LocalDateTime.now());
        competitor.setUpdateTime(LocalDateTime.now());

        // TODO: 保存到数据库

        log.info("竞品添加成功");
    }

    // ========== 内部辅助方法（v2.0.0 改造为 protected 以便子类定制） ==========

    /**
     * 生成模拟竞品数据 - protected 便于子类或测试覆盖
     */
    protected CompetitorProduct generateMockCompetitor(String platform, String productUrl) {
        CompetitorProduct competitor = new CompetitorProduct();

        // 模拟价格 [PRICE_MIN, PRICE_MAX_EXCLUSIVE)
        BigDecimal price = new BigDecimal(PRICE_MIN + randomizer.nextIntInRange(PRICE_MAX_EXCLUSIVE - PRICE_MIN))
                .setScale(2, RoundingMode.HALF_UP);

        // 模拟评分 [RATING_MIN_TENTH, RATING_MAX_EXCLUSIVE_TENTH) / 10
        BigDecimal rating = new BigDecimal(RATING_MIN_TENTH + randomizer.nextIntInRange(RATING_MAX_EXCLUSIVE_TENTH - RATING_MIN_TENTH))
                .divide(new BigDecimal("10"), 1, RoundingMode.HALF_UP);

        // 模拟评论数 [REVIEW_MIN, REVIEW_MAX_EXCLUSIVE)
        Long reviewCount = REVIEW_MIN + randomizer.nextIntInRange(REVIEW_MAX_EXCLUSIVE - (int) REVIEW_MIN);

        // 模拟销量 [SALES_MIN, SALES_MAX_EXCLUSIVE)
        Long salesVolume = SALES_MIN + randomizer.nextIntInRange(SALES_MAX_EXCLUSIVE - (int) SALES_MIN);

        competitor.setCompetitorName(platform + " 竞品 " + randomizer.nextIntInRange(1000));
        competitor.setCurrentPrice(price);
        competitor.setProductUrl(productUrl);
        competitor.setPlatform(platform);
        competitor.setRating(rating);
        competitor.setReviewCount(reviewCount);
        competitor.setSalesVolume(salesVolume);
        competitor.setScrapeTime(LocalDateTime.now());
        competitor.setCreateTime(LocalDateTime.now());
        competitor.setUpdateTime(LocalDateTime.now());

        return competitor;
    }

    // ========== 随机源抽象（v2.0.0 新增） ==========

    /**
     * 随机源抽象 - 默认实现使用 {@link Random}，测试可注入确定性实现
     */
    public interface PriceRandomizer {
        /**
         * 返回 [0, bound) 范围内的整数
         */
        int nextIntInRange(int bound);
    }

    /**
     * 默认随机源 - 基于 {@link Random}
     */
    public static class DefaultPriceRandomizer implements PriceRandomizer {
        private final Random random = new Random();

        @Override
        public int nextIntInRange(int bound) {
            return random.nextInt(bound);
        }
    }

    /**
     * 固定 seed 随机源 - 用于单元测试产生确定性数据
     */
    public static class SeededRandomizer implements PriceRandomizer {
        private final Random random;

        public SeededRandomizer(long seed) {
            this.random = new Random(seed);
        }

        @Override
        public int nextIntInRange(int bound) {
            return random.nextInt(bound);
        }
    }
}