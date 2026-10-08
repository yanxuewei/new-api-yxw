# Day 2 · 任务 17｜Secret 注入 + 卡片复核与 B 线收口 —— 执行/核验报告

- **任务**：Day 2 · 任务 17 收尾项「把 `LOG_SQL_DSN` 注进集群」（任务 41 I-1 的 (a) 路线前置；任务 9 卡 S-4 销账项）→ **§七 起为本卡完整复核**（卡片判据 vs 实况）与 **B 线收口**（2026-10-05 项目负责人裁定：**全线不使用 KMS**）
- **日期**：2026-10-05（复核 + 1 次 sg Secret 修正写操作 + 1 批两地 ConfigMap/SA 配置对齐 + 1 次 mnl master 滚动重启）
- **通道**：`deploy/ack_remote.sh`（云助手 → worker 节点内 kubectl）· 两地（mnl `cd57e40c…` / sg `ca75829e…`）
- **结论**：✅ **本卡闭合**（按 §七 的实测口径判据）。两地 `Secret/new-api-secrets` 均含 `LOG_SQL_DSN` 且端到端鉴权通过；同时**修正 sg 侧一处端点错误**（原指 CK 私网 VPC 端点 → 跨区不可达）；RRSA/KMS/ExternalSecret **按裁定不实施**；`SQL_MAX_OPEN_CONNS` 150→**100** 两地落地并确认生效。**遗留三项**（§九）：Cookie `Secure` 缺项、DSN 证书校验档位、`SESSION_SECRET` 轮换待核准。

---

## 一、最终状态（2026-10-05 实测）

| 站点 | ns | Secret 键数 | 键清单 | `LOG_SQL_DSN` 端点 | 鉴权 |
| --- | --- | --- | --- | --- | --- |
| mnl | `new-api` | **6** | LOG_SQL_DSN · REDIS_CONN_STRING · SESSION_SECRET · SESSION_SECRET_OLD · SQL_DSN · SQL_DSN_MIGRATE | `cc-5tsv2o51s1360b0pr-clickhouse.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（**VPC**，同区私网） | ✅ `SELECT 1`→`1` · `SHOW TABLES`→`logs` |
| sg | `new-api` | **3** | LOG_SQL_DSN · SESSION_SECRET · SQL_DSN | `cc-5tsv2o51s1360b0pr-public.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（**PUBLIC**，跨区） | ✅ 同上 |

- DSN 结构（脱敏共通）：`clickhouse://newapi:<pw_len=24>@<host>:9000/newapi_logs`
- ConfigMap `new-api-config`（两地）：`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` ✅ · ~~`LOG_SQL_MAX_OPEN_CONNS=50`~~ **已于 21:34 删除**（⚠ 代码无此 env，空转配置，见任务 41 坑 11；详见下面 §七/§八）
- CK 实例：`cc-5tsv2o51s1360b0pr` · 端点 `DescribeEndpoints` 回 PUBLIC + VPC 两条（`NetType=PUBLIC`/`VPC`）· 公网 IP `43.118.97.47`

## 二、修正事件（本次唯一写操作）

- **现象**：sg 侧 `LOG_SQL_DSN` 与 mnl **同值**，指 **VPC 端点**；从 SG worker（`i-t4nb4aj0ssltm7jjawuv`）实测 **TCP 9000 不可达**（超时）⇒ 备站写日志必然失败。
- **依据**：2026-09-30 裁定③「备站 → CK 走 `CreateEndpoint` 公网端点」（`sg_eip` 白名单组已含 SG 4 出口 EIP）。
- **动作**：`kubectl -n new-api patch secret new-api-secrets --type merge --patch-file <json>`，仅把 host 的 `-clickhouse.clickhouseserver` 换成 `-public.clickhouseserver`；**口令/库名/端口不变，明文不落盘、不进日志**（patch json 由节点内 python 生成，用后即删）。
- **验证**：改后 sg → public 端点 `SELECT 1` = `1`、`SHOW TABLES` = `logs` ✅；mnl 侧未动（同区走 VPC 是对的，私网更省 NAT 流量）。

## 三、判定与影响

