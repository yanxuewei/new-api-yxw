-- Migrate 阶段（发布 N 之后）：分批回填历史数据。
--
-- 三个硬要求（卡片步骤 3 表格）：
--   分批   —— 每批 500 行，避免长事务与 WAL 膨胀
--   限速   —— 每批 sleep 10ms，给业务写留 IO/CPU
--   可续跑 —— 条件是 nickname IS NULL，被中断后重跑只处理剩余行（幂等）
--
-- FOR UPDATE SKIP LOCKED：与其他回填/写入并发时不会互相等锁。

DO $$
DECLARE
    batch_size int := 500;
    affected   int := 0;
    total      int := 0;
BEGIN
    LOOP
        WITH picked AS (
            SELECT id
              FROM drill_accounts
             WHERE nickname IS NULL
             ORDER BY id
             LIMIT batch_size
             FOR UPDATE SKIP LOCKED
        )
        UPDATE drill_accounts a
           SET nickname = left(regexp_replace(a.display_name, '\s+', '', 'g'), 64)
          FROM picked p
         WHERE a.id = p.id;

        GET DIAGNOSTICS affected = ROW_COUNT;
        total := total + affected;
        EXIT WHEN affected = 0;

        PERFORM pg_sleep(0.01);
    END LOOP;

    RAISE NOTICE 'backfill drill_accounts.nickname: % rows', total;
END $$;
