# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威文档**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（4 天/单人/CLI-first · F1–F11 · 56 任务卡）② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（7 表）。二者冲突 **以 ① 为准**（① 修订 09-27/28，晚于 ② 的 09-24）。
> **详版口径 + 全部坑 → `REFERENCE.md`**（账号/CLI/权限/RG/RAM/ACR/配额/询价/容灾/SLS/网络/Docker/私网通道/ACK 节点池/ALB/域名 DNS）。过程流水 → `YYYY-MM-DD.md`。权限权威 `deploy/用户设置指南.md`；切换方案 `deploy/DCDN回源层切换_方案.md`。
> **本文只留：执行环境 + 文档冲突 + 高频铁律 + 付费 + 域名 + 当前状态**。写细节请写 REFERENCE。

## 执行环境（2026-09-28 起 · 优先级最高）
**所有命令默认在 WSL Ubuntu 跑**，不用宿主 Git Bash / PowerShell。
- 调用 `wsl -d Ubuntu -u root -- bash -c "..."`；**带引号/多行脚本先 Write 成文件再 `bash /mnt/e/.../x.sh`**（直传被 wsl.exe 拆坏）。宿主 `E:\git_code\new-api-yxw` = WSL `/mnt/e/git_code/new-api-yxw`。
- ⚠️ `/mnt/e` 文本是 **CRLF** → `grep`/`awk`/命令替换读入残 `\r` → 比对**必然假失败** → **一律接 `tr -d '\r'`**。
- ⚠️ `bash -c` 不读 `/etc/profile.d/`；`go env -w` per-user → root 与 fanyan 各一份。`$?` 在 `bash -c "...; echo $?"` 里被吞成 0 → 用 `&& echo A || echo B`。
- ✅ Go 1.25.1（= `go.mod`）+ `GOPROXY=https://goproxy.cn,direct`；`web/` 前端用 bun（WSL 内**无 node/npm/bun/kubectl/helm**，需时装 Linux 版）。
- ✅ PATH 污染已清：`/etc/wsl.conf` 加 `[interop] appendWindowsPath=false`。**编译/装依赖别放 `/mnt/e`**（`/tmp` 2.9 GB/s vs 421 MB/s）。
- 容器 `new-api`(:3000) · `postgres:15` · `redis` 均 `restart: always`。
- ⚠️ **本机不适合构建本仓镜像（2026-10-09 实测）**：`web/` 800+ 依赖使 `bun install` 一次性开 **200+ 并发 TCP**，**WSL2 NAT 建不起来** → 容器内采样 `SYN_SENT≈211 / ESTABLISHED 13~25`（`nf_conntrack 112/262144`，**非**表满）→ bun 永久等齐卡死；**脱离 BuildKit 也能稳定复现**。反证：低并发 `bun add lodash`（4 请求）**391ms 成功**、主机 `curl` 正常 ⇒ **与代码/Dockerfile 无关**。`go mod download` 走 `--go-proxy aliyun` 可用（2.7s）。⇒ 发版构建走 **CI** 或 **macOS**（⚠ fork 现有 `docker-image-branch.yml`/`docker-build.yml` **推 Docker Hub `calciumion/new-api`，无推 ACR 的 workflow**，需新增）。
- **macOS 侧直操云端**：`~/.workbuddy/binaries/aliyun-cli/aliyun`（**无 `--region` 会静默用 profile 地域 ap-southeast-6**）；集群操作用 `deploy/ack_remote.sh`。

