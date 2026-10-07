-- Expand 阶段（发布 N）· 第 2 步：并发建索引。
--
-- ★★ 本文件必须**只含这一条语句**。这是 golang-migrate 下跑 CONCURRENTLY 的唯一正确姿势：
--   1. golang-migrate **没有**「按文件关闭事务」的注解。`-- +migrate NoTransaction` 是误传
--      （那是 goose 的 `-- +goose NO TRANSACTION`）——实测 v4.19.1 直接报
--      `CREATE INDEX CONCURRENTLY cannot run inside a transaction block in line 0: -- +migrate NoTransaction`。
--   2. 默认 x-multi-statement=false 时，postgres 驱动把**整个文件**当作一条 statement 交给 Exec；
--      多条语句挤进一次 Exec = 隐式事务块 ⇒ 加第二条语句必然失败。
--   3. ⇒ 规则：**每个 CONCURRENTLY 语句独占一个迁移文件**（SQL 注释不算语句）。
--   官方口径：golang-migrate database/postgres README —— "put CREATE INDEX CONCURRENTLY in its own migration"。
--
-- ⚠ 不做 CONCURRENTLY 的代价：普通 CREATE INDEX 持 SHARE 锁直到事务结束，
--   大表上让业务写排队数分钟 —— 直接击穿 99.95% 可用性预算（21.6 分钟/月）。
-- ⚠ CONCURRENTLY 代价：失败会留下 INVALID 索引且**不自动回滚**，必须人工 DROP 后重建。

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_drill_accounts_nickname ON drill_accounts (nickname);
