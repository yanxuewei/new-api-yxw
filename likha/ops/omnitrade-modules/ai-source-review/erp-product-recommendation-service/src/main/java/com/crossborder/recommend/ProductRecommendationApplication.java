package com.crossborder.recommend;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * AI 智能选品推荐服务启动类
 *
 * 服务职责：
 *  - 基于历史销售数据 + 多因子加权评分，为卖家推荐下一个周期值得选品的商品
 *  - 提供趋势识别、竞品分析、利润预估、风险提示
 *  - 与下游 product / order / inventory 服务联动
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableScheduling
@EnableAsync
public class ProductRecommendationApplication {

    public static void main(String[] args) {
        SpringApplication.run(ProductRecommendationApplication.class, args);
        System.out.println("""

            ╔════════════════════════════════════════════════════════════╗
            ║   🎯 AI 智能选品推荐服务启动成功                            ║
            ║   Product Recommendation Service v1.7.0                   ║
            ║   📈 多因子加权评分 + 趋势预测 + 风险评估                  ║
            ╚════════════════════════════════════════════════════════════╝
            """);
    }
}