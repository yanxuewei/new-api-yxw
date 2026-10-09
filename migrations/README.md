# migrations/ —— 版本化 DDL（golang-migrate）

> 任务 54 产物。**本目录是 schema 的唯一真相来源**；`migrations/` 一旦启用，应用侧 GORM
> AutoMigrate 必须整体关闭（`MIGRATE_MODE=off`，见 `deploy/docs/G8代码补项_交付说明_2026-09-28.md`）。
> 两条路径并存 = 回滚永远不干净（坑 2），所以切换是**一次性**的。

## 1. 命名与结构

```
<6位数字>_<英文短名>.up.sql     前滚
<6位数字>_<英文短名>.down.sql   回滚（强制，见 §4）
```

- 版本号连续、不重号；`migrate create -dir ./migrations -format numbering -ext sql -seq <name>` 生成骨架。
- 每个迁移文件只做一件事；DDL 与数据回填**分开**成两个版本（便于分批与单独回滚）。

## 2. expand-contract 三段式

| 阶段 | 迁移示例 | 兼容性 | 何时做 |
| --- | --- | --- | --- |
| **Expand** | `000002_expand_add_nickname` + `000003_expand_concurrent_index` | 新旧代码都能跑（加 nullable 列/新表 + 双写） | 发布 N |
| **Migrate** | `000004_migrate_backfill_nickname` | 只影响性能（分批/限速/可续跑） | 发布 N 之后 |
| **Contract** | `000005_contract_drop_legacy_alias` | **需要只有新代码在跑** | 发布 N+1（灰度 100% 且稳定 ≥24h） |

> Expand 被拆成两个文件，是因为「加列」要在事务里、「并发建索引」必须在事务外 —— 事务边界
> 是**文件级**的，所以阶段内也可以有多个版本号。`down 4`（5→1）能一次性把整个 expand-contract
> 走完再重放，这是本目录锁观测演练用的动作。

Contract 的 PR 标题强制带 `[N+1]`，评审门禁核对「线上是否 100% 新代码」——这是唯一能挡住
「旧实例读不到被删列」的人类检查点。

## 3. 并发 DDL 的铁律（**本仓实测踩过坑，别照抄网上写法**）

- **PG 加索引一律 `CREATE INDEX CONCURRENTLY`**。
- **`CREATE INDEX CONCURRENTLY` 必须独占一个迁移文件，且文件内只有这一条语句。**
  - golang-migrate **没有**「按文件关闭事务」的注解。`-- +migrate NoTransaction` 是**误传**
    （那是 goose 的 `-- +goose NO TRANSACTION`）。实测 v4.19.1：
    `CREATE INDEX CONCURRENTLY cannot run inside a transaction block in line 0: -- +migrate NoTransaction`，
    并把库留在 `version 2 (dirty)`。
  - 正确原理：默认 `x-multi-statement=false` 时，postgres 驱动把**整个文件**当作一条 statement
    交给 `Exec`；多条语句挤进一次 `Exec` = 隐式事务块。**单语句文件不在事务块里**。
  - 官方口径：golang-migrate `database/postgres` README —— "put `CREATE INDEX CONCURRENTLY`
    in its own migration"。
  - 示例：`000003_expand_concurrent_index` 与 `000002_expand_add_nickname` 是**两个**文件。
- 不做 CONCURRENTLY 的代价：普通 `CREATE INDEX` 持 SHARE 锁直到事务结束，大表上让业务写排队
  数分钟 → 直接击穿 99.95% 可用性预算（21.6 分钟/月）。
- `CONCURRENTLY` 失败会留下 `INVALID` 索引且**不自动回滚** → 显式 `DROP INDEX` 后重建。
- MySQL 侧（若将来支持）用 `ALGORITHM=INPLACE, LOCK=NONE`。
- 回滚（down）也必须用 `CONCURRENTLY`，否则回滚本身变成故障源。
- **dirty 恢复**：半途失败会留 `version N (dirty)`，`up` 会拒绝执行。用
  `migrate force <上一个成功版本>` 清 dirty（不执行任何 DDL），再重跑 `up`。禁止手改 `schema_migrations`。

## 4. 每个迁移都必须有可跑的 `.down.sql`

「从没跑过的 down」= 出事时的二次故障。规范：

- down 必须是 up 的**对称逆操作**，且在 staging 真跑过（本目录每周自动 `up → down 1 → up` 一轮，纳入 §12 证据）。
- 确实不可逆的迁移（如 Contract 删列、`DROP TABLE`），必须在文件头**显式标注**
  `⚠ 不可逆 / 仅前滚修复` 并过评审；`deploy/ops/ci_check_migrate_versioned.sh` 会检查该标注是否存在。
- 数据类迁移（回填）的 down 要求「可推导还原」或先建归档表。

## 5. 执行方式

**CI / 人工（staging）**

```bash
migrate -path ./migrations -database "$DSN_STAGE" version
migrate -path ./migrations -database "$DSN_STAGE" up
migrate -path ./migrations -database "$DSN_STAGE" down 1 && migrate -path ./migrations -database "$DSN_STAGE" up
migrate -path ./migrations -database "$DSN_STAGE" up            # 期望 "no change"
```

**K8s Job（prod）**：`deploy/aliyun/ph/migrate-job.yaml`
- `backoffLimit: 0`（迁移失败不重试，人工介入）
- 只用 `newapi_migrate` 账号（§5.5 已在 DB 层强制）
- 与 master Deployment 不同时启动（Argo PreSync 或人工顺序保证）
- migrations 内容通过 ConfigMap 挂载：

```bash
kubectl -n new-api create configmap new-api-migrations \
  --from-file=migrations/ --dry-run=client -o yaml | kubectl apply -f -
```

## 6. 已知边界

- **本目录当前只在 staging（`newapi_stage`）验证过**；prod 仍为「master-only AutoMigrate」，
  待 G8 的 `MIGRATE_MODE` 合并 + 一次完整演练后才切换。
- `schema_baseline` 表记录「版本 1 = AutoMigrate 历史产物」这一分界事实，不重建已有表。
- 000001 的 `down` 会删掉版本分界物证，**禁止在生产执行**。
