-- 回滚 000004（Contract）：把列建回来（nullable，无默认值）。
-- ⚠ 只能恢复**列结构**，legacy_alias 的**数据不可恢复** —— 这就是 Contract 阶段的不可逆点，
--   也是「Contract 必须等 N+1、必须过评审」的原因。
--   若 up 之前做过归档表，此时需人工从归档表回灌。

ALTER TABLE drill_accounts ADD COLUMN IF NOT EXISTS legacy_alias varchar(64);
