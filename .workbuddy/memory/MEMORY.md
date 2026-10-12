# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威文档**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（4天/单人/CLI-first · 56卡）② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`；冲突**以 ① 为准**。**详版口径 / 全部坑 → `REFERENCE.md`**；流水 → `YYYY-MM-DD.md`。**新增细节写 REFERENCE，勿堆本文。**

## 执行环境（2026-09-28 起 · 优先级最高）
**命令默认在 WSL Ubuntu 跑**（`wsl -d Ubuntu -u root -- bash -c "..."`；带引号/多行/长中文载荷**先 Write 成文件再 `bash /mnt/e/.../x.sh`**）。宿主 `E:\git_code\new-api-yxw` = `/mnt/e/git_code/new-api-yxw`。
- ⚠️ `/mnt/e` 文本是 **CRLF** ⇒ 读入残 `\r` ⇒ 比对**必然假失败** ⇒ 一律接 `tr -d '\r'`。
- ⚠️ `bash -c` 不读 `/etc/profile.d/`；`go env -w` per-user；`$?` 被吞成 0 ⇒ 用 `&& echo A || echo B`；**内联 `$VAR` 不可靠 ⇒ 全写绝对路径**。
- ✅ Go 1.25.1（= `go.mod`）+ `GOPROXY=goproxy.cn`；`web/` 用 bun（WSL 内无 node/bun/kubectl/helm）；**编译/装依赖别放 `/mnt/e`**。
- ⚠️ **本机不适合构建本仓镜像**（WSL2 上行并发 >20 丢 SYN ⇒ `bun install` 永挂）⇒ 发版走 **CI / macOS**（macOS 侧 `aliyun` 无 `--region` 会用 profile 地域；集群操作用 `deploy/ack_remote.sh`）。

## 上游二次开发纪律（10-09 下达）
`new-api-yxw` = `QuantumNous/new-api` 二次开发分支（origin `git@github.com:yanxuewei/new-api-yxw.git`，`main`，**单人直推、无 PR 流程**）。
**五铁律**：① 能扩展不改源码 ② `UPSTREAM_CHANGES.md` 记清单、sync 前对照 ③ 自研代码放 `ours_likha/{code,ops,doc}` 隔离 ④ 禁无意义格式化上游文件 ⑤ merge 冲突后跑全量测试、CI 不许 skip job。（落地物/唯一上游改动见 REFERENCE）

