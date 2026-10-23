package com.crossborder.erp.inventory.alert.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.crossborder.erp.inventory.alert.entity.SlowMovingInventory;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface SlowMovingInventoryMapper extends BaseMapper<SlowMovingInventory> {
}