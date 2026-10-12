# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威文档**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（4天/单人/CLI-first · 56卡）② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`；冲突**以 ① 为准**。
> **详版口径 / 全部坑 / 归档 → `REFERENCE.md`**；流水 → `YYYY-MM-DD.md`。**新增细节写 REFERENCE，勿堆本文。**

## 执行环境（2026-09-28 起 · 优先级最高）
**命令默认在 WSL Ubuntu 跑**（`wsl -d Ubuntu -u root -- bash -c "..."`；带引号/多行/长中文载荷**先 Write 成文件再 `bash /mnt/e/.../x.sh`**）。宿主 `E:\git_code\new-api-yxw` = `/mnt/e/git_code/new-api-yxw`。
- ⚠️ `/mnt/e` 文本是 **CRLF** ⇒ 读入残 `\r` ⇒ 比对**必然假失败** ⇒ **一律接 `tr -d '\r'`**。
- ⚠️ `bash -c` 不读 `/etc/profile.d/`；`go env -w` per-user（root/fanyan 各一份）；`$?` 被吞成 0 ⇒ 用 `&& echo A || echo B`；**内联 `$VAR` 不可靠 ⇒ 全写绝对路径**。
- ✅ Go 1.25.1（= `go.mod`）+ `GOPROXY=goproxy.cn`；`web/` 用 bun（WSL 内**无 node/npm/bun/kubectl/helm**）；`/etc/wsl.conf` 已关 Windows PATH 注入；**编译/装依赖别放 `/mnt/e`**；`aliyun` 3.5.1 + `ossutil` 2.2.1 在 `/usr/local/bin/`。
- ⚠️ **本机不适合构建本仓镜像**（WSL2 上行并发 >20 丢 SYN ⇒ `bun install` 永挂）⇒ 发版走 **CI / macOS**（macOS 侧 `aliyun` ⚠ 无 `--region` 会用 profile 地域）。

## 上游二次开发纪律（2026-10-09 下达 · fork 维护总纲）
`new-api-yxw` = `QuantumNous/new-api` 二次开发分支（origin `git@github.com:yanxuewei/new-api-yxw.git`，`main`）。
**五条铁律**：① **能扩展不改源码** ② `UPSTREAM_CHANGES.md` 记清单、**sync 前对照** ③ 自研代码放 `ours_likha/{code,ops,doc}` **物理隔离** ④ **禁止无意义格式化上游文件** ⑤ **merge 冲突解决后跑全量测试**，CI **不许 skip job**。
- 落地物与唯一上游改动（日志毫秒化 · 3 文件 5 处）**见 REFERENCE**。无扩展点 ⇒ 原地最小补丁（登记清单 + 可复现补丁 + 在位校验）。

