package com.crossborder.anomaly.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Swagger / OpenAPI 配置
 */
@Configuration
public class SwaggerConfig {

    @Bean
    public OpenAPI anomalyOpenAPI() {
        return new OpenAPI().info(new Info()
            .title("AI 订单异常检测服务 API")
            .description("基于规则引擎 + AI 评分的跨境电商订单风险检测")
            .version("1.0.0"));
    }
}
