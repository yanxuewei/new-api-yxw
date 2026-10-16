# deploy/jakarta_pre/pre_grants.sql —— 任务 45 步骤 4 权限 SQL（雅加达 pre / perf 两库）
#
# 格式（runner 按 `scope|SQL` 逐行读，每条单独一次 psql -c）：
#   pre   = 以 newapi_ops 连库 `newapi_pre`
#   perf  = 以 newapi_ops 连库 `newapi_perf`
#   check = 生效判据回读（pre/perf 各跑一遍）
#
# 口径来源：与 `deploy/jakarta_dev/dev_grants.sql` 的 **main 段逐字同构**（生产主库的双账号切分），
#   差异只有两处，且都是刻意的：
#   ① 没有 logs 段 —— pre/perf **不建独立日志库**（裁定只给 `newapi_pre`/`newapi_perf` 两库），
#      清单里不注入 `LOG_SQL_DSN` ⇒ 日志表随主库 AutoMigrate 一起建，运行账号无需 CREATE。
#   ② `REVOKE/GRANT CONNECT` 数据库级语句仍**不写**（坑 14 与生产同一套文本，运维只记一份）。
#
# 执行前置（本文件能落地的原因）：云侧 `GrantAccountPrivilege DBOwner` 给 **newapi_ops** 后，
#   两库 owner = newapi_ops（与 dev 现网终态一致），ops 才有资格对 schema public 做 GRANT。
#   绝不给 `newapi` / `newapi_migrate` 提 DBOwner —— 那会把业务账号提成库 owner，schema 级最小化白做（坑 11）。

# ---- pre：newapi_pre（pre 与 dev 共机，NODE_TYPE=master 自持 AutoMigrate）----
pre|REVOKE CREATE ON SCHEMA public FROM PUBLIC
pre|GRANT USAGE, CREATE ON SCHEMA public TO newapi_migrate
pre|GRANT USAGE ON SCHEMA public TO newapi
pre|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO newapi
pre|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO newapi

# ---- perf：newapi_perf（同构；perf 侧本轮只到"空跑清单 + 双库冒烟"，无压测）----
perf|REVOKE CREATE ON SCHEMA public FROM PUBLIC
perf|GRANT USAGE, CREATE ON SCHEMA public TO newapi_migrate
perf|GRANT USAGE ON SCHEMA public TO newapi
perf|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO newapi
perf|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO newapi

# ---- check：生效判据（坑 14：绝不用"命令成功"当"权限落地"）----
# 期望：db_owner=newapi_ops；has_create_migrate=true；has_create_runtime=false；tables=0（空库首启前）
check|select 'db_owner=' || pg_get_userbyid(datdba) from pg_database where datname = current_database()
check|select 'nspacl=' || coalesce(array_to_string(nspacl,','),'(null)') from pg_namespace where nspname='public'
check|select 'has_create_migrate=' || has_schema_privilege('newapi_migrate','public','CREATE')::text || ' has_usage_migrate=' || has_schema_privilege('newapi_migrate','public','USAGE')::text || ' has_create_runtime=' || has_schema_privilege('newapi','public','CREATE')::text || ' has_usage_runtime=' || has_schema_privilege('newapi','public','USAGE')::text
check|select 'default_acl=' || pg_get_userbyid(defaclrole) || '=' || defaclacl::text from pg_default_acl d join pg_namespace n on n.oid=d.defaclnamespace where n.nspname='public'
check|select 'tables=' || count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'
