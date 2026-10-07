-- 回滚 Expand 第 1 步：删列。
--
-- 顺序要求：必须先撤掉依赖该列的索引（000003.down），否则 DROP COLUMN 会连带删掉索引
-- 但不在迁移历史里留痕，下次 up 时索引定义与代码期望会不一致。

ALTER TABLE drill_accounts DROP COLUMN IF EXISTS nickname;
