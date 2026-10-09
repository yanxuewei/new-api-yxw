# Day 2 · 任务 28｜新加坡 PH 备 Deployment + Secret —— 执行报告

- **判定**：**⚠ 部分交付，不计闭合**。V1/V2/V3 **✅ 实测通过**；**V4 ⛔ 阻塞**（卡片判据要"主站 token 打 SG ALB"，而 SG 侧 ALB/Ingress 属任务 25，实测集群内 `AlbConfig` 与 `Ingress` 均为 0、云侧 ap-southeast-1 ALB 实例数 **0**）。
- **卡片窗口**：D2 上午 11:00–13:00（单人 2 人时）。**实际执行 13:42–14:00**（顺延，原因：先完成 10-06 F13/F14 裁定回写）。
- **通道**：`deploy/ack_remote.sh sg`（SG 集群 `ca75829e3492d491d9d434de087913798`，`endpoint_public_access=false`，全部 kubectl 经云助手在 VPC worker `10.1.x` 节点内执行；`ACKCTL_DIR=/tmp/ackctl-sg-t28`）。
- **写操作清单**：`Deployment/new-api-ph-standby`、`Service/new-api-ph-standby`（**均为新建**，SG `ns/new-api` 此前实测**无任何业务对象**，不覆盖、不修改既有对象）；另有两个**临时探针 Pod**（`t28-pg`/`t28-pg2`，`postgres:17`，用完即删，实测已删）。**未新增任何云资源、未产生云费用**（跑在既有 2 台按量节点上）。
- **产物**：`deploy/aliyun/ph/standby-deployment.yaml`、`deploy/task28_standby.sh`、`deploy/task28_bodies/{00-recon,01-recon2,02-mnl-check,03-ingressclass,04-verify-extra}.sh`、`deploy/logs/task28_*`（11 个目录）。

---

## 一、前置复核（卡片「前置/状态」四条逐条对账）

| 卡片前置 | 实况 | 证据 |
| --- | --- | --- |
| 任务 24 SG 集群就绪、**常态 2 节点** | ✅ 2 节点，且**分属 1a/1b**：`ap-southeast-1.10.1.19.103`=**1a**/`ecs.g9ae.2xlarge`、`…10.1.38.113`=**1b**/`ecs.g8ine.2xlarge`；allocatable 各 **7910m / ~29.5Gi**；已请求 1a `3310m/4626Mi`、1b `1400m/2204Mi` ⇒ 单 AZ 放 1 副本（requests 2C/4Gi）绰绰有余 | `logs/task28_recon2_20261006-134525/`、`logs/task28_precheck_20261006-135341/` P4 |
| 机型口径 | ⚠ **卡片原写 g9i.2xlarge 与实际不符**（两台既非同类、也不是 g9i）⇒ 已在指南卡片前置段落落 10-06 纠偏；成本口径按 `task23_price_matrix.py` 的 1a 三机型含盘包月（g9i 302.10 / g9ae 332.32 / g8ine 362.44） | 同上 + `deploy/docs/Day2任务23_stable部署_执行报告.md` |
| 任务 22 跨区 DSN 路径已定 | ✅ 现网 sg `SQL_DSN` 实测 = `postgres://newapi_sg:***@pgm-5tstdhko64x2c01wpub…:6432/newapi?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`（**verify-full 已落**，卡片步骤 2 的"sg 现为 require"**已过时**）；CA 由 `secret/rds-ca-apse6` 提供 | `logs/task28_recon_20261006-134247/` §5（值已脱敏）、`logs/task28_precheck_…-135341/` P1 |
| 单地域镜像源，两集群同仓同 tag | ✅ 同仓同 tag 同 **digest**：`…newapi-master:20260928-26ac63233`，`imageID=sha256:38fd74feac699a7926378f5bed197fd881409d58dddd2ab56f550ecdd72282b3`（两 Pod 一致），与马尼拉 stable 同 tag | `logs/task28_verifyextra_20261006-135749/` ⑤ |
| **两地域 `SESSION_SECRET` 必须一致** | ✅ **实测同指纹**：mnl `sha256[:12]=c5fbe2dbc89b`（len 42）、sg `c5fbe2dbc89b`（len 42）⇒ 保管目录单真源生效。⚠ `SESSION_SECRET_OLD` **sg 缺失**（mnl 有，`6b9e5430519c`）⇒ 属任务 17 残留，**不影响本卡**（备站只用现役密钥），但双密钥过渡（任务 55 R40）在 sg 侧尚未武装 | `logs/task28_mnlcheck_20261006-134548/` §A、`logs/task28_recon_…-134247/` §5c |

