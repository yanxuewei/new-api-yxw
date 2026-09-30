
---

## 七、2026-09-30 接线完成（实例已建成 → 日志库可用）

**实例**：`cc-5tsv2o51s1360b0pr`（用户开通；`enterprise` / `single_az` / `ap-southeast-6a` / oss / 按量 —— 与本报告决策口径完全一致）。

### 7.1 接线四件套（`deploy/task9_ck_wiring.sh`）

| # | 项 | 结果 |
|---|---|---|
| 1 | 白名单组 `mnl_app` | ✅ `10.0.16.0/20,10.0.32.0/20`（default 组保持 `127.0.0.1` 未动） |
| 2 | 库 `newapi_logs` | ✅ 建成 |
| 3 | 账号 `newapi`（NormalAccount） | ✅ 建成 + **数据层 GRANT**（见 7.2 坑 10） |
| 4 | DSN | ⚠ KMS 不可用（见 7.3 坑 11）→ 降级保管 `/root/.deploy_secrets/LOG_SQL_DSN`（600） |
| 5 | RAM 策略 `new-api-kms-readonly` | ✅ 默认版本 v2 已含 LOG_SQL_DSN 两地 ARN（16 ARN） |

### 7.2 新坑（9–12）

- **坑 9（实例建成 ≠ 可用）**：新实例白名单仅 `default=127.0.0.1`、账号数 0、无库 —— 「判据四件套」必须逐项过，实例 Running/ACTIVATION 不代表可写日志。
- **坑 10（★ 平台缺陷：`DmlAuthSetting` 授权映射不生效）**：`CreateAccount` 传 `{"DdlAuthority":true,"DmlAuthority":0,"AllowDatabases":["newapi_logs"]}`（JSON 数组是唯一被接受的编码；dotted 形式被 CLI 拒、逗号串被服务端拒）后，`DescribeAccountAuthority` 回读 `AllowDatabases=[]`，SQL 层 `SHOW GRANTS` 仅 `default_role` 管理类授权，**无任何 `ON newapi_logs.*` 数据权限**，`CREATE TABLE` 报 `Not enough privileges`。**绕行**：建 `ckadmin`（SuperAccount，DSN 存 `/root/.deploy_secrets/CK_ADMIN_DSN`），从 VPC 内节点 `GRANT ALL ON newapi_logs.* TO newapi`；应用账号仍是最小权限（只授 newapi_logs 单库）。**已固化进 wiring 脚本 `--apply` 步骤 4b。**
- **坑 11（★ KMS 国际站硬阻塞）**：两地 `kms CreateSecret` 均报 `UnsupportedOperation: This action is not supported`。根因：国际站「密钥与凭据须属同一 KMS 实例」，账号无 KMS 实例（`ListKeys=0`）。**这阻塞任务 17 全部 8 个凭据**，非本任务特有。DSN 暂存 WSL root `/root/.deploy_secrets/`（600，仓库外）；购 KMS 实例后迁移。
- **坑 12（RAM `ListPolicyVersions` 字段名）**：默认版本判定字段是 **`IsDefaultVersion`**（非 `IsDefault`），数组路径 `.PolicyVersions.PolicyVersion[]`，且 List 自带 PolicyDocument，无需二次 DescribePolicyVersion。

### 7.3 实测新事实（解答 09-29 报告的待办）

| 09-29 待办 | 09-30 实测结论 |
|---|---|
| B2 企业版白名单 | ✅ 已通（实例可建即证明） |
| B4 是否挂 CLB/ARMS | ✅ **未自动创建任何依赖**（马尼拉 CLB 总数不变，无新增计费项） |
| B5 状态字段 | ✅ 企业版为 **`ACTIVATION`** |
| 内核版本 | **`26.2.1.698_1`**（09-29 文档猜的 24.8 作废；存算分离引擎实测 **`SharedMergeTree`**） |

### 7.4 端到端验证（`--verify`，VPC 内 worker 节点发起）

| 项 | 结果 |
|---|---|
| V1 认证/库/版本 | ✅ `newapi / newapi_logs / 26.2.1.698` |
| V2 应用同款 DDL 建表 | ✅（表 `logs` 由代码自动建，schema 与文档 DDL 基线不同——**以代码为准**） |
| V3 INSERT + count | ✅ 1 |
| V4 引擎/TTL | ✅ `SharedMergeTree` + `TTL ... + INTERVAL 90 DAY` |
| V5 TRUNCATE 清探针 | ✅ 0 |

**剩余**：① `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 进任务 17 ConfigMap；② DSN 注入待 KMS 实例（或走保管文件注入 Secret）；③ 备站 SG 走 CK 公网端点（CreateEndpoint）仍待裁定。
