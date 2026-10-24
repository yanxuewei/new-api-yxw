package com.crossborder.recommend.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class SwaggerConfig {

    @Bean
    public OpenAPI productRecommendOpenAPI() {
        return new OpenAPI().info(new Info()
            .title("AI 智能选品推荐服务 API")
            .description("为跨境电商卖家提供基于销售数据 + 多因子加权 + LLM 推理的智能选品推荐")
            .version("v1.7.0"));
    }
}