## 高频铁律（写命令前必看）
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`；**写完全脚本扫描**。
- **脚本日志勿与 API 输出混流**：日志走 `exec 3>&2`、数据落文件（污染 JSON → jq 假失败）。`tee` ≈0.6 s/次 → 逐行日志**不用 tee**。
- **PATH 自愈**：脚本头部加 `case ":${PATH}:"` 兜底（模板见既有脚本）。
- **★ 写操作先干跑**：通用 `--cli-dry-run`；ALB `--DryRun true` → `DryRunOperation` 即校验全过（⚠ 托管 ALB 例外，见域名节）。
- **CLI 3.5.1 口径**：配额只有 `--ProductCode`、分页 `--MaxResults`（**上限 100**）、类别 `--QuotaCategory CommonQuota`；vCPU 在 `--ProductCode ecs-spec`；地域**必须用维度** `--Dimensions.1.Key regionId`；**`Agree` 只在 `ListQuotaApplications` 返回** ⇒ 巡检一律 `jq -e`。**CLI 说参数名非法就先信它**（错 API/参数名 = exit 2；jq 语法错 = 3）。
- **探针法（零成本确证能力）**：踩**服务端**校验点看错误落在哪层。**禁用 CLI 已声明 enum/range 的参数当"必失败点"**；跑完复核资源数未变。
- 权限探测**严禁子串匹配**；**不能用不存在的资源 ID 探测**（存在性先于鉴权）→ 用幂等写。**资源前缀不代表地域** → 判残留必实查 API。
- **VPC 端点两端皆偶发抖动** → 写操作**重试 ≥3 次**并校验返回是合法 JSON，否则**静默漏建资源**。
- 一键复核 `deploy/verify_deploy_0_6.sh`（8 项全走 `jq -e`）。**`WARN` ≠ 通过**。⚠️ **`UID` 是 bash 只读变量**（root 下=0）→ 换名（如 `RAM_UID`）。

## RAM 权限与 K8s RBAC（10-10 定论 · 全文见 REFERENCE）
**★ 两套互不相通**：**RAM 策略**管「能否调 OpenAPI」；**K8s RBAC**管「K8s 里能否 list/get/update」（`APISERVER.403 … cannot list resource`）。
- `newapi-ops-operator` = v3（挂 3 组；Deny `kvstore:DeleteInstance`）· IaC `deploy/ops/ram_policy_newapi-ops-operator.v3.json` + `ram_ops_operator_extend.sh`（⚠ 上限 5 版）。
- **动作前缀必须逐个核准**（凭记忆写**静默失效**）：`kvstore`=Tair · `hdm`=DAS · **`yundun-cert`=证书（无 `cas:`/`ssl:`）** · `clickhouse` · `quotas` · `resourcemanager` · `tag`。
- **ACK RBAC 两坑**：`cs GrantPermissions` **全量覆盖**（读现状→保留全部集群→只改角色）；**响应把预置角色名放在 `role_type`**。IaC `deploy/ops/ack_rbac_grant.sh`（防降权护栏）。
- **集群（3）**：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(apse-6) · sg `ca75829e3492d491d9d434de087913798`(apse-1) · `cb0abf5bc06034f7bbdb991752f6f3e62`(apse-6)。

## 付费方式（09-28/09-29/10-06 裁定 · 详表见 REFERENCE）
RDS PG = 包年包月 **1 年** · Tair = 12 月（`PrePaid`）· **ECS 节点池 = 按量**（`PostPaid`，10-06 维持）· **ACK 管理费不支持包月** → 资源包 · **CK 企业版只能按量** → 计算资源包（抵扣因子 **1.45**）。
- ⚠️ **月付上限 <12**（`Period=Month`+`UsedTime=12` 报 `Order.PeriodInvalid`）。配额按量口径 `q_ecs_enterprise_postpay_c`（mnl 64 / sg 96）；**10-12 实测已用 mnl 32（4 节点）/ sg 16（2 节点）⇒ mnl 仅余 4 节点额度**（HPA 硬顶）；包月/按量**库存池不共享**（prepay 实为 **1024/5120**，旧写 100/100 已过时）。

## 域名与 ALB（likha.hk · 全文见 REFERENCE §4/§5/§10）
- **DNS**：NS `ns7/ns8.alidns.com`（**非** `ns*.aliyuncs.com`）生效；`DomainId 3b4321ce86d3436aa46e3a8ba96a6133`；**免费版 TTL 下限 600s**；`aliyun alidns` 无需 `--region`。记录 7 条：`@`+`www` 双 A → mnl ALB `8.212.161.49`/`8.212.183.7`；`sg` 双 A → `43.98.186.238`/`47.237.68.142`；**`_dnsauth` TXT（DCV）须保留**（续签复用）。`ops`/`static` 未建（前置未就绪）。⚠ **SOA 序列号不随记录增删递增** ⇒ 验生效只能逐条 `dig`。脚本 `deploy/manifests/dns-likha-hk.sh`。
- **★ 负缓存坑**：改记录后权威+公共递归秒级生效，但**本地路由器**可能因旧 NXDOMAIN 负缓存（SOA min TTL 600s）回空 → `curl` 回 **000** ⇒ 逐层对比上游。
- **★ 443 + canonical（10-12）**：canonical = `www.likha.hk`；80 一律 **301**、443 一律 **308**（`new-api[-sg]-https-canonical`）；sg `ph-standby-ip` 补 **443 兜底 + order=50**。**承载 API 的域名收敛一律 308**（P0 实测 `curl -L -d ''` → `404 redirects=1`，POST 未降级）。⚠ **SG 次序**：先补 443 兜底再上 canonical。⚠ 伪造 Host 经兜底仍 200（任务 47）。取证 `deploy/docs/Day2_域名规范化canonical闭环_2026-10-12.md`。
- **★ ALB 硬结论（7 条，详见 REFERENCE）**：① 证书字段 **`certificates[].CertificateId`** ② 托管 ALB = **`ServiceManagedResource`**（OpenAPI/DryRun 被拒、控制台灰态）③ **跨地域证书可用** ④ 跳转注解 **`RedirectConfig`+`httpCode`**（写错**静默忽略仍回 200**）⑤ **未匹配 Host ⇒ 占位组 ⇒ 502** ⇒ 对外域名须**显式 Host** ⑥ **裸 IP 的 HTTPS 无解**（裁定 A 仅限 HTTP）⑦ **域名转发只能改 Ingress+AlbConfig**（压过兜底须 `order`<50）。
- ⚠ **规则/组 ID 会漂移** ⇒ **判路由一律实时查 API**。★ **规则非 1:1**（N = host×path×端口数）⇒ 控制台「路由」页按 Ingress 聚合、ALB 页平铺**无归属**，**看着对不上是正常的**。★ **服务器组派生粒度 = Ingress**（同 Ingress 复用、跨 Ingress 各派生 ⇒ 同 Service **同名不同 ID**，非残留）⇒ 按 `ServerGroupId` 引用、归属看 `ingress_name` 标签；**托管组删不掉**（`ResourceInUse`→`ServiceManagedResource`→reconcile 重建），删了即 **502**。★ **`order` 是 Ingress 级** ⇒ 含无 Host rule 必须留默认值。★ **`order` ≠ `Priority`**。口径 `deploy/docs/{新增域名转发配置口径_Ingress优先,服务器组同名重复_成因与处置}_2026-10-12.md`。
- **★ 工具 `deploy/ops/add-domain.sh`**（`plan|apply|verify|ls|delete`）＝加域名一条命令（预检 8 项 + 云端对账 3 项 + 回写真源）。默认 `--order` forward=40 / redirect=1；redirect 80→301 / 443→**308**。⚠ **云助手 `RunCommand` Output 有 ~24 KB 上限且「掐中间」**（行数不变却丢内容）⇒ **回传载荷必须 < 2 KB**，回读**不要 `-o json`**（用 go-template 打紧凑 TSV）；`kubectl get <名字> -o go-template='{{range .items}}'` **静默输出空**。详见 REFERENCE。

## 当前状态（截至 2026-10-12）
- **23/56 卡闭合**（Day1 全 **13** + Day2 A 窗 **8** + 10-12 新闭合 **19/25**）。**未动**：任务 3 · 29（SG Tair）· Day2 B 窗 · Day3/Day4。⚠ **任务 1、2 已于 10-12 复核收口**：任务 2 ✅ 完成；**任务 1 ✅ 本卡收口**（门禁 4 项未过均属他卡，G8/G9 经裁定，见下）。
- **任务 26 = 完成**：SLS / ARMS / Grafana / 站点监控。⚠ `/api/status` 的 `"version":""` ⇒ 版本断言不可行。
- **★ G5 证书 = 已闭环（10-12 · Plan C）**：**DV 通配符**（US$207）⇒ `CertIdentifier=606823-ap-southeast-1` / `issued` / SAN `*.likha.hk,likha.hk`（链 ← DigiCert Global Root G2）。⚠ **→ 2027-04-28 且 `AutoReissue=disable` ⇒ 2027-03 前须续签**。脚本 `deploy/ops/cas_dv_cert.sh`。
- **既有实例**：RDS `pgm-5tstdhko64x2c01w`（PG 17.0，**2C8G**，主 6b/备 6a，Prepaid，**到期 2026-10-28 ⚠**）· Tair `r-5tsf1fe16543e274`（企业版 1G/2DB/6proxy，仅 6a，只买 1 个月）· Tair SG **0 实例** · CK `cc-5tsv2o51s1360b0pr`（企业版单 AZ 6a）。⚠ 待对齐：RDS 2C8G vs 任务 4 卡 16C64G；**F11**（`max_connections` 6400 vs 800）待 `SHOW` 定论。
- **账务**：余额 **699.00 USD**（10-12）。未支付订单 `518158947970481`（RDS 16C64G）与实建不符，**须确认已取消**。`bssopenapi QueryAccountBalance` 须 `--region ap-southeast-1`。
- **五项裁定（09-30）**：KMS 不买 · CK 资源包不买 · 备站→CK 走 **CreateEndpoint 公网** · ALB 已买 · **GTM 挂起**。
- **集群侧已落地**：`new-api` ns/SA/Quota/CM 两地 · RRSA ×2 · Secret `new-api-secrets`（mnl 6/sg 3 键）· `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` · SG `SQL_DSN`=`sslmode=verify-full`+Secret `rds-ca-apse6`（**备站 Deployment 必挂**）· 网络/安全组/ACR/SLS/ACK/私网通道。
- **凭据**：`/root/.deploy_secrets/`（600）= RDS 三账号口令 + CK 两 DSN + SESSION_SECRET×2；Tair 口令在 `deploy/.env`（gitignored）；`newapi_ops` 在 `/home/fanyan/.newapi_rds_ops_password`。待补 `PAYMENT_PRIVATE_KEY`、SG 三键。
- **G0 门禁实况（10-12 裁定后 · 门禁 12 项过 8 / 未过 4）**：✅ G1 G2 G3 G4 G5 **G9** G10 G12。❌ **G6 模板 PR**（13 件落盘 `deploy/aliyun/ph/`，**2 件未提交**）· **G7 白名单书面确认** · G11 连接预算表 · G13 staging。**⏸ G8 代码补项 = 裁定移出门禁 → T+14 后补**（过渡：探针用 `/api/status`+TCP；Tair 故障 fail-closed；`MIGRATE_MODE`/`G8-EV-1` 滞后）。**裁定：`yanxuewei` 降权不做 ⇒ G9 知情接受闭合**。另欠上游 8 EIP 白名单。取证 `deploy/docs/Day1任务1_2_G0收口与NS复核_执行报告_2026-10-12.md`（§七）。
- **账号侧「开通/购买」类阻塞**：`aliyun cms` 无 Open 接口、`bssopenapi` 新版**已移除 `CreateOrder`** ⇒ **开通类只能控制台**。

## 已打通但易忘的通道（详见 REFERENCE）
- `ack_remote.sh <mnl|sg> <body.sh>`（**body 禁反引号与裸 `$VAR`**）· `aliyun_rpc.py`（绕 CLI 嵌套参数）· `aliyun arms GrafanaWorkspaceHttpApiProxy` · `aliyun workorder`（须 `--region ap-southeast-1`）。
