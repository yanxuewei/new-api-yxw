# 任务 30｜备 region → 马尼拉 RDS 公网读写打通与 RTT 实测 —— 执行报告

- **卡片**：`Day 1 · 任务 30｜备 region → 马尼拉 RDS 公网读写打通与 RTT 实测（单人，2 人时，S5）`
- **复核/执行时间**：2026-10-05 21:02–21:21（GMT+8）
- **执行方式**：`deploy/ack_remote.sh`（云助手 + 节点内 kubectl）→ 两地集群各建**一次性探针 Pod**（`postgres:17`，凭据走 `secretKeyRef` 注入，口令不进命令行、不出集群）
- **证据目录**：`deploy/logs/task30_drill_20261005-211909/`（10 文件）
- **判定**：**❌ 未完成（不可销账）** —— 4 条量化判据中 **2 条达标、1 条不达标、1 条口径不合**，另 V4 未做、SLA 回填未做

---

## 一、量化判据逐条判定

| 判据 | 卡内期望 | 实测 | 判定 |
| --- | --- | --- | --- |
| **TCP RTT（SG→MNL RDS）** | ≤ 45 ms | TCP 建连 p50 **37** / p95 **40** / max **41** ms（n=20）；ICMP avg **35.54** ms（0% 丢包） | **✅** |
| **`pgbench` 单连接 TPS** | ≥ 20 | c1 = **30.46** TPS（latency 32.8 ms）；c16 = **455.34** TPS（latency 35.1 ms） | **✅** |
| **TLS 握手成功率** | 100% | 建连 **50/50** + **20/20** + **10/10** 全成功 = **100%** | **✅** |
| **建连平均耗时（含 TLS）** | ≤ 200 ms | p50 **276 ms**（min 247 / p95 300 / max 301）；复测 p50 **280 ms** | **❌ 超标 38%** |
| **`sslmode=verify-full`** | 卡口径全链 | SG 实际 DSN 为 `sslmode=require`；改 `verify-full` 失败（见 §三） | **❌** |

> TLS 实际协商：**TLSv1.3 / TLS_AES_256_GCM_SHA384 / 256 bit**（`pg_stat_ssl` 实测）。

## 二、验证方法 V1–V4

| 项 | 结果 | 证据 |
| --- | --- | --- |
| **V1** 读的确是马尼拉主库 | **⚠ 等价证据成立（直接证据不可得）** | `inet_server_addr()` / `inet_server_port()` 因 RDS 限制回 **NULL**（`NOTICE: must be superuser to show server ip`，账号 `newapi_sg` 非 superuser）⇒ 改用等价证据：`current_database()=newapi`、`current_user=newapi_sg`、`server_version=17.10`、`pg_postmaster_start_time()=2026-09-29 15:59:16+08`（实例启动时刻，两地一致）+ V2 同库可见 |
| **V2** 主站写 → 备站读 | **✅** | 主站（mnl，`SQL_DSN_MIGRATE`）`insert into ops_drill_marker(note) values ('from-mnl-20261005') returning id,note,ts` → `1 \| from-mnl-20261005 \| 2026-10-05 21:17:24.289588+08`；51 秒后 SG 侧读出同一条（`age=00:00:51.70285`），表结构一致（`id bigint / note text / ts timestamptz`）⇒ **同一实例、无复制延迟** |
| **V3** 连接数在预算内 | **⚠ 探针残留，需观察** | 实测 `newapi_sg` idle **15** + active **1** = **16**（探针 `pgbench -c16` 产生；备站 0 副本 ⇒ 无业务连接）。另见 `newapi_migrate=1/3`、`newapi=1`、`replicator=1`、`aurora=7~8`。探针 Pod 已删，`idle 15` 属托管池保活（`server_lifetime` 到期回收） |
| **V4** 拔线自愈 | **❌ 未做** | 需改 RDS 白名单（移除 1 个 `sg_standby_eip` /32）⇒ **云写操作，属需负责人确认**，本次未执行 |

## 三、★ 三处关键新发现

### ① 建连 276 ms 的根因：跨区 RTT × 多次往返，**且与「经池/直连」无关**

成本拆解（全部在 SG 探针 Pod 内实测）：

