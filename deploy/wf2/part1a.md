## Day 1 · 泳道 B：数据库、缓存、对象存储与跨区数据链路

> 基线参数（浓缩自 §2.1/§2.2，本泳道全程照此执行）：主 region `ap-southeast-6`（仅 6a/6b 两个可用区），备 region `ap-southeast-1`（**不部署任何数据库**）；服务端口 3000；账号 `5108890064395960`。
> **真实网络 ID（实测确认，覆盖 v2.1 文档占位）**：马尼拉 VPC `vpc-5tst1tgeessxn1azwasg2`（交换机 `vsw-mnl-data-a` `10.0.48.0/20`、`vsw-mnl-data-b` `10.0.64.0/20` 供 RDS/Tair）；新加坡 VPC `vpc-t4nimmwvruexbnene0a3r`。应用网段 `10.0.16.0/20`（6a）/`10.0.32.0/20`（6b）。
> **配额 API 实测坑（适用于本泳道全部资源申请）**：调用配额中心 API 必须带 `--Dimensions.1.Key regionId --Dimensions.1.Value <地域>`，否则返回 cn-hangzhou 的配额；审批通过的状态值是 `Agree`（不是 Approved）；申请量参数拼写是 `--DesireValue`；**Tair/RDS 配额需在产品开通后复查**（ECS 配额已批：马尼拉 64 / 新加坡 96）。
> 所有密码、DSN、连接串一律以 `${PLACEHOLDER}` 出现，真实值只进**密钥管理服务（凭据管家）**，经 ExternalSecret 注入集群，严禁落盘 Git/CI 变量。

### Day 1 · 任务 4｜马尼拉 RDS PostgreSQL 高可用版（人员B，2 人时，S1）

**前置/状态**：G1–G13 门禁已过；RDS 配额已确认（用上述带 regionId 维度的配额命令复查，状态 `Agree`）。产品：**云数据库 RDS PostgreSQL 版**。

**操作步骤（CLI-first）**：

1. 先验证可买性（决定后续一切，不要跳）：

```bash
# 0. 先复查 RDS 配额（实测坑：不带 regionId 维度会返回 cn-hangzhou 的配额）
aliyun quotas ListProductQuotas --ProductCode rds --QuotaCategory CommonConfig \
  --RegionId ap-southeast-6 | jq '.Quotas[]|{QuotaActionCode,TotalQuota}'
aliyun quotas GetProductQuota --ProductCode rds --QuotaActionCode <code> \
  --Dimensions.1.Key regionId --Dimensions.1.Value ap-southeast-6 \
  | jq '{Status: .QuotaInfo.Status, TotalQuota: .QuotaInfo.TotalQuota}'   # 期望 Status=Agree
# 1. 验证可买性（决定后续一切，不要跳）
aliyun rds DescribeRegions --RegionId ap-southeast-6 \
  | jq -r '.Regions.RDSRegion[]|.ZoneId' | sort -u
```

期望输出：可用区列表含 `ap-southeast-6a`/`ap-southeast-6b`。

```bash
aliyun rds DescribeAvailableClasses --RegionId ap-southeast-6 --ZoneId ap-southeast-6a \
  --Engine PostgreSQL --EngineVersion 15.0 --DBInstanceStorageType cloud_essd \
  --InstanceChargeType Postpaid --Category HighAvailability | jq '.DBInstanceClasses'
```

期望输出：非空规格列表（形如 `pg.x4.2xlarge.2c`，≈16C/64G）。空结果依次换 `EngineVersion` 14.0/15.0/16.0、`StorageType` cloud_essd/cloud_essd2、`Category` HighAvailability/Basic。

2. 创建实例（CLI 为主路径；规格/多可用区以购买页列表为准，购买页核对标【控制台】）：

```bash
aliyun rds CreateDBInstance --RegionId ap-southeast-6 \
  --Engine PostgreSQL --EngineVersion <上一步实测版本> \
  --DBInstanceClass <实测规格> --DBInstanceStorage <GB> --DBInstanceStorageType cloud_essd \
  --Category HighAvailability --ZoneId ap-southeast-6a --ZoneIdSlave1 ap-southeast-6b \
  --VPCId vpc-5tst1tgeessxn1azwasg2 --VSwitchId <vsw-mnl-data-a ID> \
  --InstanceNetworkType VPC --PayType Postpaid
```

期望输出：`{"DBInstanceId":"pgm-...", ...}`。【控制台】购买页复核「多可用区部署（主 6a/备 6b）+ 不勾选外网地址（任务 15 再开）」。
`[图 D1-B-4｜拍摄对象：RDS 购买页多可用区部署与不勾外网地址选项；打码：账号 ID、订单金额]`

3. 记下 `${RDS_MNL_ID}` 供后续全部任务卡引用；按 §2.3 补标签 `project=new-api site=ph-mnl env=prod`。

**验证方法**：

```bash
aliyun rds DescribeDBInstanceAttribute --DBInstanceId ${RDS_MNL_ID} \
 | jq '.Items.DBInstanceAttribute[0]|{Engine,EngineVersion,Category,MasterZone,SlaveZone,DBInstanceClass,DBInstanceStorageType}'
# 期望：Category=HighAvailability，MasterZone/SlaveZone=6a/6b
# 连通性必须从同 VPC 跳板机执行（不要本地直连内网）：
psql "host=<内网连接串> port=5432 dbname=postgres user=${ACCT} sslmode=require" -c "select version();"
# 期望：PostgreSQL <实测版本> ...（把输出回填方案表作为交付基线）
```

**不通过时修复**：
- `DescribeAvailableClasses` 返回空 → 换 EngineVersion/StorageType 再查；仍空 = 马尼拉不卖该组合 → 降版本或改地域。
- 购买页无「多可用区部署」→ 该地域/引擎未开多可用区 → 退化为单可用区 + 强备份，并**书面记录 SLA 降级**（RDS 高可用是 99.95% 最低配置之一，方案 R17）。
- 实例 Running 但连不上 → 九成是白名单默认 `127.0.0.1` 拒绝一切（见任务 13 坑 1），先配白名单再排网络。
- `InsufficientResourceCapacity` → 换可用区/换同族相邻规格；仍不行提工单查库存。

**坑**：
- 坑 1｜PG 版本以购买页为准：方案写"选 15"，国际站海外地域滞后。**后果**：文档承诺 16、实建 14，依赖新特性的 SQL/迁移踩空。**改进**：`select version();` 输出回填方案表作为交付基线。
- 坑 2｜主备切换闪断约 30 秒。**后果**：应用未配重连时表现为一波集中 5xx。**改进**：D7 必做一次主动 HA 切换演练（`aliyun rds SwitchDBInstanceHA --DBInstanceId ${RDS_MNL_ID}`），验证客户端自动重连与成功率曲线。
- 坑 3｜连接串被写死在 CI 变量/Git。**后果**：实例释放重建后连接串变，全站启动失败。**改进**：一律 KMS + ExternalSecret 注入。
- 坑 4｜"Running" ≠ "可连"：创建需 1–10 分钟。**改进**：验收以 `psql` 实际连通为准。

### Day 1 · 任务 13｜RDS 账号与权限最小化（人员B，1 人时，S2）

**前置/状态**：任务 4 实例 Running。三账号一主库：`newapi_migrate`（master 专用，含 DDL）、`newapi`（stable/canary 运行账号，仅 DML）、`newapi_sg`（备 region 运行账号，仅 DML）；高权限账号只留运维/DMS，**绝不写进任何 DSN**。

**操作步骤（CLI-first）**：