| 项 | 结果 |
| --- | --- |
| 任务 17「`LOG_SQL_DSN` 注入」 | ✅ 完成（两地） |
| 任务 41 **I-1 (a) 路线** | ✅ 成立 —— CK 日志库分支 `16×100 + 24×10 = 1840 ≤ 2000`；**(b) 临时 `conns=45` 不再需要** |
| 任务 9 卡 **S-4** | ✅ 销账（原「DSN 未注入集群」结论作废） |
| 约束 | 应用首启前 DSN 必须指向 CK —— 现已满足（任务 18/23 部署 Pod 时即生效） |
| 未落地（不属本项） | `PAYMENT_PRIVATE_KEY` / `TLS_WILDCARD`（待用户提供，G5 依赖）；sg 侧 `REDIS_CONN_STRING`（sg Tair 未建）/ `SQL_DSN_MIGRATE`（备站迁移账号未下发）/ `SESSION_SECRET_OLD`（⚠ 本行 16:22 原文把三项都归因于"sg Tair / 迁移账号"，**`SESSION_SECRET_OLD` 的归因是错的**——它属任务 55 双密钥前置、与 Tair 无关，且当时被脚本 sg 分支"只写 3 键"卡死；该脚本障碍已于 §十二 清除） |

## 四、核验脚本

`deploy/task17_dsn_verify.sh [mnl|sg|both]`（幂等**只读**）
1. Secret 键清单（仅键名）
2. DSN 结构脱敏（scheme/user/pw_len/host/port/db）
3. **端点口径断言**：mnl 应 VPC（`-clickhouse.clickhouseserver.`）；sg 应 PUBLIC（`-public.clickhouseserver.`）
4. 端到端鉴权：节点内用 Secret 自身值连 CK HTTP 8123 跑 `SELECT 1` / `SHOW TABLES`；**内层重试 3 次**（VPC 端点偶发抖动），失败时自动用另一端点做判别
5. ConfigMap TTL 值
- 输出落 `deploy/logs/task17_verify_<ts>/{mnl,sg}.log`；出现 `[XX]` 即退出码 1。
- 最近一次全绿：`deploy/logs/task17_verify_20261005-162208/`。

## 五、本次踩到的坑（已固化）

1. **远端 curl `-w '%{http_code}'` 可能不回显**（得空串），导致"响应体正常但判定失败"的假阴性 ⇒ 改用 `curl -fsS -m 10 -o file` + 退出码 + 响应体判定。
2. **`ack_remote.sh` 的 body 是「不带引号的 heredoc」**：正文里出现**反引号**会被本地 shell 当命令替换执行（实测报 `-w: command not found`）；出现未转义 `$1/$2` 会被本地 `set -u` 打成 `unbound variable` ⇒ 正文一律 `\$` 转义、注释里别写 `$1`/反引号。
3. **mnl VPC 端点 8123 偶发超时**（同秒内另一次直连成功）—— 与项目「VPC 端点两端皆抖动」一致 ⇒ 鉴权检查必须带重试。
4. **SDK 参数差异**：`aliyun cas` 不带 `--region` 会报 `unknown endpoint for region ap-southeast-6`（CAS 该地域无端点），查证书须显式 `--region ap-southeast-1`。
5. **`patch secret --type merge` 用 `stringData`** 可直接传明文，避免手工 base64；配合 `--patch-file` 规避口令出现在 `ps` 参数里。

## 六、证据

- 站点日志：`deploy/logs/task17_verify_20261005-162208/{mnl,sg}.log`
- 关键行：mnl `[OK] SELECT 1 → 1` / `[OK] SHOW TABLES → logs`；sg `[OK] 端点=PUBLIC` / 同上查询结果
- 云侧：`aliyun clickhouse DescribeEndpoints --DBInstanceId cc-5tsv2o51s1360b0pr --RegionId ap-southeast-6` → `VPC` + `PUBLIC` 两条端点

---

## 七、卡片判据复核（2026-10-05 21:1x，只读）

> 复核对象：指南 v2.0 任务 17 卡 + xlsx `落地计划` row20（判据「密钥不落 Git，注入后应用可正常启动」）。取证脚本 `deploy/task17_cardcheck_body.sh`（经 `ack_remote.sh` 在节点内跑），日志 `deploy/logs/task17_cardcheck_20261005-211402/mnl.out`。

