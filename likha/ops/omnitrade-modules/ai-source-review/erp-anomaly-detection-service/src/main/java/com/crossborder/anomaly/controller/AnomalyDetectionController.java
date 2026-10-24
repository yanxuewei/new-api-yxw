package com.crossborder.anomaly.controller;

import com.crossborder.anomaly.dto.AnomalyDetectionResult;
import com.crossborder.anomaly.dto.OrderFeatures;
import com.crossborder.anomaly.service.AnomalyDetectionService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * 异常检测控制器
 */
@Slf4j
@RestController
@RequestMapping("/api/v1/anomaly")
@RequiredArgsConstructor
@Tag(name = "AI 订单异常检测", description = "基于规则引擎 + AI 评分的订单风险检测")
public class AnomalyDetectionController {

    private final AnomalyDetectionService detectionService;

    @PostMapping("/detect")
    @Operation(summary = "单订单异常检测")
    public AnomalyDetectionResult detect(@RequestBody OrderFeatures features) {
        return detectionService.detect(features);
    }

    @PostMapping("/detect-batch")
    @Operation(summary = "批量异常检测")
    public List<AnomalyDetectionResult> detectBatch(@RequestBody List<OrderFeatures> featuresList) {
        return detectionService.detectBatch(featuresList);
    }

    @GetMapping("/health")
    @Operation(summary = "健康检查")
    public String health() {
        return "AI 异常检测服务运行正常";
    }
}