## 二、与卡片 YAML 的 **5 处差异**（每处都是"照卡片写就起不来/不自洽"，已写进清单文件头注释）

| # | 卡片写法 | 为什么必须改 | 实测证据 | 改法 |
| --- | --- | --- | --- | --- |
| ① | `image: ${ACR_PUB_PREFIX}`（占位，未强调域名） | SG 解析不到马尼拉 `-vpc` 端点 | 节点侧 `curl …-registry-vpc…/v2/` → **`http=000`**；公网域名 → `8.220.143.202`、`http=401 connect=0.033s`（401=待鉴权，helper 补） | 清单钉死**公网域名**；执行器 `--precheck` 还加了"镜像域名含 `-vpc` 即 die"的护栏 |
| ② | `envFrom` **只写 configMapRef** | 凭据全在 Secret 里；照卡片 ⇒ Pod 起来但无 `SQL_DSN`，连不上库，表现为"readiness 不过" | sg `new-api-secrets` 实测键 `['LOG_SQL_DSN','SESSION_SECRET','SQL_DSN']` | 补 `secretRef: new-api-secrets` |
| ③ | 无 CA volume | DSN 写死 `sslrootcert=/etc/ssl/rds/ca.crt`，**文件不存在则建连直接失败** | sg 已有 `secret/rds-ca-apse6`（键 `ca.crt`）；挂载后 Pod 内 `/etc/ssl/rds/ca.crt -> ..data/ca.crt` 且 `pg_stat_ssl.ssl=t` | 补 `rds-ca` volume + `mountPath=/etc/ssl/rds`（readOnly） |
| ④ | 无 `GOMAXPROCS` | limits 4C 而节点 8C 机型，Go 按宿主核数起 worker 会被 throttle（任务 23 坑 2 同源） | sg 节点 `g9ae/g8ine` = 8C | 补 `GOMAXPROCS=4` |
| ⑤ | 只有 readiness + `livenessProbe.initialDelaySeconds: 40` | 备站冷启动含**跨区公网拉镜像**（任务 16 实测 11 s）+ 首连马尼拉主库，40 s 窗口在慢拉取时会把冷 Pod 打死 | `imagePullPolicy: IfNotPresent` + 本次首拉发生在节点冷态（apply 后 25 s 内 2/2 Ready） | 补 `startupProbe`（5s×30=150 s），readiness/liveness **参数保持卡片原值** |
| 补 | 卡片 V2/V3 用 `kubectl exec deploy/… -- psql` | **业务镜像里没有 psql** | `command -v` 实测：`psql/pgbench/curl/nc = MISSING`，只有 `wget`、`openssl` | V2/V3 改走 `postgres:17` 探针 Pod（沿用任务 30 已验证做法），注入同一条 Secret + 挂同一份 CA |

## 三、执行流水