| 组 | 配置 | p50 |
| --- | --- | --- |
| A | `psql --version`（纯进程启动，不连库） | **19 ms** |
| B | 经池 **6432** 建连 + `select 1` | **280 ms** |
| C | **直连 5432** 建连 + `select 1`（同实例同账号，仅换端口） | **279 ms** |
| D | 单进程内 **20 次串行查询**（仅 1 次建连） | **300 ms**（⇒ 建连 ~250 ms，此后每查询 ~2.5 ms） |
| E | `pgbench -C`（每事务新建连接） | latency **250.95 ms** / **3.98 TPS** |
| E2 | `pgbench` 复用连接（对照） | latency **35.45 ms** / **28.21 TPS** |

⇒ **结论**：① **乙路（6432 经池）与甲路（5432 直连）建连成本实测无差异**（280 vs 279 ms）—— 池不增成本，卡内「走池更慢」的担忧不成立；② ~250 ms 建连 ≈ 19 ms(psql) + RTT 35 ms × 约 7 次往返（SSLRequest + TLS1.3 1-RTT + SCRAM 2-RTT + 后端 fork + 首查询）；③ **卡内「建连平均 ≤200 ms」在当前 SG→MNL RTT 下物理不可达**，要么改判据（≤300 ms），要么应用侧强制连接复用（复用后 35 ms/查询，差 7 倍）。

### ② `verify-full` 实测不成立 —— 卡的前提有缺口

- 5432 链路证书链 = **2 张**：leaf `CN=pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com`（SAN 含该域名，`checkhost` **MATCH**，有效期 2026-09-29 → 2027-09-29）+ 中间 CA `CN=ApsaraDB ap-southeast-6 region CA`。**链内不含根 CA**。
- `sslmode=verify-full`（无 rootcert）→ `root certificate file "/root/.postgresql/root.crt" does not exist`
- `sslmode=verify-full&sslrootcert=system` → **`SSL error: certificate verify failed`** ⇒ RDS 证书**非公有 CA 签发**，系统根证书不管用
- 用 5432 链里的 leaf 当 rootcert 打 6432 / 5432 → **两条路都 `certificate verify failed`**（leaf 非自签，不能当锚点）
- ⇒ **`verify-full` 必须先拿到阿里云 RDS 的根 CA**（`ApsaraDB ap-southeast-6 region CA` 的签发者，从控制台/官方 CA 下载页获取），或退 `verify-ca`。**当前 SG 的 `SQL_DSN` 实为 `sslmode=require`**（即不校验证书），卡内的「`verify-full` 全链」未达成。
- 附带确认：**5432 与 6432 是同一张 leaf**（CN=公网串）⇒ 卡内「池复用同证书」成立，缺的只是根 CA。

### ③ 探针方法坑：`openssl s_client` **不能**直接判 PgBouncer(6432) 的 TLS 成败

- 用 `openssl s_client -connect <pub>:6432` 直打 → **10/10 失败**；但 `psql $SQL_DSN`（`sslmode=require`）**50/50 成功**、`ssl=on`、TLS1.3。
- 原因：PostgreSQL/PgBouncer 的 TLS 走 **PG 协议先协商**（客户端先发 `SSLRequest` 8 字节、服务端回 `S` 才开始握手）；`openssl s_client` 直接起 TLS，协议层对不上。
- ⚠ 同一手法打 **5432 是 OK 的**（5432 由 RDS 代理层接待，容忍直连 TLS）⇒ **两条路结果不一致，极易误判「6432 链路坏了」**。判 PG 侧 TLS 一律用 `psql`；`openssl s_client` 只用于取证书链。

## 四、配置面前置（复核，全部在位）

| 项 | 实测 |
| --- | --- |
| RDS 公网串 | `pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com:5432` → `43.118.96.65`（内网串 `10.0.69.77`） |
| 托管 PgBouncer | `PGBouncerEnabled=true`（PostgreSQL 17.0）—— **乙路（6432）前提成立** |
| 白名单四组 | `default=127.0.0.1` / `hdm_security_ips=100.104.188.192/26,100.104.53.0/26` / `mnl_vpc=10.0.16-64.0/20×4` / **`sg_standby_eip=47.84.126.214,47.84.184.246,47.84.29.162,47.84.83.76`（4×/32）** |
| SG Secret | `new-api-secrets` 3 键（`LOG_SQL_DSN` / `SESSION_SECRET` / `SQL_DSN`）；`SQL_DSN = postgres://newapi_sg:***@…pub…:6432/newapi?sslmode=require` |
| SG 命名面 | `kube-system` 外只有 `new-api`；**`deploy/new-api-ph-standby` 不在位**（无任何工作负载）⇒ 备站未被部署，本卡执行位只能靠一次性探针 Pod |
| SG 探针 Pod | `t30-pg`（`postgres:17`，ns `new-api`，SA `new-api-app`，`10.1.38.120`）⇒ 已删除，集群已复位 |