| # | 卡片原判据 | 实况 | 判定 |
| --- | --- | --- | --- |
| 1 | 密钥不落 Git | 卡片命令 `git log -p --all \| grep -Eci "LTAI[0-9A-Za-z]{16}\|-----BEGIN (RSA\|EC) PRIVATE KEY-----"` 回 **18**（非 0）⇒ **正则不可作门禁**：命中全是文档占位符/示例与 base64 噪声。决定性取证改为**按值比对**：现用 AK ID、AK Secret、ACR 口令三个字面值在 Git 全历史 / 已跟踪 / 未跟踪文件里计数均 **0**；Git 内 4 处"口令形态"串（长度 10/4/6/6）与集群真值（21/21/24）无一对应；PEM 命中全部是文档正文与 `relay/channel/vertex/service_account.go:68/74` 的字符串拼接，历史中带私钥体的 base64 行 = 0；`deploy/.env` 未被跟踪且从未进历史 | ✅ |
| 2 | 注入后应用可正常启动 | mnl `deploy/new-api-master` 1/1，Pod `NODE_TYPE=master`、`SQL_MAX_OPEN_CONNS` 容器 env 生效、日志出现 `channels synced from database` | ✅（16:2x 首验，21:4x 重启后复验，见 §八） |
| 3 | Namespace + ResourceQuota 先设后部署 | 两地 `new-api-quota` hard = `requests.cpu 48` / `requests.memory 96Gi` / `limits.cpu 64` / `limits.memory 128Gi`，与卡片逐字一致 | ✅ |
| 4 | ConfigMap 关键约束 | 见 §八（含 150→100 与两个空转键删除） | ✅（本卡收口后） |
| 5 | Secret 键齐 | mnl 6 / sg 3。sg 缺 `REDIS_CONN_STRING`（SG Tair 未建，任务 29 被"交易侧拒付"卡住 ⇒ **不在可补范围**）、`SQL_DSN_MIGRATE`（备站迁移账号未下发）、`SESSION_SECRET_OLD`（双密钥轮换前置）⇒ **三键里只有两键可补**。**2026-10-06 用户已核准补齐**（「sg 三个 Secret 键可以补齐」），注入脚本 sg 分支已从 4 键加固为 **5 键**（原先**没有** `SQL_DSN_MIGRATE`）并加 `--apply [mnl|sg|both]` 单站过滤与写前/写后键集对照，详见任务 28 报告 §十二-补。**⚠ 执行位在 WSL 堡垒机**（明文只在 `/root/.deploy_secrets/`），Mac 本机跑不了 | 🔶 分阶段，前置在别的卡；补键动作**待人工执行** |
| 6 | 两地 `SESSION_SECRET` 同一份 | 两地 sha256 前 12 位同为 `c5fbe2dbc89b`（len 42）⇒ 同值 | ✅ 附条件（轮换须两地同批，见 §十） |
| 7 | RRSA + KMS + ExternalSecret 三步 | **按裁定不实施**。实测：RAM `new-api-rrsa-kms-mnl/-sg` 与 `new-api-kms-readonly` 全部 **404 不存在**（从未 apply，`task17_rrsa.sh` 只跑过 `--check`）；KMS `ListSecrets` 菲/新均 **0**、`ListKeys` **0**（但菲区**存在**实例 `kst-php6abb88e21s0imvefj0` ⇒ 旧文档"必须先购实例"的阻塞理由已失效）；两地 addon 清单**无 `ack-secret-manager`**，集群**无 ExternalSecret CRD**；master 容器内 `ALIBABA_CLOUD_*` 变量数 **0** ⇒ 该链路从未产生注入 | ⛔ 不实施 |

**结论**：卡片两条真判据（1/2）实测通过，3/4 通过，5 是跨卡依赖，6 通过附条件，7 按裁定作废 ⇒ **本卡按"实测口径"闭合**。判据同步写回指南卡片头（`> ⛔ 裁定` + `> ✅ 执行登记` 两段）。

## 八、B 线收口写操作（21:34–21:40，两地）

执行器：`deploy/task17_bline_align.sh --apply`（幂等，节点侧生成 RFC6902 ops，只对差异下刀）；日志 `deploy/logs/task17_bline_20261005-213429/{mnl,sg}_apply.out`。

