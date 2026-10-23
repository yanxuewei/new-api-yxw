#!/usr/bin/env python3
"""创建 inventory-service 缺失的主类 InventoryServiceApplication.java"""

content = '''package com.crossborder.erp.inventory;

import org.mybatis.spring.annotation.MapperScan;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

@SpringBootApplication
@EnableDiscoveryClient
@MapperScan("com.crossborder.erp.inventory.mapper")
public class InventoryServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(InventoryServiceApplication.class, args);
    }
}
'''

import os
target = "/opt/OmniTradeERP/erp-inventory-service/src/main/java/com/crossborder/erp/inventory/InventoryServiceApplication.java"
os.makedirs(os.path.dirname(target), exist_ok=True)
open(target, 'w').write(content)
print("CREATED", target)

# 同时检查 warehouse-service 主类
wh = "/opt/OmniTradeERP/erp-warehouse-service/src/main/java/com/crossborder/erp/warehouse"
found = False
for root, dirs, files in os.walk(wh):
    for f in files:
        if f.endswith(".java"):
            p = os.path.join(root, f)
            if "@SpringBootApplication" in open(p).read():
                print("WH main class OK:", p)
                found = True
if not found:
    wh_main = wh + "/WarehouseServiceApplication.java"
    wh_content = '''package com.crossborder.erp.warehouse;

import org.mybatis.spring.annotation.MapperScan;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

@SpringBootApplication
@EnableDiscoveryClient
@MapperScan("com.crossborder.erp.warehouse.mapper")
public class WarehouseServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(WarehouseServiceApplication.class, args);
    }
}
'''
    os.makedirs(os.path.dirname(wh_main), exist_ok=True)
    open(wh_main, 'w').write(wh_content)
    print("CREATED", wh_main)

print("ALL DONE")
