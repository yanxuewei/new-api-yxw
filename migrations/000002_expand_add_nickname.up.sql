-- Expand 阶段（发布 N）· 第 1 步：新增 nullable 列。
--
-- ⚠ 本文件只放「事务内可执行」的语句。必须跑在事务外的语句（CREATE INDEX CONCURRENTLY）
--   一律另起一个独占文件，见 000003_expand_concurrent_index —— 这是 golang-migrate 的硬规则。
--
-- ⚠ PG 11+ 的 ADD COLUMN 即使带 DEFAULT 也只是元数据操作（不重写表），这里仍选择
--   「nullable 列 + 后续回填」，目的是让「结构就绪」与「数据就绪」成为两个可独立回滚的状态。
--
-- 兼容性：老代码不认识 nickname 也不写它；新代码写入前该列为 NULL ⇒ 新旧代码都能跑。

ALTER TABLE drill_accounts ADD COLUMN IF NOT EXISTS nickname varchar(64);
