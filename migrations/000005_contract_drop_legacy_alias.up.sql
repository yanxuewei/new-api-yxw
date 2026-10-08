-- Contract 阶段（发布 N+1）：删除旧列。
--
-- ⚠⚠ 前置门禁（评审必须核对，不满足不许合并）：
--   1. PR 标题带 [N+1] 标记；
--   2. 线上 100% 已是新代码（灰度 100% 且稳定 >= 24h），没有任何在跑的实例会读 legacy_alias；
--   3. 全库 grep 确认代码与 SQL 里已无 legacy_alias 引用。
--
-- ⚠ 不可逆：DROP COLUMN 之后数据不可恢复，只能靠 000004 的 down 建回空列。
--   若需保留数据，Contract 前先做一次归档表/备份：CREATE TABLE drill_accounts_legacy_archive AS
--   SELECT id, legacy_alias FROM drill_accounts WHERE legacy_alias IS NOT NULL;

ALTER TABLE drill_accounts DROP COLUMN IF EXISTS legacy_alias;
