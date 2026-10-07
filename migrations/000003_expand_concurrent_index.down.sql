-- 回滚 Expand 第 2 步：并发删索引。
--
-- 同样必须独占一个文件（DROP INDEX CONCURRENTLY 也不能在事务块内）。
-- 必须用 CONCURRENTLY：否则回滚本身持锁阻塞业务，把「回滚」变成新的故障源。

DROP INDEX CONCURRENTLY IF EXISTS idx_drill_accounts_nickname;
