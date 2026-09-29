# Day 1 · 任务 4｜马尼拉 RDS PostgreSQL 高可用版 — 执行报告

- 执行时间：2026-09-28 22:12–22:35（GMT+8）
- 依据：`deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` § Day 1 · 任务 4（v2.0 修订版口径）
- 计费口径：**包年包月**（`PayType=Prepaid`）
- 状态：**可买性 + 定价 ✅ 全部通过；实例未创建 —— 卡在账户余额 0.00 USD，已产出可直接支付的未支付订单**

---

## 一、结论（先看这段）

| 项 | 结果 |
|---|---|
| 可用区 | ✅ `ap-southeast-6a` / `ap-southeast-6b` 双区 |
| 包年包月可售规格 | ✅ **73 个**（6a 与 6b 各 73，两区一致） |
| 目标规格 | ✅ `pg.x4.2xlarge.2c` —— 订单原文标注 **「16核 64GB（独享）」** |
| PG 版本 | ✅ 17.0 / 16.0 / 15.0 三版均可售 → 选 **16.0** |
| 存储类型 | ✅ `cloud_essd` / `cloud_essd2` / `cloud_essd3` 各 73；`cloud_ssd`、`local_ssd` **不可售（0）** |
| **下单** | ✅ **成功** —— 订单 `518158947970481`，**未支付**，实付 **10594.13 USD/年**（标价 15134.47，折扣 30%） |
| **账户余额** | ❌ **0.00 USD** → 无法支付，实例未创建（硬阻塞） |
| 交付物 | ✅ 一个可重跑脚本 `deploy/task4_rds_mnl.sh`（7 step，幂等）+ 指南任务 4 已按实测修订 |

> **关键路径**：充值 → 支付订单 `518158947970481` → 实例自动创建（1–10 min）→ 跑 `./deploy/task4_rds_mnl.sh check` 验收。
> **本次未产生任何费用**：下单用 `--AutoPay false`，只出订单不扣费、不建实例（零资金风险，这是本轮验证方式的要点）。

---

## 二、Step 1｜可买性验证（P0）

### 2.1 账号与余额

```
AvailableAmount = 0.00 USD   Cash = 0.00   QuotaLimit = 0.00
```

### 2.2 可用区（注意：`DescribeRegions` 返回全球列表，必须按 RegionId 过滤）

```bash
aliyun rds DescribeRegions | jq -r '.Regions.RDSRegion[]|select(.RegionId=="ap-southeast-6")|[.RegionId,.ZoneId]|@tsv'
# ap-southeast-6  ap-southeast-6a
# ap-southeast-6  ap-southeast-6b
```

### 2.3 配额（指南此处有误，已修订）

| 写法 | 实测结果 |
|---|---|
| `--ProductCode rds --QuotaCategory CommonConfig`（指南原写） | ❌ `--QuotaCategory value "CommonConfig" is not allowed`（合法值仅 `CommonQuota`/`FlowControl`/`WhiteListLabel`） |
| `--ProductCode rds --QuotaCategory CommonQuota`（合法值） | ❌ `PARAMETER.ILLEGALL`（rds 产品不接受该 Category） |
| `--ProductCode rds_pg` / `rds-postgresql` | ❌ 同样 `PARAMETER.ILLEGALL` |

**结论：RDS 无 vCPU 配额闸门**（与 ECS 的 `q_ecs_enterprise_prepay_c` 不同）→ 改用「包年包月可售规格 + 存量实例」双验代替配额复查。

### 2.4 包年包月可售规格（关键：Prepaid 与 Postpaid 可售池不共享）

```bash
aliyun rds DescribeAvailableClasses --RegionId ap-southeast-6 --ZoneId ap-southeast-6a \
  --Engine PostgreSQL --EngineVersion 16.0 --DBInstanceStorageType cloud_essd \
  --InstanceChargeType Prepaid --Category HighAvailability
```

- 6a → **73** 个规格；6b → **73** 个规格
- 存储类型横比（同一查询换 `--DBInstanceStorageType`）：`cloud_essd` 73 · `cloud_essd2` 73 · `cloud_essd3` 73 · `cloud_ssd` **0** · `local_ssd` **0**
- 版本横比：PG 17.0 / 16.0 / 15.0 **各 73**（马尼拉 PG 版本目录完整，不存在"海外滞后只有 14"的问题）
- 目标规格 `pg.x4.2xlarge.2c` 命中；存储范围 **20–64000 GB，步长 5**

> 规格命名澄清（易误判）：`pg.x4.2xlarge.2c` 与 `pg.x4m.2xlarge.2c` 都是 **16C64G**，属不同规格族；国际站订单配置原文对前者的描述是「16核 64GB（独享）」。

---

## 三、Step 2｜定价实测定标（ap-southeast-6）