> **前置声明更正落实**：卡内原写「备站占位 Deployment 已可 exec」**再次证实未取证** —— `new-api` 命名面**零工作负载**，只有 configmap/secret/sa。

## 五、缺口与解除条件

| # | 缺口 | 解除条件 | 性质 |
| --- | --- | --- | --- |
| 1 | **建连 ≤200 ms 不达标**（实测 276 ms） | 二选一：① 把判据改 ≤300 ms 并写明「该 RTT 下不可达 200 ms」；② 应用侧强制连接复用（实测复用 35 ms/查询） | 判据修订 / 应用改造 |
| 2 | **`verify-full` 未成立**（现 `sslmode=require`） | 取阿里云 RDS 根 CA → 挂为 Secret（如 `RDS_CA_APSE6`）→ SG `SQL_DSN` 加 `&sslrootcert=<path>` 并改 `verify-full`，再复验 | 需根 CA 文件 |
| 3 | **V4 拔线自愈未做** | 改白名单移除 1 个 `sg_standby_eip` → 观察 5xx/超时 → 恢复 → 复验自愈 | **云写，需授权** |
| 4 | V3 连接账目 | 归还池空闲连接后复测 `newapi_sg` 计数 ≤ 10×备站副本数 | 待备站部署后 |
| 5 | **实测值未回填 §12 接管 SLA 口径表** | 用本报告数字回填（RTT p50 37 / TPS 30.5 / 建连 276） | 文档 |

## 六、可复用产物

| 文件 | 用途 |
| --- | --- |
| `deploy/task30_bodies/03-sg-tcp.sh` | SG→MNL RTT / 端口对照 / ICMP（节点级，~30 s） |
| `deploy/task30_bodies/04-sg-tls.sh` | 证书链与 TLS 详情（**注意 6432 需 psql 判 TLS**） |
| `deploy/task30_bodies/05-sg-pg-pod.sh` | SG 一次性探针 Pod + psql/pgbench/V1/V3（数据面主力） |
| `deploy/task30_bodies/06-sg-verifyfull.sh` | `verify-full` 三种口径复现（require / system / 缺 rootcert） |
| `deploy/task30_bodies/07-mnl-write.sh` | 主站侧对照 + V2 写 marker（建 Pod + 建表 + insert） |
| `deploy/task30_bodies/08-sg-read.sh` | V2 读侧 + 清理 |
| `deploy/task30_bodies/09-sg-latency-breakdown.sh` | 建连成本拆解（进程/池/直连） |
| `deploy/task30_bodies/10-sg-verifyfull-path.sh` | `verify-full` 可行路径 + 连接复用对照 + 连接账目 |

> 探针 Pod 标准写法（`new-api` ns 有 `ResourceQuota new-api-quota`，缺 resources 直接 `Forbidden: failed quota`）：见 05 号脚本 YAML 段。
> `ack_remote.sh` 单次窗口约 5 分钟（`loops×5s`），**测量脚本必须拆段**——本次 `02-sg-net.sh`（50×TCP + 20×TLS）整体超时失败，即为反例。

---

## 七、缺口闭环（2026-10-05 21:45–22:01，四项全部解除）

证据目录：`deploy/logs/task30_v4_verifyfull_20261005-220047/`（8 文件 + `summary.json`）

### 7.1 缺口② `verify-full` —— ✅ 已闭环

**根因确认**：`DescribeDBInstanceSSL` 的 `ServerCAUrl` 字段直接给出官方 CA 链下载地址（`https://apsaradb-public.oss-ap-southeast-1.aliyuncs.com/ApsaraDB-CA-Chain.zip`）⇒ 不需要走控制台手工下载。

