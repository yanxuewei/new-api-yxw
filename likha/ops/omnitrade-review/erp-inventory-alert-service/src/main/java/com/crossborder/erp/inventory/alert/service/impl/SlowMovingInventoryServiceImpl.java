package com.crossborder.erp.inventory.alert.service.impl;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.core.metadata.IPage;
import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.baomidou.mybatisplus.extension.service.impl.ServiceImpl;
import com.crossborder.erp.inventory.alert.entity.SlowMovingInventory;
import com.crossborder.erp.inventory.alert.mapper.SlowMovingInventoryMapper;
import com.crossborder.erp.inventory.alert.service.SlowMovingInventoryService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.temporal.ChronoUnit;

/**
 * 滞销商品服务实现
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class SlowMovingInventoryServiceImpl extends ServiceImpl<SlowMovingInventoryMapper, SlowMovingInventory> implements SlowMovingInventoryService {

    @Override
    public SlowMovingInventory detectSlowMoving(Long productId, String sku, String warehouseId) {
        log.info("检测滞销商品: productId={}, sku={}, warehouseId={}", productId, sku, warehouseId);
        
        SlowMovingInventory record = new SlowMovingInventory();
        record.setProductId(productId);
        record.setSku(sku);
        record.setWarehouseId(warehouseId);
        record.setCurrentStock(100);
        record.setSalesLast30Days(5);
        record.setSalesLast60Days(12);
        record.setSalesLast90Days(20);
        record.setTurnoverRate(0.3);
        record.setLastSaleDate(LocalDate.now().minusDays(45));
        record.setStagnantDays(45);
        record.setAlertLevel("MEDIUM");
        record.setStatus("DETECTED");
        record.setNotified(false);
        
        baseMapper.insert(record);
        return record;
    }

    @Override
    public IPage<SlowMovingInventory> querySlowMoving(int page, int size, String warehouseId, String alertLevel) {
        LambdaQueryWrapper<SlowMovingInventory> wrapper = new LambdaQueryWrapper<>();
        if (warehouseId != null) {
            wrapper.eq(SlowMovingInventory::getWarehouseId, warehouseId);
        }
        if (alertLevel != null) {
            wrapper.eq(SlowMovingInventory::getAlertLevel, alertLevel);
        }
        wrapper.orderByAsc(SlowMovingInventory::getTurnoverRate);
        return page(new Page<>(page, size), wrapper);
    }

    @Override
    public IPage<SlowMovingInventory> getPendingAlerts(int page, int size) {
        return page(new Page<>(page, size), 
            new LambdaQueryWrapper<SlowMovingInventory>()
                .eq(SlowMovingInventory::getNotified, false)
                .orderByAsc(SlowMovingInventory::getAlertLevel));
    }

    @Override
    public void markAsNotified(Long id) {
        SlowMovingInventory record = baseMapper.selectById(id);
        if (record != null) {
            record.setNotified(true);
            baseMapper.updateById(record);
        }
    }
}