| 动作 | mnl | sg |
| --- | --- | --- |
| `SQL_MAX_OPEN_CONNS` | 150 → **100**（replace） | 150 → **100**（replace） |
| `SQL_MAX_IDLE_CONNS` | 已为 50，无 op | **新增 50**（原先根本没有这个键） |
| `LOG_SQL_MAX_OPEN_CONNS` | 删除（代码无此 env） | 删除（同） |
| `SESSION_MAX_AGE` | 删除（Go 全仓 0 命中；会话寿命由 DB `expiresAt` 推导，`service/auth_session.go:315`） | 删除（同） |
| SA `pod-identity.alibabacloud.com/role-name` | 原本 live 就为空（只在 `last-applied` 里）⇒ 无 op | `new-api-rrsa-kms-sg` → **摘除**（指向不存在的角色） |
| 滚动重启（坑 7：改 CM 不重启不生效） | `rollout restart deploy/new-api-master` → `new-api-master-6858cb9cd7-hmgh6` Running | 无工作负载，跳过 |

收口后两地 ConfigMap 一致为 **7 键**：`TZ` / `NODE_TYPE=slave` / `MEMORY_CACHE_ENABLED=false` / `SYNC_FREQUENCY=30` / `SQL_MAX_OPEN_CONNS=100` / `SQL_MAX_IDLE_CONNS=50` / `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`（`SQL_MAX_LIFETIME` 两地均未显式设 ⇒ 取代码默认 60s，与卡片值等价）。

**幂等复测**（`deploy/logs/task17_postrestart_20261005-213600/mnl.out`，脚本 `deploy/task17_postrestart_verify_body.sh`）：

- 容器 env 实测 `SQL_MAX_OPEN_CONNS=100` / `SQL_MAX_IDLE_CONNS=50`，两个已删键为空 ⇒ 配置真生效。
- 重启后 DDL 分口径计数 **PG=0 / CK=3 / ERROR=0**，日志总行数 ≤20000（窗口未截断，计数可信）。
- schema 指纹 = 任务 18 基线 `36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127`，**逐字相同**。
- **中途一次假警报**：首跑指纹是 `37|77f5c248d32…|1174c9028…`（表数 37 ≠ 36）。根因**不是**本次配置改动，而是**并行会话的任务 30 演练**在 21:17:24 建了 `ops_drill_marker` 表（oid 序 + 仓库 `deploy/task30_bodies/07-mnl-write.sh:63-66` 佐证）。在指纹 SQL 里加 `table_name<>'ops_drill_marker'` 排除后回到基线值；演练表（1 行）未动。⇒ 教训：**并发操作同库时，指纹比对必须先隔离他人的写入面**。

## 九、DSN 的 TLS 档位实测（新增）

脚本：`deploy/task17_dsn_sslmode_body.sh`（结构脱敏）+ `deploy/task17_dsn_ssl_probe_body.sh`（临时 psql Pod 查 `pg_stat_ssl`，只 `SELECT`）；日志 `deploy/logs/task17_sslcheck_20261005-220/{mnl_sslmode,sg_sslmode,mnl_sslprobe}.out`。

| 站点/键 | `sslmode` 实况 | 实测结论 |
| --- | --- | --- |
| mnl `SQL_DSN`（6432） | **未写** ⇒ pgx/libpq 默认 `prefer` | 连上后 `ssl=true` ⇒ **链路已加密** |
| mnl `SQL_DSN_MIGRATE`（5432） | **未写** | 同上 `ssl=true` |
| mnl `SQL_DSN`/`_MIGRATE` + `verify-ca`/`verify-full` | — | **建连即失败**：`root certificate file "/root/.postgresql/root.crt" does not exist` ⇒ 卡片要求的 `verify-ca` **未落地**，且缺 CA 时不可直接打开 |
| sg `SQL_DSN`（公网 6432） | `require` | TLS 但不验证书；卡片裁定②乙写的是 `verify-full` ⇒ 同样未落地 |
| sg `SQL_DSN_MIGRATE` | 键不存在 | 见 §十 遗留 |

**判读**：加密这一层是真的（不是"裸连"），**证书校验这一层为零**。主站内网串上 `verify-full` 本就不可用（证书 CN 绑公网串，任务 15 坑 7／任务 41 坑 9），正确目标是 `verify-ca` + `sslrootcert`；落地必须"CA 文件挂载 + DSN 参数"**同批**，只改 DSN 会让全站建连失败 ⇒ 本卡只登记，不动手（已写进卡片坑 11）。与任务 30 的 `sslmode=verify-full ❌（缺 RDS 根 CA）` 是同一根因。