| 步骤 | 模式 | 结果 | 日志 |
| --- | --- | --- | --- |
| 只读侦察 | `task28_bodies/00-recon.sh` | 拿到节点/Secret/CM/SA/Quota/拉取/6432 六项现值；**脚本缺陷见 §七** | `logs/task28_recon_20261006-134247/` |
| 缺口复测 | `01-recon2.sh` | ns 对象全清单（**全空**）；SG 无 Redis 键；IngressClass 异常发现 | `logs/task28_recon2_20261006-134525/` |
| 两地配对 | `02-mnl-check.sh`（mnl 集群） | SESSION_SECRET 同指纹；镜像无 psql；mnl cm 与 sg 仅 TZ 不同 | `logs/task28_mnlcheck_20261006-134548/` |
| IngressClass 取证 | `03-ingressclass.sh` | 见 §七 坑 5 | `logs/task28_ingressclass_20261006-135357/` |
| 预检 | `--precheck` | P1–P7 全绿（修掉两处脚本 bug 后复跑）：依赖齐、配额 `4.00/48.00 C`、`16.00/128.00 Gi`、AZ=2、registry 401、6432 OPEN、无同名对象 | `logs/task28_precheck_20261006-135239/`（首跑，含脚本缺陷）、`…-135341/`（复跑） |
| 服务端校验 | `--dryrun` | `deployment.apps/… created (server dry run)` + `service/… created (server dry run)` | `logs/task28_dryrun_20261006-135438/` |
| 落地 | `--apply` | `poll 5 ready=2 available=2 → 达标`（≈25 s） | `logs/task28_apply_20261006-135507/` |
| 验收 | `--verify` | 首跑（`…-135538/`）暴露 §六 三处判据缺陷；**规范跑**（`…-135936/`）无错误、V1/V2/V3 全绿 | 两份都留 |
| 补强取证 | `04-verify-extra.sh` | 401 鉴权响应、digest 核对、`pg_postmaster_start_time`、backend_start 差分 | `logs/task28_verifyextra_20261006-135749/` |

## 四、验收结果（判据原文 vs 实测）

| 判据 | 卡片期望 | 实测 | 结论 |
| --- | --- | --- | --- |
| **V1** 副本分布 | 2 副本分属 1a/1b | `spec.replicas=2 ready=2 available=2`；`bkgkz`→node 10.1.38.113=**1b**、`clkzv`→node 10.1.19.103=**1a**；去重 AZ=2 | **✅** |
| **V2** 备地域不写 | `permission denied` | `ERROR: permission denied for schema public`（建表包在 `begin;…;rollback;` 里做二次护栏；随后 `drop table if exists` 报 `table "_t28_probe" does not exist` ⇒ **确认库里没留下表**） | **✅** |
| **V2b** 连的是马尼拉主库 | （卡片未给判据，执行时补） | `inet_server_addr()` 需 superuser、实测回 **NULL** ⇒ 用等价证据：`newapi_sg / newapi / 17.10`、`pg_postmaster_start_time()=2026-09-29 15:59:16+08`（与任务 30 留档的马尼拉实例启动时刻逐字一致）、`ssl=t`、`TLSv1.3` | **⚠ 等价证据成立，直接证据技术不可得**（沿用任务 30 §V1 口径） |
| **V3** 连接账目 | ≤ 150×2=300 | `newapi_sg` 会话 **6**（规范跑）/7（补强跑），状态 `idle 5 + active 1`；**归因**：`backend_start` 全部落在 `2026-10-06 13:55:00+08`，即备站 Pod 启动那一分钟，而任务 30 留档"0 副本时该账号会话归 0"⇒ 这 6 条就是备站 2 个 Pod 的（每 Pod ≤ 显式 `SQL_MAX_OPEN_CONNS=10`） | **✅（远优于判据）** |
| **V4** 会话/令牌互通 | 主站 token 打 `SG_ALB_DNS` → `true` | SG 集群 `AlbConfig`/`Ingress` **均无**、云侧 ap-southeast-1 `ListLoadBalancers` **TotalCount=0** | **⛔ 阻塞（任务 25）** |
| V4 替代取证 | — | 无效 token 打 `/api/user/self`、`/api/log/self` → 两条 **`HTTP/1.1 401 Unauthorized`**（不是 500）；`/api/status` 经 Service DNS 返回 JSON；`information_schema.tables(public)=37`、`select count(*) from users` 可读 | **⚠ 只能算"链路可用"，不等同 V4**（真实主站 token 的跨区验签仍未做） |
| 附：容器 env 生效 | 卡片裁定② 10/5 覆盖 cm 100/50 | Pod 内 `SQL_MAX_OPEN_CONNS=10`、`SQL_MAX_IDLE_CONNS=5`、`NODE_TYPE=slave`、`GOMAXPROCS=4`、`SYNC_FREQUENCY=30`、`MEMORY_CACHE_ENABLED=false`、`TZ=Asia/Singapore` | **✅**（`env` 优先于 `envFrom` 得到实证） |
| 附：备站不发 DDL | §6.2 坑 1 | 启动日志 grep `redis|memory.?cache|migrat` 只命中 `[SYS] … REDIS_CONN_STRING not set, Redis is not enabled`，**无任何 migrate/AutoMigrate 行** | **✅** |