```bash
# 1. 建库与账号（密码从 KMS 生成占位，创建后立刻把真实值写入凭据管家，不落 shell 历史）
aliyun rds CreateDatabase --DBInstanceId ${RDS_MNL_ID} --DBName newapi \
  --CharacterSetName UTF8 --AccountPrivilege ReadOnly
aliyun rds CreateAccount --DBInstanceId ${RDS_MNL_ID} --AccountName newapi_migrate \
  --AccountPassword ${PW_MIGRATE} --AccountType Normal
aliyun rds CreateAccount --DBInstanceId ${RDS_MNL_ID} --AccountName newapi \
  --AccountPassword ${PW_APP} --AccountType Normal
aliyun rds CreateAccount --DBInstanceId ${RDS_MNL_ID} --AccountName newapi_sg \
  --AccountPassword ${PW_SG} --AccountType Normal
# 若任务 9 决策为方案 C，另建 newapi_log 库
```

期望输出：各命令返回 `RequestId`。复核账号与库：

```bash
aliyun rds DescribeAccounts --DBInstanceId ${RDS_MNL_ID} \
  | jq -r '.Accounts.DBAccount[]|[.AccountName,.AccountType,.AccountStatus]|@tsv'
# 期望三行：newapi_migrate/newapi/newapi_sg 均 Normal、Available；高权限账号不在任何 DSN 中
aliyun rds DescribeDatabases --DBInstanceId ${RDS_MNL_ID} | jq -r '.Databases.Database[].DBName'
```

【控制台】账号管理页确认创建时绑定的授权库为 `newapi`（DML 账号勾选只读/读写，不给结构权限）。
`[图 D1-B-13｜拍摄对象：账号列表与授权库下拉（migrate=读写、app/sg=DML）；打码：账号名后缀]`

2. 权限落地（用高权限账号经 DMS/psql 执行 SQL）：

```sql
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT, CREATE, USAGE ON SCHEMA public TO newapi_migrate;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO newapi;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO newapi_sg;
GRANT USAGE ON SCHEMA public TO newapi, newapi_sg;        -- 注意：不给 CREATE
```

3. **建实例的同一分钟配好白名单**：【控制台】或 `aliyun rds ModifySecurityIps` 内网组绑 `sg-mnl-app` 安全组（比 IP 列表可维护），网段用 `10.0.16.0/20,10.0.32.0/20` + 节点网段。
`[图 D1-B-13｜拍摄对象：白名单命名组与安全组绑定；打码：具体公网 IP]`

**验证方法**：

```bash
psql "<newapi DSN>" -c "CREATE TABLE _t(x int);"          # 期望：permission denied for schema public
psql "<newapi_migrate DSN>" -c "CREATE TABLE _t(x int); DROP TABLE _t;"   # 期望：成功
psql "<newapi_sg DSN>" -c "INSERT INTO users(id) VALUES(-1) ON CONFLICT DO NOTHING;"  # 期望：成功
```

**不通过时修复**：
- 一切连接超时 → 白名单默认组 `127.0.0.1` 拒绝一切（坑 1），先复核 `aliyun rds DescribeDBInstanceIPArrayList`。
- AutoMigrate 报 `permission denied for schema public` → PG15+ 的 public schema 权限变化（坑 4），确认 `GRANT ... TO newapi_migrate` 已执行且账号无误。
- `newapi` 能建表 → `REVOKE CREATE ON SCHEMA public FROM PUBLIC` 未生效，重跑第 2 步 SQL。

**坑**：
- 坑 1｜白名单默认分组 `127.0.0.1` 含义是"拒绝所有"而非"允许本机"。**后果**：实例建好后一切连接超时，容易误判为网络/安全组问题，白查一小时。**改进**：建实例同一分钟配好白名单，内网绑安全组。
- 坑 2｜两 region 共用同一账号（方案 R18 禁止）。**后果**：凭据泄露面翻倍、无法按 region 撤权、轮换没法分批。**改进**：分账号 + KMS 两个独立 Secret，轮换错开。
- 坑 3｜迁移账号 ≠ 运行账号：DDL 权限只给 master，备 region 误以 master 启动时数据库直接拒绝它改 schema。**后果**：把方案 R19 红线从"靠约定"升级为"靠强制"——防"并发迁移 → 锁表/数据损坏"最有效的一招。
- 坑 4｜PG15+ `public` schema 权限变化，且只在部分 RDS 版本/参数下出现。**改进**：建完账号立刻跑一次真实 AutoMigrate 冒烟，不要等到 D4。

### Day 1 · 任务 14｜RDS 备份策略 PITR 7 天 + WAL（人员B，1 人时，S2）

**前置/状态**：任务 4/13 完成。目标：数据备份保留 7 天（方案 R17 口径；范围 7–730，建议 30 天更稳）、日志备份（WAL）必开（PITR 前提）、备份窗口 UTC+8 18:00–19:00（马尼拉低峰，按实际调）。本卡在任务 15（开公网）之前完成：备份不可用时不得推进网络暴露面。

**操作步骤（CLI-first）**：

```bash
aliyun rds ModifyBackupPolicy --DBInstanceId ${RDS_MNL_ID} \
  --BackupRetentionPeriod 7 --EnableBackupLog 1 --LogBackupRetentionPeriod 7 \
  --PreferredBackupTime "10:00Z-11:00Z" --BackupLog "1"
```

期望输出：`RequestId` 正常返回。注意 `PreferredBackupTime "10:00Z-11:00Z"` 即 UTC+8 18:00–19:00（UTC 表示）；若容量允许，`--BackupRetentionPeriod` 直接取 30（建议口径），并同步放大 `LogBackupRetentionPeriod`。触发一次手动备份验证链路：

```bash
aliyun rds CreateBackup --DBInstanceId ${RDS_MNL_ID} --BackupMethod Physical
# 期望：返回 BackupJobID；稍后 DescribeBackups 出现 BackupStatus=Success 记录
```

策略变更命令可重复执行（改→验→再改确认幂等），避免在实例变配窗口内下发。

跨地域备份（马尼拉→新加坡）是否支持需【控制台核实】：备份恢复页看跨地域备份开关；不支持则改用 DBS（数据灾备）或逻辑备份到 OSS + 跨区域复制（任务 8 的 CRR 通道已实测可用，可直接复用）。
`[图 D1-B-14｜拍摄对象：跨地域备份可选项与备份策略页；打码：账号 ID]`

> **⚠ 现实约束（实测确认）**：ESSD 云盘实例的备份文件**不能直接下载**（只有老本地 SSD 支持）；方案 R17 写的"每日全量 + WAL 归档 OSS"——**RDS 自动备份并不落在你自己的 OSS 里**。三选一写进方案：
> 1. 接受备份在 RDS 托管侧，用**恢复到新实例**做演练（够用、最省）；
> 2. **DBS（数据灾备 Database Backup）** 做物理/逻辑备份到 OSS + 跨区域复制到新加坡 → 满足"OSS 归档"字面要求；
> 3. 每周 `pg_dump` 到 OSS（DMS 定时任务），仅作离线合规副本。

选路线 2/3 时与任务 8 衔接：产物写入 `oss-newapi-mnl` 的 `rds-backup/` 前缀即可，CRR 规则已覆盖该前缀，自动复制到 `oss-newapi-backup-sgp`，无需另配跨区通道。

**验证方法**：

```bash
aliyun rds DescribeBackupPolicy --DBInstanceId ${RDS_MNL_ID} \
  | jq '{BackupRetentionPeriod,EnableBackupLog,LogBackupRetentionPeriod,PreferredBackupTime}'
# 期望：EnableBackupLog=1 且 BackupRetentionPeriod>=7
aliyun rds DescribeBackups --DBInstanceId ${RDS_MNL_ID} \
  | jq '.Items.Backup[]|{BackupId,BackupStartTime,BackupMethod,BackupStatus}' | head
# 期望：至少一条 BackupStatus=Success；手动备份任务进度可用 BackupJobID 复查：
aliyun rds DescribeBackupTasks --DBInstanceId ${RDS_MNL_ID} --BackupJobID ${JOB_ID} \
  | jq '.Items.BackupTask[]|{BackupStatus,BackupProgressStatus,ProcessId}'
```

+ 控制台备份恢复页**能看到可选时间点** = 方案 AB 列"有可恢复时间点"。可选时间点存在即代表 WAL 链路可用；若只能按备份集恢复、无时间点可选，按下方"不通过"第 2/3 条处理。恢复演练不在本卡（见任务 50 / 坑 1）。

