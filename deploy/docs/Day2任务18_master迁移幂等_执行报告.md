# Day 2 · 任务 18｜master Deployment 跑通 AutoMigrate，连跑两次验幂等 —— 执行报告

- **卡片**：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` §Day2 任务 18（单人，2 人时，13:30–15:30）
- **执行日期**：2026-10-05
- **执行通道**：`deploy/ack_remote.sh mnl`（云助手 `ecs RunCommand` → worker 节点内 kubectl，admin 私网 kubeconfig；`ACKCTL_DIR=/tmp/ackctl-mnl-t18` 与并行的任务 17 会话隔离）
- **产物**：`deploy/aliyun/ph/master-deployment.yaml`、`deploy/task18/master_migrate.sh`（`--precheck/--apply/--verify/--status/--cleanup`）、`deploy/logs/task18_*_20261005-*/`（body.sh + remote.out 全量留存）
- **结论**：✅ **完成**。空库首启建出 36 表 / 177 索引 / 0 ERROR；第 2 次冷启动 schema 指纹与首启**逐字相同**（幂等成立）；master 红线、不接流量、迁移账号边界三项验收全过。收口后追加一项修复：**master 的镜像拉取路径由公网域名改为 ACR 企业版 VPC 内网域名（`-vpc`），并在零缓存节点完成全量冷拉复测**（§十）。
- **授权留痕**：① 拉取凭据修复方式 = 「装 credential-helper 组件」；② 生产 DDL 门禁 = 「一次核准，apply+verify 连着跑」（项目负责人 IM 会话内答复，2026-10-05）。

---

## 一、幂等的判定口径（本卡最关键的口径修正）

卡片原口径：`logs | grep -Ec "ALTER TABLE|CREATE TABLE|CREATE INDEX"`，第一次 >0、第二次 =0。

实测前提：**这个 grep 在默认配置下恒为 0**，与迁移是否发生无关。

| 事实 | 依据 |
| --- | --- |
| GORM logger 级别固定 `Warn`，不可由配置放开 | `model/gorm_logger.go:42` |
| Warn 级只打印「慢查询」，阈值默认 200 ms | `model/gorm_logger.go:33`（`SQL_SLOW_THRESHOLD_MS`，`defaultSlowThresholdMs=200`） |
| 空库首启的建表/建索引单条耗时 1.3–5.6 ms | 见 §三 日志样本 |

⇒ 本卡改为**双口径互证，且明确主次**：

- **主口径 = schema 指纹**：`public` 下 (a) 表数 (b) `information_schema.columns` 有序集合 md5 (c) `pg_indexes.indexdef` 有序集合 md5。两次冷启动必须逐字相同。这个口径不依赖日志，也不受「应用没打印」影响。
- **副口径 = DDL 日志计数**：靠 master 专属 env `SQL_SLOW_THRESHOLD_MS=1` 强制逐条打印，且**必须按库拆分**：
  - `DDL·主库 PG` = 命中双引号标识符的 GORM 语句（`CREATE TABLE "x"` / `CREATE INDEX … ON "x"` / `ALTER TABLE "x" …`）；
  - `DDL·日志库 CK` = 命中无引号的 ClickHouse 语句（`CREATE TABLE IF NOT EXISTS logs (` / `ALTER TABLE logs MODIFY TTL`）。

四个残留盲区（①–③ 本卡实测都踩过；④ 本次现测已排除，但会随 Pod 存活时间自动触发）：

| # | 盲区 | 后果 | 已落地的处置 |
| --- | --- | --- | --- |
| ① | GORM 仅在 `elapsed > 阈值` 时打印 | <1 ms 的语句仍不落日志 ⇒ 计数偏低 | 幂等结论只认主口径 |
| ② | Pod Ready **早于**日志库迁移段刷盘 | `--verify` 首测在 Ready 即刻计数 ⇒ 抓到「假 0」 | `wait_log_settled()`：轮询到 CK 段出现（最多 60 s）再计数 |
| ③ | 日志库 CK 的 DDL **每次启动固定重放 3 条**（`CREATE TABLE IF NOT EXISTS` + `MODIFY TTL` 本身幂等，由 `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 驱动，`model/main.go:395-407`、`:468`） | 不分库的 grep 在第二次恒为 3 ⇒ 「第二次不得有 DDL」被误判成不通过 | 卡片口径限定为**主库 PG**；CK 的 3 条列为常量、不参与幂等判定 |
| ④ | 计数走 `kubectl logs --tail=20000`，而 1 ms 阈值下日志约 174~218 行/分 | Pod 存活超过 ~90 min 后窗口吃掉启动段 ⇒ PG 计数**又变成假 0** | 本卡在现测窗口内证明未截断（总行数 4529 < 20000，见 §四-①）；长跑场景改查 SLS 或先回退阈值 |

⇒ 综合：**副口径单独不能证明幂等**，只用于正向证明「首启确实在建表」；幂等结论只认主口径，且副口径读数的可信期受 ④ 限制。

---

## 二、前置核实（--precheck，只读 + 事务回滚探针）

| 项 | 结果 | 说明 |
| --- | --- | --- |
| 应用镜像可拉性 | ❌ 首测 `ImagePullBackOff` → ✅ 修复后 1.6 s 拉起 | 见 §六-①（当时走的是**公网**域名；18:53 起改内网 `-vpc`，见 §十） |
| 依赖端点连通（Pod 内 `nc -z`） | ✅ 四端口全通 | RDS 6432（PgBouncer）/ RDS 5432（直连）/ ClickHouse 9000 / Redis 6379 |
| DSN 真握手 | ✅ | 两个账号均拿到 `PostgreSQL 17.10`，经 transaction 池握手无 `08P01`/`42P05`（呼应 §6.4 步骤 3 的判据） |
| Redis / CK 协议握手 | ✅ | Redis `PING`→`+PONG`；CK `8123 /ping`→`Ok.` |
| 权限边界（卡片验收项） | ✅ | `newapi`（DML）建表 → `ERROR: permission denied for schema public`；`newapi_migrate` 建表 → `CREATE TABLE` 且 `begin/rollback` 不留痕（`_perm_probe` 存在数=0） |
| 迁移前指纹 FP0 | `FP0 0\|` | **public schema 空** ⇒ 首启是真建表，第二启的指纹比对才有意义 |

⚠ 探针写法教训：`psql -c begin -c create -c rollback` 的多个 `-c` 不保证同事务，改成单条 `-c "begin; create table _perm_probe(id int); rollback"`；探针 Pod 必须显式 `requests+limits`，否则被 `new-api-quota` 直接拒（`must specify limits.cpu/memory`）。

---

## 三、第 1 次冷启动（--apply）

```
deployment.apps/new-api-master created
[OK] 第 1 次冷启动完成
DDL 行数(第1次) = 173        ERROR/FATAL 行数 = 0
FP1 36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127
readyReplicas=1 replicas=1
```

⚠ 这里的 173 是**未拆分口径**（PG 与 CK 混在一条 grep），且计数时刻早于日志库段 ⇒ 首启 PG 侧的真实值只能记为 **170~173**，拆分见 §四-① 末尾的说明。

日志样本（`SQL_SLOW_THRESHOLD_MS=1`，参数已被 `ParameterizedQueries` 过滤，不含取值）：

```
[SYS] 2026-10-05 17:42:20 | database migration started
[5.605ms] [rows:0] CREATE TABLE "channels" ("id" bigserial,"type" bigint DEFAULT 0,"key" text NOT NULL,...
[1.629ms] [rows:0] CREATE INDEX IF NOT EXISTS "idx_channels_tag" ON "channels" ("tag")
[1.310ms] [rows:0] CREATE TABLE "tokens" ("id" bigserial,"user_id" bigint,"key" varchar(128),...
```

落库结果：**36 张 BASE TABLE**（`abilities, auth_flows, authz_roles, casbin_rule, channels, checkins, custom_oauth_providers, external_identity_claims, login_encryption_keys, logs, midjourneys, models, options, passkey_credentials, perf_metrics, prefill_groups, quota_data, redemptions, setups, subscription_orders, subscription_plans, subscription_pre_consume_records, system_instances, system_task_locks, system_tasks, task_plugins, tasks, tokens, top_ups, two_fa_backup_codes, two_fas, user_oauth_bindings, user_sessions, user_subscriptions, users, vendors`）、**177 索引 / 64 UNIQUE / 0 外键**（与 GORM 不建 FK 的既有行为一致）。
非 DDL 写入仅 1 行：`options.theme.frontend = 'default'`（初始化种子，不是业务数据）。

## 四、第 2 次冷启动（--verify）＝ 幂等证明

```
FPA = 36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127
kubectl rollout restart deploy/new-api-master（strategy=Recreate ⇒ 旧 Pod 先退出，等价冷启动）
DDL 行数(第2次) = 0          ERROR/FATAL 行数 = 0
FPB = 36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127
[OK]  幂等成立：第 2 次冷启动零 schema 变更
```

⚠ 上面这行 `DDL 行数(第2次) = 0` 是 `--verify` 的**当场原始输出**，其口径在收口终检时被推翻 —— 指纹结论不变，DDL 计数请以 §四-① 的分口径重测为准。

**FPA == FPB** ⇒ 不存在卡片「修复」段所担心的 `ALTER TABLE` 漂移（索引/类型/布尔默认值反复改表），任务 54 的版本化迁移基线可以在此之上推进。

### ① 但对上述 "DDL = 0" 的**复核推翻了它的口径**（本报告的关键更正）

收口后做终检时发现：同一个第 2 次冷启动 Pod 的完整日志里其实有 **3 行 DDL 形态语句**，与 --verify 当场报的 0 矛盾。拆开看，两个原因都是真的：

| 成因 | 证据 |
| --- | --- |
| **计数时刻早于日志落盘段** | Pod `startTime=09:43:38Z`，3 条 DDL 的时间戳 `17:43:42`；`wait_rollout` 在 readiness 满足时就返回，`ddl_count` 抓的是当时尚未写到日志库段的尾部 ⇒ 报 0 是**假 0** |
| **PG 与 CK 两个库的 DDL 混在同一条 grep** | `migrateLOGDB()`（`model/main.go:395-407`）在**每次** master 启动都执行 `CREATE TABLE IF NOT EXISTS audit_logs` / `logs`，再由 `syncClickHouseLogTTL`（`model/main.go:468`）发 `ALTER TABLE logs MODIFY TTL …`（实测 `[1018.135ms]`，因 `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 生效）⇒ 这 3 条**永远不为 0**，属设计上的幂等重放，不是漂移 |

在**同一个 Pod 上不重启**改用分口径重测（口径靠标识符引号区分：GORM/PG 输出 `CREATE TABLE "x"`，CK 输出 `CREATE TABLE IF NOT EXISTS logs (`）。下面两段是收口时**再次现跑**的原始输出（未改写格式）；`startTime` 仍是 `09:43:38Z` ⇒ 证明确实没重启。全量留存于 `deploy/logs/task18_recount_20261005-180904/` 与 `deploy/logs/task18_coverage_20261005-180954/`：

```
  Pod 启动时间 = 2026-10-05T09:43:38Z（= 第 2 次冷启动的那个 Pod，未再重启）
  PG 口径 DDL = 0
  CK 口径 DDL = 3
  ERROR/FATAL = 0
  PG 口径命中行（应为空）：
  CK 口径命中行（固定 3 条）：
    [59.190ms] [rows:0] CREATE TABLE IF NOT EXISTS audit_logs (
    CREATE TABLE IF NOT EXISTS logs (
    [1018.135ms] [rows:0] ALTER TABLE logs MODIFY TTL toDateTime(created_at) + INTERVAL 90 DAY DELETE
```

「PG = 0」还要排除**采样窗口截断**这一种假 0（计数走 `kubectl logs --tail=20000`，窗口若盖不住启动段就会漏掉真实 DDL），现测覆盖度：

```
  Pod = new-api-master-59f758484-b99n4 2026-10-05T09:43:38Z
  日志总行数(全量) = 4529
  tail=20000 行数 = 4529                 ← 窗口 = 全量，无截断
  tail=20000 窗口首行 = [SYS] 2026-10-05 - 17:43:40 | initializing token encoders
                                        ← 距 Pod 启动 2 s，盖住迁移段
  窗口内是否有 migration started 标记 = 2
  全量内是否有 migration started 标记 = 2
```

（该标记出现 2 次 = 主库与日志库各报一次迁移开始，正好说明两个库的段都在同一窗口内。）

⇒ 两条独立证据（分口径计数 + 窗口未截断）与指纹逐字相同一致。**注意**：这个「未截断」只在总行数 < 20000 时成立；`SQL_SLOW_THRESHOLD_MS=1` 下约 174~218 行/分 ⇒ 约 90~115 分钟后窗口就会吃掉启动段，届时 PG 计数会重新变成假 0，得改查 SLS 或先关 1 ms 阈值。

⇒ **修正后的结论**：主库 PG 在第 2 次冷启动**零 DDL**（分口径现测 + 指纹逐字相同，两条独立证据一致）；日志库 CK 每次启动固定重放 3 条幂等 DDL，**不该**被当成非幂等。**幂等判定不受影响，但"第二次不得有 DDL"这句卡片原文必须限定为「主库」**，否则任何人照 grep 复跑都会得到 3 而误判成漂移，进而去"修"一张本来就没问题的表。

脚本已按此改：`ddl_count` 拆成 `ddl_count_pg` / `ddl_count_ck`，并新增 `wait_log_settled`（等日志跑到日志库段再计数，避免假 0）；`err_count`/样本 grep 的 `--tail` 从 6000 提到 20000（1 ms 阈值下日志量远超 6000 行，见 §八-1）。

首启那个数字要如实降级：`DDL 行数(第1次) = 173` 是**未拆分口径**测得，且同样受计数时刻影响 ⇒ 首启 PG 侧应记为 **170~173**；该 Pod 日志已随 `Recreate` 销毁，无法复核拆分（若需要，SLS 里的容器 stdout 是唯一的回溯源）。这不改变结论：首启确实建出了 36 表 / 177 索引，由 FP0=`0|`(空库) → FP1=36 表 直接证明。

## 五、卡片验收项逐条判定

| 验收项（卡片原文） | 判定 | 实测 |
| --- | --- | --- |
| `readyReplicas` = 1 | ✅ | `1` |
| master Pod 仅 1 个 | ✅ | `new-api-master-59f758484-b99n4` 1/1 Running，节点 `ap-southeast-6.10.0.43.200` |
| `NODE_TYPE=master` 且全集群仅此 | ✅ | Deployment env 显式 `master`；ConfigMap `NODE_TYPE=slave`（其余工作负载继承 slave）；apply 前红线自检 = 集群内无任何「显式非 slave」容器；收口后 18:14 再遍历 ns 内**全部** Deployment ⇒ 只有 `deploy/new-api-master` 一个显式值（stable/canary 尚未部署） |
| 迁移账号正确 | ✅ | Pod 内 `$SQL_DSN` 解析出 `newapi_migrate`（由 Secret 键 `SQL_DSN_MIGRATE` 映射而来） |
| DML 账号不得改表（stable 侧） | ✅（等价口径） | 卡片命令 `exec deploy/new-api-stable` **不可执行**（stable 属任务 23，尚未部署）⇒ 改用 precheck 的 psql 探针，结论相同 |
| master 不挂 Service / 不进 ALB 后端 | ✅ | 占位 `svc/new-api-master` selector=`{app: new-api-master}`，master Pod 标签 `app=new-api-migrate` **故意不命中**；`endpoints/new-api-master ready=0`；`ingress/new-api-verify → svc/new-api-master:80` 后端为空 ⇒ 坑 1 未发生 |
| `\d users` 关键列 | ✅ | `quota bigint default 0` / `used_quota bigint default 0` / `access_token character(32)` + `UNIQUE idx_users_access_token` / `status bigint default 1` / `aff_quota` |
| `IsMasterNode` 回归基线 | ✅ 已记录 | **63** 处（全仓 `*.go` 内 `grep -rn "IsMasterNode"` 计数），作为 master-only 后续任务的对照基线 |

镜像与代码一致性：tag `20260928-26ac63233` 之后 `git log 26ac63233..HEAD -- '*.go'` 与 `-- model/` 均为空 ⇒ 本次建出的 schema 与当前 `main` 的模型定义同源，不存在「跑老镜像建新库」的偏差。

---

## 六、本次为执行本卡而落地的前置修复（4 项，均含实测证据）

### ① 任务 16 步骤 7「ACR 免密拉取」此前从未执行 —— 已补齐（本卡头号阻塞）
- 现象：`ImagePullBackOff`，`insufficient_scope: authorization failed`。
- 排除项：**不是** tag 不存在（`ListRepoTag` 有该 tag，78 MB）；**不是** NAT 出网问题（同 Pod 拉 `docker.io` 镜像正常）。
- 根因：全集群**无任何** `kubernetes.io/dockerconfigjson` Secret，SA `imagePullSecrets` 为空，credential-helper 未安装。ACR 企业版 `acr-newapi-mnl`（`cri-avfqy9xkqi5bj8ee`）匿名 token 的 `access` 声明为 `[]`、`sub=""` ⇒ **企业版即使 RepoType=PUBLIC 也要鉴权**（任务 16 卡片坑 5 的说法需要按此修正）。
- 处置（已核准）：安装 **`managed-aliyun-acr-credential-helper`**（托管版；集群 worker RAM 角色 `KubernetesWorkerRole-4f4f9191-…` 挂载策略数 = 0，自管版依赖 worker role，故不选）。任务 `T-6ac36dad95069a010300025d` → success，addon `active v24.01.29.1-5318af4-aliyun`，配置 `watchNamespace=new-api` / `serviceAccount=new-api-app`，实例 `cri-avfqy9xkqi5bj8ee`。
- 结果：helper 生成 `new-api/acr-credential-secret-aggregation`（覆盖公网 + `-vpc` 两个域名），**只 patch `new-api-app` 这一个 SA**。⇒ 新红线：`default` SA 仍无凭据，**任何要拉本镜像的 Pod（含临时调试 Pod）必须显式 `serviceAccountName: new-api-app`**（已写进清单头 ④ 与 precheck/临时 Pod 模板）。
- 复测：1.628 s 拉完，digest `sha256:38fd74feac69…` 与 `ListRepoTag` 一致。

### ② 迁移账号只能靠 env 映射（代码里没有 `SQL_DSN_MIGRATE`）
`grep -rn "SQL_DSN_MIGRATE" --include="*.go" .` = **0** 命中，应用只读 `SQL_DSN`。⇒ master 用 `env SQL_DSN ← secretKeyRef(SQL_DSN_MIGRATE)` 覆盖，且显式 env 优先于 `envFrom`，stable/canary 继续用 `newapi@6432`。卡片 YAML 未体现这一点，属卡片缺项。

### ③ 删掉卡片给的 PVC + 挂载点（两处都会造成故障）
- 挂载点 `/app/data`：镜像 `ENTRYPOINT=/new-api`、`WORKDIR=/data`，应用根本不写 `/app/data`；改挂 `/data` 会盖掉工作目录。
- 本站主库是 PG（`SQL_DSN` 非空 ⇒ 不走 SQLite），master Pod **无本地持久状态**；而 RWO 云盘是单 AZ 资源，`Recreate` 换 AZ 时正是卡片「PVC Multi-Attach」的成因。⇒ 不建 PVC，卡片该条修复项对本卡不适用（留作 stable 若引入本地盘时的参考）。

### ④ 执行通道 `ack_remote.sh` 的两个真 bug（曾造成本卡一次假成功）
- **空 `InvokeId` 被当成成功**：`aliyun` CLI 出错时返回的是 `{"message":…,"error_code":…}` 这类**合法 JSON**，`json.load(...).get('InvokeId','')` 静默返回空串；旧守卫只判字面量 `FAIL`。随后 `DescribeInvocationResults --InvokeId ''` 回的是**上一次调用**的输出 ⇒ 日志里出现「BODY END · Success」+ 旧 body 内容，而 `--apply` 从未执行（复测：`kubectl get deploy new-api-master` → `No resources found`）。现已：空值即硬失败 + 把 stderr 原始响应打出来。
- **PATH**：`aliyun` 由 `~/.zshrc` 追加，非交互 shell 不 source ⇒ 命令找不到。脚本已自行补 PATH 并前置存在性检查。
- ~~附带澄清：卡片/报告担心的「命令内容超长」**不是**本次原因~~ ⇒ **本条已被 18:51 的现测推翻，更正如下**：`ecs RunCommand` 的 `CommandContent` **Base64 编码后不得超过 24 KB**（官方 API 文档原文 "The command content cannot exceed 24 KB after Base64 encoding"，见 https://www.alibabacloud.com/help/en/ecs/developer-reference/api-ecs-2014-05-26-runcommand ）。§五 的 `--apply` body 加长后 raw 22.7 KB → 注入 kubeconfig + base64 = **30.3 KB ⇒ `403 {"error_code":"CmdContent.ExceedLimit"}`**（原始响应留存 `deploy/logs/task18_apply_20261005-185149/remote.out`）。先前"24.5 KB 实测可下发"只落在 <24 KB 边界内，属把边界内样本外推成"无上限"的推理错误——而且正是坑 6/§四-① 那一类"空/异常响应被当成成功"的同源问题：这次的守卫（空 `InvokeId` 即硬失败 + 打印 stderr 原文）让 403 当场暴露，否则又会是一次假成功。**处置**：`ack_remote.sh` 改为「外层只传解压器」——body 先 `gzip -9` 再 base64 内嵌 bootstrap，节点侧 `base64 -d | gzip -dc` 还原执行；切换后同一 body 的体积链是 `raw 23,499 B → gzip+b64 17,080 B → 外层命令 b64 23,132 B` ⇒ 落在 24 KB 内，18:53 下发成功（`logs/task18_apply_20261005-185315/`）。附带两处可移植性修正：bootstrap 先做 `command -v gzip` 存在性检查；编码统一用 `python3`，**不用 `base64 -w0`**（BSD/macOS 不认 `-w`，会静默产出空 Body）。

## 七、与本卡相关的口径冲突（供指南/xlsx 回改）

| # | 冲突 | 实测事实 | 建议 |
| --- | --- | --- | --- |
| 1 | 卡片前置写「任务 17 的 ExternalSecret 已 Ready」 | 集群**无 ExternalSecret CRD**（`the server doesn't have a resource type "externalsecret"`）；`new-api-secrets` 是手工 `kubectl apply` 的 Opaque Secret（键：`SQL_DSN / SQL_DSN_MIGRATE / LOG_SQL_DSN / REDIS_CONN_STRING / SESSION_SECRET / SESSION_SECRET_OLD`） | 与 09-30 裁定「手工 Secret 注入」一致，卡片措辞需改 |
| 2 | 卡片 YAML `image: ${ACR_MNL_PREFIX}:<git-sha>` | 实名 `acr-newapi-mnl-registry[-vpc].ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:<date>-<sha>`；`-vpc` 端点**已闭环**（10-05 18:18 关联，本报告 §十），消费侧 18:53 起已改用内网域名 | 卡片已补真实域名并切到 `-vpc`；原「VPC 端点未关联」遗留项作废 |
| 3 | ConfigMap `SQL_MAX_OPEN_CONNS=150` | 裁定① 要求 100 | 未在本卡改动；见 §八 |
| 4 | ConfigMap `LOG_SQL_MAX_OPEN_CONNS=50` | 代码无该 env 读取点（CK 日志库连接池不走这键）⇒ **死配置** | 待清理 |
| 5 | 方案假定 3 可用区 | 实际只有 6a/6b（4 worker：2+2）；单节点 allocatable CPU 7910 m，四节点合计约 31.6 核 | 任务 23 的 16 副本上限受**节点**而非 quota 约束 |
| 6 | 任务 19 报告③「ALB Ingress Controller 不在集群内」 | 本次复核：云端 `ListClusterAddonInstances` 仍报 `alb-ingress-controller active v3.1.1`，集群内**确实无 alb 组件 Pod** | 报告结论成立（元数据与运行态不一致），无需推翻 |
| 7 | `arms-prometheus active 1.1.44` 但集群内无 Pod | ACK Pro 的 Prometheus 走托管侧，集群内无 Pod 属预期 | 不作为异常记录 |

## 八、遗留与下一步

1. **`SQL_SLOW_THRESHOLD_MS=1` 只能当"迁移窗口"配置，不能常驻**（本卡新发现）。实测 master 稳态运行 13 分钟产生 **2833 行日志**（≈218 行/分）：阈值降到 1 ms 后，master 的后台任务轮询（`model/task.go:402`、`model/system_task.go:169/261` 等每轮 `SELECT`，单条 1.2–1.8 ms）也全部落盘。站点日志走 SLS（`logtail-ds` + `sls-newapi-mnl`），常驻 1 ms 等于给采集链路加一条与 QPS 无关的固定流量。⇒ 建议：迁移/排障窗口设 1，窗口结束改回默认 200（或 0 关闭慢查询日志）；ConfigMap 化以便一键回退。**本次未改动**（属配置变更，需单独核准）。
   附带确认：`ParameterizedQueries` 生效，日志里是 `$1$/$2$` 占位而非实值（`gorm_logger.go:44`），降到 1 ms 不引入数据泄露。
   ⚠ 这条不只是优化项，它给本卡的**副口径读数设了软截止**：计数走 `--tail=20000`，第 2 次冷启动 Pod 起于 17:43:40、18:09:54 现测总行数 4529 ⇒ 按 174~218 行/分推算约 **19:20–19:40** 启动段就会被挤出窗口，此后 `PG=0` 不再可信，只能改查 SLS 容器 stdout。
   **19:12 现跑复核**（`logs/task18_vpcstate_20261005-191213/`，内网切换后的当前 Pod 起于 18:55:57）：`全量行数=4550 = tail20000 行数`、`窗口首行 = 18:55:57 initializing token encoders`（Pod 启动即首行，仍盖住迁移段）⇒ **当前未截断**，`PG=0 / CK=3 / ERROR=0` 依旧可信。顺带纠正一处速率算法：把这个 Pod 的"总行数 ÷ 存活分钟"直接当稳态会得到 ≈325 行/分，但其中约 1919 行是**启动突发**（apply 那次实测 1 分钟内就有 1919 行），扣除后稳态 ≈**175 行/分**，落在本卡既有区间内 ⇒ 当前 Pod 的窗口触顶约 **20:20–20:40**。⚠ 另外，17:43 那个作为幂等证明的第 2 次冷启动 Pod 已随 `Recreate` 销毁，§四-① 的**原始输出文件**（`task18_verify_*` / `task18_recount_*` / `task18_coverage_*`）现在是那条结论唯一的可回溯证据；当前 Pod 只支撑"内网切换后仍零 DDL/零漂移"（§十）。指纹口径不受以上任何一条影响。
2. **本卡未做、也不该顺手做**：`SQL_MAX_OPEN_CONNS` 150→100 的 ConfigMap 改动（§七-3）——影响 stable 连接池预算，属任务 13/23 口径，需单独核准。
3. ~~**任务 16 2b**：ACR 企业版 VPC 端点关联马尼拉 VPC（当前仍 `LinkedVpcs=[]`，节点靠公网 NAT 拉镜像）~~ ⇒ **本项已闭环**：端点 10-05 18:18 关联（另一会话），本卡消费侧 18:53 起改为 `-vpc` 内网域名拉取并完成零缓存冷拉复测，详见 **§十**。§六-① 的公网拉取不再是最优路径，只作为应急通道保留（同 tag、同 digest，切换无需改 SA/Secret）。
4. **任务 54**：AutoMigrate 幂等已确认 ⇒ 可在 staging 建 `golang-migrate` 基线；prod 保持 master-only AutoMigrate。
5. **任务 23**：`endpoints/new-api-master ready=0` 是占位资源，清理时点为任务 23；master 标签 `app=new-api-migrate` 与其 selector 的隔离关系必须保留，否则坑 1 立刻复现。任务 23 卡片前置里的"ExternalSecret 已建"已随本次一并改为实测口径（手工 Opaque Secret）。
6. ~~**新加坡集群的 credential-helper 仍未装**（本卡只闭环马尼拉侧）~~ ⇒ **2026-10-05 21:2x 复核推翻此条**：SG 侧 `managed-aliyun-acr-credential-helper` 状态 `active`（`cs ListClusterAddonInstances --cluster_id ca75829e…`），`new-api` ns 内已生成 `secret/acr-credential-secret-aggregation`（创建时间 `2026-10-05T10:19:10Z`，覆盖 `-vpc` 与公网两个 mnl registry host，字段齐备），且 SG 的 SA `new-api-app` 已挂 `imagePullSecrets=[acr-credential-secret-aggregation]`。⇒ 遗留项从「未装」改为「**未验证过 SG 侧真实拉取**」（SG 目前无任何工作负载，任务 24/23 部署时一并验）。红线不变：**任何要拉本镜像的 Pod 必须显式 `serviceAccountName: new-api-app`**。
7. master Deployment **保持 Running**（本卡交付态即运行中，未 `--cleanup`）；回退方式 `bash deploy/task18/master_migrate.sh --cleanup`（只删 Deployment 与本卡临时 Pod，**不动 schema**）。

## 九、证据索引

| 文件 | 内容 |
| --- | --- |
| `deploy/logs/task18_precheck_20261005-*/` | 端口连通、DSN 握手、权限边界、FP0（空库） |
| `deploy/logs/task18_apply_20261005-174217/` | 第 1 次冷启动：create、DDL 173（未拆分口径，见 §四-①）、0 ERROR、FP1 |
| `deploy/logs/task18_verify_20261005-174334/` | 第 2 次冷启动：FPA/FPB、验收项、`\d users`（当场 DDL 计数为假 0，已被 §四-① 更正） |
| `deploy/logs/task18_recount_20261005-180904/` | 同一 Pod 分口径重测（收口现跑）：PG=0 / CK=3 / ERROR=0 |
| `deploy/logs/task18_coverage_20261005-180954/` | 计数窗口覆盖度：总行数 4529 = tail 窗口 ⇒ 未截断 |
| `deploy/logs/task18_finalcheck_20261005-181405/` | 收口后 §五 验收项**现跑复核**：ready 1/1、单 Pod 30m/0 重启、ns 内仅 `deploy/new-api-master` 显式 `NODE_TYPE=master`（ConfigMap=slave）、`endpoints/new-api-master` subsets 为空、`t18-*` Pod 数=0、Secret 仅列键名 |
| `deploy/logs/t18_pullcheck_body.sh` | 拉取凭据修复前后的单点复测（ImagePullBackOff → 1.6 s，公网域名） |
| `deploy/logs/task18_apply_20261005-185149/` | **下发失败原件**：`403 CmdContent.ExceedLimit` 的 RunCommand 原始 JSON（§六-④ 更正的证据） |
| `deploy/logs/task18_vpcnodeprobe_20261005-184553/` | 4 台 worker 的 `-vpc` / 公网域名**节点侧**解析与 443 取证（每节点一个 `.out`） |
| `deploy/logs/task18_vpcpullprobe_20261005-184831/` | 零缓存探针 Pod 的内网全量冷拉：`1.183 s / 78,074,255 B`（§十） |
| `deploy/logs/task18_apply_20261005-185315/` | 切内网域名的 apply：A0 基线 → A3b `imageID=-vpc` 取证 → A4/A5（含 `master-deployment.rendered.yaml`） |
| `deploy/logs/task18_vpcswitch_20261005-185433/` | 钉节点复测（**含"98 ms 假冷拉"原件**，§十 坑） |
| `deploy/logs/task18_vpcfullpull_20261005-185539/` | `crictl rmi` 后 Deployment 级零缓存冷拉：`1.23 s / 78,074,255 B` |
| `deploy/logs/task18_vpcfinal_20261005-185643/` | 切换后收口终检（Z1–Z6；其中探针计数那一行因 `$$` 被 shell 吞而报错，见 §十 末） |
| `deploy/logs/task18_probetable_20261005-185714/` | 上述报错的重跑结果：`perm_probe=0 / t18_tables_left=0 / tables=36` |
| `deploy/logs/task18_vpcstate_20261005-191213/` | 交回前**现跑只读复核**（§十-⑦）：`image`/`imageID` 域名、窗口覆盖度、分口径 DDL、指纹、探针与 `nodeSelector` 残留 |
| 本报告 §五/§六 表格内命令 | `IsMasterNode`=63、`SQL_DSN_MIGRATE`=0、addon 状态、表/索引清单 |

> 密钥口径：全程只打印 Secret **键名**，未打印任何值；`SQL_SLOW_THRESHOLD_MS=1` 下日志仍不含参数，因 `ParameterizedQueries = !DebugEnabled`（`model/gorm_logger.go:44`）。

---

## 十、收口后追加：镜像拉取路径改为 ACR VPC 内网域名并完整复测（10-05 18:44–18:57）

**触发**：项目负责人对照 ACR 控制台的「专有网络」行与 ACK YAML 编辑器里的 `image:`，指出 master 拉的是**公网**域名 `acr-newapi-mnl-registry.ap-southeast-6…`，要求「修复为内网地址拉取，然后完整的再测试一次内网拉取镜像」。本节即该修复 + 复测记录；线上状态此前已由任务 16 2b 把 VPC 端点关联好（18:18），缺的是**消费侧没有在用它**。

### ① 端点事实（API 断言，不靠文档自证）

`cr GetInstanceVpcEndpoint --InstanceId cri-avfqy9xkqi5bj8ee` →

```
LinkedVpcs=[{Status:"RUNNING", VpcId:"vpc-5tst1tgeessxn1azwasg2",
             VswitchId:"vsw-5tswpyzfa8od6je95td1h", Ip:"10.0.22.220",
             DefaultAccess:true, Issue:"NO_PRIVATE_ZONE_AUTHORIZED"}]
```

⚠ 两个"看着像没配好"的字段实测**不阻塞**解析：`Issue=NO_PRIVATE_ZONE_AUTHORIZED` + 账号级 PrivateZone 记录数 = 0，而 `DefaultAccess=true` 会把 ACR 内置解析下发到 **VPC DNS**（4 台 worker 的 `/etc/resolv.conf` 都是 `100.100.2.136 100.100.2.138`）。⇒ 判断"内网拉取能不能用"要以下面②的节点侧解析+连通为准，不能拿 `Issue` 字符串当结论。

### ② 节点侧取证（4/4，`logs/task18_vpcnodeprobe_20261005-184553/`）

| 节点 | `-vpc` 解析 | 443 握手（`curl /v2/`） | 公网域名解析 |
| --- | --- | --- | --- |
| 10.0.22.194 | `10.0.22.220` | `http=401 ip=10.0.22.220 connect=0.0012s` | `8.220.143.202` |
| 10.0.22.195 | `10.0.22.220` | `http=401 … connect=0.0008s` | `8.220.143.202` |
| 10.0.43.200 | `10.0.22.220` | `http=401 … connect=0.0016s` | `8.220.143.202` |
| 10.0.43.201 | `10.0.22.220` | `http=401 … connect=0.0017s` | `8.220.143.202` |

`401` 是**期望值**：TCP+TLS 已到 registry、只差鉴权（企业版匿名 token 的 `access=[]`，见 §六-①）。⚠ 节点上**没有 `dig` 也没有 `nc`**（本卡 precheck 的 `nc -z` 是在 Pod 里跑的），所以用 `getent hosts` + `curl -w '%{http_code} %{remote_ip}'`；`ip route get 10.0.22.220` 回 `dev eth0 src 10.0.22.194` ⇒ 走 VPC 内二层，不经 NAT 出网。

### ③ 真实冷拉（零缓存）

⚠ 本节两块引用均为**节选**：长域名中段以 `…` 省略、事件表去掉列头，逐字原文见对应目录的 `remote.out`。

**探针 Pod**（`nodeName` 固定到 10.0.22.194，先断言 `crictl 里 newapi 镜像数 = 0`，SA `new-api-app`）—— `logs/task18_vpcpullprobe_20261005-184831/`：

```
Normal  Pulling  Pulling image "acr-newapi-mnl-registry-vpc…:20260928-26ac63233"
Normal  Pulled   Successfully pulled image "acr-newapi-mnl-registry-vpc…:20260928-26ac63233"
                 in 1.183s (1.183s including waiting). Image size: 78074255 bytes.
imageID = acr-newapi-mnl-registry-vpc…/newapi-prod/newapi-master@sha256:38fd74feac69…282b3
```

**Deployment 级**（18:54 那次在**有缓存**的 10.0.22.195 上只拿到 `98ms`，见 ⑤）⇒ 18:55 在 10.0.22.194 `crictl rmi` 掉 `-vpc` 副本（先断言本机 newapi 容器数=0）再用 `nodeSelector` 钉机触发，`logs/task18_vpcfullpull_20261005-185539/`：

```
F1) Deleted: acr-newapi-mnl-registry-vpc…:20260928-26ac63233 ；删除后本机 newapi 条目 = 0
F3) Pulling … -vpc …  →  Successfully pulled … in 1.23s (1.23s including waiting). Image size: 78074255 bytes.
F4) CK=3 PG=0 ERROR=0 总行数=2978 ；ready=1/1
F5) 解除 nodeSelector 后 残留 = []
```

### ④ 改动面（最小化）

`deploy/aliyun/ph/master-deployment.yaml` 只改 `image:` 的**主机名**（→ `-vpc`），tag 与 digest 未动：

- **不需要**改 SA / `imagePullSecrets`：`acr-credential-secret-aggregation` 由 helper 同时覆盖公网与 `-vpc` 两个域名（§六-①）。
- 公网域名保留为**应急通道**（同 digest，随时可回退，回退=改一行 `image:`）。
- 清单头的偏差说明同步改写为「端点已关联 + `NO_PRIVATE_ZONE_AUTHORIZED`/PrivateZone=0 不阻塞 + 冷拉实测数字」。

### ⑤ 新坑：`Pulled` 事件里的 `Image size` 会骗人（已升为指南任务 18 卡**坑 8**）

18:54 在 10.0.22.195 上，`-vpc` 冷拉事件打印 `Successfully pulled … in 98ms (98ms including waiting). Image size: 78074255 bytes.` —— 98 ms 不可能是 78 MB 的下载。原因：**containerd 的内容存储按 layer digest 寻址，与 registry 主机名/仓库名无关**，换域名拉同一个 digest 直接命中本机已有 layer；调度到别的节点还会看到 `already present on machine and can be accessed by the pod`（18:53 的 apply 就是这个，`logs/task18_apply_20261005-185315/A3b`）。⇒ 拉取路径的**合格证据**只有三条同时成立：**①** `status.containerStatuses[].imageID` 的**域名**（`spec.image` 只代表"期望"）；**②** 事件序列必须是 `Pulling` + `Successfully pulled`，不是 `already present`；**③** 前置条件：目标节点 `crictl images | grep newapi` 为空（必要时 `crictl rmi` + `nodeSelector` 钉机，否则又是假冷拉）。

### ⑥ 切换后的完整复测结论

| 复测项 | 结果 |
| --- | --- |
| `imageID` = `-vpc` 域名 + `sha256:38fd74feac69…` | ✅（与 `ListRepoTag`、与公网域名同 digest ⇒ 只换路径不换镜像身份） |
| 零缓存冷拉 | ✅ 探针 1.183 s / Deployment 1.23 s，均 `78,074,255 B` |
| schema 指纹（第 3、4 次冷启动后） | ✅ `36\|e0573c6f…\|8a088809…` 与首启/二启**逐字相同**；apply 当场 `FPA0 == FP1` ⇒ 换域名零 schema 影响 |
| 分口径 DDL | ✅ PG=0 / CK=3 / ERROR=0（日志库段已进入窗口，故非 §四-① 的假 0）；日志总行数 1919~2990 < 20000 ⇒ 未截断 |
| master 红线 | ✅ ns 内显式 `NODE_TYPE` 只有 master Pod；ConfigMap 仍 `slave` |
| 坑 1（不接流量） | ✅ `endpoints/new-api-master` `subsets=[]` |
| 临时资源 | ✅ `nodeSelector` 残留 `[]`；探针/`t18-*` Pod 数 = 0；`perm_probe=0 / t18_tables_left=0 / tables=36` |

⚠ 一处如实记录的自测缺陷：`logs/task18_vpcfinal_20261005-185643/` 的 Z4 段里，探针表计数那条**报错而不是 0** —— `ERROR: trailing junk after numeric literal at or near "13public13"`，成因是把 PG 的 `$$` 美元引号写进了 `$( … )` 命令替换，`$$` 被 shell 展开成 PID。已按本卡既有写法改成「SQL 先写进 Pod 内文件，再 `psql -Atq -f`」重跑，结果见 `logs/task18_probetable_20261005-185714/`（`perm_probe=0 / t18_tables_left=0 / tables=36`）。这是同一类"空/异常输出被当成通过"的风险，指南任务 18 卡的探针示例里应继续禁用 `$$` 引号内联。

### ⑦ 交回前的现跑复核（19:10–19:12，只读，`logs/task18_vpcstate_20261005-191213/`）

文档写完后再取一次**当前**状态，避免"文档描述的是历史态"。（下面是**节选**：`AGE` 列、域名中段与 digest 中段用 `…` 省略，逐字原文见该目录 `remote.out`。）

```
  new-api-master   1/1   …  acr-newapi-mnl-registry-vpc…newapi-master:20260928-26ac63233  app=new-api-migrate,track=master
  pod=new-api-master-566f5794d6-6mrls node=ap-southeast-6.10.0.22.195 start=2026-10-05T10:55:57Z ready=true restarts=0
  imageID=acr-newapi-mnl-registry-vpc…/newapi-prod/newapi-master@sha256:38fd74feac69…282b3
  全量行数=4550  tail20000 行数=4550  窗口首行=[SYS] 2026-10-05 - 18:55:57 | initializing token encoders
  PG=0（期望 0）  CK=3（期望 3）  ERROR=0（期望 0）
  36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127   ← 与首启/二启/A0 逐字相同
  探针表计数 = 0|0 ；nodeSelector = （空）
```

⇒ **线上交付态 = 内网域名**，`imageID` 与 `spec.image` 域名一致、digest 未变、`restarts=0`；计数窗口仍未截断；指纹仍是任务 18 建立的那个值。⚠ 两条留痕：①S2 打出的 `Pulled` 是 `already present on machine`（当前 Pod 落在 10.0.22.195 的缓存节点上），所以这条**不能**当拉取路径证据，能证的只有 `imageID` 的域名 + ③⑤ 里那两次 `Successfully pulled`；②本次为取指纹建的 `t18-pgcli` 已在 body 末尾删除，输出里的 `ns 内非 master Pod = pod/t18-pgcli` 是删除**之前**那一行的快照。

