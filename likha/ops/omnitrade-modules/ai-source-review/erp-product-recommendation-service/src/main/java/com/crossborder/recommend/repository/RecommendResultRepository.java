package com.crossborder.recommend.repository;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.recommend.entity.RecommendResult;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface RecommendResultRepository extends BaseMapper<RecommendResult> {
}