```bash
# ★ 下单口径（Year/1）；月单价单独取；按量需 --CommodityCode bards
aliyun rds DescribePrice --RegionId ap-southeast-6 --Engine PostgreSQL --EngineVersion 16.0 \
  --DBInstanceClass pg.x4.2xlarge.2c --DBInstanceStorage 100 --DBInstanceStorageType cloud_essd \
  --PayType Prepaid --TimeType Year --UsedTime 1 --OrderType BUY --Quantity 1 --CommodityCode rds
```

| 口径 | 金额（USD） | chargeType | commodityCode |
|---|---|---|---|
| 月单价（`Month`/1） | **1,261.21** / 月 | 1 包年包月 | `rds_intl` |
| 月付 9 个月（月付上限探针） | 11,350.85 | 1 | `rds_intl` |
| **1 年标价（`Year`/1）** | **15,134.47** | 1 | `rds_intl` |
| **1 年实付（订单折扣后）** | **10,594.13** | 1 | `rds_intl` |
| 按量（`Postpaid` + `bards`） | **2.63232** / 小时 ⇒ 月约 1,921.59 | 2 按量 | `bards_intl` |

**折扣**：`DiscountAmount = 4540.34`（≈ 30%）→ 实付 **10,594.13 USD/年**，月均 **882.84**。
**对比按量**：月均 882.84 vs 1921.59 → **包年包月省约 54%**（不是 18%，ECS 那边的 18% 不能类推到 RDS）。
**结论：包年无额外年折扣**（1 年标价 = 月单价 × 12），省钱全部来自"包年包月 vs 按量"本身与活动折扣。

---

## 四、Step 3｜下单确证（零资金风险路径）

采用 `--AutoPay false`：**只生成未支付订单，不扣费、不创建实例**，可完整验证参数合法性、风控与折扣价。

```bash
aliyun rds CreateDBInstance --RegionId ap-southeast-6 \
  --Engine PostgreSQL --EngineVersion 16.0 \
  --DBInstanceClass pg.x4.2xlarge.2c --DBInstanceStorage 100 --DBInstanceStorageType cloud_essd \
  --Category HighAvailability --ZoneId ap-southeast-6a --ZoneIdSlave1 ap-southeast-6b \
  --VPCId vpc-5tst1tgeessxn1azwasg2 --VSwitchId vsw-5tswufq2pi26l4ahoiu84 \
  --DBInstanceNetType Intranet --InstanceNetworkType VPC --ConnectionMode Standard \
  --SecurityIPList "127.0.0.1" \
  --PayType Prepaid --Period Year --UsedTime 1 \
  --AutoPay false --AutoRenew true \
  --DBInstanceDescription newapi-pg-mnl \
  --ResourceGroupId rg-aek4nyivmmsb6iy \
  --ClientToken "task4-probe-year-..."
```

返回：

```json
{"Message":"The order has been placed successfully, but payment has not been made. Please make the payment as soon as possible within the specified time.",
 "RequestId":"01A0E867-D690-377A-A3D7-4C598F71773B",
 "DBInstanceId":"pgm-5ts8mee1iiw13m89","OrderId":"518158947970481"}
```

订单明细（`bssopenapi GetOrderDetail`）：

| 字段 | 值 |
|---|---|
| OrderId | `518158947970481` |
| PaymentStatus | **Unpaid** |
| OrderType / SubscriptionType | New / Subscription |
| PretaxGrossAmount → PretaxAmount | 15134.47 → **10594.13** |
| ExtendInfos.DiscountAmount | **4540.34** |
| UsageStartTime → UsageEndTime | 2026-09-28T14:25:15Z → **2027-09-28T16:00:00Z**（1 年） |
| 配置原文 | `rds_class:[pg.x4.2xlarge.2c]` · `rds_arch:[X86]` · `rds_dbversion:[16.0]` · `rds_nodetype:[HighAvailability]` · `rds_iz:[ap-southeast-6a]` · `rds_storage:[100]` · `rds_storagetype:[cloud_essd]` |

`DescribeDBInstances` 复核：**列表为空** —— 印证「未支付订单不创建实例」。
预分配实例 ID：`pgm-5ts8mee1iiw13m89`（供 `${RDS_MNL_ID}` 预登记，支付后不变的概率高，但**以支付后实测为准**）。

### 风控对照（重要）

| 产品 | 下单/开通是否被风控拦 | 说明 |
|---|---|---|
| ACK 集群 | ⛔ 拦（`RISK.RISK_CONTROL_REJECTION`） | 拦的是"付费服务开通"这一步，文案不提余额 |
| **RDS** | ✅ **未拦** | 同一账号、同样余额 0，RDS 下单畅通 → 风控是按产品/服务开通维度，不是账号级封禁 |

**推论**：任务 4 的解除路径比任务 10 短 —— 不需要先解风控，**充值后直接支付订单即可**。

---

## 五、解除阻塞的操作（充值后一条命令）

```bash
# 1) 支付订单（控制台：费用中心 → 订单管理 → 未支付订单 → 支付）
#    订单 518158947970481，应付 10594.13 USD
# 2) 等待 1–10 分钟后验收
./deploy/task4_rds_mnl.sh check
```

