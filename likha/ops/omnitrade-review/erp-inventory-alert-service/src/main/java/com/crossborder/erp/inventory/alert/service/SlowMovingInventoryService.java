package com.crossborder.erp.inventory.alert.service;

import com.baomidou.mybatisplus.core.metadata.IPage;
import com.crossborder.erp.inventory.alert.entity.SlowMovingInventory;
import com.baomidou.mybatisplus.extension.service.IService;

/**
 * 滞销商品服务
 */
public interface SlowMovingInventoryService extends IService<SlowMovingInventory> {
    
    /**
     * 检测滞销商品
     */
    SlowMovingInventory detectSlowMoving(Long productId, String sku, String warehouseId);
    
    /**
     * 分页查询滞销商品
     */
    IPage<SlowMovingInventory> querySlowMoving(int page, int size, String warehouseId, String alertLevel);
    
    /**
     * 获取待推送的滞销预警
     */
    IPage<SlowMovingInventory> getPendingAlerts(int page, int size);
    
    /**
     * 标记已通知
     */
    void markAsNotified(Long id);
}