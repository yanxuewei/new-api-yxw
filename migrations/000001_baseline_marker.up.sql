-- 版本化基线标记（任务 54 · 步骤 1）
--
-- 既有 schema 由 GORM AutoMigrate 建立（任务 18 实测：空库首启 36 表 / 177 索引 /
-- 64 UNIQUE / 0 外键；二次冷启动 schema 指纹逐字相同）。本迁移**不重建**这些表，
-- 只把「版本 1」钉到 golang-migrate 的 schema_migrations 上，作为两条路径的分界点：
--   版本 <= 1：AutoMigrate 的历史产物
--   版本 >= 2：全部 DDL 由 migrations/ 负责
--
-- 幂等：全部 IF NOT EXISTS / ON CONFLICT，重复 up 不产生漂移。

CREATE TABLE IF NOT EXISTS schema_baseline (
    id              smallint     PRIMARY KEY DEFAULT 1,
    baseline_source text         NOT NULL,
    captured_at     timestamptz  NOT NULL DEFAULT now(),
    notes           text,
    CONSTRAINT schema_baseline_singleton CHECK (id = 1)
);

INSERT INTO schema_baseline (id, baseline_source, notes)
VALUES (1,
        'gorm-automigrate',
        'Task 18: 36 tables / 177 indexes / 64 UNIQUE / 0 FK; 2nd cold start fingerprint identical')
ON CONFLICT (id) DO NOTHING;

-- expand-contract 演练表：模拟「线上已存在、需要演进」的业务表。
-- legacy_alias 故意保留到 000004（Contract）删除，用来验证 N+1 删列闭环。
CREATE TABLE IF NOT EXISTS drill_accounts (
    id           bigserial    PRIMARY KEY,
    email        varchar(128) NOT NULL UNIQUE,
    display_name varchar(64)  NOT NULL,
    legacy_alias varchar(64),
    quota        bigint       NOT NULL DEFAULT 0,
    created_at   timestamptz  NOT NULL DEFAULT now()
);

-- 种子：给 Migrate 阶段（回填）准备可处理的数据。仅当表为空时写入。
INSERT INTO drill_accounts (email, display_name, legacy_alias, quota)
SELECT 'drill-' || g || '@example.internal',
       'drill user ' || g,
       'legacy-' || g,
       (g * 100)::bigint
  FROM generate_series(1, 2000) AS g
 WHERE NOT EXISTS (SELECT 1 FROM drill_accounts);