## 上游二次开发纪律（2026-10-09 fanyan 下达 · fork 维护总纲）
`new-api-yxw` = `QuantumNous/new-api` 的二次开发分支（origin `git@github.com:yanxuewei/new-api-yxw.git`，分支 `main`）。
**五条铁律**：① **能扩展不改源码**（优先插件/hook/配置覆盖，其次才改上游文件）② 根目录 `UPSTREAM_CHANGES.md` 记定制清单、**每次 sync 前对照检查冲突点** ③ 自研代码放 `ours_likha/{code,ops,doc}` 与上游**物理隔离** ④ **禁止无意义的格式化改动上游文件**（一次格式化 = 永久冲突源）⑤ **merge 冲突解决后必须跑全量测试**，sync PR 的 CI **不允许 skip 任何 job**。
- **落地物**：`UPSTREAM_CHANGES.md`（清单，含"不动的地方"反例表）· `ours_likha/ops/patches/0001-log-ms-precision.patch`（复现补丁）· `ours_likha/ops/verify-upstream-changes.sh`（**在位校验，sync 前后必跑**）· `ours_likha/ops/local-ci.sh`（本地复现 `ci.yml` 全量 job：backend `go vet/build` + `make test`，frontend `bun typecheck/test`）· `ours_likha/code/cmd/logms-check`（**运行时自检**：`go run ./ours_likha/code/cmd/logms-check` → 期望 `RESULT=MS_CONFIRMED`；不需 DB/Redis/Docker）。
- **当前唯一上游改动**：日志时间格式毫秒化 —— **3 文件 5 处**（`middleware/logger.go:38`、`common/sys_log.go:20/27/34`、`logger/logger.go:113`），`15:04:05` → `15:04:05.000`。该需求**无扩展点**（GIN formatter 是闭包硬编码；`middleware.SetUpLogger` 还承载私有脱敏 `redactTaskArtifactAccessQuery`，整体替换会丢脱敏）⇒ 原地最小改写，符合纪律 1/4。
- ⚠️ **纪律 3 的例外**：当"能扩展不改源码"不成立时，允许**最小化原地补丁**，但必须登记清单 + 附可复现补丁 + 配在位校验。

## 两文档口径冲突（一律按 ①）
| 项 | ② xlsx v2.3 | ① 指南（采信） |
|---|---|---|
| 排期 | 2 人×5 天 = 120 人时 | 1 人×4 天×2 窗（A 08:30–14:00 / B 14:00–22:00）；backlog 顺延 T+14 |
| 日志库 | 马尼拉 CK 社区版 + 新加坡 CK | **F9** 仅马尼拉 CK **企业版单 AZ**；日志不入 SLA 证据链 + 写失败必须降级 |
| 镜像源 | 双地域 ACR | **单地域马尼拉 ACR**；SG 走公网端点拉（RTO 须含拉取耗时） |
| 连接收敛 | RDS 代理独享型 | **F10 已撤销**（改用 RDS PG **内置托管 PgBouncer**）；**F11** `max_connections=800` 不可改 → 预算 640 |
| 机型 | `g8i.2xlarge` | **F1 `ecs.g9i.2xlarge`**（g8i 马尼拉全系未上架），备 `g8ine` |
| ALB 超时 | 180s | **600s（上限）**；SSE 靠 15–20s ping 保活 |
| ACK | 1.31+ | **1.35**（1.31/1.33 已 EOL） |
| 证据目录 | `.deploy/evidence/` | `deploy/evidence/` |