## 十、遗留 / 待核准

1. **`SESSION_SECRET` 轮换**（⚠ 破坏性，需项目负责人核准留痕）：核查脚本 `deploy/task17_pw_hash_body.sh` 的非 DSN 分支曾打印该值**前 12 位**（值只出现在当次会话输出）。已修脚本为"只输出 sha256 指纹 + 长度"并注明禁止改回明文；检索 `/tmp/ackctl-*`、`deploy/logs`、`/tmp` 确认**落盘副本 = 0**。轮换前置：**sg 集群还没有 `SESSION_SECRET_OLD` 键**，须先补该键（普通写；脚本已于 §十二 具备该能力，**待一次 `--apply`**），再走"旧值进 `_OLD`、新值进主键、两地同批、各自 `rollout restart`"。
2. **Cookie `Secure` 缺项**：`SESSION_COOKIE_SECURE` / `SESSION_COOKIE_TRUSTED_URL` 两地 ConfigMap 均未设 ⇒ `common/session_cookie.go:44-83` 默认 `false`，签发的会话 Cookie 不带 `Secure`。与 443/证书同批补（任务 19/23），且 `SECURE=true` 必须配对 `TRUSTED_URL`，否则 `InitSessionCookieSettings()` 报错、应用起不来。
3. **DSN 证书校验**（§九）：需 RDS 根 CA + DSN 同批改动，另立卡。
4. **sg 侧缺口**：`REDIS_CONN_STRING`（等 SG Tair，任务 29 交易拒付 ⇒ **故意不写，不是遗漏**）、`SQL_DSN_MIGRATE`、`SESSION_SECRET_OLD` ⇒ 后两键**可补且已于 2026-10-06 核准**，脚本 sg 分支现为 5 键（见任务 28 报告 §十二-补），**须由项目负责人在 WSL 堡垒机执行** `bash deploy/task17_secret_inject.sh --check` 后 `--apply sg`（先看 `LOG_SQL_DSN` 是否 `-public`，守卫不过会 die）；且 sg **无 PAYMENT_PRIVATE_KEY / TLS_WILDCARD**（G5 与支付私钥依赖）。
5. **本卡不做的事**：不建 KMS 凭据、不建 RRSA 角色（裁定）；`deploy/task17_rrsa.sh` 保留仅作留痕，**不再执行**。

## 十一、脚本与证据索引

| 用途 | 路径 |
| --- | --- |
| 手工 Secret 注入（`--check`/`--apply`） | `deploy/task17_secret_inject.sh`（值源 `~/.deploy_secrets/*` + `deploy/.env`，body `shred` 销毁；mnl 6 键 / **sg 4 键，含 `SESSION_SECRET_OLD`**，见 §十二） |
| DSN/鉴权只读核验 | `deploy/task17_dsn_verify.sh` → `deploy/logs/task17_verify_20261005-162208/` |
| 卡片判据只读核查 | `deploy/task17_cardcheck_body.sh` → `deploy/logs/task17_cardcheck_20261005-211402/` |
| 口令指纹（绝不出口令） | `deploy/task17_pw_hash_body.sh` |
| 配置对齐（幂等写） | `deploy/task17_bline_align.sh` → `deploy/logs/task17_bline_20261005-213429/` |
| 重启后幂等 + 期望态 | `deploy/task17_postrestart_verify_body.sh` → `deploy/logs/task17_postrestart_20261005-213600/` |
| TLS/sslmode 实测 | `deploy/task17_dsn_sslmode_body.sh`、`deploy/task17_dsn_ssl_probe_body.sh` → `deploy/logs/task17_sslcheck_20261005-220/` |

## 十二、注入脚本补 `SESSION_SECRET_OLD`（2026-10-05 收口后追加，仅改本地脚本，未动集群）

**动因**：任务 55 的双密钥轮换被脚本卡住——`deploy/task17_secret_inject.sh` 的 sg 分支只写 3 个 `--from-literal`（`SQL_DSN`/`SESSION_SECRET`/`LOG_SQL_DSN`），**无论跑多少次都不带 `SESSION_SECRET_OLD`**，轮换 SOP 的 T1「两地同批写」在备站根本无法成立。