## 五、Secret 侧结论（卡片步骤 2 只写了 ExternalSecret）

- `ExternalSecret`/KMS 按 2026-10-05 裁定**不实施**；卡片步骤 2 那两行 `kubectl apply -f external-secret-sg.yaml` **作废留痕**。
- 本卡**不新建 Secret**：实测 sg `new-api-secrets` 三键已覆盖备站所需（`SQL_DSN`、`LOG_SQL_DSN`、`SESSION_SECRET`）；缺的 `REDIS_CONN_STRING`/`SQL_DSN_MIGRATE`/`SESSION_SECRET_OLD` 属任务 17 的 sg 残留 —— **三键里只有两键可补**（`REDIS_CONN_STRING` 需 SG Tair），且脚本 sg 分支原先不带 `SQL_DSN_MIGRATE`，已在 10-06 加固为 5 键并加单站过滤（见 §十二-补 与任务 17 报告 §十三），**不在本卡窗口内动**（整键覆盖写，须单独执行且只能在 WSL 堡垒机）。

## 六、卡片"验证方法"的三处方法级错误（本轮实测带出，卡片必须改）

1. **V2/V3 的前提不成立**：`kubectl exec deploy/new-api-ph-standby -- psql …` ⇒ 业务镜像**没有 psql**（也没有 curl/nc）。必须显式写明"用一次性 `postgres:17` 探针 Pod + 同 Secret + 同 CA 挂载"。
2. **V3 的 `client_addr` 归因是错的**：经 RDS 侧连接池，`pg_stat_activity.client_addr` 实测**全是 `127.0.0.1`**，无法证明"这些连接来自备站 Pod"。可用方法是**差分**：`backend_start` 时间分布 vs 副本启动时刻 + 0 副本基线（任务 30 已留档归 0）。
3. **V3 的池判据不可取证**：`show pool_mode / default_pool_size / max_client_conn` 在 6432 端点实测 **`unrecognized configuration parameter`**（`show max_connections=820` 可取）。⇒ "含池化后实际值"只能引用任务 41 的配置侧留档，不能写成可在 Pod 内 SHOW 出来的判据。

## 七、坑与风险（新增/复核）

- 坑 1（**卡片坑 5 已兑现为正面对策**）：备站 Service 只有 ClusterIP，未挂任何 ALB/GTM ⇒ 常态零流量，实测 endpoints 存在但集群内无 Ingress 引用。
- 坑 2｜**SG 无 Redis 是"已知降级"不是遗漏**：`common/redis.go:25` 对空 `REDIS_CONN_STRING` 是 `RedisEnabled=false` + 一条日志 + `return nil`（**不致命**），而 cm `MEMORY_CACHE_ENABLED=false` ⇒ 限流退化为单 Pod 内存态（`middleware/rate-limit.go:148`）、渠道/配置每次读库。备站常态零流量可接受；**要恢复跨副本一致性需 SG Tair（成本项，另卡裁定）**。现网日志已实测到该降级行。
- 坑 3｜liveness 绑 `/api/status`（卡片坑 3 仍在）：主库抖动时 `/api/status` 虽不查库，但冷 Pod 一旦被 startupProbe 放行后仍有 5×15 s 的 kill 窗口；根治仍是 G8 的 `/healthz`。本卡把风险从"启动期"收住，未消除"运行期"。
- 坑 4｜探针 Pod 也受 `new-api-quota` 管：必须给 `resources`，否则 `Forbidden: failed quota`（任务 16 §六③ 已记，本卡脚本照做：100m/128Mi）。探针 `postgres:17` 走公网拉取，实测 `phase=Running` 约 8–12 s。
- 坑 5｜**并发会话已在动 SG 集群**：`IngressClass/alb`（`parameters → AlbConfig/sg-alb`，labels `site=ph-sg`，`kubectl.kubernetes.io/last-applied-configuration` 注解）实测创建于 `2026-10-06T05:44:40Z`（本地 13:44:40），**正好落在我这次侦察窗口内**；`ownerReferences=None`、集群内 `AlbConfig` 对象数 0、云侧 ALB 实例 0，`deploy/manifests/ingressclass-sg.yaml` + `deploy/task25_bodies/01-ingressclass.sh` 是同一份内容 ⇒ 判定为**任务 25 的并发执行**，非本卡所为、也非控制器自动建。ALB 控制器本身活着（`lease/alb` holder `controlplane-alb-85b899ccd-ccz2p`，`renewTime` 与节点 UTC **同秒**）。⇒ 两卡对象不重叠（本卡只 deploy/svc `new-api-ph-standby`），但**任务 25 的 Ingress 后端正是本卡 Service**，本卡 apply 客观上是它的前置。
- 坑 6｜`v1 Endpoints is deprecated in v1.33+`：集群 1.35.7，卡片 `kubectl get endpoints` 仍可用但每次带告警；判据应改 `EndpointSlice`。

