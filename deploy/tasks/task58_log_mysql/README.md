# task58 · 日志库去 ClickHouse → 专用 RDS MySQL（2026-10-15）

## 背景
CK 企业版按量 $1,082.44/月 = 生产最大单项。代码核查发现 GORM 决定性差异：
- mysql driver v1.5.7 `DeleteClauses` 含 LIMIT（`mysql.go:64`）⇒ 批删生效
- postgres driver v1.5.9 `DeleteClauses` 无 LIMIT（`postgres.go:77`）⇒ **PG 上 `Limit()` 静默忽略 = 一次全删大事务** ⇒ PG 路线全部排除（并入现役 PG 亦踩坑）
⇒ 选型 **专用 RDS MySQL 8.0 `mysql.x2.medium.2c`**（跨 AZ HA，$133.06/月，净省 $949.38/月）。

## 落地物
- RDS MySQL 实例：**`rm-5ts0ez22t67il9oz3`**（newapi-logs-mysql，包月至 2026-11-15，VPC `vpc-5tst1tgeessxn1azwasg2`，主 6b/备 6a，100G cloud_essd）
- 连接串：内网 `rm-5ts0ez22t67il9oz3.mysql.ap-southeast-6.rds.aliyuncs.com:3306`（10.0.64.1）；公网 **`newapi-logs-public.mysql.ap-southeast-6.rds.aliyuncs.com:3306`**（43.123.80.14，已开 SSL，`CAType=aliyun`）
  - ⚠ 公网串原名 65 字符超 `ModifyDBInstanceSSL` 的 64 上限（`ConnectionStringLengthExceeded`）⇒ 前缀改为 `newapi-logs-public`
- 白名单：`mnl_vpc`（4 个 10.0.x/20）+ `sg_standby_eip`（4 EIP，照抄现役 PG）+ hdm 默认组
- 库/账号：`newapi_logs`（utf8mb4）/ `newapi_logs`（Normal，ReadWrite）；口令 `/root/.deploy_secrets/RDS_PW_newapi_logs`
- DSN：`/root/.deploy_secrets/MYSQL_LOG_DSN_{MNL,SG}`；**回滚留档** `/root/.deploy_secrets/CK_LOG_DSN_{MNL,SG}`（原 CK DSN）

## 接线（2026-10-15 14:3x~14:5x 完成）
`Secret new-api-secrets` 单键 `LOG_SQL_DSN` merge patch + 三部署（mnl）/一部署（sg）滚动重启：
- mnl（ns new-api：new-api-stable / new-api-master / new-api-canary）：日志库 → MySQL 内网串（无 TLS，与原内网口径一致）。应用日志实证 `using PostgreSQL as database` + `using MySQL as database`，0 错误。
- sg（ns new-api：new-api-ph-standby）：日志库 → MySQL 公网串 **`?tls=skip-verify`**。
- 应用自动建表：`logs` + `audit_logs`（AutoMigrate）。
- ⚠ `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`（ConfigMap）保留不删：仅 CK 生效，回滚时仍需要。

## ⚠ 知情偏离（备站 TLS）
MySQL 客户端 `VERIFY_IDENTITY` 报 `CA certificate is required` ⇒ 阿里云端证书不在系统信任链；go-sql-driver DSN 不支持自定义 CA（需上游代码 `RegisterTLSConfig`，违反铁律①）⇒ sg 采用 **`tls=skip-verify`**（传输加密保留、身份校验关闭）。**回滚/升级路径**：若要求强校验，需上游改造支持 custom CA。

## 脚本（本目录）
- `provision.sh`：白名单 + 公网端点 + 建库建号授权（幂等重试）
- `switch.sh <mnl|sg> <switch|probe>`：DSN patch + 滚动重启 / MySQL 连通探针（probe 用目标 DSN 预检；切后可看 log_rows）
- `verify.sh`：应用日志核验（DB 选择行 + DB 错误扫描）
- `wait_running.sh`：实例创建轮询

## 回滚（单条链路，CK 实例保留至稳定 3-7 天）
```bash
# 例：sg 回滚到 CK（mnl 同理换 mnl 与 MYSQL_LOG_DSN_MNL）
DSN_OVERRIDE=/root/.deploy_secrets/CK_LOG_DSN_sg bash deploy/tasks/task58_log_mysql/switch.sh sg switch
```
CK 回滚稳定后释放实例：`cc-5tsv2o51s1360b0pr`（按量释放即停计费），释放后跑 `deploy/ops/gen_cost_table.py --apply` 更新成本表。

## 遗留
1. **余额告急**：2026-10-15 15:0x 实测 **$44.51**（包月 MySQL 已扣 $133.06）；充值未到账 → 生产随时欠费停机。
2. CK 实例未释放（回滚窗口）；释放后成本表需更新（生产两站预计 4,301.55 → 3,352.17 USD/月）。
3. 数据迁移：本次**未迁移** CK 存量日志（90 天历史留 CK 内，未导出）；如需保留先从 CK 导出再释放。
4. 清理自动化：logs 表 TTL 需运维侧定期调管理台「清理历史日志」或外部 cron（MySQL 批删原生生效，system_task 可直接用）。
