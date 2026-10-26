package com.crossborder.recommend.controller;

import com.crossborder.recommend.dto.RecommendRequest;
import com.crossborder.recommend.dto.RecommendResponse;
import com.crossborder.recommend.entity.RecommendResult;
import com.crossborder.recommend.service.ProductRecommendationService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 选品推荐 REST API
 */
@Slf4j
@RestController
@RequestMapping("/api/v1/recommend")
@RequiredArgsConstructor
@Tag(name = "Product Recommendation", description = "AI 智能选品推荐 API")
public class ProductRecommendationController {

    private final ProductRecommendationService recommendationService;

    @PostMapping("/run")
    @Operation(summary = "执行选品推荐（核心端点）")
    public ResponseEntity<RecommendResponse> recommend(@RequestBody RecommendRequest request) {
        return ResponseEntity.ok(recommendationService.recommend(request));
    }

    @GetMapping("/results")
    @Operation(summary = "查询已保存的推荐结果")
    public ResponseEntity<List<RecommendResult>> savedResults(
        @RequestParam(value = "limit", required = false, defaultValue = "50") Integer limit) {
        return ResponseEntity.ok(recommendationService.findSavedResults(limit));
    }

    @PutMapping("/results/{id}/adoption")
    @Operation(summary = "更新推荐采纳状态 (ACCEPTED/REJECTED/PENDING)")
    public ResponseEntity<RecommendResult> updateAdoption(
        @PathVariable Long id,
        @RequestParam String status) {
        return ResponseEntity.ok(recommendationService.updateAdoptionStatus(id, status));
    }

    @GetMapping("/health")
    @Operation(summary = "服务健康检查")
    public ResponseEntity<Map<String, Object>> health() {
        Map<String, Object> r = new HashMap<>();
        r.put("status", "UP");
        r.put("service", "erp-product-recommendation-service");
        r.put("version", "v1.9.0");
        return ResponseEntity.ok(r);
    }
}