## 八、待办 / 需裁定

| 项 | 归属 | 说明 |
| --- | --- | --- |
| **V4 真判据**（主站 token → SG ALB） | 任务 25 落地后回补 | 需要 SG ALB DNS + 一个真实主站 token；**token 属凭据，执行时只走集群内注入、不进日志** |
| sg 补 `SESSION_SECRET_OLD` + `SQL_DSN_MIGRATE`（`REDIS_CONN_STRING` **不在可补范围**） | 任务 17 残留 | ✅ **2026-10-06 用户核准补齐**（原话「sg 三个 Secret 键可以补齐」）。脚本已就绪并加护栏（见 §十二-补），但**本会话无法执行**：明文只在 **WSL 堡垒机** `/root/.deploy_secrets/`（本机 macOS 实测 `ls /root/.deploy_secrets` = No such file、`/mnt/e/...` 不存在）⇒ 属"核准到但执行位不在此"，须由项目负责人在 WSL 侧跑 `bash deploy/task17_secret_inject.sh --apply sg`。**三键里只有两键可补**：`REDIS_CONN_STRING` 需 SG Tair（任务 29 仍 `Trade_Not_Support_Async_Pay`）⇒ 脚本对 sg **不写该键**，不是遗漏 |
| SG Tair 是否采购（决定备站有无 Redis 一致性） | 成本裁定项 | 现状=不建；若 GTM 接管后要求限流/缓存跨副本一致，则必须建 |
| 443 / `SESSION_COOKIE_SECURE` / `TRUSTED_URL` | 任务 44 + G5 证书 | 与主站同批，本卡未动 |
| 任务 43 的 sg HPA（`2–24`） | 任务 43 | 本卡按卡片**只建 Deployment 副本数 2**，未建 HPA/PDB；**且 24 需按 F12/F14 口径重算 = 主站 15 × 1.5 ≈ 23** |

## 九、xlsx 回改项（只列不改，遵守"绝不编辑 xlsx"）

| 格 | 现值 | 应改 | 依据 |
| --- | --- | --- | --- |
| `资源清单-新加坡!H18` | `… SQL_MAX_OPEN_CONNS=150；HPA min 2 / max 24` | ① `SQL_MAX_OPEN_CONNS` **150 → 10**（与 `SQL_MAX_IDLE_CONNS=5` 同批；这是卡片裁定② 2026-09-29 的口径，现网 Pod 实测 10/5）；② `max 24` → **23**（F12 主站 15 × 1.5，与总结 §7 `B29` 行同源，不能只改一处） | 本报告 §四 附行、`logs/task28_verify_20261006-135936/` |
| `里程碑与验收!D7` | 含"PH 备 Deployment 部署完成" | 标 **⚠ 部分**（Deployment/Service ✅、V4 会话互通 ⛔ 依赖任务 25） | §四 V4 |
| `落地计划!C26`/对应 AC 列（SG 侧那行） | 未开始 | **配置完成 / 验收 V4 未做** | §三 |

## 十、安全事件（必须留痕）