## 高频铁律（写命令前必看）
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`。**PATH 自愈**：脚本头部加 `case ":${PATH}:"` 兜底。
- **脚本日志勿与 API 输出混流**：日志走 `exec 3>&2`、数据落文件（污染 JSON → jq 假失败）。`tee` ≈0.6 s/次 → 逐行日志不用 tee。
- **★ 写操作先干跑**：`--cli-dry-run` / ALB `--DryRun true` → `DryRunOperation` 即全过（⚠ 托管 ALB 例外）。
- **CLI 3.5.1**：配额只有 `--ProductCode`、`--MaxResults`（上限 **100**）、`--QuotaCategory CommonQuota`；vCPU 在 `ecs-spec`；地域**必须用维度** `--Dimensions.1.Key regionId`；**`Agree` 只在 `ListQuotaApplications` 返回** ⇒ 巡检一律 `jq -e`；**CLI 说参数名非法就先信它**。
- **探针法**：踩**服务端**校验点看错误落哪层；**禁用 CLI 已声明 enum/range 的参数当"必失败点"**；跑完复核资源数未变。权限探测**严禁子串匹配**、**不能用不存在的资源 ID**（存在性先于鉴权）→ 用幂等写。**资源前缀不代表地域**。
- **VPC 端点两端皆偶发抖动** → 写操作**重试 ≥3 次**并校验返回合法 JSON，否则**静默漏建**。
- 一键复核 `deploy/verify_deploy_0_6.sh`。**`WARN` ≠ 通过**。⚠️ **`UID` 是 bash 只读变量**（root 下=0）→ 换名。

## RAM 权限与 K8s RBAC（10-10 · 全文见 REFERENCE）
**★ 两套互不相通**：**RAM 策略**管「能否调 OpenAPI」；**K8s RBAC**管「K8s 里能否 list/get/update」（`APISERVER.403 … cannot list resource`）。
- `newapi-ops-operator` = v3（挂 3 组；Deny `kvstore:DeleteInstance`）；IaC `deploy/ops/{ram_policy_newapi-ops-operator.v3.json,ram_ops_operator_extend.sh}`（⚠ 上限 5 版）。**动作前缀必须逐个核准**（凭记忆写会**静默失效**）：`kvstore`=Tair · `hdm`=DAS · **`yundun-cert`=证书（无 `cas:`/`ssl:`）** · `clickhouse` · `quotas` · `resourcemanager` · `tag`。
- **ACK RBAC 两坑**：`cs GrantPermissions` **全量覆盖**（读现状→保留全部集群→只改角色）；**响应把预置角色名放 `role_type`**。IaC `deploy/ops/ack_rbac_grant.sh`（防降权护栏）。
- **集群（3）**：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(apse-6) · sg `ca75829e3492d491d9d434de087913798`(apse-1) · `cb0abf5bc06034f7bbdb991752f6f3e62`(apse-6)。

## 付费方式（09-28/09-29/10-06 裁定 · 详表见 REFERENCE）
RDS PG = 包年包月 **1 年** · Tair = 12 月 · **ECS 节点池 = 按量**（`PostPaid`）· **ACK 管理费不支持包月** → 资源包 · **CK 企业版只能按量** → 计算资源包（因子 **1.45**）。
- ⚠️ **月付上限 <12**（`Period=Month`+`UsedTime=12` 报 `Order.PeriodInvalid`）。配额按量 `q_ecs_enterprise_postpay_c`（mnl 64 / sg 96）；**10-12 实测已用 mnl 32（4 节点）/ sg 16（2 节点）⇒ mnl 仅余 4 节点额度**（HPA 硬顶）；包月/按量**不共享库存**（prepay 实为 **1024/5120**）。

## 域名与 ALB（likha.hk · 全文见 REFERENCE §4/§5/§10）
- **DNS**：NS `ns7/ns8.alidns.com`（**非** `ns*.aliyuncs.com`）；**免费版 TTL 下限 600s**；`aliyun alidns` 无需 `--region`。记录 7 条：`@`+`www` 双 A → mnl ALB、`sg` 双 A → SG ALB、**`_dnsauth` TXT 须保留**（续签复用）；`ops`/`static` 未建。⚠ **SOA 序列号不随记录增删递增**。脚本 `deploy/manifests/dns-likha-hk.sh`。
- **★ 负缓存坑**：改记录后权威+公共递归秒级生效，但**本地路由器**可能因旧 NXDOMAIN 负缓存回空 → `curl` 回 **000** ⇒ 逐层对比上游。
- **★ 443 + canonical（10-12）**：canonical = `www.likha.hk`；80 一律 **301**、443 一律 **308**（`new-api[-sg]-https-canonical`）；sg `ph-standby-ip` 补 **443 兜底 + order=50**。**承载 API 的域名收敛一律 308**（P0：`curl -L -d ''` → `404 redirects=1`）。⚠ **SG 次序**：先补 443 兜底再上 canonical。⚠ 伪造 Host 经兜底仍 200（任务 47）。
- **★ ALB 硬结论（7 条，详见 REFERENCE）**：① 证书字段 **`certificates[].CertificateId`** ② 托管 ALB = **`ServiceManagedResource`**（OpenAPI/DryRun 被拒、控制台灰态）③ 跨地域证书可用 ④ 跳转注解 **`RedirectConfig`+`httpCode`**（写错**静默忽略仍回 200**）⑤ **未匹配 Host ⇒ 占位组 ⇒ 502** ⑥ **裸 IP 的 HTTPS 无解**（裁定 A 仅限 HTTP）⑦ **域名转发只能改 Ingress+AlbConfig**（压过兜底须 `order`<50）。
- ⚠ **规则/组 ID 会漂移** ⇒ **判路由一律实时查 API**。★ **规则非 1:1**（N = host×path×端口数）⇒ 控制台「路由」页按 Ingress 聚合、ALB 页平铺**无归属**。★ **服务器组派生粒度 = Ingress**（同 Ingress 复用、跨 Ingress 各派生 ⇒ 同 Service **同名不同 ID**，非残留）⇒ 按 `ServerGroupId` 引用、归属看 `ingress_name` 标签；**托管组删不掉**，删了即 **502**。★ **`order` 是 Ingress 级**；★ **`order` ≠ `Priority`**。
- **★ 工具 `deploy/ops/add-domain.sh`**（`plan|apply|verify|ls|delete`）＝加域名一条命令（预检 8 + 云端对账 3 + 回写真源；默认 order forward=40/redirect=1，redirect 80→301 / 443→**308**）。⚠ **云助手 `RunCommand` Output 有 ~24 KB 上限且「掐中间」**（行数不变却丢内容）⇒ **回传载荷 < 2 KB**、回读**不要 `-o json`**（用 go-template 打紧凑 TSV）；`kubectl get <名字> -o go-template='{{range .items}}'` **静默输出空**。

## 当前状态（截至 2026-10-12）
- **23/56 卡闭合**（Day1 13 + Day2 A 窗 8 + 10-12 的 19/25）。**未动**：任务 3 · 29（SG Tair）· Day2 B 窗 · Day3/Day4。任务 26 = 完成（SLS/ARMS/Grafana/站点监控；⚠ `/api/status` 的 `"version":""`）。**任务 1、2 已收口**（任务 2 ✅；任务 1 ✅ G0 门禁 11 项全过）。
- **★ G5 证书 = 已闭环（10-12 · Plan C）**：**DV 通配符**（US$207）⇒ `CertIdentifier=606823-ap-southeast-1` / `issued` / SAN `*.likha.hk,likha.hk`。⚠ **→ 2027-04-28 且 `AutoReissue=disable` ⇒ 2027-03 前须续签**。脚本 `deploy/ops/cas_dv_cert.sh`。
- **既有实例**：RDS `pgm-5tstdhko64x2c01w`（PG 17.0，**2C8G**，主 6b/备 6a，**到期 2026-10-28 ⚠**）· Tair `r-5tsf1fe16543e274`（企业版 1G/2DB/6proxy，仅 6a，只买 1 个月）· Tair SG **0 实例** · CK `cc-5tsv2o51s1360b0pr`（企业版单 AZ 6a，已接线）。⚠ 待对齐：RDS 2C8G vs 任务 4 卡 16C64G。**F11 已定论：`max_connections = 800`**（10-12 实测，用户不可改）⇒ 服务端预算封顶 **640**。
- **账务**：余额 **699.00 USD**（10-12）。未支付订单 `518158947970481`（RDS 16C64G）与实建不符，**须确认已取消**。`bssopenapi QueryAccountBalance` 须 `--region ap-southeast-1`。
- **五项裁定（09-30）**：KMS 不买 · CK 资源包不买 · 备站→CK 走 **CreateEndpoint 公网** · ALB 已买 · **GTM 挂起**。
- **集群侧已落地**：`new-api` ns/SA/Quota/CM（实名 **`new-api-config`**）两地 · RRSA ×2 · Secret `new-api-secrets`（mnl **6** 键 / sg **4** 键）· `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` · SG `SQL_DSN`=`sslmode=verify-full`+Secret `rds-ca-apse6`（**备站 Deployment 必挂**）。
- **凭据**：`/root/.deploy_secrets/`（600）= RDS 三账号口令 + CK 两 DSN + SESSION_SECRET×2；Tair 口令在 `deploy/.env`；`newapi_ops` 在 `/home/fanyan/.newapi_rds_ops_password`。待补 `PAYMENT_PRIVATE_KEY`、SG 三键。
- **G0 门禁实况（10-12 三次更新后 · 11 项全过）**：✅ G1–G7 G9 G10 **G11** G12。**G11 产出**：连接预算表实测版 `deploy/docs/G11连接数预算表_线上核实_2026-10-12.md`（左端全取实况值）⇒ **I-1 `1600≤2000` ✅ · I-2 `≤220≤640` ✅ · I-3 5432 旁路 ✅**。**复核闭合 2**：**G6** 模板（14 件全入库 + 已推 `origin/main`；单人 fork 直推 ⇒ PR 要件不适用）· **G7** 产品开通（实例全建成 ⇒ CK 白名单实际已通）。**移出门禁 2**：**G8**（T+14，探针用 `/api/status`+TCP、Tair fail-closed）· **G13**（Day 3）。**裁定闭合 1**：**G9**（降权不做）。另欠上游 8 EIP 白名单。**⚠ 门禁外风险登记 2（10-12 新发现）**：① **`pool_mode` 实况 `session`**（文档记 `transaction`；**ActionTrail 实证 09-30 09:33 `root` 云写、未登记**）⇒ 新增 **I-4「并发服务能力」不成立**（接管态 `1300:50` = 26:1 排队）⇒ 兜底窗口态，须跑任务 41 步骤 3 矩阵后热切回 `transaction`；② **HPA CPU 目标现网 `70%` vs F14 裁定 `65%`**（两侧均 70）⇒ drift。取证 G11 报告 + `Day1任务1_2_G0收口与NS复核_执行报告_2026-10-12.md` §七。
- **★ PgBouncer 语义（10-12 定论）**：`default_pool_size` **在任何 `pool_mode` 下都是每池 `(user,db)` 的 server 连接上限**（session/transaction 相同，差别只在 client **何时归还** server，不在总数）⇒ 任务 41 原「session 下 50 不再是上限、I-2 作废」**已更正**；session 真实后果是 **client 排队**（`query_wait_timeout=120s` 到点报错）。⚠ **"可热改" ≠ "没改过"**：查运行值只看 `DescribeParameters.RunningParameters`（`TemplateRecord` 不算数）+ `actiontrail LookupEvents`（**驼峰字段** `eventName`/`serviceName`）追溯。⚠「Pod 内真实生效 env」只能靠 `kubectl exec … env`（**Deployment env 覆盖 ConfigMap**：sg 即 CM 100/50 → env 10/5）；⚠ **CM 实名 `new-api-config`**（卡内 `newapi-config` 是笔误）。
- **账号侧「开通/购买」类阻塞**：`aliyun cms` 无 Open 接口、`bssopenapi` 新版**已移除 `CreateOrder`** ⇒ **开通类只能控制台**。

## 已打通但易忘的通道（详见 REFERENCE）
`ack_remote.sh <mnl|sg> <body.sh>`（**body 禁反引号与裸 `$VAR`**）· `aliyun_rpc.py`（绕 CLI 嵌套参数）· `aliyun arms GrafanaWorkspaceHttpApiProxy` · `aliyun workorder`（须 `--region ap-southeast-1`）。
