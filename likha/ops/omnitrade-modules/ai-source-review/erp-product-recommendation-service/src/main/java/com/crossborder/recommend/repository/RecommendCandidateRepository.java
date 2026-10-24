package com.crossborder.recommend.repository;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.recommend.entity.RecommendCandidate;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface RecommendCandidateRepository extends BaseMapper<RecommendCandidate> {
}