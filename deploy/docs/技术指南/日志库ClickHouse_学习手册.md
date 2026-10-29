# ClickHouse 日志库 · 学习手册（new-api 菲律宾部署）

> **定位**：讲清三件事 —— ① 这个工程为什么要有"独立日志库"、CK 在里面是什么角色；② 不用它会怎样；③ 怎么查里面的日志（含脚本与 SQL 速查）。
> **读者**：接手运维 / 排障 / 对账的人。
> **版本**：2026-10-09 整理；事实基线 = 指南 v2.0（2026-10-07 版）+ 2026-10-08 云侧实测。
> **口径**：任何一处与控制台/工单回答不一致，**以控制台 + 工单为准**。

---

## 目录

1. [一句话结论](#1-一句话结论)
2. [为什么需要"独立日志库"](#2-为什么需要独立日志库)
3. [CK 在工程里的角色（代码事实）](#3-ck-在工程里的角色代码事实)
4. [用 CK 的好处](#4-用-ck-的好处)
5. [不用 CK 会怎样](#5-不用-ck-会怎样)
6. [本部署的连接信息](#6-本部署的连接信息)
7. [怎么查日志：两条路](#7-怎么查日志两条路)
8. [表结构与 SQL 语义（CK vs PG）](#8-表结构与-sql-语义ck-vs-pg)
9. [常用 SQL 速查](#9-常用-sql-速查)
10. [安全纪律](#10-安全纪律)
11. [排障判据](#11-排障判据)
12. [附录：2026-10-08 实测记录](#12-附录2026-10-08-实测记录)

---

## 1. 一句话结论

**ClickHouse 在本工程里只干一件事：当日志库**（`LOG_SQL_DSN` 的一个可选实现）。

- **主库代码层面禁止用 CK** —— 遇到 CK DSN 直接报错；
- 选它不是为了"架构先进"，而是因为：在"主库 RDS PG 只有 2C8G / `max_connections=800` + 应用侧连接经托管 PgBouncer（`max_client_conn=2000`）"这个既定前提下，**日志库用 PG 会让连接预算数学上不成立**（3680 > 2000），换成 CK 才成立（1840 ≤ 2000）。详见 §4.2。

---

## 2. 为什么需要"独立日志库"

`logs` 表是「一行 / 请求」的**只追加型**数据，三个特征决定了它不该和计费主库混在一起：

| 特征 | 说明 |
|---|---|
| **体量最大** | 每次转发请求都写一条（成功走 `RecordConsumeLog`、失败走 `RecordErrorLog`）；`logs` 是增长最快的表 |
| **只追加、按时间查** | 几乎没有 UPDATE；查询形态 = "最近 N 条 + 按时间/用户/模型过滤 + `count()/sum()` 聚合" |
| **是对账与排障的底座** | 后台用量统计、RPM/TPM、额度对账、`request_id` 追单、审计留痕，全靠它 |

不拆出去的后果：`logs` 与计费事务抢 **CPU / IO / 锁 / vacuum / 备份窗口**，而主库只有 2C8G、盘 100G，备份（PITR 7 天 + 每日全量）的体积与耗时会被它主导。

> 所以"日志库"是一个**独立的连接池**：`LOG_SQL_DSN` 为空 → `LOG_DB = DB`（同库同池）；非空 → 另开一个池，可以指向另一个实例、甚至另一种数据库。

---

## 3. CK 在工程里的角色（代码事实）

### 3.1 只能当日志库，且靠 DSN 前缀判定

```120:125:model/main.go
func isClickHouseDSN(dsn string) bool {
	return strings.HasPrefix(dsn, "clickhouse://") ||
		strings.HasPrefix(dsn, "tcp://") ||
		strings.HasPrefix(dsn, "http://") ||
		strings.HasPrefix(dsn, "https://")
}
```

```143:149:model/main.go
		if isClickHouseDSN(dsn) {
			if !isLog {
				return nil, "", fmt.Errorf("%s does not support ClickHouse; use SQLite, MySQL, or PostgreSQL for the primary database and LOG_SQL_DSN for ClickHouse logs", envName)
			}
			common.SysLog("using ClickHouse as log database")
```

- 主库（`SQL_DSN`）：SQLite / MySQL ≥ 5.7.8 / PostgreSQL ≥ 9.6；
- 日志库（`LOG_SQL_DSN`）：上述三者 **+ ClickHouse**；
- 有测试兜底：`TestChooseDBRejectsClickHouseForMainDatabase`（`model/clickhouse_log_test.go`）。

### 3.2 两个库、两个池

```230:240:model/main.go
func InitLogDB() (err error) {
	if os.Getenv("LOG_SQL_DSN") == "" {
		LOG_DB = DB
		common.SetLogDatabaseType(common.MainDatabaseType())
		...
	}
	db, dbType, err := chooseDB("LOG_SQL_DSN", true)
```

`common.UsingLogDatabase(common.DatabaseTypeClickHouse)`（`common/database.go:40:42`）是全文所有 CK 分支的开关。

### 3.3 表结构由代码创建（不是 AutoMigrate）

```436:462:model/main.go
CREATE TABLE IF NOT EXISTS logs (
	id Int64 DEFAULT 0, user_id Int32 DEFAULT 0, created_at Int64 DEFAULT 0, type Int32 DEFAULT 0,
	content String DEFAULT '', username String DEFAULT '', token_name String DEFAULT '',
	model_name String DEFAULT '', quota Int32 DEFAULT 0, prompt_tokens Int32 DEFAULT 0,
	completion_tokens Int32 DEFAULT 0, use_time Int32 DEFAULT 0, is_stream UInt8 DEFAULT 0,
	channel_id Int32 DEFAULT 0, token_id Int32 DEFAULT 0, `group` String DEFAULT '',
	ip String DEFAULT '', request_id String DEFAULT '', upstream_request_id String DEFAULT '',
	other String DEFAULT ''
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(toDateTime(created_at))
ORDER BY (created_at, request_id)
TTL toDateTime(created_at) + INTERVAL N DAY DELETE
```

- 保留了 20 列，与 PG/MySQL 版 `Log` 结构同名同序（便于迁移与代码共用）；
- **月分区 + 内置 TTL** 是列存库给的额外能力：过期数据由后台自动删，不需要应用层定时 DELETE；
- TTL 天数取环境变量 `LOG_SQL_CLICKHOUSE_TTL_DAYS`（`model/main.go:413:419`；0/负数 = 不设 TTL）。**本部署 = 90 天**；
- 实例上 `SHOW CREATE TABLE` 实测引擎是 **`SharedMergeTree`**（企业版云原生共享存储变体），TTL 落为 `toIntervalDay(90)`。

审计表另有 DDL，且**故意不设 TTL**：

```241:255:model/audit_log.go
// MigrateAuditLogs also supports independently configured ClickHouse log stores.
// No TTL clause or usage-log cleanup integration is intentional.
... CREATE TABLE IF NOT EXISTS audit_logs ( ... other JSON ) ENGINE = MergeTree()
    PARTITION BY toYYYYMM(toDateTime(created_at)) ORDER BY (created_at, event_id)
```

⚠ 注意：`audit_logs.other` 是 CK 原生 **`JSON` 类型**，而 `logs.other` 是 **`String`（JSON 文本）** —— 两者取字段的写法不同（见 §8）。

### 3.4 写入点密集，但**失败可降级**

```101:104:model/log.go
func createLog(log *Log) error {
	ensureLogRequestId(log)
	return LOG_DB.Create(log).Error
}
```

```162:165:model/log.go
	err := createLog(log)
	if err != nil {
		common.SysLog("failed to record log: " + err.Error())
	}
```

⇒ **日志库抖动不会变成在线故障**（只打日志，不阻断用户请求）。这也是"CK 单 AZ 的故障域可以用『日志不入 SLA 证据链 + 写失败可降级』对冲"的代码依据。

### 3.5 代码里的 CK 适配分支（说明它不是"换 DSN 就完"）

| 位置 | 差异 | 处理 |
|---|---|---|
| `model/log.go:33:57` | CK 的 `LIKE` **不支持 `ESCAPE`** | 单写一套 `sanitizeClickHouseLikePattern`（`\_` 转义） |
| `model/log.go:140:148`、`:501:513`、`:595:597` | CK 无自增 `id` 语义，不能 `ORDER BY id desc` | 排序统一改 `created_at desc, request_id desc` |
| 同上 | 前端要有"页内序号" | 用 `assignDisplayLogIds` 造**显示用** id |
| `model/log.go:705:739` | CK 的 `DELETE` 是重写 data part 的 **mutation** | 不分批，一次性同步删（`SETTINGS mutations_sync = 1`） |
| `model/audit_log.go:120`、`:141:144` | 原生 JSON 类型需以文本 `Scan` | 加 `clickhouse.Settings` 上下文 |

---

## 4. 用 CK 的好处

### 4.1 通用收益（列存库本身）

| 收益 | 说明 |
|---|---|
| **压缩与存储便宜** | 列存 + MergeTree，String/数值列分开存，压缩比通常 5–10×；本部署还落在 OSS（`0.000044 USD/GB·h`） |
| **聚合统计快** | 后台"按用户/模型/渠道统计消耗、RPM/TPM、Top N"是 `count()/sum() + GROUP BY` 的全表性质扫描，列存比行存快 1–2 个数量级 |
| **TTL 自动过期** | `PARTITION BY toYYYYMM(...)` + `TTL ... DELETE`；行存库只能靠应用层分批 DELETE（PG 上删大表会带来膨胀 + vacuum 压力，见 `DeleteOldLogBatch` 的非 CK 分支） |
| **与主库解耦** | 日志写入/查询不抢主库 IO、锁、vacuum、连接；日志库挂了业务照跑（§3.4） |
| **单一收口** | 两站点（马尼拉 + 新加坡）写**同一个** CK 实例，不必在新加坡再买一套（F9 决策），日志查询口径唯一 |

### 4.2 本项目的**硬理由**：连接预算

主库是 **RDS PostgreSQL `pg.n4.2c.2m`（2C/8G）**，实测 `max_connections = 800` 且用户不可改 ⇒ 服务端可用预算封顶 `800 × 0.8 = 640`；应用侧客户端连接经 **RDS 内置托管 PgBouncer**（`max_client_conn = 2000`，端口 6432）。

应用侧 `SQL_MAX_OPEN_CONNS` 的取值（**一个值同时管主库与日志库**，代码里不存在 `LOG_SQL_MAX_OPEN_CONNS`）：
- 主站 100 / 副本；备站 10 / 副本（`env` 覆盖 CM，实测生效）。

| 日志库形态 | I-1 客户端连接账目 | 对 `max_client_conn = 2000` | 结论 |
|---|---|---|---|
| **日志库 = PG**（含独立 PG 实例） | 主库与日志库**各占一条**客户端连接 ⇒ 每副本翻倍：`16×200 + 24×20` | **3680 > 2000** | ❌ **不成立** |
| **日志库 = CK** | 日志连接走 CK 协议（8123/9000），**不占 PG 池额度** ⇒ `16×100 + 24×10` | **1840 ≤ 2000** | ✅ **成立** |

> F12 二次裁定后主站 `maxReplicas = 13`、备站接管上限 = 20 副本 ⇒ 实况是 `13×100 + 20×10 = 1500`（余量 500）；`16/24` 口径按"保守上界"保留、不重算。
> **一句话**：CK 是让这个不等式从"不成立"变成"成立"的那个开关。

---

## 5. 不用 CK 会怎样

**CK 完全可选** —— 不配 `LOG_SQL_DSN` 就是默认路径。所以"不用"不会让部署跑不起来，只会回落到下面三条路之一：

| 方案 | 代码可行性 | 代价 / 影响 |
|---|---|---|
| **A. 不配 `LOG_SQL_DSN`**（日志与主库同库） | ✅ 默认（`LOG_DB = DB`） | 连接不翻倍，但**全部日志写入/查询压在主库**：2C8G 同时扛计费 + 日志；`logs` 最大表 ⇒ 备份/PITR 体积与耗时上升；后台统计扫全表抢主库 CPU/IO；**无 TTL** ⇒ 必须自己跑定期清理任务 |
| **B. `LOG_SQL_DSN` 指向独立 PG/MySQL** | ✅ 官方支持的"独立日志库"路径 | **I-1 立刻不成立（3680 > 2000）** ⇒ 必须同时降 `SQL_MAX_OPEN_CONNS`、抬 `max_client_conn`、或让日志库绕开池；多一套实例的成本与运维面；PG 上仍需分批删日志；聚合仍是行存性能 |
| **C. 用 CK（现状）** | ✅ 已落地 | 连接预算成立 + 存储/聚合/TTL 优势；代价：引入新组件、马尼拉 **只有 6a 单 AZ**、**只有 OSS 存储**、**只有按量付费**（或 3 年预付不可退的计算资源包）、`NodeScaleMax` 默认 32 会放大成本上限、部分 SQL 语义需适配 |

**"不用"具体会缺哪些能力**（不是上线阻断，是能力缺口）：

- 管理端/用户端**日志列表与筛选**；
- **用量统计与额度对账**（任务 37/38）；
- **排障取证**（`request_id` / `upstream_request_id` 追单）；
- **审计留痕**（`audit_logs`）。

> 还有一个"连日志都不要"的极端开关：**配置项 `LogConsumeEnabled = false`**（`common/constants.go:94` 默认 `true`，运行时改 DB option 即可）会**直接停写消费日志**（`model/log.go:340:342`）。代价是彻底失去对账与排障能力 —— 只在压测/演练时临时用，不能当生产方案。

---

## 6. 本部署的连接信息

| 项 | 值 |
|---|---|
| 实例 | `cc-5tsv2o51s1360b0pr`（企业版 · 单可用区 `ap-southeast-6a` · OSS 存储 · 按量付费 · 2 节点 active） |
| 库 / 表 | `newapi_logs`.`logs`（20 列）· `newapi_logs`.`audit_logs` |
| 主站端点（VPC 私网） | `cc-5tsv2o51s1360b0pr-clickhouse.clickhouseserver.ap-southeast-6.rds.aliyuncs.com`（`10.0.54.122`） |
| 备站/外部端点（公网） | `cc-5tsv2o51s1360b0pr-public.clickhouseserver.ap-southeast-6.rds.aliyuncs.com`（`43.118.97.47`） |
| 端口 | **8123（HTTP）** / 9000（native）/ 8443 / 9004 / 9100 / 9440 |
| 账号 | `newapi`（应用用，`AllowDatabases=["newapi_logs"]`）/ `ckadmin`（权限更宽，查 `system.*` 需它） |
| 白名单 | `mnl_app` = `10.0.16.0/20` + `10.0.32.0/20`（马尼拉 app 段）；`sg_eip` = 新加坡 4 个 NAT EIP；默认 `127.0.0.1` |
| DSN | `clickhouse://newapi:<pw>@<host>:9000/newapi_logs`（**口令不入文档/仓库**） |
| 口令来源 | K8s Secret `new-api-secrets` → 键 `LOG_SQL_DSN`；明文只在 WSL 堡垒机 `/root/.deploy_secrets/LOG_SQL_DSN`（600） |
| 保留期 | `logs` = **90 天**（`LOG_SQL_CLICKHOUSE_TTL_DAYS=90`，生产实测 TTL 已生效）；`audit_logs` = **无 TTL** |

**两条端点口径（按站点分配，别写错）**：

- 主站（马尼拉）：必须 `-clickhouse.clickhouseserver`（**同区私网**，更省 NAT 流量）；
- 备站（新加坡）：必须 `-public.clickhouseserver`（**跨区公网**，2026-09-30 裁定③）；写错成 VPC 端点 ⇒ **跨区不可达、备站日志全丢**。

> ⚠ 已知陷阱：Secret 注入脚本 `deploy/tasks/task17/secret_inject.sh` 是**整键覆盖**写。若保管文件的 `LOG_SQL_DSN` 仍是 VPC host，跑一次 `--apply` 就会把 sg 已修正的 `-public` 悄悄退回 —— 脚本已加 `-public` 断言（不命中直接 die），但**改集群必须同批改真源**。

---

## 7. 怎么查日志：两条路

### 7.1 首选 —— 走应用接口（有字段可见性投影）

```313:320:router/api-router.go
		logRoute := apiRouter.Group("/log")
		logRoute.GET("/", middleware.AdminAuth(), controller.GetAllLogs)
		logRoute.GET("/stat", middleware.AdminAuth(), controller.GetLogsStat)
		logRoute.GET("/self/stat", middleware.UserAuth(), controller.GetLogsSelfStat)
		logRoute.GET("/self", middleware.UserAuth(), controller.GetUserLogs)
```

| 接口 | 鉴权 | 用途 |
|---|---|---|
| `GET /api/log/` | 管理员 | 全站日志分页列表（控制台「日志」页） |
| `GET /api/log/stat` | 管理员 | 汇总：`quota` / `rpm` / `tpm` |
| `GET /api/log/self`、`/self/stat` | 用户 | 只能看自己 |
| `GET /api/log/token` | Token（只读） | 按 token 查 |
| `GET /api/audit` | 管理员 + `authz.AuditRead` | 审计日志（表 `audit_logs`） |
| `GET /api/audit/self` | 用户 | 自己的审计 |
| `POST /api/system-task/log-cleanup` | Root | 按 `target_timestamp` 清理 |

**查询参数**（`start_timestamp` / `end_timestamp` 为**秒**级）：

`p` · `page_size` · `type` · `start_timestamp` · `end_timestamp` · `username` · `token_name` · `model_name` · `channel` · `group` · `request_id` · `upstream_request_id`

```bash
# 最近 1 小时的消费日志（type=2）
curl -sS "https://www.likha.hk/api/log/?p=1&page_size=50&type=2&start_timestamp=$(( $(date +%s) - 3600 ))&end_timestamp=$(date +%s)" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "New-Api-User: <ADMIN_USER_ID>"

# 按 request_id 追单（排障最常用）
curl -sS "https://www.likha.hk/api/log/?request_id=<RID>" -H "Authorization: Bearer <ADMIN_TOKEN>" -H "New-Api-User: <UID>"
```

> `/api/log/search` 与 `/api/log/self/search` **已废弃**（直接返回 `success:false`，`controller/log.go:63:77`），不要再用。

**为什么优先走接口**：`other` 字段里的 `admin_info`（含 `reject_reason`）/`root_info`/`audit_info`，以及 `channel_id`/`channel_name`/`channel_type`，在用户/管理员视角会被**按角色剥离**：

```229:249:model/log_other.go
	if visibility == logOtherVisibilityUser {
		for _, key := range []string{logOtherAdminInfoKey, logOtherRootInfoKey, logOtherAuditInfoKey} {
			if _, exists := values[key]; exists { delete(values, key); changed = true }
		}
		for _, key := range legacySensitiveLogOtherKeys { ... delete ... }
	} else {
		changed = normalizeLegacyRejectReason(values)
		if visibility == logOtherVisibilityAdmin { delete(values, logOtherRootInfoKey) ... }
```

⇒ **直连 CK 看到的是"原始未投影"数据（含 root_info），属特权视角**。

### 7.2 直连 ClickHouse（排障 / 对账 / 取数）

本机（办公网）**连不上**：白名单只有 `mnl_app` 两段 + `sg_eip` ⇒ 必须**从集群内**发起。

#### 通道 A（推荐）—— 仓内脚本 `deploy/ops/ck_query.sh`

已封装：取 Secret 凭据 → 端点口径断言 → 只读白名单 → SQL 经 base64 传递（引号/反引号/中文都不会被 shell 吃掉）→ HTTP 8123 重试 3 次 → 证据落 `deploy/logs/ck_query_<ts>/<site>.log`。

```bash
bash deploy/ops/ck_query.sh <mnl|sg|both> [options] "<SQL>"

# 常用
bash deploy/ops/ck_query.sh mnl --show-dsn                      # 只打印脱敏 DSN + 端点口径
bash deploy/ops/ck_query.sh mnl "SELECT count() FROM logs"      # 默认 TSV（带表头）
bash deploy/ops/ck_query.sh both --json "SELECT ... LIMIT 5"    # JSONEachRow
bash deploy/ops/ck_query.sh mnl -f query.sql                    # 从文件读 SQL
bash deploy/ops/ck_query.sh mnl --print-body "SELECT 1"         # 离线看远端脚本，不连集群

# options: -f/--file · --json · --raw · --db NAME · --timeout SEC · --show-dsn · --print-body
```

- **只读守卫**：首关键字白名单 `SELECT|WITH|SHOW|DESCRIBE|DESC|EXISTS|EXPLAIN`；`ALTER/DELETE/INSERT/...` 在 **HTTP 之前**就被拒（带 `[XX]`、退出码 1）；
- 它内部复用 `deploy/lib/ack_remote.sh`（云助手 + admin 私网 kubeconfig，在节点内执行）；
- 退出码：`0` 全 `[OK]` / `1` 出现 `[XX]`/`[!!]` / `2` 用法或环境错误。

> **环境前置**：`/tmp/ackctl-<site>` 若被历史 root 运行创建成 `root:root`，所有走 `deploy/lib/ack_remote.sh` 的脚本会写 body 失败（`PermissionError`）。脚本已自动降级到 `/tmp/ackctl-<site>-<user>`；永久修复：`sudo chown -R $USER /tmp/ackctl-mnl /tmp/ackctl-sg`。

#### 通道 B（可选）—— 原生 9000 + `clickhouse-client`

ACK 节点上没有该二进制，需要临时探针 Pod（口令同样从 Secret 注入、不回显）：

```bash
kubectl -n new-api run ckcli --rm -it --restart=Never \
  --image=clickhouse/clickhouse-client:latest \
  --overrides='{"spec":{"containers":[{"name":"ckcli","image":"clickhouse/clickhouse-client:latest","command":["sh"],"tty":true,"stdin":true,
    "env":[{"name":"LOG_SQL_DSN","valueFrom":{"secretKeyRef":{"name":"new-api-secrets","key":"LOG_SQL_DSN"}}}]}]}}' -- sh
```

> 客户端协议要够新（实例内核 `26.2.1.698_1`），用 `latest` 或 ≥ 25.x。
> 本仓已验证的路径是 **HTTP 8123**（`deploy/tasks/task17/dsn_verify.sh` 就用它做端到端鉴权）。

---

## 8. 表结构与 SQL 语义（CK vs PG）

### 8.1 `logs` 的 20 列

| 列 | 类型 | 说明 |
|---|---|---|
| `created_at` | Int64 | **Unix 秒**（不是毫秒）；分区键 `toYYYYMM(toDateTime(created_at))` |
| `id` | Int64 DEFAULT 0 | **恒为 0、无自增语义** —— 不要排序、不要当游标 |
| `type` | Int32 | 1 充值 / 2 消费 / 3 管理 / 4 系统 / 5 错误 / 6 退款 / 7 登录 |
| `user_id` / `channel_id` / `token_id` | Int32 | 维度键 |
| `content` / `username` / `token_name` / `model_name` | String | 文本维度 |
| `quota` | Int32 | 额度（`QuotaPerUnit` 默认 500000 ⇒ 1 USD = 500000） |
| `prompt_tokens` / `completion_tokens` | Int32 | token 数 |
| `use_time` | Int32 | 耗时（秒） |
| `is_stream` | UInt8 | 0/1 |
| `group` | String | **保留字**，引用要 `"group"`（或反引号） |
| `ip` | String | 客户端 IP |
| `request_id` / `upstream_request_id` | String | 追单主键；排序键第二列 |
| `other` | **String（JSON 文本）** | 见 §8.3 |

### 8.2 六个"CK 与 PG 不一样"（最容易踩）

1. **排序键是 `(created_at, request_id)`** ⇒ 查询**必须带时间范围**；只按 `user_id`/`model_name` 过滤 = **全表扫**（无二级索引）。
2. **排序不能写 `id desc`** —— 应用侧因此统一换成 `created_at desc, request_id desc`；直连时照抄。
3. **`LIKE` 不支持 `ESCAPE`** ⇒ 匹配字面 `%`/`_` 时必须 `\_`（这也是应用单写转义函数的原因）。
4. **`logs.other` 是字符串 JSON、`audit_logs.other` 是原生 `JSON` 类型** ⇒ 前者用 `JSONExtractString(other,'k')`，后者可用点号取值。
5. **TTL 90 天自动删** ⇒ 历史窗口只有 90 天；**`audit_logs` 反而不删**（无 TTL）。
6. **`DELETE` 是 mutation**（`ALTER TABLE … DELETE … SETTINGS mutations_sync = 1`）⇒ 别在库里频繁按条件删；应用侧清理任务在 CK 下是**一次性同步删**。

### 8.3 `other` 的三种可见性（写日志时就分好了）

| 键 | 谁能看 | 说明 |
|---|---|---|
| 顶层（公开） | 用户 / 管理员 / root | 如 `model_ratio`、`group_ratio`、`completion_ratio`、`cache_tokens`、`cache_ratio`、`model_price`、`user_group_ratio`、`frt`、`reasoning_effort`、`is_model_mapped`、`upstream_model_name`、`response_model`、`task_id`、`usage_semantic`… |
| `admin_info` | 管理员 / root | 如 `reject_reason` |
| `root_info` | 仅 root | 最敏感的调试信息 |
| `audit_info` | 审计 | 与审计链路相关 |

历史敏感键 `channel_id`/`channel_name`/`channel_type`/`reject_reason` 会被**剥离出用户视角**（`model/log_other.go:11:24`、`formatLogOtherJSON`）。

---

## 9. 常用 SQL 速查

> 前提：一律**带 `created_at` 区间** + `LIMIT`；`FROM logs` 即可（DSN 已指定 `newapi_logs`）。

```sql
-- 1) 最近 20 条消费日志
SELECT fromUnixTimestamp(created_at) AS ts, user_id, username, token_name, model_name,
       channel_id, "group", quota, prompt_tokens, completion_tokens, use_time, is_stream,
       request_id, upstream_request_id, ip
FROM logs
WHERE type = 2 AND created_at >= toUnixTimestamp(now() - INTERVAL 1 HOUR)
ORDER BY created_at DESC, request_id DESC
LIMIT 20;

-- 2) 单笔全链路（含上游 id + 失败原因）
SELECT fromUnixTimestamp(created_at) ts, type, user_id, model_name, channel_id, quota, use_time, content,
       JSONExtractString(other, 'admin_info', 'reject_reason') AS reject_reason,
       JSONExtractString(other, 'response_model', 'upstream_model') AS upstream_model
FROM logs
WHERE request_id = 'RID' OR upstream_request_id = 'RID'
ORDER BY created_at;

-- 3) 某用户某日消耗汇总
SELECT count() AS reqs, sum(quota) AS quota_sum,
       round(sum(quota) / 500000, 4) AS usd,          -- QuotaPerUnit 以配置为准，别硬编码
       sum(prompt_tokens + completion_tokens) AS tokens, avg(use_time) AS avg_sec
FROM logs
WHERE type = 2 AND user_id = 42
  AND created_at BETWEEN toUnixTimestamp('2026-10-08 00:00:00') AND toUnixTimestamp('2026-10-09 00:00:00');

-- 4) 模型 × 渠道 Top20（按额度）
SELECT model_name, channel_id, count() reqs, round(sum(quota)/500000, 2) usd
FROM logs
WHERE type = 2 AND created_at >= toUnixTimestamp(now() - INTERVAL 1 DAY)
GROUP BY model_name, channel_id ORDER BY usd DESC LIMIT 20;

-- 5) 错误日志 / 慢请求 / 流式占比
SELECT fromUnixTimestamp(created_at) ts, user_id, model_name, channel_id, content
FROM logs WHERE type = 5 AND created_at >= toUnixTimestamp(now() - INTERVAL 2 HOUR)
ORDER BY created_at DESC LIMIT 100;

SELECT quantiles(0.5, 0.95, 0.99)(use_time) AS p50_p95_p99
FROM logs WHERE type = 2 AND created_at >= toUnixTimestamp(now() - INTERVAL 1 DAY)
  AND model_name = 'gpt-4o-mini';

SELECT countIf(is_stream = 1) AS stream_reqs, count() AS total,
       round(100 * countIf(is_stream = 1) / count(), 1) AS pct
FROM logs WHERE type = 2 AND created_at >= toUnixTimestamp(now() - INTERVAL 1 DAY);

-- 6) 从 other 取计费明细
SELECT fromUnixTimestamp(created_at) ts, model_name,
       JSONExtractString(other,'model_ratio')      AS model_ratio,
       JSONExtractString(other,'group_ratio')      AS group_ratio,
       JSONExtractString(other,'completion_ratio') AS completion_ratio,
       JSONExtractString(other,'cache_ratio')      AS cache_ratio,
       JSONExtractInt(other,'frt')                 AS frt_ms
FROM logs
WHERE created_at >= toUnixTimestamp(now() - INTERVAL 1 HOUR) AND JSONHas(other,'model_ratio')
ORDER BY created_at DESC LIMIT 50;

-- 7) 数据量与磁盘（system.* 需权限更宽的账号 ckadmin，且要 --db system）
SELECT count() FROM logs;
SELECT partition, sum(rows) rows, formatReadableSize(sum(bytes_on_disk)) size
FROM system.parts WHERE database='newapi_logs' AND table='logs' AND active
GROUP BY partition ORDER BY partition;
SHOW CREATE TABLE logs;      -- 核对 TTL 是否 90 天生效

-- 8) 审计日志（无 TTL，可长期查；other 是原生 JSON 类型）
SELECT fromUnixTimestamp(created_at) ts, user_id, username, category, action, success, ip, route
FROM audit_logs
WHERE created_at >= toUnixTimestamp(now() - INTERVAL 1 DAY)
ORDER BY created_at DESC LIMIT 50;
```

跑法：

```bash
bash deploy/ops/ck_query.sh mnl "SELECT count() FROM logs"
bash deploy/ops/ck_query.sh mnl --json "SELECT fromUnixTimestamp(created_at) ts, model_name, quota FROM logs WHERE type=2 ORDER BY created_at DESC LIMIT 5"
```

---

## 10. 安全纪律

1. **不要把口令打进命令行**：`--user u:p` 会进 shell history / 会话记录。脚本里从 Secret 读、只回传结果。
2. ⛔ **禁用 `kubectl get secret … -o jsonpath='{.data}'`** —— 它会把 base64 全值打进输出（2026-10-06 已发生过一次泄露事件，事后脱敏 + 复扫）。取单键要写 `{.data.LOG_SQL_DSN} | base64 -d`。
3. **直连 = 特权视角**：能看到用户界面看不到的 `other.admin_info` / `other.root_info`；`audit_logs` 含 IP / UA（个人信息）⇒ 按最小必要取用并留痕。
4. **别在实例上跑重查询**：企业版按 CCU 计费，且实测 `NodeScaleMax=32`（计划是 8）⇒ 一次大范围 `SELECT *` 既拖 IO 也推高成本。生产查询一律带时间范围 + `LIMIT`。
5. **白名单加人 / 开公网端点属写操作**，走变更流程（不要随手 `ModifySecurityIPList`）。
6. **CK 的写入不是"必须成功"**：`createLog` 失败只记日志（§3.4）⇒ 出现"日志缺失但业务正常"时，先查 CK 连通性再查代码。

---

## 11. 排障判据

按序排查"查不到 / 查得慢"：

1. **确认走的是 CK 分支**：Pod 内 `echo $LOG_SQL_DSN`（应为 `clickhouse://…`）；启动日志有 `using ClickHouse as log database`。
2. **确认在写**：`SHOW TABLES` → `logs`；`SELECT count() FROM logs`。`count()=0` 且服务在跑 ⇒ 看第 3 条。
3. **消费日志开关**：`LogConsumeEnabled=false` 时**根本不写消费日志**（运行时配置项，默认 `true`）。
4. **时间口径**：`created_at` 是**秒**；且 `logs` 只保留 **90 天**（TTL）。
5. **只缺备站日志**：sg 的 DSN 必须是 `-public.clickhouseserver`；被整键覆盖退回 VPC 端点会**跨区不可达、备站日志全丢，而脚本仍报 ok**。
6. **慢**：补 `created_at` 区间、别按 `user_id` 单条件扫、别 `SELECT *`（列存全表扫描最贵）。
7. **对账差异**：先看 `type` 是否只算 `2`（消费），再看 `quota` 与 `QuotaPerUnit` 的换算口径。

---

## 12. 附录：2026-10-08 实测记录

用 `deploy/ops/ck_query.sh` 对主站做的只读验证（证据 `deploy/logs/ck_query_20261008-*/mnl.log`）：

| 用例 | 结果 |
|---|---|
| `--show-dsn` | 端点 = **VPC**（预期口径）· `user=newapi` · `pw_len=24` · `db=newapi_logs`，**口令未回显** |
| `SELECT count() AS n FROM logs` | `{"n":71}` |
| `SELECT fromUnixTimestamp(created_at) ts, model_name, "group" … LIMIT 3` | 返回真实行（如 `gpt-5.5`、`gpt-6-astra`，`group=default`）⇒ 保留字 / 时间函数 / 排序均正确 |
| `ALTER TABLE logs DELETE …` | `[XX] 只允许只读语句：首关键字「ALTER」不在白名单`，退出码 1（**未发出任何 HTTP 请求**） |
| `SHOW CREATE TABLE logs` | **`ENGINE = SharedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')`**、`PARTITION BY toYYYYMM(toDateTime(created_at))`、`ORDER BY (created_at, request_id)`、**`TTL toDateTime(created_at) + toIntervalDay(90)`**、`SETTINGS index_granularity = 8192` |

> 一处与代码 DDL 的差异：代码写 `ENGINE = MergeTree()`，企业版实例上是 **`SharedMergeTree`**（云原生共享存储变体）—— 建表语句会被服务端归一化，不影响列/排序键/TTL 语义。

---

## 附：延伸阅读（仓内事实源）

| 文档 | 内容 |
|---|---|
| `deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` | 任务 9（日志库决策 F9）、任务 17（DSN 注入）、任务 29（CK 接线四步）、任务 41（连接预算 I-1/I-2/I-3）、F9/F10/F11/F12 |
| `deploy/docs/Day1任务9_日志库CK决策_执行报告.md` | 为什么是"马尼拉企业版单 AZ"、三处口径收紧、成本与资源包 |
| `deploy/docs/Day2任务17_DSN注入_执行报告.md` | 两地 DSN 端点（VPC vs PUBLIC）与鉴权证据 |
| `deploy/ops/ck_query.sh` | 只读查询脚本（本手册 §7.2 通道 A） |
| `deploy/tasks/task17/dsn_verify.sh` | 只读核验：Secret 键清单 + DSN 结构 + 端点口径 + 端到端鉴权 |
| `deploy/tasks/task9/ck_decision.sh` | CK 可购性/成本探针（`verify\|probe\|cost\|create\|check`） |
| `deploy/docs/风险_ALB健康检查被限流429_2026-10-06.md` | 与"日志库无关但与日志观测相关"的 429 事件（健康检查路径撞全局限流） |
