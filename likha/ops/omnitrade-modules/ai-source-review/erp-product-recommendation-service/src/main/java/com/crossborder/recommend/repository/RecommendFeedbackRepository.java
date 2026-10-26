package com.crossborder.recommend.repository;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.recommend.entity.RecommendFeedback;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface RecommendFeedbackRepository extends BaseMapper<RecommendFeedback> {
}