# 数据库初始化指南

## 文件清单

| 文件 | 作用 |
|------|------|
| `init.sql`   | **主脚本**——19 张核心业务表的 DDL |
| `seed-data.sql` | 配套种子数据（与 init.sql 一一对应） |

## 执行顺序

```bash
# 1. 先跑主脚本建库建表
mysql -uroot -p < init.sql

# 2. 再跑种子数据（生产环境不需要）
mysql -uroot -p < seed-data.sql
```

## 数据库清单

| 库名 | 主要表 | 角色 |
|------|--------|------|
| `erp_user`     | user / role / permission / user_role / role_permission | 权限中心 |
| `erp_product`  | product / product_sku / product_category / platform_product_mapping | 商品中心 |
| `erp_order`    | order / order_item | 订单中心 |
| `erp_inventory`| inventory / inventory_log | 库存中心 |
| `erp_warehouse`| warehouse / warehouse_in_out / warehouse_in_out_item | 仓库中心 |
| `erp_finance`  | finance_flow | 财务流水 |
| `erp_platform` | platform_config / sync_log | 平台接入 |

## 种子数据规模

| 表 | 行数 |
|---|------|
| t_user             | 7   |
| t_role             | 5   |
| t_permission       | 31  |
| t_user_role        | 7   |
| t_role_permission  | 67  |
| t_product          | 10  |
| t_product_sku      | 16  |
| t_product_category | 11  |
| t_platform_product_mapping | 10 |
| t_warehouse        | 5   |
| t_warehouse_in_out | 8   |
| t_warehouse_in_out_item | 8 |
| t_inventory        | 19  |
| t_inventory_log    | 8   |
| t_order            | 30  |
| t_order_item       | 31  |
| t_platform_config  | 2   |
| t_sync_log         | 11  |
| t_finance_flow     | 15  |
| **合计**           | **330 行种子数据** |

## 默认账号

```
用户名: admin     密码: admin123   角色: 超级管理员
用户名: ops001    密码: admin123   角色: 运营管理员
用户名: finance001 密码: admin123  角色: 财务
用户名: wh001     密码: admin123   角色: 仓库管理
用户名: cs001     密码: admin123   角色: 客服
```

密码字段已用 BCrypt 加密（占位 hash `$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy`），实际部署请用 erp-user-service 的真实加密逻辑重置。
