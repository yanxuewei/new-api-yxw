# deploy/jakarta_dev/dev_grants.sql —— 2d 权限 SQL（雅加达 dev，逐条执行）
#
# 格式（runner 按 `scope|SQL` 逐行读，每条单独一次 psql -c）：
#   main  = 以 newapi_ops 连库 `newapi`
#   logs  = 以 newapi_ops 连库 `newapi_logs`
#   check = 生效判据回读（两条都跑，main/logs 各一次；见 runner 的 scope=check 分发）
#
# 口径来源：指南-v2.0 任务 13 第 2 步（第 1240–1300 行）+ 坑 6/7/8/11/14。与生产**逐字同构**的部分：
#   - 权限只由 SQL 落，RDS API 侧保持"零库权限"（坑 11：PG+云盘的 GrantAccountPrivilege 只有
#     `DBOwner` 一个值，用 API 授权等于把账号提成库 owner，schema 级最小化白做）。
#   - `ALTER DEFAULT PRIVILEGES` 必须 `FOR ROLE newapi_migrate`（坑 8：不带 FOR ROLE 只影响执行者
#     自己后续建的对象，AutoMigrate 建出的表全线无权限）。
#   - database 级 `REVOKE/GRANT CONNECT` **不写**（坑 14：RDS PG 上库 owner 是内部账号 aurora，
#     Super 只是 pg_rds_superuser 成员，两条语句只回 WARNING 静默 no-op；2026-09-29 已裁定接受）。
#     dev 现状补记：owner 已改为 newapi_ops，坑 14 的前提在 dev 不再成立 ⇒ 这两条理论上能落地，但
#     仍**不写**，保持与生产同一套 SQL 文本（运维只记一份），隔离靠白名单 + 口令轮转 + 手工 Secret。
#
# dev 唯一偏差（有意，写在台账 §12）：日志库 `newapi_logs` 的 DDL 由**运行账号 newapi** 自己承担，
#   因为 dev 是单工作负载 NODE_TYPE=master（`SQL_DSN` 取 SQL_DSN_MIGRATE 只覆盖主库；日志库走
#   `LOG_SQL_DSN`=newapi），所以这里给 newapi 的是 USAGE+CREATE，而不是生产主库那种
#   "migrate 独享 CREATE / runtime 仅 USAGE" 的双账号切分。主库侧仍保持生产切分不变。

# ---- main：主库 newapi（生产同构的双账号切分）----
main|REVOKE CREATE ON SCHEMA public FROM PUBLIC
main|GRANT USAGE, CREATE ON SCHEMA public TO newapi_migrate
main|GRANT USAGE ON SCHEMA public TO newapi
main|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO newapi
main|ALTER DEFAULT PRIVILEGES FOR ROLE newapi_migrate IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO newapi

# ---- logs：日志库 newapi_logs（dev 偏差：newapi 一肩挑 DDL+DML）----
logs|REVOKE CREATE ON SCHEMA public FROM PUBLIC
logs|GRANT USAGE, CREATE ON SCHEMA public TO newapi
logs|GRANT USAGE ON SCHEMA public TO newapi_migrate

# ---- check：生效判据（坑 14 的教训：绝不用"命令成功"当"权限落地"）----
# owner 期望值 = newapi_ops（2026-10-12 实测修正）：
#   本轮那次 GrantAccountPrivilege DBOwner 曾把 owner 提成业务账号；RDS 不给"还原内部账号 aurora"的通路
#   （newapi_ops 只属于 pg_rds_superuser，SET ROLE aurora ⇒ permission denied；RevokeAccountPrivilege 回 200
#    但 owner 不变），所以非破坏的可达目标是 **newapi_ops（应用绝不使用的高权限账号）** ⇒ 只要 owner 不是
#   newapi/newapi_migrate，schema 级最小化就真正生效。判据看 has_create_runtime（主库必须 false）。
#   若负责人坚持 owner=aurora，唯一路径是删库重建（两库 objects=0，无数据损失，但属破坏性 API ⇒ 待核准）。
check|select 'db_owner=' || pg_get_userbyid(datdba) from pg_database where datname = current_database()
check|select 'nspacl=' || coalesce(array_to_string(nspacl,','),'(null)') from pg_namespace where nspname='public'
check|select 'has_create_migrate=' || has_schema_privilege('newapi_migrate','public','CREATE')::text || ' has_usage_migrate=' || has_schema_privilege('newapi_migrate','public','USAGE')::text || ' has_create_runtime=' || has_schema_privilege('newapi','public','CREATE')::text || ' has_usage_runtime=' || has_schema_privilege('newapi','public','USAGE')::text
check|select 'default_acl=' || pg_get_userbyid(defaclrole) || '=' || defaclacl::text from pg_default_acl d join pg_namespace n on n.oid=d.defaclnamespace where n.nspname='public'
check|select 'tables=' || count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'