**不通过时修复**：
- 无备份记录 → 窗口未到，`aliyun rds CreateBackup --DBInstanceId ${RDS_MNL_ID}` 手动验一次。
- `EnableBackupLog=0` → 日志备份被关（**PITR 不可用，RPO 立刻从分钟级掉到 24h 级**）→ 重开并等一个 WAL 周期再验。
- 恢复页只有备份集、无可选时间点 → WAL 上传未就绪或 `LogBackupRetentionPeriod` 短于数据保留 → 拉长 WAL 保留再等一个周期复核。
- 手动 `CreateBackup` 长时间不完成 → 实例正在变配/迁移/HA 切换中（`DescribeDBInstanceAttribute` 看 `DBInstanceStatus`）→ 等实例回 Running 再触发，勿并发多个备份任务。
- `DescribeBackupPolicy` 报错/空 → 实例尚未进入 Running（任务 4 坑 4"Running ≠ 可配"同理）→ 等创建收敛后重试。

+ 【控制台】"恢复到新实例"入口可选时间点覆盖近 7 天 = 本卡达标（正式 PITR 演练在任务 50）。

**坑**：
- 坑 1｜从没做过恢复演练：备份 ≠ 可恢复。**后果**：真出事才发现恢复要 4 小时/恢复实例连不上/数据不一致。**改进**：任务 50 做 PITR 恢复演练并回填实测 RPO/RTO，这是 M5 硬证据。
- 坑 2｜演练选"覆盖原实例"。**后果**：演练变事故。**改进**：一律恢复到新实例，验完删除；写进 Runbook 红字。
- 坑 3｜恢复耗时没有 SLA 承诺：64GB 级 PITR 需按 **1.5–4 小时**预算（快照 + WAL 回放）。**后果**：SLA 的"RTO ≤5min"在 region 级故障下根本不成立（方案 R26 承认，属排除项②）。**改进**：演练实测值写进 M5；客户不接受 → 唯一解是第三 region 主库（超本次范围，需重新立项）。

### Day 1 · 任务 7｜Tair 主备 4GB（人员B，1 人时，S3）

**前置/状态**：产品：**云数据库 Tair（兼容 Redis）**；配额需产品开通后复查（带 `--Dimensions.1.Key regionId`，状态 `Agree`）。规格：标准版（主从架构）4GB，多可用区 6a 主/6b 备，VPC `vpc-5tst1tgeessxn1azwasg2` + `vsw-mnl-data-a`，版本选页面可用的最高（5.0/6.0/7.0）。

**操作步骤（CLI-first）**：

```bash
# 1. 查可售规格（空结果换 InstanceType/EngineVersion）
aliyun r-kvstore DescribeAvailableResource --RegionId ap-southeast-6 --ZoneId ap-southeast-6a \
  --Engine Redis | jq '.SupportedEngines'
# 2. 创建主备实例（规格码以上一步列表为准，≈4GB 主从版）
aliyun r-kvstore CreateInstance --RegionId ap-southeast-6 --ZoneId ap-southeast-6a \
  --SecondaryZoneId ap-southeast-6b --VPCId vpc-5tst1tgeessxn1azwasg2 \
  --VSwitchId <vsw-mnl-data-a ID> --NetworkType VPC --InstanceClass <4GB规格码> \
  --EngineVersion <最高可售版本> --Password ${TAIR_PW} --InstanceName tair-mnl-newapi
# 3. 参数：maxmemory-policy 改 allkeys-lru，禁用危险命令
aliyun r-kvstore ModifyInstanceParameter --InstanceId ${TAIR_MNL_ID} \
  --Parameters '{"#no_loose_maxmemory-policy":"allkeys-lru","#no_loose_disabled-commands":"FLUSHALL,FLUSHDB,KEYS"}'
# 4. 白名单建组 mnl_app：Pod/节点网段
aliyun r-kvstore ModifySecurityIps --InstanceId ${TAIR_MNL_ID} \
  --SecurityIps "10.0.16.0/20,10.0.32.0/20" --ModifyMode Cover --DBInstanceIPArrayName mnl_app
```

期望输出：`InstanceId`（形如 `r-5ts...`）/ 各操作 `RequestId`。等实例进入 Normal 状态并复核多可用区：

```bash
aliyun r-kvstore DescribeInstanceAttribute --InstanceId ${TAIR_MNL_ID} \
  | jq '.Instances.DBInstanceAttribute[0]|{InstanceStatus,ZoneId,SecondaryZoneId,InstanceClass,Capacity}'
# 期望：InstanceStatus=Normal、SecondaryZoneId=ap-southeast-6b、Capacity=4096(MB)
```

【控制台】连接信息页复制内网地址（不要手拼），并确认页面显示的"可用区"为主备双区。
`[图 D1-B-7｜拍摄对象：Tair 连接信息页（内网地址+账号栏）；打码：实例连接串]`
DSN 中地址**从连接信息页复制**；真实密码只进 KMS 凭据管家，经 ExternalSecret 注入：

```
REDIS_CONN_STRING=redis://<user>:${TAIR_PW}@${TAIR_MNL_HOST}:6379/0
```

**验证方法**：

```bash
redis-cli -h ${TAIR_MNL_HOST} -p 6379 -a "<user>:${TAIR_PW}" ping            # 期望 PONG
redis-cli -h ${TAIR_MNL_HOST} -p 6379 -a "<user>:${TAIR_PW}" config get maxmemory-policy   # 期望 allkeys-lru
redis-cli -h ${TAIR_MNL_HOST} -p 6379 -a "<user>:${TAIR_PW}" config get maxmemory          # 期望 ≈4GB 对应字节数
redis-cli -h ${TAIR_MNL_HOST} -p 6379 -a "<user>:${TAIR_PW}" info clients | head
# 禁用命令复核（仅验证被拒，确认返回错误后才算生效；勿在未禁用前执行）：
redis-cli -h ${TAIR_MNL_HOST} -p 6379 -a "<user>:${TAIR_PW}" flushall      # 期望：命令被禁用报错，绝不允许成功
```

**不通过时修复**：
- `NOAUTH` → 自定义账号需 `user:password` 格式。
- `Could not connect` → 白名单没加真实来源 IP（Pod 私网 IP/节点 IP）；注意配额/实例状态复查用带 regionId 维度的命令。
- `-READONLY` → 连到了备地址，改主地址。

**坑**：
- 坑 1｜`maxmemory-policy` 默认 `volatile-lru`，而 new-api 大量 key 无 TTL。**后果**：内存满后无法淘汰 → 写入 OOM 报错 → 限流与缓存整体失效；若 `/readyz` 又把 Redis 当硬依赖，触发全站 Pod 重启风暴。**改进**：显式 `allkeys-lru` + **必须**先完成 G8 的"Redis 故障降级放行"。
- 坑 2｜为了"安全"给 Redis 开公网 + TLS。**改进**：只走 VPC 内网 + 白名单；TLS 主机名校验坑与 RDS 同源（任务 15），没必要时不要引入。
- 坑 3｜4GB 主备版承载限流 + token 缓存（方案 R20 自评"建议升级集群版"）。**后果**：热点分片、限流精度下降。**改进**：上线后看 `info stats` 命中率与 `instantaneous_ops_per_sec` 决定升配；转集群版前确认跨 slot 命令（`MGET`/事务/`SCAN`）在集群模式的限制。
- 提醒｜`GLOBAL_API_RATE_LIMIT` 默认 **360 次 / `GLOBAL_API_RATE_LIMIT_DURATION` 180s**（`common/init.go:124-125`）——WAF 的 CC 阈值要与它对齐且不更严，否则用户看到 WAF 拦截页而不是网关 429，客诉归因跑偏。

### Day 1 · 任务 8｜OSS Bucket（人员B，1 人时，S3）——已落地 ✅