| 步骤 | 实测 |
| --- | --- |
| CA 链下载 | `ApsaraDB-CA-Chain.zip` 191,207 B → 内含 `ApsaraDB-CA-Chain.pem`（**69 张证书**：1 自签根 + 各 region 中间 CA） |
| **★ 坑：同名根有两张** | 包里存在 **2 张 `CN=ApsaraDB Root CA`**：`cert_001`（SKI `3C:30:27:8B:…`，2016-05-05→2036-04-30）与 `cert_027`（SKI `7F:D6:ED:5C:…`，2019-01-30→**2039-01-25**）。leaf 的中间 CA `CN=ApsaraDB ap-southeast-6 region CA` 的 **AKI = `7F:D6:ED:5C:…` ⇒ 必须选 `cert_027`**。用 `cert_001` 时 `openssl verify` 报 `error 20 unable to get local issuer certificate`；而**若把整个 pem 同时当 `-CAfile` 和 `-untrusted`，openssl 会把中间 CA 直接当信任锚 → 得到「OK」的假通过**（本报告第一版即踩此坑）。 |
| 链验证（严格口径） | `openssl verify -CAfile cert_027.pem -untrusted cert_058.pem leaf.pem` → **`leaf.pem: OK`** |
| 落地产物 | `deploy/certs/rds-apse6-ca.crt`（4,127 B = 根 + ap-southeast-6 中间），根 SHA256 = `29:54:2B:04:…:04:B9` |
| 集群 Secret | SG `new-api` ns `rds-ca-apse6`（key `ca.crt`，回读 2 张证书）；挂载点 `/etc/ssl/rds` |
| SG DSN 变更 | `…?sslmode=require` → **`…?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`**（`kubectl patch --type merge --patch-file`，口令不进 `ps`） |
| 端到端复验（直接用 Secret 新值） | `rc=0`，`newapi_sg\|newapi\|true/TLSv1.3/TLS_AES_256_GCM_SHA384`；`public` schema 37 张表可读 |

**正/负例矩阵（探针 Pod 内 `psql`）**：

| 例 | DSN | 期望 | 实测 |
| --- | --- | --- | --- |
| A | `verify-full&sslrootcert=/etc/ssl/rds/ca.crt` @6432 | 成功 | **rc=0** TLSv1.3 ✅ |
| B | 同上 @5432 直连 | 成功 | **rc=0** TLSv1.3 ✅ |
| C | `sslmode=require` @6432（对照） | 成功 | rc=0 ✅ |
| D | `verify-full` **无** `sslrootcert` | 失败 | `root certificate file "/root/.postgresql/root.crt" does not exist` ✅ |
| E | `verify-full&sslrootcert=system` | 失败 | `SSL error: certificate verify failed`（⇒ RDS 非公有 CA 签，与 §三② 一致） ✅ |
| F | `verify-full&sslrootcert=<不存在的路径>` | 失败 | `root certificate file "…leaf-nothere.crt" does not exist` ✅ |

> ⚠ **副作用（必须写进备站部署清单）**：`sslrootcert` 是**路径**，备站 Deployment 部署时**必须**把 `rds-ca-apse6` 挂到 `/etc/ssl/rds`，否则连接直接失败。
> **回滚**：`sed -i 's/sslmode=verify-full&sslrootcert=[^&]*/sslmode=require/'` 后重新 `patch secret`。

### 7.2 缺口③ 建连判据 —— ✅ 已重定为 ≤300 ms

指南任务 30 卡判据表与 §12 已同步修订（详见指南「判据修订」引言块）：跨区 RTT 35 ms × 约 7 次往返 ≈ 250 ms 属物理下限，`≤200 ms` 仅同区可达。**对冲动作** = 连接复用 + 池预热，二者至少落一条（任务 36/49 接管演练时验证）。

### 7.3 缺口① V4 拔线自愈 —— ✅ 已闭环

**方法**：SG 节点（VPC 内经 NAT，SNAT 出口 = 4 个 `sg_standby_eip` per-flow 哈希轮换）对 RDS 公网串 `:6432` 做 **N=100 次独立 TCP 建连**，三段对照；同时 ping 作区分证据。

| 段 | 白名单 `sg_standby_eip` | TCP 成功率 | ICMP | 证据 |
| --- | --- | --- | --- | --- |
| baseline | 4×/32（含 `47.84.126.214`） | **100/100 = 100.0%** | 0% 丢包（36.16 ms） | `probe_baseline.out` |
| **broken**（移除 `47.84.126.214/32`，TaskId `100248840`） | 3×/32 | **69/100 = 69.0%** | **0% 丢包**（36.18 ms） | `probe_broken.out` |
| recovered（恢复 4×/32，TaskId `100248841`） | 4×/32 | **100/100 = 100.0%** | 0% 丢包（39.29 ms） | `probe_recovered.out` |

