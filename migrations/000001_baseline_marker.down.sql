-- 回滚 000001：删除基线与演练表。
-- 仅在演练库（staging）使用；生产库该 down 从未也不应执行——
-- 它会在生产上删掉「版本分界点」的物证。生产回滚一律走前滚修复。

DROP TABLE IF EXISTS drill_accounts;
DROP TABLE IF EXISTS schema_baseline;