## 高频铁律（写命令前必看）
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`；**写完全脚本扫描**。
- **脚本日志勿与 API 输出混流**：日志走 `exec 3>&2`，数据落文件（污染 JSON → jq 假失败）。本机 `tee` ≈0.6s/次 → 逐行日志**不用 tee**。
- **PATH 自愈**：脚本头部加 `case ":$PATH:" in *".workbuddy/binaries/aliyun-cli:"*) ;; *) export PATH=... ;; esac`。
- **CLI 3.5.1 口径**：配额参数**只有 `--ProductCode`**、分页 `--MaxResults`、类别 `--QuotaCategory CommonQuota`；vCPU 配额在 **`--ProductCode ecs-spec`**；地域**必须用维度** `--Dimensions.1.Key regionId`；**`Status: Agree` 只在 `ListQuotaApplications` 返回**（`ListProductQuotas` 无 Status → `select(.Status=="Agree")` 得空集且 **exit 0 假通过**）→ 巡检一律 `jq -e`。错 API/参数名 = exit 2；jq 语法错 = 3。**遇 CLI 说参数名非法，先信 CLI**（如 `alb ListRules` 是 `--ListenerIds` 复数）。
- **探针法（零成本确证能力）**：故意踩**服务端**校验点，看错误落在哪一层。**禁用 CLI 已声明 enum/range 的参数当"必失败点"**；跑完必须复核资源数未变。
- 权限探测**严禁子串匹配**；**不能用不存在的资源 ID 探测**（存在性先于鉴权）→ 用幂等写。**资源 ID 前缀不代表地域** → 判残留必实查 API。
- **VPC 端点两端皆偶发抖动** → 写操作**重试 ≥3 次**并校验返回是合法 JSON，否则**静默漏建资源**。
- **ALB 写操作先干跑**：`--DryRun true` 回 `DryRunOperation` 即校验全过、零变更。
- 一键复核 `deploy/verify_deploy_0_6.sh`（8 项全走 `jq -e`）。**`WARN` ≠ 通过**。

## RAM 权限与 K8s RBAC（2026-10-10 定论）

**★ 两套互不相通的体系，配齐才不报错**：**RAM 策略**管「能否调 OpenAPI」（控制台报「无权限查看」）；**K8s RBAC**管「K8s 里能否 list/get/update 资源」（报 `APISERVER.403 … is forbidden: User "<uid>" cannot list resource "…"`）。两个症状必须分别处理，别混为一谈。

- **`newapi-ops-operator` 现为 v3**（2026-10-10 发布并 SetAsDefault，AttachmentCount=3：挂 `ops_group`/`dev_group`/`ops-prod_group`）。v3 相比 v2 新增 Allow：`kvstore:*`(Tair) · `hdm:*`(DAS) · `yundun-cert:*`(数字证书/原SSL) · `arms:*`(ARMS+Grafana) · `clickhouse:*`(CK) · `quotas:*` · `resourcemanager:Get*|List*` · `ram:Get|ListResourceGroup*` · `tag:Get*|List*|Describe*` · `*:ListTagResources` 等；新增 Deny **`kvstore:DeleteInstance`**（与 `rds:DeleteDBInstance` 同口径）。**IaC（此前正文只在控制台、无 IaC）**：`deploy/ops/ram_policy_newapi-ops-operator.v3.json`（真源）+ `deploy/ops/ram_ops_operator_extend.sh`（`check|apply|verify|desc|rollback`）。⚠️ 策略版本上限 **5**（现 v1/v2/v3）。
- **★ 动作前缀必须逐个在系统策略里核准**（凭记忆写会**静默失效**，RAM 不报错）。已知：`kvstore`=Tair · `hdm`=DAS · **`yundun-cert`=数字证书（原SSL，无 `cas:`/`ssl:` 前缀）** · `clickhouse`=CK · `quotas`=配额中心 · `resourcemanager`/`ram:Get|ListResourceGroup*`=资源组 · `tag`+`*:ListTagResources`=标签。核验方式：`aliyun ram GetPolicyVersion --PolicyName Aliyun<X>FullAccess --PolicyType System`。
- **★ ACK RBAC（`cs`）两条坑**：① **`cs GrantPermissions` 是「全量覆盖」** —— body 必须列出该用户要保留的**全部**集群，否则抹掉其它集群授权 ⇒ 正确姿势「读现状→原样保留所有集群→只改角色」。② **响应字段名与请求不一致**：请求用 `role_name`(预置角色名: admin|admin-view|ops|dev|restricted) + `role_type`(cluster|namespace|all-clusters)；**响应**把预置角色名放在 `role_type`、`role_name` 为空。③ `cs DescribeUserPermission`（`--uid`）**不分地域**，一次返回该用户**全部**集群授权。IaC：`deploy/ops/ack_rbac_grant.sh`（`check|apply|verify`，含**防降权护栏**：admin→ops 会被拒绝，需 `ALLOW_DOWNGRADE=1`）。
- **当前集群清单（3 个）**：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(ap-southeast-6) · sg `ca75829e3492d491d9d434de087913798`(ap-southeast-1) · `cb0abf5bc06034f7bbdb991752f6f3e62`(ap-southeast-6, ack.standard, 09-30 建, 私网端点 `10.2.25.173:6443`)。
- ⚠️ **`UID` 是 bash 只读变量**（root 下=0）——脚本里用它作变量名会静默取到 0；一律换名（如 `RAM_UID`）。

## 付费方式（2026-09-28 指令 + 09-29 CK 补丁 + **10-06 节点池裁定**）
| 产品 | 口径 | 计费参数名 |
|---|---|---|
| ECS 节点池 | **按量付费**（10-06 裁定维持；原「包年包月 1 年」作废） | `instance_charge_type: PostPaid` |
| Tair | 包年包月 12 月 | `ChargeType: PrePaid` |
| RDS PG | 包年包月 **1 年** | `PayType: Prepaid` + **`Period=Year`/`UsedTime=1`** |
| ACK 集群管理费 | **不支持包年包月** → ACK 资源包 | — |
| ClickHouse 企业版 | **只能按量** → **计算资源包**（马尼拉**抵扣因子 1.45**） | 无 `PayType` 参数 |
- ⚠️ **月付周期上限 <12**：`Period=Month`+`UsedTime=12` 报 `Order.PeriodInvalid`。
- **配额口径**：按量 `q_ecs_enterprise_postpay_c`（马尼拉 64 / 新加坡 96，工单 `Agree`）为核量口径；包年包月 `prepay_c`（100/100）仅对照——**两套独立计量**。⚠ **按量下 `max_size` 顶满即零余量**（mnl 8×8=64；sg 12×8=96），**扩容前须先提额**。
- **本池按量 ⇒ HPA 扩容随用随计费、可停可退**；包月/按量**库存池不共享**（查可售须 `--InstanceChargeType PostPaid`）。

## 域名与 DNS（likha.hk · 阿里云云解析）
- **NS `ns7/ns8.alidns.com` 2026-10-06 已生效**（终结 10-05 的 NXDOMAIN）；`DomainId 3b4321ce86d3436aa46e3a8ba96a6133`，免费版 TTL 下限 **600s**。`aliyun alidns` 无需 `--region`，当前 AK 与域名同账号。
- **记录**：`@`（根域）+ `www` 各双 A → `8.212.161.49`(6a) + `8.212.183.7`(6b)，TTL 600（DNS 轮询 = 天然双 AZ）。
- **★ 负缓存坑**：改记录后**权威 + 公共递归秒级生效**，但**本地路由器**可能因旧 NXDOMAIN 负缓存（SOA min TTL **600s**）仍回空 → `curl` 回 **000**。症状出现时**逐层对比上游**，勿误判配置。
- **脚本** `deploy/manifests/dns-likha-hk.sh`（`status|add|del|verify`，幂等，`RR=@` 表示根域，`RR`/`IPS`/`TTL`/`LINE` 可覆盖）。
- ⚠ **两个域名现都靠 ALB「无 Host 兜底规则」命中主站** ⇒ 证书到位加 443 时**必须补 `Host=` 规则**（HTTPS 必带 SNI）。**443 不存在**；`ops.` / `*.` **未配**。
- ⚠ **规则 ID / 服务器组 ID 会漂移**：Controller 重建后 `rule-80-1/2` → `rule-0f7ru4csbcn41ygmb4` / `rule-b1t5tod05rdsfdua8n`。**判路由一律实时查 API，勿引用历史 ID。**

## 进度与环境实况（截至 2026-10-06 21:00）
- **21/56 卡闭合 + 2 张部分交付**。闭合：Day1 全 **13** 张（5/12/6/16/4/13/14/7/8/9/15/41/30）+ Day2 A 窗 **8** 张（10/11/24/42/46/18/17/54）。**部分交付（不计闭合）**：① **任务 19（马尼拉 ALB）** — V1b 超时已修（60/600 ✅）、IP 直访 ✅、drift 占位组已清空；仅剩 `443+TLS` 待 G5。② **任务 25（新加坡 ALB + Ingress）** — ALB `alb-amdwm60xmznh7s1nae` + IngressClass + Ingress + 无 Host Ingress 全通（HTTP 80），**任务卡验收基于 HTTPS 443 ⇒ 不计闭合**。**未动**：任务 3（证书，G5）· 1/2（G0+NS，G4）· 29（SG Tair）· Day2 B 窗 · Day3 / Day4。
- **集群**：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`（ap-southeast-6）· sg `ca75829e3492d491d9d434de087913798`（ap-southeast-1，2 节点 v1.35.7）。
- **★ AlbConfig 字段定论（SG 侧实测定论）**：`idleTimeout`/`requestTimeout` ✅ 有效；`defaultActions` ❌ 与 `httpDefaultActions` ❌ **均不生效**（Controller 一律用 ForwardGroup 覆盖派生占位组，与字段名无关）⇒ 想让 default 兜底**只能靠 Ingress 规则**；`accessLogConfig.logStore` **必须 `alb_` 前缀**（webhook 硬校验）。
- **★ 集群内无 alb-controller Pod 属正常**：ACK 托管形态（webhook+reconcile 在托管平面）⇒ 判死活**一律用 server-side dry-run**，勿看 Pod。
- **既有实例**：RDS `pgm-5tstdhko64x2c01w`（`rds-mnl-newapi`，**PG 17.0**，`pg.n4.2c.2m` **2C8G**，主 6b/备 6a，Prepaid，Running，**到期 2026-10-28 ⚠ 倒计时风险**）· Tair `r-5tsf1fe16543e274`（企业版 1G/2DB/6proxy，仅 6a，**只买 1 个月**）· Tair 新加坡**仍 0 实例** · CK `cc-5tsv2o51s1360b0pr`（企业版单 AZ 6a，已接线）。**规格/周期与指南口径不符 → 待用户裁定**。
- **⚠ RDS 规格口径矛盾**：实况 2C8G，但任务 4 卡正文仍以 `pg.x4.2xlarge.2c` 16C64G 的 15134.47 / 实付 10594.13 USD 为准 —— 两处须对齐。
- **账务**：账户余额 **1,260.55 USD**（**2026-10-09 复核，已充值**；10-05 曾为 0.00）；未支付订单 `518158947970481`（RDS **16C64G**，10594.13 USD）与实建 2C8G 不符，**须确认已取消**。`bssopenapi QueryAccountBalance` 须 `--region ap-southeast-1`（`ap-southeast-6`/`cn-hangzhou` 无 endpoint）。
- **五项裁定（09-30）**：① KMS 实例**不买**（凭据走手工 Secret，已落地）② CK 计算资源包**不买**（走按量）③ 备站→CK 走 **CreateEndpoint 公网**（已落地）④ ALB 现在买（已执行）⑤ **GTM 挂起**（域名到位后可重启评估）。
- **集群侧已落地**：`new-api` ns/SA/ResourceQuota/ConfigMap 两地 · RRSA 角色 `new-api-rrsa-kms-mnl/-sg` · Secret `new-api-secrets`（mnl 6 键 / sg 3 键）· CM `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` · SG `SQL_DSN` 已切 `sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt` + Secret `rds-ca-apse6`（**备站 Deployment 必须挂载，否则连不上**；mnl 侧仍 `prefer`）· VPC/vSwitch · SG×5 · NAT/EIP · ACR（全项闭合）· SLS 两项目 · ACK 两集群 + 节点池 · 私网运维通道。
- **凭据保管**：`/root/.deploy_secrets/`（root 600）= RDS 三账号口令 + CK 两 DSN + SESSION_SECRET×2；Tair 口令在 `deploy/.env`（gitignored）；`newapi_ops` 在 `/home/fanyan/.newapi_rds_ops_password`。待补：`PAYMENT_PRIVATE_KEY`、`TLS_WILDCARD`（用户提供）；SG `REDIS`/`SESSION_SECRET_OLD`/`SQL_DSN_MIGRATE`（SG Tair 未建）。
- **仍未闭环门禁**：G1 实名 · G4 NS · **G5 证书** · G6 模板 PR · **G7 产品开通（含 CK 企业版白名单）** · **G8 代码补项（/healthz·/readyz·/metrics + 限流降级放行）** · G11 连接预算表 · G12 SLA 签字 · G13 staging · 上游 8 EIP 白名单。
- **★ 账号侧「开通/购买」类阻塞（2026-10-10 更新）**：① ✅ **NAAM 网络分析与监控**（`cms_naam_public_intl`，站点监控归属）**2026-10-10 已由控制台开通**（免费/按量；境外探测 8.4 USD/万次，本方案 ≈2.9 USD/月）→ `SiteMonitorTask.QuotaLimit` **0 → 9999**（`SuitInfo=free`）。`aliyun cms` 无 Open 接口、`bssopenapi` 新版**已移除 `CreateOrder`** ⇒ **开通只能控制台「立即开通」**；开通后创建/查询全可 CLI。② ✅ **Grafana 工作区 2026-10-10 已由控制台建成**（`gra-newapi-sg` / `grafana-intl-sg-swy4zuysc01` / 新加坡 / 专家版 10U / Grafana **12.4.x**，snatIp `8.222.236.38`，到期 2026-11-11）；CLI 建工作区历史恒报 601（`grafana_prepaid_public_intl` 在 `ap-southeast-1` 无 `DescribePricingModule` 模块）⇒ **工作区创建必须走控制台，但建好之后的一切配置可全脚本化**（见下条）。
- **★ Grafana 配置通道（2026-10-10 定论）**：`aliyun arms GrafanaWorkspaceHttpApiProxy` —— **`--BodyStr` 就是被代理的 Grafana 请求本身** `{"method","path","headers","body"}`（**不是**包装对象；⚠️ `body` 必须是**转义后的 JSON 字符串**；POST 须显式带 `Content-Type: application/json`）。**两个坑**：① 调用者须先 `CreateGrafanaWorkspaceAccount --AliyunUid <RAM UserId> --Role Admin --OrgId 1` 加入工作区，否则任意路径报 `40300 sub account is not authorized on this workspace`（⚠️ **`UID` 是 bash 只读变量**，误用会静默建出 `aliyunUid="0"` 的空账号）；② 代理**有路径白名单**（`/api/health`、`/api/ds/query` 被拒；`/api/datasources*`、`/api/dashboards*`、`/api/search` 可用）。**已落地**：数据源 `ARMS-Prometheus-MNL`（uid `arms-prom-mnl`，→ mnl 公网端点）+ 看板 `newapi-min-obs`（4 面板：就绪容器数 / CPU / 内存工作集 / 重启累计）；**跨区连通铁证** `GET /api/datasources/uid/arms-prom-mnl/health` → `Successfully queried the Prometheus API. status OK`。**IaC**：`deploy/tasks/task26/grafana_setup.py`（`account|ds|dash|verify|all`）+ `task26_finish_gaps.sh grafana`。
- **任务 26 判定（2026-10-10 更新）**：**完成（4/4）** —— SLS ✅ / ARMS Prometheus ✅ / Grafana ✅ / **云监控站点监控 ✅**。站点监控任务 `likha-hk-newapi-status`（TaskId `d7a836f6-b87b-4b3d-82bb-424dda2853cf`，HTTP GET 5min，断言 `match_rule=0` + `"success":true`，探针 **新加坡375/香港569/日本576/马尼拉18877**，`TaskState=1`），**实测可用性 100%、响应 63–254ms**；⚠️ 任务卡要求断言含 `version`，但实测 `/api/status` 返回 `"version":""`（空串）⇒ 版本断言不可行（增强项，待 G8/发版注入）。**马尼拉探针 18877 可用且健康，推翻 P1-13**。一键复核 `bash deploy/tasks/task26/task26_finish_gaps.sh all`。非本卡范围：blackbox 多 region 自拨（T+14/G8 后）、GTM（任务 21 挂起）；Grafana SLO/错误预算看板属任务 32。
- **F11 待裁决**：官方规格表标 `pg.x4.2xlarge.2c` `max_connections=6400`，与 F11 的 800 差 8 倍 → 实例 Running 后 `SHOW max_connections;` 定论。