**前置/状态**：**✅ 已落地，勿重做**，本卡只给复核命令。产品：**对象存储 OSS**。已建成：源桶 `oss-newapi-mnl`（马尼拉，标准存储，**ZRS 同城冗余**，私有 ACL，版本控制开启，前缀 `rds-backup/`、`actiontrail/`、`app-assets/`）；CRR 目标桶 `oss-newapi-backup-sgp`（新加坡，ZRS，版本控制），**跨区域复制已实测成功**。复核前提：RAM 主体凭证可用（`$CFG` 指向的操作配置，与任务 8 落地报告同一套）。
命名变更事实：原计划目标桶名 `oss-newapi-sgp` 在删桶后被其他账号短时抢占（桶名全局唯一，重建报 `BucketAlreadyExists`），改用 `oss-newapi-backup-sgp`——后续任何删桶/重建变更必须按"名字不可回收"对待。

> **生命周期修订事实（实测确认，覆盖 -ch.md 旧描述）**：原方案"30 天→低频访问 IA / 90 天→归档 Archive"被 **ZRS 双/多可用区冗余的产品限制否决**（ZRS 桶不支持转储到 IA/Archive 存储类型）。实际已落地规则为三条：**`backup-data-tiering` / `backup-audit-tiering` / `backup-cleanup`**（前缀分级 + 历史版本过期清理），而非按存储类型降级。原方案"NoncurrentVersion 30 天过期"由 `backup-cleanup` 承接。

**操作步骤（CLI-first）**（本卡只复核，勿重做）：

```bash
aliyun oss stat oss://oss-newapi-mnl            # 期望 RedundancyType=ZRS / ACL=private / Versioning Enabled
aliyun oss lifecycle oss://oss-newapi-mnl       # 期望三条规则 backup-data-tiering/backup-audit-tiering/backup-cleanup
aliyun oss replication oss://oss-newapi-mnl     # 期望到 oss-newapi-backup-sgp 状态 Doing/全量已完成
```

逐项复核（对齐落地报告的实际命令面，期望输出附后）：

```bash
$OSS api get-bucket-versioning --bucket oss-newapi-mnl -c $CFG          # 期望 Status=Enabled
$OSS api get-bucket-public-access-block --bucket oss-newapi-mnl -c $CFG # 期望 BlockPublicAccess=true
$OSS api get-bucket-lifecycle --bucket oss-newapi-mnl -c $CFG           # 期望三条规则 ID 齐全且 Enabled
$OSS api get-bucket-policy --bucket oss-newapi-mnl -c $CFG              # 期望 2 条 Allow（4 主体 / 3 前缀 + ListObjects 前缀条件）
$OSS api get-bucket-replication --bucket oss-newapi-mnl -c $CFG         # 期望 Destination/Location=oss-ap-southeast-1（必须带 oss- 前缀）
$OSS api get-bucket-referer --bucket oss-newapi-mnl -c $CFG             # 期望防盗链已开启（源站资源不被外链盗刷）
$OSS ls oss://oss-newapi-mnl/ --limited-num 20                          # 期望仅见 rds-backup/ actiontrail/ app-assets/ 三前缀
```

CRR 实测复核（写标记对象 → 到新加坡桶查）：

```bash
echo "d1b8-$(date +%s)" > /tmp/crr-marker.txt
$OSS cp /tmp/crr-marker.txt oss://oss-newapi-mnl/rds-backup/crr-marker.txt
# 等待同步窗口后：
$OSS ls oss://oss-newapi-backup-sgp/rds-backup/crr-marker.txt   # 期望对象存在
# 两侧均查不到 → 复制规则异常，按"不通过"第 4 条诊断；验完删除标记对象
```

**验证方法**（内网可达性，在同 VPC 跳板机执行；期望值均为"连通但无权限"，任何 2xx 都视为配置漂移）：

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://oss-newapi-mnl.oss-ap-southeast-6-internal.aliyuncs.com/
# 期望 403（能连通、无凭据），而不是 000/超时
# 匿名公网列举必须被拒（确认没有公共访问面）：
curl -sS -o /dev/null -w "%{http_code}\n" https://oss-newapi-mnl.oss-ap-southeast-6.aliyuncs.com/?list-type=2
# 期望 403（ACL=private + PublicAccessBlock 生效）
```

**不通过时修复**：
- `NoSuchBucket` → 桶名全局唯一冲突（历史教训：删桶后名字会被其他账号抢占，报 `BucketAlreadyExists`），换名。
- `000` → 内网 Endpoint 拼错或 ECS 不在同 region。
- 生命周期不生效 → 前缀规则与对象 tag 不匹配，`get-bucket-lifecycle` 比对规则 `Prefix`/`Tag` 与对象实际 key。
- CRR 标记对象未同步 → `get-bucket-replication` 看规则状态是否 `Doing`、对象 key 是否在复制前缀集内；规则被删后重建需等 `closing`（90–180 秒）结束再退避重试。

**坑**（落地时已按改进措施处理，复核确认）：
- 坑 1｜VPC 内应用走公网 Endpoint `oss-ap-southeast-6.aliyuncs.com` → 收公网流量费且更慢。**改进**：内网一律 `-internal`（流量免费）。
- 坑 2｜ACL 设公共读"方便静态资源"→ Bucket 内任何文件可被遍历（含误传备份/日志），OSS 数据泄露头号原因。**改进**：保持私有；公网静态访问走 DCDN + 回源或签名 URL。
- 坑 3｜开版本控制却没配 NoncurrentVersion 生命周期 → 历史版本无限堆积、存储费翻倍。**改进**：已由 `backup-cleanup` 规则处理（历史版本过期）。
- 坑 4｜备份与数据同 region → region 级故障时"数据和备份一起没"，PITR 承诺落空。**改进**：`rds-backup/`、`actiontrail/` 前缀已配 CRR 到新加坡桶——这是恢复演练有价值的前提。
- 补充（Bucket Policy 实测）：主体黑名单（"非本项目 RAM 主体"）在 Policy 求值时不生效，主体管控只能走 RAM 身份策略；Bucket Policy 只用于 Allow 授权 + 前缀范围。

### Day 1 · 任务 9｜日志库 ClickHouse 替代决策（人员B，2 人时，S1）——决策已完成 ✅

**前置/状态**：**✅ 决策已完成**，本卡只保留决策结论与复核。原方案要求"马尼拉 ClickHouse 社区版 24.8，2 节点"；2026-09 实测核实：**国际站云数据库 ClickHouse 支持地域列表不含马尼拉**（A0 不可行），日志表经分类**不含账类数据**。

> **决策结论（按决策树落定）**：
> - **主链路日志库 = 方案 A：新加坡云数据库 ClickHouse（≥2 节点）+ 跨区异步批量写**（落地在任务 29；云企业网或公网加白名单两条链路任选）。代价：每条日志 +60–90ms RTT，必须异步批量且写失败可降级。
> - **硬规则**：日志表含"账"类数据（额度、消费、充值、对账）→ 一律不能用 CK，只能选 C（RDS PG 独立库 `newapi_log`）或主库；CK 最终一致 + 异步写不满足资金对账可追溯要求。**是账的一律留主库并纳入 PITR 范围——本节真正红线。**
> - **代码事实修订（实测确认）**：new-api **主库不支持 ClickHouse**（`model/main.go:145` 仅 SQLite/MySQL/PostgreSQL），日志库是**独立 `LOG_SQL_DSN`**——"选 C 还是主库"的分支里 C 实际是把日志写入同一 RDS 实例的独立库，与主库争资源，不改变主库引擎。
> - 四路对比留档：

| 方案 | 延迟 | 运维负担 | 跨区流量费 | 一致性风险 | 适用前提 |
| --- | --- | --- | --- | --- | --- |
| A0 马尼拉 CK | 最低 | 中（托管） | 无 | 低 | 购买页能选到马尼拉（**2026-09 核实为否**） |
| **A 新加坡 CK（已选）** | +60~90ms/条 | 中（托管） | 有（云企业网或公网） | 低（日志可丢） | 日志异步批量写 + 写失败可降级 |
| B ACK 自建 CK | 低 | **高**（自运维备份/升级/扩容） | 无 | 中（副本少） | 团队有 CK 运维经验 |
| C RDS PG 独立库 | 低 | 低 | 无 | **中高**（与主库争资源） | 日志量可控且不含账类数据 |

各方案落地要点（备查，防止后续有人重开决策）：
- **A**：云数据库 ClickHouse → 社区版 → ≥2 节点 → VPC `vpc-t4nimmwvruexbnene0a3r`；端口 **8123(HTTP)/9000(native)**；白名单加调用方（马尼拉出口 EIP 或云企业网网段）。实例购买在任务 29 执行。
- **B**：`helm install ck <chart>` 到 `new-api-log` namespace，`StorageClass=alicloud-disk-essd`，副本 2，NetworkPolicy 限 app 段访问。
- **C**：RDS 建 `newapi_log` + 独立账号，按天声明式分区 + 定时 `DROP PARTITION`。

**操作步骤（CLI-first）**（决策已完成，本卡只复核）：

```bash
# 1. 复核地域结论：CK 购买页地域选择器能否选到菲律宾（马尼拉）【控制台核实】（截图清单第 14 项）
# 2. 复核决策落盘：确认 LOG_SQL_DSN 规划指向新加坡本地 CK（Day1 仅决策，实例在任务 29 购）
aliyun clickhouse DescribeDBInstances --RegionId ap-southeast-1 2>/dev/null | jq '.Data.TotalCount' || true
# （马尼拉侧应无 CK 可购；新加坡侧集群在任务 29 创建后此处应可见）
```

`[图 D1-B-9｜拍摄对象：云数据库 ClickHouse 购买页地域下拉（无马尼拉）；打码：账号 ID]`

TTL DDL 基线（CK 就绪后执行，版本以 `SELECT version()` 为准勿照抄 24.8，cluster 名以控制台给出为准）：

```sql
CREATE TABLE newapi_logs ON CLUSTER ck_clusters (
  ts DateTime64(3), request_id String, path String, status Int32,
  latency_ms Int32, tokens Int64, model LowCardinality(String)
) ENGINE = MergeTree() PARTITION BY toDate(ts) ORDER BY (toDate(ts), path, ts)
TTL toDate(ts) + INTERVAL 90 DAY DELETE;
```

**验证方法**（CK 实例就绪后在任务 29/35 执行，此处仅列复核项）：

```bash
curl -sS "http://<ck-host>:8123/?query=SELECT+version()"        # 以实际版本写 DDL，勿照抄 24.8
clickhouse-client --host <ck> --port 9000 --user <u> --password ${CK_PW} \
  --query "INSERT INTO newapi_logs VALUES ('2026-09-24 00:00:00.000','t1','/v1/chat',200,120,10,'gpt')"
