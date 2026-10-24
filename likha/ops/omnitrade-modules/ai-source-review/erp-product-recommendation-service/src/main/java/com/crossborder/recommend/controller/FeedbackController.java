package com.crossborder.recommend.controller;

import com.crossborder.recommend.dto.FeedbackRequest;
import com.crossborder.recommend.dto.FeedbackStats;
import com.crossborder.recommend.dto.WeightTuneResult;
import com.crossborder.recommend.engine.WeightTuner;
import com.crossborder.recommend.entity.RecommendFeedback;
import com.crossborder.recommend.service.FeedbackService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/**
 * 反馈闭环 REST API - v1.9.0
 *
 *   POST /api/v1/feedback           提交反馈
 *   GET  /api/v1/feedback           查询反馈列表
 *   GET  /api/v1/feedback/stats     反馈统计
 *   POST /api/v1/feedback/tune      触发权重调优
 *   GET  /api/v1/feedback/weights   查询当前权重
 */
@Slf4j
@RestController
@RequestMapping("/api/v1/feedback")
@RequiredArgsConstructor
@Tag(name = "Recommendation Feedback", description = "AI 选品推荐反馈闭环 API")
public class FeedbackController {

    private final FeedbackService feedbackService;
    private final WeightTuner weightTuner;

    @PostMapping
    @Operation(summary = "提交反馈 (ADOPTED/REJECTED/IGNORED)")
    public ResponseEntity<RecommendFeedback> submitFeedback(@Valid @RequestBody FeedbackRequest request) {
        return ResponseEntity.ok(feedbackService.submitFeedback(request));
    }

    @GetMapping
    @Operation(summary = "查询反馈列表")
    public ResponseEntity<List<RecommendFeedback>> listFeedback(
        @RequestParam(required = false) String type,
        @RequestParam(required = false) String category,
        @RequestParam(required = false) String platform,
        @RequestParam(required = false, defaultValue = "50") Integer limit) {
        return ResponseEntity.ok(feedbackService.findFeedbacks(type, category, platform, limit));
    }

    @GetMapping("/stats")
    @Operation(summary = "反馈统计 (采纳率/平均准确度/平均利润)")
    public ResponseEntity<FeedbackStats> stats(
        @RequestParam(required = false) String category,
        @RequestParam(required = false) String platform) {
        return ResponseEntity.ok(feedbackService.computeStats(category, platform));
    }

    @PostMapping("/tune")
    @Operation(summary = "触发权重自适应调优 (样本 >= 5)")
    public ResponseEntity<WeightTuneResult> tuneWeights() {
        return ResponseEntity.ok(weightTuner.tune());
    }

    @GetMapping("/weights")
    @Operation(summary = "查询当前评分权重 (无副作用)")
    public ResponseEntity<WeightTuneResult.ScoringWeights> currentWeights() {
        return ResponseEntity.ok(weightTuner.peekCurrentWeights());
    }
}