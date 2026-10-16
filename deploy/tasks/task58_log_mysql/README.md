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

## 回滚（⚠ CK 已于 2026-10-15 释放 ⇒ 单条 DSN 切回不再可用）
```bash
# 原回滚方式（CK 存续期）：DSN 切回 + 滚动重启
DSN_OVERRIDE=/root/.deploy_secrets/CK_LOG_DSN_sg bash deploy/tasks/task58_log_mysql/switch.sh sg switch
```
CK 释放后如需回滚：**重建 CK 实例**（`CreateDBInstance`，Serverless 4 CU 起步 ≈$35.6/天）→ 从 `CK_LOG_DSN_{mnl,sg}` 留档恢复连接串口径 → 重建库 → `switch.sh` 切回。

## 收尾（2026-10-15 17:5x 全部完成 ✅）
1. ~~CK 未释放~~ → **CK `cc-5tsv2o51s1360b0pr` 已于 2026-10-15 17:4x 释放**（`clickhouse DeleteDBInstance`，按量即停计费）。⚠ **回滚路径随之降级**：CK DSN 留档文件仍可参考，但实例没了，真要回滚需**重建 CK**（重建 + 改 DSN + 重启）。
2. ~~存量日志导出~~ → **fanyan 裁定：无用户、日志可直接弃**（CK 内 90 天历史未导出，随实例释放销毁）。
3. ~~清理自动化~~ → **已完成**：
   - 一次性基线任务：system_task `log_cleanup`（task_id `systask_MVAW7KoPubr7ZaTjcO3YbQx73pdhnGDf`，target=30 天前，`deleted_count=0`，succeeded）；
   - 每月定期：**Windows 计划任务 `newapi-log-cleanup`**（每日 09:30 唤起）→ WSL `/usr/local/bin/newapi_log_cleanup.sh`（脚本自判每月 2 号执行，或距上次成功 ≥28 天兜底；调 `POST /api/system-task/log-cleanup?target_timestamp=<now-30d>`，日志落 `/var/log/newapi_log_cleanup.log`）。⚠ 该计划任务为「仅登录时运行」——fanyan 工作站长期在线即有效。
   - 凭据：root `access_token`（32hex，2026-10-15 经主库生成，等价管理台「生成访问令牌」）落 `/root/.deploy_secrets/ADMIN_API_TOKEN`（600）。**撤销方式**：管理台 root「撤销访问令牌」或 SQL 置空。
4. 成本表已重算：生产两站 **4,301.55 → 3,352.18 USD/月**（`gen_cost_table.py --apply`，impl_deploy/impl_tech §7.10 同步）。

## 遗留
1. ~~余额告急~~ → 当日充值 $2,000 已入现金余额（对公汇款），延停服务已开通；月度消耗仍需盯（日烧 ≈$110）。
2. sg `tls=skip-verify` 知情偏离维持现状；强校验需上游 custom CA 改造。
3. `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`（ConfigMap）保留不删：仅 CK 生效，若未来重建 CK 回滚仍需要。
