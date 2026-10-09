# Day 1 · 任务 9｜日志库 ClickHouse 决策（马尼拉企业版单 AZ）— 执行报告

- 日期：2026-09-29 21:35–21:50（GMT+8）
- 依据：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` 任务 9（F9）
- 状态：**决策复核完成 ✅ · 云资源零创建**
- 脚本：`deploy/task9/ck_decision.sh`（`verify|probe|cost|create|check|all`）

---

## 一、结论（先看这段）

F9 决策「日志库收口马尼拉 CK 企业版单 AZ」**立论成立**，但本轮用 API 硬证据把三处口径**收紧了**——原表述把这三点写成了"可选项/待定项"，实测后应写成"事实"：

| # | 项 | 原表述 | 实测/权威结论 | 影响 |
|---|---|---|---|---|
| 1 | 可用区 | "6a/6b 择一，尽量与 RDS 主节点错开 AZ" | **只有 `ap-southeast-6a` 一个** | 单 AZ 是产品事实，不是取舍；"错开"是巧合结果 |
| 2 | 存储 | 未写明（默认 ESSD 惯性） | **只有 OSS**（ESSD_L0–L3/SSD 在马尼拉不可售） | 性能预期与成本口径都要改 |
| 3 | 计费 | 未写明 | **只有按量付费**（无 `PayType` 参数） | 不适用"包年包月修订"；降本改走**计算资源包** |

另外否定一条硬错误：「马尼拉 CK 企业版**仅购买页可完成**」——`clickhouse CreateDBInstance`（API 2023-05-22）**可直接创建**。

---

## 二、复核证据（9 条，全部可重跑）

| # | 复核项 | 证据 | 判定 |
|---|---|---|---|
| E1 | 马尼拉是否在 CK 支持地域内 | `clickhouse DescribeRegions` 返回 16 地域，**含 `ap-southeast-6`**；对照 `ap-southeast-9` 调 `CreateDBInstance` 报 `InvalidRegion.NotFound`，说明该列表有判别力 | ✅ 成立 |
| E2 | 马尼拉有几个 AZ | `ap-southeast-6` 的 `Zones` **只有 `ap-southeast-6a`**；对照新加坡 3 个（1a/1b/1c）、东京 2 个、吉隆坡 3 个 | ✅ 单 AZ 是硬事实 |
| E3 | 是否支持多可用区 | 官方地域表 `Philippines (Manila)` → **Multi-AZ = No**；实测传 `DeploySchema=multi_az` 报 `relevantInspectionException: The number of zones is not multi.` | ✅ 不可用 |
| E4 | 存储类型 | 官方地域表 → 马尼拉 **OSS = Yes · ESSD_L1 = No · ESSD_L2 = No**；`StorageType` 枚举实测 `ESSD_L0/L1/L2/L3/SSD/oss` | ✅ 只能 OSS |
| E5 | 计费方式 | 商品类型名即「企业版 Serverless & 社区兼容版**按量付费**」；官方计费项文档：**企业版的计算/存储/备份全为按量付费**（仅社区兼容版有包年包月）；`CreateDBInstance` 参数表**不存在 `PayType`/`ChargeType`/`Period`** | ✅ 只能按量 |
| E6 | 降本手段与单价 | 计算 **0.185350 USD/CCU·h**、存储 OSS **0.000044 USD/GB·h**；**计算资源包 0.03611 USD/CCU·H**，最小包 3000 CCU·H、**预付 3 年、不可退订、可叠加**；**马尼拉抵扣因子 1.45** | ✅ 新增成本杠杆 |
| E7 | 创建通道 | `clickhouse CreateDBInstance` 官方描述即 "To create a ClickHouse Enterprise Edition cluster" | ❌ 原"仅购买页"作废 |
| E8 | `DeploySchema` 合法值 | `single_az` ✅（走到商品校验层）· `multi_az` ✅（走到多 AZ 数量层）· `bogus_value` ❌ 报 `InvalidDeploySchema.Malformed` | 新增 |
| E9 | 内核版本 | 官方原文：企业版**默认最新内核、不允许手动选择**，向后兼容 | 版本只能建后取证 |

**零风险探针（`probe` 步骤，5 连击，跑完实例数仍 0）**

| 探针 | 构造 | 实际返回 |
|---|---|---|
| P1 | `DeploySchema=bogus_value` | `InvalidDeploySchema.Malformed`（400） |
| P2 | `DeploySchema=single_az` + `EngineVersion=99.9` | `COMMODITY.INVALID_COMPONENT`（400）⇒ **single_az 已越过参数校验** |
| P3 | `DeploySchema=multi_az` + 仅 1 个 AZ | `The number of zones is not multi.`（400） |
| P4 | `ZoneId=ap-southeast-6x` + 合法 vSwitch | `VPC or VSwitch is not valid.`（400） |
| P5 | `RegionId=ap-southeast-9`（不存在） | `InvalidRegion.NotFound`（404）⇒ 证明 P1–P4 的报错有判别力 |

> 探针原理：故意踩**服务端**校验点，看错误落在哪一层。落点在"商品校验 / 多 AZ 数量"即说明参数层已通过。
> ⚠ 红线：任何一次落到"创建成功"都是事故 —— 脚本在探针末尾**强制复核 `TotalCount` 必须仍为 0**。

---

## 三、成本（官方单价，马尼拉）

```
计算：0.185350 USD/CCU·h      存储 OSS：0.000044 USD/GB·h
计算资源包：0.03611 USD/CCU·H  马尼拉抵扣因子：1.45
```

| 场景 | 按量 | 资源包等效 | 差异 |
|---|---|---|---|
| 4 CCU 常驻（最小预留） | **541.22 USD/月** | **152.89 USD/月** | 资源包 = 按量的 **28.2%**（省 **71.8%**） |
| 8 CCU 常驻（弹性上限） | 1,082.44 USD/月 | 305.78 USD/月 | 同上比例 |
| 存储 100 GB OSS | 3.21 USD/月 | — | 相对计算费可忽略 |

**马尼拉为什么比"51% 折扣"更划算**：资源包是全国统一价 0.03611 USD/CCU·H，而马尼拉按量单价（0.18535）显著高于中国内地（0.07737）⇒ 海外地域用包的实际折扣远大于宣传值。

**资源包硬约束（采购前必读）**：最小包 **3000 CCU·H**、**预付 3 年**、**不可退订**、可叠加但不可续费。以 4 CCU 常驻计，3000 CCU·H 抵扣因子折算后仅够 **≈517 小时（21.6 天）** ⇒ 首包属于"试水包"，正式用量要按 3 年 × 常驻 CCU 估算。
**判断规则：日志库若 3 年内可能被裁撤/迁移（例如日志量下降改回 RDS PG 独立库），就不买包。**

---

## 四、交付物

| 文件 | 说明 |
|---|---|
| `deploy/task9/ck_decision.sh` | 5 步脚本：`verify`（只读复核）· `probe`（零风险探针，末尾强制复核未创建）· `cost [CCU]`（成本换算）· `create --yes`（真实创建，**默认拒绝执行**）· `check`（建后验收清单）· `all`。日志落 `deploy/logs/task9_ck_*.log` |
| `deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` | 本轮修订 **10 处**（见下） |
| `deploy/docs/Day1任务9_日志库CK决策_执行报告.md` | 本文件 |

**指南修订清单（10 处）**

1. 文档头新增「5. 日志库决策 API 加固（2026-09-29）」
2. F9 行 —— 补三个"只有"（AZ/存储/计费）+ 创建通道
3. 差异表 #1 —— 把"单 AZ 是我们接受的风险"改成"该地域不提供多 AZ"
4. §2.1 付费方式行 —— 新增 CK 例外（按量 + 计算资源包，抵扣因子 1.45）
5. G7 —— 明确"确认账号已获企业版售卖区白名单"为闭环动作
6. G0 表付费方式句 —— 补 CK 按量
7. G0 检查表 G7 行 —— 同上补白名单与资源包登记
8. 任务 9 卡片 —— 新增「2026-09-29 复核证据」E1–E9 表 + 落地要点按实测重写 + 操作步骤补探针法 + 新增坑 5–8
9. 任务 29 卡片 —— CK 创建命令按实测参数固化 + "仅购买页"作废 + 状态字段不再预设 `Activated`
10. 任务 52 成本表 —— 新增 CK 三档成本锚点与"不能按包年包月填"的提醒

---

## 五、阻塞与待办

| # | 项 | 状态 |
|---|---|---|
| B1 | **账户余额 0.00 USD** | ❌ 未解；CK 实例创建会被拦（企业版按量，但国际站 0 余额会触发风控，ACK 已有 `RISK.RISK_CONTROL_REJECTION` 先例） |
| B2 | **企业版售卖区白名单** | ⚠ 未验；官方要求控制台无企业版选项时须提工单加白（G7） |
| B3 | **CK 计算资源包是否进采购清单** | ⚠ 待用户裁定（涉及 3 年预付） |
| B4 | **企业版是否挂 CLB/ARMS 等依赖服务** | ⚠ 未实测（实例未建）→ 建成后须复查有无被自动创建并计费 |
| B5 | **实例状态字段取值** | ⚠ 未实测（企业版 ≠ 社区版 `Running` 口径，已在文档中标注） |
| T1 | **与任务 41 I-1 窗口联动** | CK 实例未创建 ⇒ 「日志库仍为 PG 分支」窗口仍敞着（`16×200+24×20=3680 > max_client_conn 2000`）。**"把 CK 提前创建"是唯一不动 conns、不动池参数的解法**——本卡已为其备好 `create --yes` 命令与探针验证，属任务 29/17 的排期裁定 |

---

## 六、方法学沉淀（可复用）

1. **零成本确证可购性**：不靠截图、不靠试建，用「非法值探针 + 错误码分层」判定 —— 报错落在**参数校验层**说明前面的层都过了。
2. **探针必须选服务端校验点**：拿 CLI 已声明 enum/range 的参数（如 `--NodeCount 1`）当"必失败点"，会在 CLI 本地被拦，**根本到不了服务端**，得到的报错没有判别力（本轮踩过一次）。
3. **地域能力要用"对照地域"证伪**：只看马尼拉回 1 个 AZ 无法排除"接口没返回全"，加新加坡（3 个 AZ）作对照才成立。
4. **CLI 大小写**：`StorageType` 值必须小写 `oss`，写 `OSS` 会被 CLI 拒并给出 `did_you_mean`，极易误读成"地域不支持"。

---

## 七、2026-09-30 接线完成（实例已建成 → 日志库可用）

**实例**：`cc-5tsv2o51s1360b0pr`（用户开通；`enterprise` / `single_az` / `ap-southeast-6a` / oss / 按量 —— 与本报告决策口径完全一致）。

### 7.1 接线四件套（`deploy/task9/ck_wiring.sh`：`--check` / `--apply` / `--verify`）

| # | 项 | 结果 |
|---|---|---|
| 1 | 白名单组 `mnl_app` | ✅ `10.0.16.0/20,10.0.32.0/20`（default 组保持 `127.0.0.1` 未动） |
| 2 | 库 `newapi_logs` | ✅ 建成 |
| 3 | 账号 `newapi`（NormalAccount） | ✅ 建成 + **数据层 GRANT**（见 7.2 坑 10） |
| 4 | DSN | ⚠ KMS 不可用（见 7.2 坑 11）→ 降级保管 `/root/.deploy_secrets/LOG_SQL_DSN`（600，仓库外） |
| 5 | RAM 策略 `new-api-kms-readonly` | ✅ 默认版本 v2 已含 LOG_SQL_DSN 两地 ARN（共 16 ARN） |

### 7.2 新坑（9–12）

- **坑 9（实例建成 ≠ 可用）**：新实例白名单仅 `default=127.0.0.1`、账号数 0、无库 —— 「判据四件套」必须逐项过，实例 `ACTIVATION` 不代表可写日志。
- **坑 10（★ 平台缺陷：`DmlAuthSetting` 授权映射不生效）**：`CreateAccount` 传 `{"DdlAuthority":true,"DmlAuthority":0,"AllowDatabases":["newapi_logs"]}`（JSON 数组是唯一被接受的编码；dotted 形式被 CLI 拒、逗号串被服务端拒）后，`DescribeAccountAuthority` 回读 `AllowDatabases=[]`，SQL 层 `SHOW GRANTS` 仅 `default_role` 管理类授权，**无任何 `ON newapi_logs.*` 数据权限**，`CREATE TABLE` 报 `Not enough privileges`。**绕行**：建 `ckadmin`（SuperAccount，DSN 存 `/root/.deploy_secrets/CK_ADMIN_DSN`），从 VPC 内节点 `GRANT ALL ON newapi_logs.* TO newapi`；应用账号仍是最小权限（只授 newapi_logs 单库）。已固化进 wiring 脚本 `--apply` 步骤 4b。
- **坑 11（★ KMS 国际站硬阻塞）**：两地 `kms CreateSecret` 均报 `UnsupportedOperation`。根因：国际站「密钥与凭据须属同一 KMS 实例」，账号无 KMS 实例（`ListKeys=0`）。**阻塞任务 17 全部 8 个凭据**，非本任务特有。购 KMS 实例后从保管目录迁移。
- **坑 12（RAM `ListPolicyVersions` 字段名）**：默认版本判定字段是 **`IsDefaultVersion`**（非 `IsDefault`），数组路径 `.PolicyVersions.PolicyVersion[]`，且 List 自带 PolicyDocument，无需二次 DescribePolicyVersion。

### 7.3 实测新事实（解答 09-29 报告的待办）

| 09-29 待办 | 09-30 实测结论 |
|---|---|
| B2 企业版售卖区白名单 | ✅ 已通（实例可建即证明） |
| B4 是否挂 CLB/ARMS 依赖 | ✅ **未自动创建任何依赖**（马尼拉 CLB 总数不变，无新增计费项） |
| B5 实例状态字段 | ✅ 企业版为 **`ACTIVATION`** |
| 内核版本（E9 遗留） | **`26.2.1.698_1`**；存算分离引擎实测 **`SharedMergeTree`** |
| B1 余额风控 | CK 实例实际开通成功（用户侧操作），B1 对 CK 创建未构成拦截 |

### 7.4 端到端验证（`--verify`，VPC 内 worker 节点发起，全部通过）

| 项 | 结果 |
|---|---|
| V1 认证/库/版本 | ✅ `newapi / newapi_logs / 26.2.1.698` |
| V2 应用同款 DDL 建表 | ✅（表 `logs` 由应用代码自动建，schema 与文档 DDL 基线不同 —— **以代码 `model/main.go` 为准**） |
| V3 INSERT + count | ✅ 1 |
| V4 引擎/TTL | ✅ `SharedMergeTree` + `TTL ... + INTERVAL 90 DAY` |
| V5 TRUNCATE 清探针 | ✅ 0 |

### 7.5 剩余

1. `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 进任务 17 ConfigMap
2. DSN 注入待 KMS 实例购买（或临时走保管文件注入 Secret）
3. 备站 SG 走 CK 公网端点（`CreateEndpoint`）仍待裁定
4. CK 计算资源包（B3）仍待用户裁定
5. T1 联动：CK 已创建 ⇒ 任务 41 I-1 的「PG 分支连接数超限」窗口关闭，任务 29/17 可按 CK 主线走