clickhouse-client ... --query "SELECT create_table_query FROM system.tables WHERE database='newapi_logs'" \
  | grep -o "TTL.*"          # 期望含 TTL toDate(ts) + INTERVAL 90 DAY
clickhouse-client ... --query "SELECT count() FROM newapi_logs"  # 期望 ≥1（写入可见）
```

**降级验证（必做，方案 R21）**：故意把 CK 停掉 / DSN 填错 → new-api 仍能正常返回回答，只在日志里报错 → 才满足"写日志失败必须降级"。

**不通过时修复**（保留源文件全部分支，CK 到位后适用）：`Code: 210 Connection refused` → 白名单未含来源/未申请公网地址；`Replicated ... ZooKeeper required` → 社区版只能用服务自带 ZK，改非 Replicated 引擎或用控制台给出的 cluster 名；写了查不到 → 写的是本地表而非分布式表，写 Distributed 或 `SET insert_distributed_sync=1`；高频小批量写入很慢 → `SET async_insert=1, wait_for_async_insert=1`；TTL 没删数据 → 合并在后台，用 `OPTIMIZE TABLE ... FINAL` 或 `ALTER TABLE ... MATERIALIZE TTL` 验证。

**坑**：
- 坑 1｜照抄"社区版 24.8"：国际站可购版本可能是老版本。**改进**：以 `SELECT version()` 为准写 DDL 与依赖特性。
- 坑 2｜CK 在新加坡、应用在马尼拉、同步写日志：每请求 +60–90ms，TTFT 明显劣化，压测不可能达标；CK 抖动会通过日志路径拖垮主链路（"日志把业务打死"典型模式）。**改进**：日志写入异步 + 批量 + 有界队列 + 满了丢弃（而非阻塞）；日志写失败单独打点告警。
- 坑 3｜把计费/对账数据放进 CK：CK 通常不做备份，且分布式表异步写的最终一致会让对账出现缺口。**后果**：丢钱，比丢日志严重一个量级。**改进**：先分类"哪些是账、哪些是日志"，见上方硬规则。

### Day 1 · 任务 15｜开启 RDS 公网地址并把白名单收死（人员B，2 人时，S4）

**前置/状态**：数据线门槛任务。这是全方案最容易做成"看似安全、实则裸奔"的一步：公网地址一开，白名单填 `127.0.0.1` 等于谁都连不上，填 `0.0.0.0/0` 等于谁都能连——两种都错且无告警。

**操作步骤（CLI-first）**：

**Step 1 — 申请公网地址**：

```bash
aliyun rds AllocateInstancePublicConnection --RegionId ap-southeast-6 \
  --DBInstanceId ${RDS_MNL_ID} --ConnectionStringPrefix ${RDS_MNL_ID}pub --Port 5432
aliyun rds DescribeDBInstanceNetInfo --DBInstanceId ${RDS_MNL_ID} \
  | jq -r '.DBInstanceNetInfos.DBInstanceNetInfo[] | [.IPType,.ConnectionString,.Port] | @tsv'
# 期望两行：Inner / Public；记下 ${RDS_MNL_PUB}（国际站 PG 高可用版后缀通常 .pg.rds.aliyuncs.com）
```

**Step 2 — 先做 TLS 证书地址绑定决策，务必在开 SSL 之前定（P0-4）**：RDS 服务器证书 **CN/SAN 只绑定"开 SSL 时所选的那个连接地址"**，顺序不能反。`aliyun rds DescribeDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} | jq '{ssl_enabled:.SSLEnabled,conn_str:.ConnectionString,ca:.CAType}'`。三条路径（按推荐度）：

| 路径 | 做法 | 适用 | 代价 |
| --- | --- | --- | --- |
| **A（推荐）** | 开 SSL 时 `ConnectionString` 选**公网地址**；新加坡 `sslmode=verify-full` 直连公网 | 只有新加坡一个备 region | 内网串应用需另配证书；证书绑地址后**换地址必须重签** |
| B | CEN（云企业网）打通两 VPC，新加坡用内网串 + verify-full | 网络团队接受跨区专线成本 | 新增 CEN 实例+跨区带宽费（impl_deploy 7.10 未计入），需财务确认，工期 +0.5 天 |
| C | 新加坡侧 `sslmode=verify-ca`（只验签发链不验主机名） | 应急 | **必须书面记录残余风险并由架构负责人签字**，否则安全核查（任务 38）挂 |

按路径 A 开 SSL：

```bash
aliyun rds ModifyDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} \
  --ConnectionString ${RDS_MNL_PUB} --Port 5432 --SSLEnabled 1 --CaEnabled 0
# 换证书/换地址用同一命令重复调用（部分版本 CARequired 必填，报参数错就补 --CaEnabled 0 --RequireUpdate yes）
aliyun rds DescribeDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} | jq '.SSLEnabled'   # 期望 1
```

**Step 3 — 白名单三层，只放新加坡 4 个 NAT EIP**：

```bash
# 3.1 独立命名组：新加坡备站公网出口（禁止复用 default）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName sg_standby_eip \
  --SecurityIps "${SG_EIP_01}/32,${SG_EIP_02}/32,${SG_EIP_03}/32,${SG_EIP_04}/32" \
  --WhitelistNetworkType MIX