**改动（4 处，全在 `collect_sg` / sg body / 脚本头注释）**：

1. sg 分支增写 `--from-literal="SESSION_SECRET_OLD=$SS_OLD"`，echo 文案同步为 **4 键**。
2. `SS_OLD` **只从 mnl 用的同一份保管文件** `/root/.deploy_secrets/SESSION_SECRET_OLD` 读（与 `SS` 同一条 `collect_mnl` 兜底路径）⇒ 结构上不可能给两地造出两个不同值。**取不到值就直接 `die` 退出，绝不现场另造随机值**（另造 = 两地密钥分叉 = GTM 接管全员 401，R40）。
3. 顺带修掉**两类**会被本脚本触发的"集群侧修正被静默回退"问题（本脚本是 `create --dry-run | kubectl apply` 的**整键覆盖**写——真源没跟上的字段一律被抹掉，而输出照样显示 "applied"）：
   - **CK 端点**：保管文件 `LOG_SQL_DSN` 存的是 **VPC** host，而 sg 集群侧的 `-public` 端点修正是当天**直接 patch Secret**、没回写保管文件 ⇒ 原脚本一跑 `--apply` 就会把 sg 的 DSN **悄悄退回 VPC**（跨区不可达、写日志全失败）。现改为 `collect_sg` 里把 host 归一化为 `-public.clickhouseserver` 并**断言必须命中该口径，否则退出**。
   - **PG TLS 档位**：脚本把 sg `SQL_DSN` 写死 `?sslmode=require`，而**任务 30 在同日 22:00 已把集群侧升级为 `sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`**（CA 在 Secret `rds-ca-apse6`，见任务 30 报告 §7.1）⇒ 一次 `--apply` 会把它**静默降回"加密但不验证书"**。现脚本按实况写 `verify-full&sslrootcert=/etc/ssl/rds/ca.crt`；副作用沿用任务 30 的硬约束：**备站 Deployment 必须挂载该 Secret 到 `/etc/ssl/rds`**，否则建连直接失败。
   - mnl 分支未动（同区走 VPC 是正确口径，`SQL_DSN`/`SQL_DSN_MIGRATE` 无 `sslmode` 与 §九 实测一致）。指南卡片已登记为**坑 12**，通则写进任务 17 卡。
4. **一处更根本的处置（未做，留待裁定）**：上面是"把真源追上集群"，但正确顺序应是**先改保管文件、再注入**。`LOG_SQL_DSN` 的保管文件至今是 VPC 口径，脚本里的 sed 只是补丁；若下一张卡又直接 patch 集群，同类回退会第三次发生。建议二选一：① 保管文件按站点拆成 `LOG_SQL_DSN.mnl` / `LOG_SQL_DSN.sg`；② 在脚本里把"整键覆盖"改为"只覆盖本次要补的键"。本轮**未擅自改动保管目录**（它在执行机上，且改真源属变更操作）。

**验证（本地哑值夹具，未接触生产凭据与集群）**：`bash -n` 通过；把脚本复制到临时目录、`VAULT`/`ENVFILE`/`HERE` 指向哑值与桩 `ack_remote.sh` 跑 `--apply`：

| 断言 | 结果 |
| --- | --- |
| sg body 键数 | **4**（含 `SESSION_SECRET_OLD`），mnl 仍 **6** |
| 两地 `_OLD` 同值 | 夹具里 vault / mnl body / sg body 三处 sha256 前 12 位逐字相同 ✅（哑值，非生产凭据） |
| 取不到 `_OLD` 时 | 退出码 **1**，报 `[XX] 保管目录缺 SESSION_SECRET_OLD…禁止给 sg 另造随机值`，**且未生成 sg body**（fail-closed）✅ |
| sg CK 端点 | `-public.clickhouseserver`；mnl 保持 `-clickhouse.clickhouseserver` ✅ |
| sg PG DSN 口径 | `…:6432/newapi?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`；mnl 两条串仍无 `sslmode` ✅ |
| 生成的 body 可解析 | `bash -n` 通过——heredoc 把反斜杠续行折叠成单行命令，`&` 始终落在双引号内 ⇒ 不会被 shell 当后台符截断 |
| 临时文件权限 | body `600`；夹具（含哑口令）跑完即 `rm -rf`，`grep -rl` 确认哑值只存在于夹具自身文件 |

