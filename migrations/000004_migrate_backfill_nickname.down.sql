-- 回滚 000003（Migrate）：清空回填值，回到「列已存在但为 NULL」的 Expand 完成态。
-- 该 down 是**可逆**的：回填值可由 display_name 重新推导，不丢原始信息。
-- （对比 000004 的 down：删列后的数据不可恢复 —— 两类迁移的性质必须在文件头写明。）

UPDATE drill_accounts SET nickname = NULL;
