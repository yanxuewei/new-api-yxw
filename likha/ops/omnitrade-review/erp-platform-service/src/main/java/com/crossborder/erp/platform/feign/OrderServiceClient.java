package com.crossborder.erp.platform.feign;

import com.crossborder.erp.order.entity.Order;
import com.crossborder.erp.order.entity.OrderItem;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@FeignClient(name = "erp-order-service", path = "/internal/orders")
public interface OrderServiceClient {

    @PostMapping("/create")
    Long createOrder(@RequestBody OrderCreateRequest request);

    @GetMapping("/platform/{platform}/{platformOrderNo}")
    Order getOrderByPlatformOrderNo(@PathVariable("platform") String platform, @PathVariable("platformOrderNo") String platformOrderNo);

    /**
     * 创建订单请求
     */
    record OrderCreateRequest(Order order, List<OrderItem> items) {}
}