**仍待执行（不在本次改动范围）**：**先补真源再注入**——把执行机保管文件 `/root/.deploy_secrets/LOG_SQL_DSN` 的 host 从 `-clickhouse` 改为 `-public`（或按站点拆成两份），否则脚本里的 sed 只是补丁。随后 `bash deploy/task17_secret_inject.sh --apply` 一次（普通写，两地 Secret + ConfigMap 同批），跑完用 `deploy/task17_dsn_verify.sh both` 复验——其第 3 项就是端点口径断言（mnl VPC / sg PUBLIC），第 4 项做端到端鉴权；再用 `task17_pw_hash_body.sh` 核对两地 `_OLD` 指纹一致。**这一步在执行机上跑，需按变更窗口登记**；真正的 `SESSION_SECRET` 轮换仍是破坏性操作，另待项目负责人核准。

**配套修正**：核对用的 `deploy/task17_pw_hash_body.sh` 键清单原本只到 `SESSION_SECRET`，**没有遍历 `SESSION_SECRET_OLD`**（指南任务 55 的 V4 注释属预期而非实测）⇒ 已把该键加入清单。哑值实测两个分支：有键时输出 `value_sha[:12] / len`（不出值），缺键时输出 `(键不存在)` ⇒ sg 在补键之前跑它就是 `(键不存在)`，正好当补键前后的判据。

## 十三、10-06 复核：上面 §十二 的三处口径已被取代（**执行时以本节为准**）

**动因**：2026-10-06 任务 28 收口时用户核准「sg 三个 Secret 键可以补齐」，复核脚本与实况后，§十二 的三处表述不再成立。

| §十二 原口径 | 10-06 实况 | 处置 |
| --- | --- | --- |
| sg body 为 **4 键**（验证表第 1 行） | sg 分支原先**没有** `SQL_DSN_MIGRATE` ⇒ 跑 `--apply` 补不出该键。现已补为 **5 键**：`SQL_DSN` / `SQL_DSN_MIGRATE` / `SESSION_SECRET` / `SESSION_SECRET_OLD` / `LOG_SQL_DSN`；mnl 仍 6 键 | 脚本已改，离线渲染自测通过（证据见任务 28 报告 §十二-补） |
| 「三键都能靠一次 `--apply` 补齐」 | **只有两键可补**。`REDIS_CONN_STRING` 需 SG Tair，而任务 29 仍是 `Trade_Not_Support_Async_Pay` ⇒ sg 分支**故意不写该键**，不是遗漏 | 已在指南任务 28 卡与本报告 §五-5 登记 |
| 「`--apply` 一次（**两地** Secret + ConfigMap 同批）」 | 本脚本是**整键覆盖写** ⇒ 不带站点参数会连带重写 mnl，而两地真源可能已分叉。现加 `--apply [mnl\|sg\|both]` 过滤，**默认 `--check`** | 执行时用 `--apply sg` |
| （新增）端点回退风险 | `LOG_SQL_DSN` 若不是 `-public` 端点，脚本现在**直接 `die`** 而不是 sed 归一后继续 ⇒ 补键前先在 `--check` 里核对保管文件 | 守卫已实测触发 |

**⚠ 执行位**：明文保管目录 `/root/.deploy_secrets/` 与 `deploy/.env` 只在 **WSL 堡垒机**上（本机 macOS `ls /root/.deploy_secrets` = No such file、`/mnt/e/...` 不存在）⇒ 补键动作**须由项目负责人在 WSL 侧执行**：

```bash
bash deploy/task17_secret_inject.sh --check        # 先盘点，确认 LOG_SQL_DSN 是 -public
bash deploy/task17_secret_inject.sh --apply sg     # 只动 sg，5 键；mnl 不碰
bash deploy/task17_dsn_verify.sh sg                # 复验端点与鉴权
bash deploy/task17_pw_hash_body.sh                 # 核对两地 SESSION_SECRET_OLD 指纹一致
```

两次 `keys BEFORE` / 键集对照的输出（**只含键名**）留档在 `deploy/logs/task17_secret_*`；body 用后即 `shred`。本会话**未执行任何注入**，集群侧 sg 仍是 3 键。