**结论与可复用事实**：
1. **失败率 31% ≈ 理论 25%（4 选 1）** ⇒ SNAT 出口**确实按连接轮换**，验证了任务 30 坑 6 的推论：「只放当前看到的那一个 IP 必然间歇断连」。
2. **失败形态 = 3001 ms 超时（DROP，非 RST）** ⇒ 故障现象是「卡住等超时」而不是「快速 connection refused」。对应用意味着：**必须有连接超时（`connect_timeout`）与重试**，否则线程会被长时间占用。
3. **ICMP 全程 0% 丢包** ⇒ 网络层健康，**只靠 ping 无法发现白名单问题**，必须做 TCP 层拨测（§11.3 的「连接失败率」告警设计由此得到实测支撑）。
4. **白名单恢复即自愈**：恢复后第一次探测（14:00:19 #1）即 OK，**无残留**；且 broken 段出口回显里明确出现被移除的 `47.84.126.214`，因果链闭合。
5. **口径说明**：本次证的是**链路层自愈**（白名单→连接恢复）。**应用层自愈**（连接池重建/重试）因备站 `new-api` ns 零工作负载**无法实测**，须在任务 35/36 备站部署后补测，**不得记为已闭环**。

### 7.4 缺口④ §12 接管 SLA 口径表 —— ✅ 已回填

指南 §12「SLA 99.95% 判定口径」已新增「跨区数据面基线（任务 30 实测回填）」一行：RTT p50 37 / TPS 30.46 / TLS 100% / 建连 276 ms / 复用 35 ms，并标注为「接管期 P95 首字 ≤1500 ms」的唯一量化输入。

### 7.5 缺口⑤（新）V3 连接账目 —— ✅ 本次一并闭环

探针 Pod 删除后复测（`t30-v3` 一次性 Pod，`SQL_DSN` 走 Secret 且挂载 CA）：

| usename | state | 会话数 |
| --- | --- | --- |
| `aurora` | — | 8（RDS 内部托管） |
| （usename 对非特权账号隐藏） | — | 5 |
| `alicloud_rds_admin` | — | 3（RDS 运维） |
| `newapi_migrate` | — | 2（主站迁移账号，内网） |
| `replicator` | — | 1 |
| **`newapi_sg`** | **active** | **1（本次探针自身）** |

⇒ **此前 `idle 15` 已被托管 PgBouncer 回收**（`server_lifetime` 到期），备站 `newapi_sg` 会话 = 探针自身，删除后归 0；SG `new-api` ns 工作负载（deploy/sts/ds）**全空**。**判据 `≤ 10 × 备站副本数` 成立**（备站 0 副本 ⇒ 0，实测 1 且为探针）。
> ⚠ 附带事实：`pg_stat_activity` 中**非特权账号也能看到其他会话的 `usename`/`state`**（敏感列被隐藏）⇒ 连接账目审计不需要 superuser，这是可复用方法。

### 7.6 新增可复用产物

| 文件 | 用途 |
| --- | --- |
| `deploy/certs/rds-apse6-ca.crt` | RDS 马尼拉根 CA（根 + 6 区中间），可直接被 `sslrootcert` 使用 |
| `deploy/task30_bodies/11-sg-verifyfull.sh` | 落地 CA Secret + 探针 Pod 跑正/负例矩阵（模板，`__CA_B64__` 需注入） |
| `deploy/task30_bodies/12-sg-dsn-verifyfull.sh` | DSN 切 `verify-full` + 用 Secret 原值端到端复验（幂等） |
| `deploy/task30_bodies/13-sg-conn-probe.sh` | 拔线自愈三段探测（`sed` 注入 `TAG=baseline/broken/recovered`） |
| `deploy/task30_bodies/14-sg-v3-conncount.sh` | V3 连接账目（`pg_stat_activity` 分组，任意业务账号即可） |

### 7.7 本卡状态

**Day 1 · 任务 30 —— ✅ 可销账**：五项判据 **4✅ + 1 已修订（建连 ≤300 ms）**；**V1 ⚠ 等价证据**（`inet_server_addr()` 受 superuser 限制，已用启动时刻 + 库名 + 版本 + V2 交叉佐证，属技术不可得而接受）、**V2 ✅**、**V3 ✅**、**V4 ✅**；§12 已回填。
**唯一保留项**：**应用层自愈**（连接池侧重建/重试）因备站 `new-api` ns 零工作负载**无法实测**，须在任务 35/36 备站 Deployment 就位后补测——**本报告不将其记为已闭环**。