# 3.2 default 组显式设为不可命中（不是"看起来安全"的写法，而是确认无人复用）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName default --SecurityIps "127.0.0.1"
# 3.3 主站内网组：ACK Pod / 节点 / data 网段
#     （修订：原 -ch.md 此条含计划外网段 10.0.80.0/20 且漏了 app-a，已按 §2.2 网段规划更正）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName mnl_vpc --SecurityIps "10.0.16.0/20,10.0.32.0/20,10.0.48.0/20,10.0.64.0/20"
```

**Step 4 — 强制 TLS 只允许（PG 侧参数）**：`aliyun rds DescribeParameters --DBInstanceId ${RDS_MNL_ID} | grep -Ei "ssl|force"`；若存在 `requires_ssl`/`rds_enable_ssl` 类可改参数设为 1；不可改则记录为"仅靠客户端 sslmode + 白名单"两层控制。

**验证方法**：

```bash
# V1 公网 TLS 握手（在新加坡集群节点或同 region ECS 执行）
openssl s_client -connect ${RDS_MNL_PUB}:5432 -starttls postgres -servername ${RDS_MNL_PUB} 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# 期望：CN 或 SAN 中包含 ${RDS_MNL_PUB}
# V2 白名单正例：新加坡 NAT 出口能连
psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=verify-full sslrootcert=./apsaradb-ca.pem" \
  -c "select current_setting('server_version'), inet_server_addr(), now();"
# V3 白名单反例：非白名单 IP 必须被丢
timeout 8 psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=disable" -c "select 1"
# 期望：timeout / connection refused，绝不能返回 1 行结果
# V4 明文必须被拒（Step 4 生效时）
psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=disable" -c "select 1"
# 期望：FATAL: no pg_hba.conf entry for host ... no SSL
```

**不通过时修复**：
- `server certificate for "pgm-xxx.pg.rds.aliyuncs.com" does not match host name "pgm-xxxpub..."` → SSL 开在内网串上（P0-4 命中）→ 按路径 A `ModifyDBInstanceSSL --ConnectionString <公网串>` 重签再复核；无法改则临时 `verify-ca` 并走 C 的签字流程。
- `timeout` 且 `nc -vz` 也不通 → NAT SNAT 条目未覆盖新 Pod 网段或 EIP 不是登记那 4 个 → 在新加坡节点跑 `for i in 1 2 3 4 5; do curl -s https://ifconfig.me; echo; done`，把真实出口 IP 补进白名单组。
- 连上但 `inet_server_addr()` 返回内网地址 → 实际走了 CEN/对等，是好事，但验收记录要写清"实际路径"，否则 M4 证据链口径不一致。
- 白名单改了 10 分钟仍不生效 → 改的是只读实例白名单（不继承）→ 主实例 `DescribeDBInstances` 核对 `DBInstanceId`。

**坑**：
- 坑 1｜"127.0.0.1 = 禁止一切"是错觉：填后主站应用连不上，D3–D4 排障方向全错，误以为 RDS 故障。改进：白名单按用途分命名组（`mnl_vpc`/`sg_standby_eip`），每组有明确 owner；验收贴命名组截图而不是 default 组。
- 坑 2｜NAT EIP 会被换：某天新加坡突然连不上主库 → 备 region 静默失去接管能力，真正切换时才发现（RTO 直接爆）。改进：§11.3 备 region→马尼拉 TCP 拨测绑定"连接失败率"告警；EIP 解绑/重绑列入变更审批。
- 坑 3｜公网地址串一旦释放不能再拿回：应用配置、RDS 证书、上游白名单全要重配。改进：**永不释放公网串**；不需要外网访问时清空白名单即可。
- 坑 4｜公网串写进 Git 的 ConfigMap 明文：Git 历史不可撤销，安全核查直接判不合格。改进：DSN 只进 KMS 凭据管家。
- 坑 5｜白名单没加 `/32`：填 `47.x.x.x` 被规范成 `47.x.x.0/24` 意外放行整段。改进：一律显式 `/32`，用 `DescribeDBInstanceIPArrayList` 复核 CIDR 掩码。

### Day 1 · 任务 41｜PgBouncer / RDS 代理 + 连接数预算三不变量（人员B，3 人时，S4）

**前置/状态**：任务 4/13 完成，HPA 目标 16 副本。选型判据：RDS **数据库代理（Database Proxy）** 可开且只需连接收敛/读写分离 → 用托管代理（少一个自运维单点）；需要 transaction pooling 或代理不可用 → ACK 自建 PgBouncer 3 副本。**连接数预算必须从 ConfigMap 反向生成，不允许手填。**

**操作步骤（CLI-first）**：

1. 连接数预算三不变量（M1 收口判据，D7 HPA 16 副本时复验）：
   - **I-1** 应用侧 `sum(副本数 × SQL_MAX_OPEN_CONNS) ≤ 池 max_client_conn`
   - **I-2** 池侧 `sum(各库 default_pool_size + reserve_pool_size) ≤ RDS max_connections × 0.8`
   - **I-3** master 迁移路径**直连 RDS 不经池**，且直连余量单独预留
   三式同时成立 → 通过；否则只能三选一：升 RDS 规格 / 降应用 conns / 加池。
   > **事实修订（实测确认）**：`SQL_MAX_OPEN_CONNS` 的**代码默认值是 1000**（`model/main.go:212`，主库与日志库**各设一次**），不是方案估的 300；**预算计算必须用配置文件显式值而非代码默认**。按 16 副本算 I-1 = **16000 > max_client_conn 4000**。现象反直觉：HPA 扩容后反而报 `FATAL: sorry, too many clients already`，**扩容变成加重故障的动作**。

```bash
# 从 ConfigMap 反向生成预算（真实值来源，不手填）
kubectl -n new-api get cm newapi-config -o jsonpath='{.data.SQL_MAX_OPEN_CONNS}'
psql "<migrate DSN>" -c "SHOW max_connections;"   # 记录真实上限（用户不可改）
```

2. 自建 PgBouncer 关键配置（完整清单参考 `impl_deploy.md §7.4.5.3`；ini 经 Secret 挂载，密码走 KMS/ExternalSecret）：

```ini
[databases]
newapi = host=<rds-internal> port=5432 dbname=newapi
[pgbouncer]
pool_mode = session            ; ⚠ 兼容性未验证前先用 session
listen_addr = 0.0.0.0
listen_port = 6432
max_client_conn = 4000
default_pool_size = 40
min_pool_size = 5
reserve_pool_size = 10
reserve_pool_timeout = 3
query_wait_timeout = 120
server_reset_query_always = 0
ignore_startup_parameters = extra_float_digits,options
admin_users = pgb_admin
```

配 3 副本 Deployment + Service（ClusterIP 5433→6432）+ PDB `minAvailable: 2` + 跨可用区反亲和 + KMS 注入 Secret；PgBouncer 不接公网。

**验证方法**：

```sql
-- PgBouncer admin 库
SHOW POOLS;    -- cl_waiting 长期 0；sv_active < default_pool_size
SHOW STATS;    -- max_wait_us 不持续增长
-- RDS 侧
SHOW max_connections;                                     -- 不可用户改，只能升规格
SELECT count(*) FROM pg_stat_activity;                    -- 必须 ≤ max_connections × 0.8
SELECT state, count(*) FROM pg_stat_activity GROUP BY 1;  -- idle 不应大量堆积
```

+ HPA 扩到 16 副本期间重复上述观测，PG 连接数不撞上限。

**不通过时修复**：
- `cl_waiting` 持续 >0 → `default_pool_size` 太小则调大；或慢查询长期占用服务端连接（查 `pg_stat_activity` 中 `xact_start` 很老的）。
- `query_wait_timeout` 报错 → 池饱和先提 `reserve_pool_size`；**真正根因常在应用侧 `SQL_MAX_OPEN_CONNS` 太大**。
- DDL/迁移失败或怪异 → 迁移走了池 → 强制 master 直连（I-3）。
- `prepared statement already exists` / `SET` 不生效 → transaction 模式与会话语句冲突 → 改 `pool_mode=session` 或应用侧关 prepared statements。

