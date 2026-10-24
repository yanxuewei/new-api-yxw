package com.crossborder.anomaly;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.scheduling.annotation.EnableAsync;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * AI 订单异常检测服务启动类
 *
 * 服务职责：
 *  - 实时分析跨境订单，识别异常模式（欺诈、退款、延迟、地址异常、价格异常等）
 *  - 基于规则引擎 + AI 评分的双层检测
 *  - 自动生成风险评估报告和处置建议
 *  - 与下游订单服务、风控服务联动
 */
@SpringBootApplication
@EnableDiscoveryClient
@EnableScheduling
@EnableAsync
public class AnomalyDetectionApplication {

    public static void main(String[] args) {
        SpringApplication.run(AnomalyDetectionApplication.class, args);
        System.out.println("""
            
            ╔════════════════════════════════════════════════════════════╗
            ║   🤖 AI 订单异常检测服务启动成功                            ║
            ║   Anomaly Detection Service v1.0.0                         ║
            ║   📊 规则引擎 + AI 评分 双层检测                            ║
            ╚════════════════════════════════════════════════════════════╝
            """);
    }
}