`check` 会完成：属性核对（Category/Zone/SlaveZone/PayType/Storage）→ 打标签 `project=new-api site=ph-mnl env=prod` → 输出 `SHOW max_connections` 待办提醒。

---

## 六、本轮新发现的陷阱（已写入指南任务 4「坑」段）

| # | 陷阱 | 实测表现 | 正确做法 |
|---|---|---|---|
| N1 | **月付周期上限 < 12** | `Period=Month` + `UsedTime=12` → `Order.PeriodInvalid: There is a problem with the period you selected`（文案完全没提"上限"） | 12 个月写 **`Period=Year` + `UsedTime=1`** |
| N2 | **`CommodityCode` 会反转计费口径** | `--CommodityCode bards`（按量码）给 Prepaid 查询 → 三档价全等于按量小时价 2.63232，看着像"包年包月无折扣" | Prepaid 用 `--CommodityCode rds`；Postpaid 用 `bards`；比价前先看 `.chargeType`（1=订阅/2=按量）与 `.commodityCode` |
| N3 | **Postpaid 询价不带 `CommodityCode` 静默返回 null** | `PriceInfo` 全 `null` → jq 出 `n/a`，不报错 | 同上；Postpaid 必带 `--CommodityCode bards` |
| N4 | **`AutoPay=false` 下单成功 ≠ 实例创建** | 返回含 `DBInstanceId`（预分配）但 `DescribeDBInstances` 查不到 | 下单后核 `QueryOrders` 的 `PaymentStatus`；**该特性正好用于零成本试单** |
| N5 | **`ClientToken` 只对同 token 幂等** | 换 token / 换周期重复执行 → 堆出多张未支付订单 | 脚本先查 `QueryOrders --ProductCode rds` 的 Unpaid，命中即拒绝下单 |
| N6 | **`CreateDBInstance` 有 9 个必填参数** | 逐次试才暴露：`DBInstanceNetType` 缺失、`AutoRenewPeriod` 不是合法参数（CLI 本地拒） | 必填清单：`DBInstanceClass` `DBInstanceNetType` `DBInstanceStorage` `DBInstanceStorageType` `Engine` `EngineVersion` `PayType` `RegionId` `SecurityIPList` |
| N7 | **三产品计费参数名各不相同** | ECS `InstanceChargeType` · Tair `ChargeType` · RDS `PayType` | 抄参数名前先 `--help` 核对 |
| N8 | **配额中心不支持 rds** | `CommonConfig` 被拒；`CommonQuota` 报 `PARAMETER.ILLEGALL` | 跳过配额复查，用可售规格 + 存量实例双验 |

---

## 七、旁路发现（非本轮任务，但影响 Day 1 泳道 B）

查订单列表时发现**马尼拉 Tair 实例已存在**（上一轮文档修订后由控制台侧创建）：

| 项 | 值 |
|---|---|
| InstanceId | `r-5tsf1fe16543e274` |
| 名称 | `tair-mnl-newapi` |
| 计费 | **PrePaid**（已包年包月，对应订单 `518158662490481` Convert，64.63 USD，**已支付**） |
| 规格 | `redis.amber.logic.sharding.1g.2db.0rodb.6proxy.multithread` = **Tair 企业版（逻辑多线程）1G / 2DB / 6 Proxy** |
| 状态 / 区 / VPC | Normal · `ap-southeast-6a` · `vpc-5tst1tgeessxn1azwasg2` |
| 资源组 | `rg-aek4nyivmmsb6iy`（rg-ph-mnl） |
| **到期时间** | **2026-10-28**（仅购 **1 个月**）· 到期后 30 天（至 2026-11-27）释放 |

⚠️ **三处与指南口径不一致，需你确认**：
1. **周期**：指南任务 7 写「包年包月 `Period: 12`」，实际只买了 **1 个月**（10-28 到期）。
2. **规格**：指南写「标准版（主从）4GB」，实际是 **企业版 amber 逻辑多线程 1G**（Connections 360000）。
3. **副本/多可用区**：实例仅 `ap-southeast-6a`，未见 6b 备节点信息 —— 与"多可用区 6a 主/6b 备"口径不符。

---

## 八、交付物

| 文件 | 说明 |
|---|---|
| `deploy/task4_rds_mnl.sh` | 7 step：`verify` / `price` / `create`（AutoPay=false 安全试单）/ `create-pay`（真实付款）/ `check` / `tag` / `all`。含 PATH 自愈、双重幂等闸门（实例查重 + 未支付订单闸门）、逐调用落盘日志 `deploy/logs/task4_rds_*.log` |
| `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` | 任务 4 已按实测修订：包年包月命令、9 必填参数、支付与幂等段、`不通过时修复` +4 条、`坑` 段新增坑 5–8；§2.1 付费方式行与任务 52 成本锚点补入 RDS 实付价 |
| 本报告 | — |

**本轮未创建任何计费资源**；产生 1 张未支付订单（`518158947970481`，可支付或取消，均由你决定）。