**坑**：
- 坑 1（最隐蔽）｜transaction 模式下会话级状态泄漏：`SET`/`SET LOCAL`、prepared statements、advisory lock、`LISTEN/NOTIFY`、跨语句事务都会出错（方案 §7.4.5.4"兼容性红线"）。**后果**：计费/余额相关的偶发、不可复现错误——比宕机更可怕，因为它悄悄改数据。**改进**：① 默认 `pool_mode=session`（牺牲收敛保正确）；② 只有跑完**经池的三数据库矩阵 + 余额对账压测**后才允许切 transaction；③ 写进上线检查表（§14）。
- 坑 2｜PgBouncer 是新增全站单点（方案 R21）：池挂 = 所有副本连不上库 = 整站不可用，故障域从"节点级"放大到"全局"。**改进**：3 副本 + PDB + 反亲和；应用侧重连 + `RetryTimes`；预置"回退直连 DSN"应急开关并演练（§13.4）。
- 坑 3｜`SQL_MAX_OPEN_CONNS` 用了代码默认值 1000 且主库/日志库各一次：预算按 300 估 → 实际 1000×16=16000 → `too many clients already`，全站 5xx + **计费写入失败（资损）**。**改进**：DSN/env 必须显式给值，预算表从 ConfigMap 反向生成。
- 坑 4｜RDS `max_connections` 不可用户修改（方案 R38 说"三者对齐"，实际只能升规格）：以为调参数能救，白折腾。**改进**：预算不满足只有三条路（升规格/降 conns/加池），结论写回 G11 文档。
- 坑 5｜池的 TLS 与 `verify-full` 冲突：**分层策略**——应用→池 `verify-ca`/`require`（集群内网），池→RDS `verify-full`（内网 + 绑内网地址证书）。

### Day 1 · 任务 29｜新加坡本地 Tair / 日志库（人员B，2 人时，S5）

**前置/状态**：前移自原 D4。新加坡 VPC `vpc-t4nimmwvruexbnene0a3r`。Tair 配额复查用带 `--Dimensions.1.Key regionId --Dimensions.1.Value ap-southeast-1` 的配额命令（状态 `Agree`）。日志库按任务 9 决策 = 方案 A（新加坡云数据库 ClickHouse）。**禁止跨区用马尼拉 Tair**（缓存 RTT 放大，限流窗口失真）。

**操作步骤（CLI-first）**：

```bash
# 1. 新加坡 Tair 主备 4GB（同任务 7 流程，换 region/VPC）
aliyun r-kvstore CreateInstance --RegionId ap-southeast-1 --ZoneId ap-southeast-1a \
  --SecondaryZoneId ap-southeast-1b --VPCId vpc-t4nimmwvruexbnene0a3r \
  --VSwitchId <vsw-sg-data ID> --NetworkType VPC --InstanceClass <4GB规格码> \
  --Password ${TAIR_SG_PW} --InstanceName tair-sg-newapi
aliyun r-kvstore ModifyInstanceParameter --InstanceId ${TAIR_SG_ID} \
  --Parameters '{"#no_loose_maxmemory-policy":"allkeys-lru"}'
# 2. 云数据库 ClickHouse（社区版 ≥2 节点，VPC 新加坡；端口 8123(HTTP)/9000(native)；
#    白名单加调用方：马尼拉出口 EIP 或云企业网网段）
# 3. LOG_SQL_DSN 各 region 指向本地日志库（真实值入 KMS）；日志采集：
#    logtail-ds + 日志服务 SLS 的 sls-newapi-sg，/app/logs/*.log 与 stdout 双路（stdout 兜底）
```

【控制台】CK 实例创建仅购买页可完成：社区版、≥2 节点、专有网络 `vpc-t4nimmwvruexbnene0a3r`；建好后可用 `aliyun clickhouse DescribeDBInstances --RegionId ap-southeast-1` 复核状态。
`[图 D1-B-29｜拍摄对象：CK 实例节点数与白名单配置页；打码：实例连接地址]`

期望输出：Tair 返回 `InstanceId`（`r-t4n...`）；CK 实例状态 Activated。CK 建表 + 写入按任务 9 的 TTL DDL 基线执行（`newapi_logs`，PARTITION BY toDate(ts)，TTL 90 天）。
SLS 采集复核：日志服务控制台确认 `sls-newapi-sg` 有 `/app/logs/*.log` 与 stdout 两路 Logtail 配置且近期有写入量。
`[图 D1-B-29b｜拍摄对象：Logtail 采集配置与 CK 集群节点数页；打码：实例地址]`

限流键设计：new-api 全局 API 限流走 Redis；跨区缓存会让主备两侧看到**不同计数器** → 接管瞬间限流形同虚设。要么接受"接管后限流重新计数"（并在 §12 记为已知行为），要么限流改走 PG 计数（成本高，不推荐）。

**验证方法**：

```bash
# V1 Tair 策略与连通
redis-cli -h ${TAIR_SG_HOST} -p 6379 -a "${TAIR_SG_PW}" CONFIG GET maxmemory-policy   # 期望 allkeys-lru
redis-cli -h ${TAIR_SG_HOST} -p 6379 -a "${TAIR_SG_PW}" info clients | grep connected_clients
# V2 限流在备站生效（不依赖主站 Redis；阈值 360 次/180s）
for i in $(seq 1 400); do curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer ${SG_TOKEN}" https://<SG_ALB>/v1/chat/completions \
  -H 'content-type: application/json' -d '{"model":"gpt-3.5-turbo","messages":[{"role":"user","content":"x"}]}'; done | sort | uniq -c
# 期望：出现足量 429
# V3 日志跨区不外写
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'echo "$LOG_SQL_DSN" | grep -o "tcp([^)]*)"'
# 期望：host 是新加坡本地 ClickHouse/PG 地址，不是马尼拉
# V4 CK HTTP 可达与版本
curl -sS "http://${CK_SG_HOST}:8123/?query=SELECT+version()"   # 期望返回实际版本号（勿照抄 24.8）
# V5 新加坡 Tair 多可用区与状态
aliyun r-kvstore DescribeInstanceAttribute --InstanceId ${TAIR_SG_ID} \
  | jq '.Instances.DBInstanceAttribute[0]|{InstanceStatus,ZoneId,SecondaryZoneId,Capacity}'
# 期望：Normal，双可用区（1a/1b），Capacity=4096
```

**不通过时修复**：
- `NOAUTH`/`Could not connect` → 同任务 7：账号 `user:password` 格式 / 白名单缺真实来源 IP。
- CK 连接拒绝（`Code: 210`）→ 马尼拉出口 EIP 未加白名单；写了查不到 → 写本地表未写分布式表（见任务 9 修复表）。
- V2 无 429 → 检查备站应用 `REDIS_CONN_STRING` 是否误指马尼拉 Tair。

**坑**：
- 坑 1｜Redis 不可用时应用 fail-closed：Tair 抖动 → 全站 429/503，实际服务完全正常——这正是 G8 要求"限流降级为放行而非拒绝"的原因。改进：G8 未合入前把"Tair 可用性"当 P1 依赖并加告警；预案见 §13.2。
- 坑 2｜`allkeys-lru` 误清非限流数据：new-api 会缓存渠道/用户配置，LRU 按最后使用时间清，包括业务缓存。后果：缓存雪崩打穿 PG。改进：限流键独立 Redis DB 或前缀 + `volatile-ttl`；配 Tair 内存告警 70%。
- 坑 3｜写日志失败拖垮请求线程。改进：日志写必须异步 + 失败丢弃计数（方案 AB 列已要求）；压测 V2 场景包含"kill 掉日志库"分支（§11.1）。

