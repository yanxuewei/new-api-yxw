# 长期记忆 — new-api-yxw

## 项目文档入口

- `impl_deploy.md`（仓库根）：技术设计文档的**部署分册** v1.0（2026-09-19，基线 commit `972aed197`），含第一章「系统概述与设计目标」、第七章「阿里云部署方案（菲律宾 + 泰国）」、第八章「SLA 99.95% 达成方案」。第九章「系统不足与改进措施」不在该文件内。
- `impl_tech.md`（仓库根）：配套的技术分册。
- 两文档均使用标注体系：`[现状]` = 仓库已实现；`[需补建]` = 落地需补齐（编号如 R-04/R-05/R-07/R-30）。

## 已确认的项目事实（读代码/文档核对过）

- **登录会话模型**（权威文档：`docs/authentication.md`）：面板鉴权 = 15 分钟 JWT Access Token（内存）+ HttpOnly Refresh Cookie（最长 30 天，服务端只存 HMAC 摘要）+ `user_sessions` 表作为登录会话控制面。**数据库是 Session 状态的最终权威**；Redis 仅缓存（TTL = min(剩余寿命, `SYNC_FREQUENCY`)，未命中回源 DB）。
- `SESSION_SECRET` 派生 Access Token、Security Proof、Refresh Token 摘要、AuthFlow 摘要的密钥 → **多节点/多区域部署必须一致**，否则会话与安全流程全部失效。
- `CRYPTO_SECRET`：多节点共享同一 Redis 时必须一致（缓存键摘要）。
- 会话相关限额：`USER_SESSION_ACTIVE_LIMIT`(50)、`USER_SESSION_ISSUANCE_LIMIT`(100)、`USER_SESSION_ISSUANCE_WINDOW_SECONDS`(86400)、`USER_SESSION_REVOKED_RETENTION_DAYS`(7)；仅 master 节点执行 session/AuthFlow 清理。
- 定时任务依靠**数据库租约**去重（`system_task_locks` 表，主键 = task type，锁 TTL 60s、心跳 TTL/3，仅 `NODE_TYPE != slave` 的 master 启动 runner）——该机制假设**单库多实例**；引入多主数据库（如双区域 DTS 双向）时该前提不再成立，会导致两区 master 重复执行同一任务（含计费结算）。详见 `impl_deploy_review.md`。
- 同类约束：计费幂等键（`subscription_pre_consume_records.request_id` 唯一索引）、任务状态 CAS（`Task.UpdateWithStatus`）、行锁 `lockForUpdate` 全部是**单库作用域**，任何多主数据库部署都必须额外设计跨区对账与仲裁。
- 仓库中**不存在任何部署清单**（无 `deploy/` 目录、无 K8s/ALB YAML）；`impl_deploy.md` 第七章的 YAML 均为文档内嵌示例，落地需从零创建。
- **额度变更默认走内存批处理**：`BATCH_UPDATE_ENABLED=true` 时 `DecreaseUserQuota`/`IncreaseUserQuota` 只累加到进程内存（`model/utils.go` 的 `batchUpdateStores`），每 `BATCH_UPDATE_INTERVAL`（默认 5s）才 flush 到库；进程被 kill 即丢失该窗口内的扣费。任何「计费零误差」要求都必须先关闭该开关（直接落库用的是原子增量 SQL `quota = quota ± ?`，可安全重放）。
- 面向 99.95% 不断服 + 计费误差 <0.001 的修订方案见 `impl_deploy_fix.md`（四条不变量：单写者 / 可转移 epoch fencing / 事实流不丢 / 入口无 DNS 依赖；分期 P0 部署层 → P1 小代码 → P2 架构）。