首版只读侦察脚本 `00-recon.sh` 在"打印 Secret 键名"那一步写法有误（`jsonpath='{.data}'` 直接把 **base64 值**一起输出），导致 `SQL_DSN`、`LOG_SQL_DSN` 的键值（含口令的 base64）与 `ca.crt` 全文出现在**会话输出与本地日志**里。处置与状态：

1. 立即用本地脚本对该日志做脱敏，复扫判据：`:[A-Za-9]{12,}@` 形态口令 **0 处**、`BEGIN CERTIFICATE` **0 处**（`logs/task28_recon_20261006-134247/remote.out`）。
2. `deploy/logs` 命中仓库 `.gitignore` 第 13 行 `logs` ⇒ **未进入 Git**（`git check-ignore -v` 实测）。
3. 脚本层已修正：后续所有 Secret 读取一律"整体 `-o json` → 本地 python 只取键名"，值不落任何输出（`01-recon2.sh` §B、`task28_standby.sh` P1、`02-mnl-check.sh` §A 的骨架掩码 + 指纹口径）。
4. **是否轮换这两个口令（RDS `newapi_sg`、ClickHouse）请裁定** —— 泄露面限于本机文件与本次会话记录，未出机器；轮换属密钥轮换，未核准不动手（任务 4 的 RDS 轮换 SOP 可复用）。
   ✅ **2026-10-06 裁定：不轮换，AI 不处理，后续由人工修改**（原话「不用处理，后面会人工修改」）。⇒ 本项从"待裁定"降为"人工待办"，脚本与集群侧**不做任何动作**；登记口径保留（事件本身与脱敏证据不得抹掉）。

## 十一、本卡应固化进指南的内容

- 清单：`deploy/aliyun/ph/standby-deployment.yaml`（差异①–⑤ 的依据写在文件头）。
- 执行器：`deploy/task28_standby.sh`，模式 `--precheck | --dryrun | --apply | --verify | --status | --cleanup`；`--cleanup` 可整卡回退（只删本卡 deploy/svc/探针，保留 Secret/CM/SA/CA）。
- 护栏已进脚本：镜像域名含 `-vpc` 即 die、tag 为 `latest` 即 die、清单解析不到 replicas/requests/limits 即 die、Apply 前 AZ 去重数打印。

## 十二、文档回写（2026-10-06 已完成，本轮实际改动清单）

| 文件 | 改动 |
| --- | --- |
| 指南 `任务 28` 卡 | ① 卡头加 `⚠ 部分交付（V1–V3 ✅，V4 阻塞于任务 25）` + 执行状态块（指向本报告/脚本/manifest）；② 前置段补"两地同 digest `sha256:38fd74f…82b3`"与"两地 `SESSION_SECRET` 同指纹 `c5fbe2dbc89b`（静态前提≠V4）"；③ 步骤 1 YAML 后加**实况纠偏表 D1–D5**（YAML 原文保留作方案口径）；④ 步骤 2 ExternalSecret 两行标"作废留痕、勿执行"并替换为"本卡不建 Secret，一律走 `task17_secret_inject.sh`"，同时**更正 `sslmode` 过期文本**（sg 已 `verify-full` + CA 落地，原"现为 require"作废）；⑤ 验证方法后加**验证实况**（3 处方法级错误 + V1 按 `nodeName` 反查 zone 的正确查法）；⑥ 不通过时修复首条补两个高频成因（未挂 CA / `-vpc` 域名 + `SA/new-api-app` 凭据）；⑦ 坑 6/7/8 新增（探针无 `psql`、取键名泄值、备站少键不报错） |
| 指南 `Day 2 · 泳道 B 出口检查清单` | "新加坡备站"行加 10-06 实况：前四项 ✅、V3 期望由 300 改 20、**V4 ⛔ 归任务 25** ⇒ 本行不得勾选 |
| `核心更新总结_2026-10-05.md` | §1 标题与计数改 **3 张部分交付**、B 窗行加任务 28；**新增 §1c 任务 28 交付明细**（含安全事件行）；§4 加"任务 28 的 V4 ⛔ 阻塞"；§5 新增 **⑧**（步骤 2 `sslmode` 与任务 30 登记矛盾，已连正文更正 + 整键覆盖写的回退风险）；§6 加 **18**（是否轮换口令，待裁定）与 **19**（补三键 + V4 重放，两项收尾）；§7 加 **4 行**（`资源清单-新加坡!H18` 补正为"CM 100 / 备站 Pod 10"两层 + `max 24→23`、`里程碑与验收!D7` 标 ⚠ 部分、`落地计划!C26/AC26` 改配置完成、`AC 列整体` 行补任务 28） |