### Day 1 · 任务 30｜备 region → 马尼拉 RDS 公网读写打通与 RTT 实测（人员B，2 人时，S5）

**前置/状态**：前移自原 D7，作为 Day2 备集群前置。任务 15（公网 + SSL + 白名单）与任务 13（`newapi_sg` 账号）已完成；新加坡侧备站占位 Deployment 已可 exec。连接串 `${RDS_MNL_PUB}`，TLS 全链 `sslmode=verify-full`（路径 A 时证书绑公网串）。

**操作步骤（CLI-first，含 RTT/TPS 测量）**：

```bash
# 从新加坡 Pod 内测「建连 + 一次查询」总耗时（各 50 次，含 TLS 握手）
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c '
i=0
while [ $i -lt 50 ]; do
  t0=$(date +%s%N)
  psql "$SQL_DSN" -Atc "select 1" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 1000000 ))
  i=$((i+1))
done' | sort -n | awk '{a[NR]=$1} END{print "min="a[1]" p50="a[int(NR*0.5)]" p95="a[int(NR*0.95)]" max="a[NR]" (ms)"}'
# 更贴近真实：pgbench 单连接与 16 连接各跑 30s
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'pgbench -n -N -c 1  -T 30 "$SQL_DSN"'
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'pgbench -n -N -c 16 -T 30 "$SQL_DSN"'
# 网络层 RTT（ICMP 可能被过滤，通不通都要记录）
kubectl --context sg run rtt --image=nicolaka/netshoot --rm -it --restart=Never -- \
  ping -c 20 ${RDS_MNL_PUB}
traceroute ${RDS_MNL_PUB}
```

**判据（RTT 验收阈值，本指南口径，方案未量化）**：

| 指标 | 期望 | 不达标影响 |
| --- | --- | --- |
| TCP RTT（SG→MNL RDS） | ≤ 45 ms | 每个 SQL 往返一次，直接叠加到 P99 |
| `pgbench` 单连接 TPS | ≥ 20 | 低于此说明链路或 SSL 握手开销异常 |
| TLS 握手成功率 | 100% | 有失败即白名单/证书问题 |
| 建连平均耗时（含 TLS） | ≤ 200 ms | 决定连接池 `default_pool_size` 是否够 |

**验证方法**：

```bash
# V1 读写真的落在马尼拉主库（而不是本地某库）
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c \
  'psql "$SQL_DSN" -Atc "select inet_server_addr(), current_database(), version()"'
# 与主站内网查询结果比对：同 address（或同一实例）、同 db
# V2 数据一致性：主站写一条标记，备站立即读到（无复制延迟）
psql "$DSN_MIGRATE" -c "insert into ops_drill_marker(note) values ('from-mnl')"
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c \
  "psql \"\$SQL_DSN\" -Atc \"select note,ts from ops_drill_marker order by id desc limit 1\""   # 期望 from-mnl
# V3 连接数在预算内
psql "$DSN_MIGRATE" -c "select usename,state,count(*) from pg_stat_activity group by 1,2 order by 3 desc"
# newapi_sg 总数 ≤ 150 × 备站实际副本数，且 ≤ 预算 I-2
# V4 链路抖动时的应用行为（拔线测试）：临时把白名单里一个 EIP 移除
# → 观察是否有请求超时/5xx 上升，恢复后是否自愈
```

**不通过时修复**：
- TLS 证书不匹配（`does not match host name`）→ 回到任务 15 Step 2 路径 A 重签，或走 C 的 `verify-ca` 签字流程。
- 建连超时 → 按任务 15 修复表：NAT SNAT 未覆盖 / EIP 未登记，`for i in ...; do curl -s https://ifconfig.me; done` 核对真实出口。
- RTT > 45ms → traceroute 定位绕行链路；跨区链路无法优化时回到判据表重评接管后 SLA，并把结论书面记录。
- V3 连接数超预算 → 按任务 41 三不变量处理（降应用 conns 是唯一可当日完成项）。

**坑**：
- 坑 1｜把"延迟可接受"当成"SLA 成立"：常态不走备站所以没问题，但接管后 100% 请求跨区，P99 从 ~200ms 变成 ~400ms+，且每条 SQL 一次 RTT → 一次业务请求 3–5 条 SQL 就是 150–250ms 纯网络。改进：① §12 SLA 口径书面区分"主站延迟"与"接管后延迟"；② 应用侧减少同步 SQL 次数（G8：热配置走 Redis、额度写回批量化）；③ 接管前 `pgbench` 复测并留证据。
- 坑 2｜RTT 测了但没测"TLS + 连接建立"总成本：接管瞬间连接池冷启动，前 30 秒全部超时。改进：预热（§11.4）+ `default_pool_size` 调大 + 池预热脚本随 Deployment `initContainer` 跑。
- 坑 3｜白名单只有 4 个 EIP 但 SNAT 表项按 vSwitch 粒度：新加坡扩容出新 vSwitch/新节点时用未登记 IP 出口 → 偶发连不上。改进：白名单按 NAT 网关 SNAT 条目核对（`aliyun vpc DescribeSnatTableEntries`），并保证所有节点在登记 vSwitch 内。
- 坑 4｜DNS 解析出的 RDS 公网 IP 变更但应用连接池长期不重建：主备切换/实例迁移后仍连旧 IP，`Connection refused` 且不自愈。改进：GORM `ConnMaxLifetime` 设 ≤ 5min（必查：代码未设则作为 G8 需求）；PgBouncer `server_lifetime` 同理。

### Day 1 · 泳道 B 出口检查清单

- [ ] RDS 实例 `Category=HighAvailability`、主备 6a/6b，`select version()` 实测版本已回填方案表（任务 4）。
- [ ] 三账号权限边界实测通过：`newapi` 建表被拒、`newapi_migrate` 可 DDL、`newapi_sg` 可 DML；AutoMigrate 冒烟已过；白名单命名组已配且贴组截图（任务 13）。
- [ ] `DescribeBackupPolicy` 显示 `EnableBackupLog=1` 且 `BackupRetentionPeriod>=7`；备份恢复页可见可选时间点；跨地域备份结论已【控制台核实】并记录三选一路线（任务 14）。
- [ ] Tair `config get maxmemory-policy` = `allkeys-lru`，危险命令已禁用，`mnl_app` 白名单生效；G8 Redis 降级放行已合入（任务 7）。
- [ ] OSS 复核：ZRS + 私有 + 版本控制；三条生命周期规则 `backup-data-tiering`/`backup-audit-tiering`/`backup-cleanup` 在位；CRR 到 `oss-newapi-backup-sgp` 状态正常；内网 Endpoint 返回 403（任务 8）。
- [ ] 日志库决策记录在案：马尼拉 CK 不可购（截图第 14 项）、选方案 A、账类数据不入 CK、主库不支持 CK（`model/main.go:145`）已写入设计文档（任务 9）。
- [ ] 公网地址已申请且**永不释放**；证书 CN/SAN 含 `${RDS_MNL_PUB}`；白名单三层（`sg_standby_eip` 4×/32、default 不可命中、`mnl_vpc`）复核 CIDR 掩码；V1–V4 全通过（任务 15）。
- [ ] 三不变量 I-1/I-2/I-3 用 ConfigMap 真实值（非默认 1000）计算成立；`SHOW POOLS`/`pg_stat_activity` 达标；master 直连路径与回退直连应急开关演练过（任务 41）。
- [ ] 新加坡 Tair `allkeys-lru` 生效、备站限流出现足量 429、`LOG_SQL_DSN` 指向本地日志库（任务 29）。
- [ ] SG→MNL RTT ≤ 45ms、pgbench 单连接 TPS ≥ 20、TLS 握手成功率 100%、建连平均 ≤ 200ms；V1–V3 通过，V4 拔线自愈；实测值已回填接管 SLA 口径表（任务 30）。
- [ ] 所有新增 Secret 均已入 KMS 凭据管家并经 ExternalSecret 注入，仓库/CI/ConfigMap 明文中无任何密码或完整 DSN。