> xlsx **未编辑**（遵守"只出回改清单"）。本轮全部改动**未 commit**。

## 十二-补、`task17_secret_inject.sh` 加固（2026-10-06，响应"sg 三键可补齐"的核准）

| 改动 | 为什么 |
| --- | --- |
| sg 分支补 `SQL_DSN_MIGRATE`（**公网串 5432 直连** + `verify-full` + `sslrootcert=/etc/ssl/rds/ca.crt`），注入键数 4 → **5** | 原 sg 分支**根本没有这个键**，所以"跑一次 `--apply` 就能补齐三键"是不成立的（报告上一版的说法已随本条更正）。迁移是 DDL，按任务 41 不得经 6432 池 ⇒ 与 mnl 同口径用 5432，跨区只能 `-public`；接管态要在 sg 跑 `deploy/aliyun/ph/migrate-job.yaml` 必须有它 |
| `--apply [mnl\|sg\|both]` 站点过滤（默认 both） | 本脚本是**整键覆盖写**。两地实况已分叉（mnl 6 键 / sg 3 键），默认 both 会在补 sg 的同时把 mnl 也重写一遍 ⇒ 必须能只动一侧 |
| 两地 body 各加 `== keys BEFORE ==` 打印（与注入后对照） | 覆盖语义下"少了哪个键"只能在**写前写后两次键集对照**才看得见；这正是任务 28 坑 8 的根因，不能靠事后 `--status` 补救 |
| 键名打印由 `jsonpath='{.data}'` 改为 `-o json` → python 只取 `.data` 的 keys | **原脚本自身就带着坑 7 的写法**：`jsonpath='{.data}'` 经 `tr/sed/awk` 会把 **base64 值一起打出来**。已两处（mnl/sg）替换，值不再进 stdout |
| `VAULT` / `ENVFILE` 改为 `${VAULT:-…}` / `${ENVFILE:-…}` 可覆盖 | 为了能在无明文的开发机上做**离线渲染自测**（见下），不需要为测试把口令搬到本机 |

**离线渲染自测（本轮实跑，不触碰真值）**：用 `/tmp` 伪造保管目录（值全为 `FAKE-*`）→ `source` 脚本前半 → `build_body sg` → 断言渲染结果：**5 个 `--from-literal`**、含 1 行 `keys BEFORE`、两条 DSN 均为 `sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`；随后 `shred -u` 渲染产物与伪保管目录。另外该次自测还**顺带证实了 sg 的 `-public` 守卫会拦**：伪造 VPC 端点时脚本直接 `die "sg LOG_SQL_DSN 端点不是 -public"`。`bash -n` 通过。

**⚠ 仍待人工执行（本会话做不到）**：明文保管目录在 **WSL 堡垒机** `/root/.deploy_secrets/`，本机 macOS 上 `ls /root/.deploy_secrets` = No such file、`/mnt/e/git_code/new-api-yxw/deploy/.env` 不存在 ⇒ **注入动作须在 WSL 侧运行**：

```bash
# 在 WSL 堡垒机（有 /root/.deploy_secrets 与 deploy/.env 的那台）执行
bash deploy/task17_secret_inject.sh --check
bash deploy/task17_secret_inject.sh --apply sg      # 只动 sg，5 键；mnl 不碰
# 回读判据：两地键集差只剩 REDIS_CONN_STRING（SG Tair 未建，故意不写）
```

执行后请把 `== keys BEFORE ==` 与注入后键集留进 `deploy/logs/task17_secret_*`，并回写本报告 §四 附行与 `核心更新总结` §6-19。
