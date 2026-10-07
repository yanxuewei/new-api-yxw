# new-api 菲律宾部署 · 项目长期约定

> 权威源：`.deploy/用户设置指南.md`（权限）、`.deploy/DCDN回源层切换_方案.md`（切换）、`.workbuddy/memory/YYYY-MM-DD.md`（过程）。本文只存反复引用的口径与坑。

## 账号 / 工具 / 端点
- 账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b 两 AZ），备 `ap-southeast-1`（新加坡）。
- `aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 shell 用 `zsh -i -c`）；OSS 用 `ossutil` v2（`~/.aliyun/ossutilconfig` 600）。
- 部分国际站服务**必须 `--region ap-southeast-1`**：RAM、`resourcemanager`（6 无 endpoint）、`bssopenapi`（只能 `business.ap-southeast-1.aliyuncs.com`）。VPC/ECS/CR/SLS 类只传 `--endpoint` 不够，必带 `--region`。

## shell / CLI 踩坑
- 变量后紧跟中文或全角标点会被 bash 3.2 吞进变量名 → 一律 `${VAR}`。
- bash 3.2 + `set -u`：`local x y` 里未赋值即 unbound → 写 `local y=""`。
- 函数日志与返回值不能同走 stdout：`ID=$(f)` 会吞日志 → 日志一律 `>&2`。
- zsh 不做分词：数组必须 `"${ARR[@]}"`；`$ACC:t` 被当参数修饰符 → 用 `${ACC}`。
- 禁用变量名（bash 内建只读）：`GROUPS`（macOS=20，赋值静默忽略）、`UID`、`EUID`、`PPID`、`RANDOM`、`SECONDS`、`PIPESTATUS`、`FUNCNAME`、`BASH_*`、`LINENO`、`OPTARG`、`HOSTNAME`。
- macOS BSD grep 不认 `'A\|B'` → 用 `grep -qE 'A|B'`；`awk '$1=""'` 留多前导空格 → 用 python 过滤。
- 预演结论与人工核对矛盾时，先怀疑脚本/工具。

## 权限探测铁律
- **严禁子串匹配**：`actiontrail LookupEvents` 事件正文含 `AccessDenied`（测试自身产生）→ 按结构化字段判定：CLI 看顶层 `error_code`；ossutil 看 stderr `Error Code: xxx`；XML 兜底 `<Code>`。`Access denied by bucket policy` 是误导文案（RAM 拒绝也返回它）。
- **不能用不存在的资源 ID 探测**（资源存在性校验先于鉴权）→ 改用幂等写（写回当前值）。
- `acs:ResourceGroupId` 条件键已实测对 OSS 对象与 VPC API 生效；`NotAction` 支持 `*:Describe*`/`*:List*`/`*:Get*`/`*:Query*` 通配。

## 资源组
`rg-ph-mnl` `rg-aek4nyivmmsb6iy`｜`rg-sg` `rg-aek4zvb3ldoiyua`｜`rg-nonprod` `rg-aek4hk3prqgqjcy`（staging/perf/压测）｜`rg-shared` `rg-aek3yypouljf4ry`（ACR / ActionTrail / CMS）｜默认 `rg-acfnssmgwnsb5oa` **禁止**放 new-api 资源。
**生产 vs 非生产 = RG 权限边界；站点 = 标签 `site` + K8s 命名空间。** 铁律：① RG 须**创建时**指定（`CreateVpc --ResourceGroupId`；`CreateVSwitch` 无此参数但**继承 VPC 的组**）→ 先 VPC 后 vSwitch；② **vSwitch 不可单独换组**（`MoveResources` → `UnsupportedOperation`），迁 VPC 级联；**③ ACK/CS 集群同样不可换组**（`MoveResources` 对 `Service=cs|ack` × `ResourceType=cluster|Cluster` 四组合全返 `UnsupportedOperation.MoveResources`）→ body 漏写 `resource_group_id` 会**静默落 default 组**，只能**删除重建**（见 `deploy/ack_ledger.md` 坑 A）；④ OSS 换组 `ossutil api put-bucket-resource-group`，ACR 用 `cr ChangeResourceGroup --ResourceRegionId`（**非** `--RegionId`）；⑤ 启用按 RG 授权后，迁移与策略变更**同批发布**；⑥ `resourcemanager ListResources` **不索引 vSwitch** → 盘点走 `vpc DescribeVSwitches`；⑦ `resourcemanager` 在 `ap-southeast-6` **无 endpoint** → 必带 `--region ap-southeast-1`；`MoveResources` 要 **flat 格式** `--Resources.1.Service/ResourceType/ResourceId/RegionId` + `--method POST`（数组 JSON 报 `Illegal parameter serialization format`）。

## RAM 治理
- 策略全 Custom 前缀 `newapi-`：admin-identity · ops-operator · cicd-acr-push · iac-terraform · dev-program · enforce-mfa · audit-protect · prod-boundary · prod-oss-guard。
- **「仅组级承载」**：用户级绑定已全解（权限零变化）→ **禁止再 `AttachPolicyToUser`**（会退回两层漂移）；临时提权用临时组。
- `enforce-mfa` 只约束控制台会话，`acs:MFAPresent` **对 AK 不判定** → 两者都拦不住 AK，程序用户靠 IP 白名单。
- `prod-boundary` = `Deny NotAction[*:Describe*,*:List*,*:Get*,*:Query*]` + `Condition acs:ResourceGroupId ∈ [rg-ph-mnl, rg-sg]`（生产只读）。`prod-oss-guard` = 无条件 Deny 生产桶 30 个写删动作，**必须含 `oss:PutBucketResourceGroup`**（否则桶可移出生产 RG 绕过 boundary）。
- **七类角色 → 6 组**：管理人员 `admin_group`｜财务 `fin_group`（`AliyunBSSReadOnlyAccess`，**不绑 MFA**）｜开发(人) `dev_group`｜开发程序 `dev-program_group`（纯 AK、无 LoginProfile）｜开发 Leader = 前两组并集｜初级运维 `ops_group`（非生产写 / 生产只读）｜运维 Leader `ops-prod_group`（生产可写不可销毁，**刻意不挂** boundary/oss-guard，唯一手工动生产通道；与 `ops_group` 唯一实质差异 = `oss:DeleteObject` 不在 ops-operator Deny 列表）。`iac-terraform_group` **故意不绑** boundary（要管生产桶配置）→ 云 API 层生产变更走 IaC。
- `power_user_group` = 应急临时全权组（0 成员）：`PowerUserAccess` + `enforce-mfa` + `audit-protect`。缺口：AK 可绕 MFA；`audit-protect` 只护 OSS `actiontrail/` 前缀对象，**不挡 `actiontrail:DeleteTrail`/`StopLogging`**。`super_group` 文档只写中性提示；⚠️ 事实：`yanxuewei` 持 `AdministratorAccess` + `AliyunRAMFullAccess` + **1 个 Active AK**。`newapi-oss-replication` 挂**服务关联角色 `aliyunosssystemdefaultrole`**，不在任何组上。
- 脚本 `bind_mfa.sh` · `attach_group_policies.sh` · `ram_user_detach.sh` · `ram_ops_prod_group.sh` · `ram_group_annotate.sh` · `ram_user_mgmt.sh`（回滚清单 `.workbuddy/ram_detach/`）。组备注三段式 `<角色/用途>|策略:<清单>|注意:<边界与坑>`，**≤128 字符**，**人身份组带 `(人)` 后缀**；**唯一真源 = `ram_group_annotate.sh` 的 `comments_for()`**，`apply` **会覆盖**控制台手工改动（须回灌，已对撞 3 轮靠 `backup_<ts>.tsv` 救回）。备注不影响权限。
- CLI：`GetPolicy` 的 PolicyDocument 在**顶层 `DefaultPolicyVersion.PolicyDocument`**，URL-encoded（须 `unquote`）；版本管理 `CreatePolicyVersion --SetAsDefault` / `SetDefaultPolicyVersion --VersionId` / `ListPolicyVersions`（后两者返回明文 JSON）。

## ACR（马尼拉）
- 实例 `acr-newapi-mnl` = `cri-avfqy9xkqi5bj8ee` @ ap-southeast-6，**Enterprise_Basic**，RUNNING，RG `rg-aek3yypouljf4ry`。域名 **`acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`**（`GetInstanceEndpoint` **必带 `--EndpointType internet`**）。配额：命名空间 15 / 仓库 1000。
- 4 命名空间（均 PRIVATE / NORMAL，自动继承实例 RG）：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vwhfmm9qid60vomq`。脚本 `.deploy/acr_namespace_init.sh`（`check|apply|verify|all`，含实例名预检 + repoType/status 断言）。
- **⚠️ ACR ARN**（`help/en/doc-detail/144229.html`）：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repositoryname]`；资源类型只有 `*`/`instance`/`repository`/`chart`，**无 `namespace/` 前缀**。Action→Resource：`CreateNamespace`→`repository/$instanceid`；`ListNamespace`→`…/$instanceid/*`；`GetNamespace`/`CreateRepository`→`…/$namespacename`；`Get/List/Push/PullRepository`→`…/$namespacename[/$repositoryname]`。
- **2026-09-27 15:33 已修 `newapi-cicd-acr-push`**：v1 三条 ARN（`repository/newapi/*`、`repository/*/newapi/*`、`namespace/newapi*`）**全部永不匹配**；v2 = `repository/cri-avfqy9xkqi5bj8ee/*`（ListNamespace）+ `…/newapi*` + `…/newapi*/*`（其余 cr 动作）；回退 `ram_cicd_acr_fix.sh rollback v1`。
- **tag 不可变两层（互不覆盖）**：命名空间 `DefaultRepoConfiguration.TagImmutability`（只对 `AutoCreateRepo=true` 的自动建仓生效）＋ 仓库自身 `TagImmutability`（**真正生效层**，建仓参数决定）。脚本 `.deploy/acr_tag_immutable.sh check|apply|verify|all [prod|all]`（默认只 prod）。现状：`newapi-prod` 默认 true；`newapi-prod/newapi-master`（`crr-eo15b1p46wt8yeek`）**type=PUBLIC** 待处理；pre/test/dev 默认 false、无仓库。四命名空间 `AutoCreateRepo=false` → 建仓须显式（cicd 现无 `cr:CreateRepository`）。

## 配额
- **按节点池 `max_size` 申请，不按常态值**：马尼拉 `64 = 8×8 vCPU`、新加坡 `96 = 12×8`。按常态申请 → autoscaler `ScaleOutBlocked` → HPA 扩上限全 Pending。
- code `ecs-spec` / `q_ecs_enterprise_postpay_c`（**无 general-purpose 族**）；CLI `--DesireValue`（无 d）、**无 `--Version`**；状态值 **`Agree`**（中间态 `Process`）；两地分单；**分钟级自动审批**。已批：马尼拉 50→**64**、新加坡 50→**96**；**64 零余量**（指南要求 ≥20%）。
- 机型 `g8i` 全系马尼拉**未上架**（实测）→ 主力 `g9i.2xlarge`（同 8C32G，vCPU 口径不变），备选 `g8ine.2xlarge`。
- 地域**必须用维度**传 `--Dimensions.1.Key regionId`（只传 `--RegionId` → **静默返回 cn-hangzhou 值**）；`ecs-spec`/`ecs` 支持，`eip/csk/oss/nat/slb/alb` **不支持**。
- **`ListQuotaApplications` 地域字段是 `Dimension`（单数）**，`ListProductQuotas` 才是 `Dimensions` —— 取错 → 幂等失效重复提单。
- 脚本 `quota_apply.sh`（`check|apply|verify|probe|all`）· `quota_probe.py`。现值：ALB 60/地域 · EIP 20（账号级）· NAT 5/VPC · ACK Pro 100 · OSS 100/region · VPC 10 · vSwitch 150/VPC。

## ★ 付费方式裁定（2026-10-06 · 节点池 = 按量）
- **ECS 节点池维持按量 `PostPaid`**（用户裁定，**不转包年包月**）——实查 `DescribeClusterNodePools`：`np-mnl-app` / `np-sg-ph-standby` 的 `scaling_group.instance_charge_type=PostPaid`、`period=0`、`period_unit=""`、`auto_renew=false`；`DescribeInstances` 6 台 worker 全 `PostPaid`、`ExpiredTime=2099-12-31`（**无到期时间 = 反证非包年包月**）。
- **配额核量改按量口径** `q_ecs_enterprise_postpay_c`（mnl **64** / sg **96**，工单 `b140e263-…`/`e117bf2b-…` `Agree`）⇒ ⚠ **`max_size` 顶满即零余量**（8×8=64；12×8=96），**扩节点前须提额**（`--QuotaActionCode q_ecs_enterprise_postpay_c --DesireValue …`）。包年包月 `prepay_c`=100/100 仅作对照。
- **仍为包年包月**：Tair（`ChargeType: PrePaid`）· RDS PG（`PayType: Prepaid`）。唯一实况 `PrePaid` 的 ECS = 跳板机 `i-5tsil3ca5dfkus9zpj7u`（`newapi-ops-mnl`，`ExpiredTime=2026-10-29`）。
- 全文口径 → 指南 v2.0 **F13** + 任务 11 卡（坑 7/7b 已反转）。改前备份 `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md.bak-20261006-paytype`。

## 询价
- ECS：`ecs DescribePrice --RegionId <r> --ResourceType instance --InstanceType <t> --PriceUnit Hour|Month --Amount 1 --InstanceNetworkType vpc --SystemDisk.Category cloud_essd --SystemDisk.Size 100`。**系统盘参数必填**；**本 CLI 无 `InstanceChargeType`** → 取不到包年包月价，`Month` 是月度档价 **≠ Hour×720**。
- 磁盘 `--ResourceType disk --DataDisk.1.*`（**只支持 Hour**，参数带序号）。Tair：`r-kvstore DescribePrice … --ChargeType PostPaid --OrderType BUY`（**OrderType 必填**）。**报价可查 ≠ 可下单**（`g8i.2xlarge` 有价无库存：`DescribeAvailableResource` 为空）。
- BSS：`GetPayAsYouGoPrice --endpoint business.ap-southeast-1.aliyuncs.com --ProductCode <p>`（RDS 需 `--ProductType bards`）+ `ModuleList.1.Config="k1:v1,k2:v2"`。⚠️ **RDS PG 规格费 / ESSD 存储价 / KMS / ACR 现价 官网未公示**。
- 单价与站点成本 → `.deploy/gen_cost_table.py` 顶部常量（按量项统一 **730 h/月**）+ `.deploy/资源配额申请_执行报告.md`。常态 **9,865.36 USD/月**；接管峰值 15,322.51；备站冗余 623.90（6.32%）。

## 容灾与切换
- **SLA 链**：`0.9999^5 ≈ 0.9996` → 月不可用 **17.28 min**；预算 21.6 min → 仅余 **4.32 min**。（注：`impl_deploy_fix.md:751-772` 已修正为 `0.9999^5 = 0.99950`，即**刚好达标、零余量**。）
- **ACK 控制面 SLA ≠ 可选形态（2026-09-29 更正）**：ACK SLA（生效 2023-04-01）§1.4/§1.5 —— **区域级集群 regional = 所在地域 AZ 数 ≥3**；**可用区级集群 zonal = AZ 数 ≤2**；§2.2 承诺 99.95% / **99.50%**。**马尼拉 `ap-southeast-6` 只有 6a/6b 两个 AZ → 恒为 zonal、承诺 99.50%（月不可用上限 ≈3.6 h），无任何建簇选项可提升**。且 **ACK 控制面不在上面那条五项串联链内**（链路为 GA/ALB/应用数据面/RDS PG/Tair）→ **§8.2 推导不受 ACK SLA 影响**。指南原「选 regional 得 99.95%，否则 8.2 从根上错」系**双重误判，已在 `-v2.0.md` / `.md` / `-ch.md` / `wf2/part2a.md` 四份更正**（工具 `deploy/patch_ack_task10.py`）。对冲：控制面停摆**不影响已运行 Pod**（数据面继续服务），但**部署/扩缩容/HPA 停摆** → 冻结期内不得依赖临时扩缩容。
- **切换三层**：① GTM 判定摘除 45–60s（可控）② DNS 传播 理论 60s / **实际 5–30 min**（运营商 LocalDNS，**不可控**）③ 客户端长连接（SSE 已建立**不迁移**）。**RTO**：乐观 2.3 min · 中位 6.3 min（**已超 4.32**）· 长尾 31.3 min。GTM TTL 最小 **1s**、探测最小 **15s**；探测节点**无菲律宾**；探测源 IP 须进 WAF 白名单。
- **GTM 池间语义 = 主备 failover，不是分摊**：主池健康 → 备池零流量；`pool-sg` 绝不进主地址池集合；**可用 IP 最小阈值 = 1**（马尼拉 ALB 仅 2 IP，设 2 → 单 AZ 抖动误切）。
- **备站容量 = 并列第二段 RTO**（HPA 爬坡 + 节点扩容 90–180s）；`impl_deploy.md §7.4.4` 只写 `replicas: 2`（**缺 HPA**）vs 指南 `:208`「HPA 2-24」→ 待统一。
- **降 RTO 正解 = 切换下沉到 DCDN 回源层**：ALB 实例地址配为源站（主备优先级 20/30），主动探测 **2.5s×3 = 7.5s**，客户端连边缘 **IP 不变**、不吃运营商缓存 → RTO **10–20s**，净增 **≈ +74 USD/月**。三硬约束：① 探测是**四层 TCP** → 对「ALB 活但 Pod 全挂」的 5xx 免疫（须工单开七层或叠加 GTM）；② 动态资源**默认性能优先回源**会绕过主备优先级；③ 回源读超时**默认 30s** → SSE 截断（调 120–150s）。**DCDN 不支持内网源站**。全文与工单模板 → `.deploy/DCDN回源层切换_方案.md`。
- **双活被四重否决**：单写者（主库只在 MNL/BKK）+ 跨区 RTT 45–70 ms 进 TTFT + 就近解析已否需求（PH→MNL 5–15 ms vs PH→SG 30–45 ms）+ 需新增跨区仲裁点。真正该砍的是 CK 备站复用（1,728.32 ≈ 备站节点的 2.8×）。

## 观测（SLS）
- `sls-newapi-mnl`（ap-southeast-6 / `rg-ph-mnl`）· `sls-newapi-sg`（ap-southeast-1 / `rg-sg`），各 7 logstore：app-stdout · app-file · alb-access · waf-log · rds-audit · actiontrail（ttl 30）+ app-file-audit（ttl 180）；ZRS、shardCount 2、mode standard。脚本 `.deploy/sls_init.sh`（`check|apply|verify|all` 幂等）。
- **`aliyun sls` 是 ROA 风格**（无 `--ProjectName`）：`CreateProject --region <r> --body '{...}'`；`CreateLogStore --project <p> --region <r> --body '{...}'`。坑：`sls POST /` 被拒（**too broad path** → 用 ApiName）；`GetLogStore` 的 logstore 是 **path 参数 `--logstore`**；`ListProject --projectName` 是**前缀匹配**（判存在须精确比对）；**每次调用必须带 `--region`**；`CreateProject` 支持 `resourceGroupId`。

## 文档体系
- **「用户设置指南.md」单文件自包含**：10 章 + 19 条出错手册 + 10 张**内联 SVG**（`width="100%" max-width:1120px`，上方带 `<!-- svg:<文件名> -->` 标签）。**GitHub 会过滤内联 SVG**（备用 `user-guide-images/index.html` 画廊）。
- **改图三步**：改 `gen_guide_images.py` → 重生成（10 SVG + 画廊）→ `inline_svg_into_md.py --apply`（按标签替换 + 备份）。两个坑：`table()` 的 `j==0` 列只画复选框 → 行首须补 `""` 占位；`inline_svg_into_md.py` **必须感知代码围栏**。
- **术语**：用「**管理人员** admin」（非「管理员」），角色用**七类**。指南双份（`.md` / `-ch.md`）**必须同步改**；回写工具 `patch_g9i_and_sec34.py`（幂等 + 备份）。

## 网络基线（勿改）
马尼拉 `vpc-newapi-mnl-prod` `10.0.0.0/16`（6 vSwitch：pub `10.0.0.0/24`·`10.0.1.0/24`，app `10.0.16.0/20`·`10.0.32.0/20`，data `10.0.48.0/20`·`10.0.64.0/20`）；新加坡 `vpc-newapi-sg-prod` `10.1.0.0/16`（4 vSwitch：pub `10.1.0.0/24`·`10.1.1.0/24`，app `10.1.16.0/20`·`10.1.32.0/20`）。完整 CIDR 见指南 §2.2。**Terway 每 Pod 占真实 VPC IP** → app 段免费 IP 基线 4092，**低于 200 告警 P2**。

## Docker 构建环境补充（macOS 本地，2026-09-27）

- **Docker 预定义 ARG 免声明**：`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`（含全小写）**无需 Dockerfile 里 `ARG` 声明**即被注入构建环境 → 这是「一个文件都不改就能换源」的唯一通用手段，`push.sh --proxy auto` 走的就是它（`http://host.docker.internal:7890` = 本机 Clash，容器内实测可达）。**自定义变量（`NPM_REGISTRY`/`GOPROXY`）必须显式 `ARG` 声明**，否则 BuildKit 只打一条 `not consumed` 警告、**不注入**——push.sh 已自动读 `-f` 指定的 Dockerfile 做声明检测，未声明则跳过并在 banner 提示「未生效」。
- `bun install` 1202 包实测：npmmirror **101s** ＜ Clash 代理走官方源 **889s** ＜ 官方源直连 **1041s**（npm 三者**均成功**，官方源只是慢）。Go 侧无此宽容度——官方源**直接失败**。
- Go 模块源实测：`proxy.golang.org` 直连 **http=000 / 10s 超时**；`goproxy.cn` 200 / 0.58s；`mirrors.aliyun.com/goproxy` 200 / 0.47s；`proxy.golang.org` 经 Clash 7890 → 200 / 0.68s。
- 查 VM 内剩余空间（无 CLI 直读）：`docker run --rm --privileged --entrypoint sh alpine:3.20 -c 'df -Pk /'`。`Docker.raw` 的 `ls -l` 是 **apparent size**（恒等于上限、无意义），`du` 才是宿主真实占用。
- 改 Docker Desktop 配置须 `docker desktop stop` → 改文件 → `docker desktop start`；沙箱内 `osascript -e 'quit app "Docker Desktop"'` 报 Apple Events `-10004` 权限违例，不可用。设置文件：`~/Library/Group Containers/group.com.docker/settings-store.json`（虚拟盘上限 `DiskSizeMiB`）；镜像加速器在 **`~/.docker/daemon.json`**（不是 settings-store）。

## 私网集群运维通道（2026-09-29 新打通 · **替代「等任务 46 堡垒机」**）

- **云助手直连私网节点**：
  `aliyun ecs RunCommand --RegionId <r> --region <r> --Type RunShellScript --ContentEncoding Base64 --Timeout 600 --InstanceId.1 <i-xxx> --Name <n> --CommandContent "$(base64 -w0 body.sh)"`
  → 轮询 `aliyun ecs DescribeInvocationResults --RegionId <r> --region <r> --InvokeId t-xxx`，**`Output` 是 base64，必须解码**。
  - `--Type` 必须是 **`RunShellScript`**（写 `Shell` 报 `InvalidCmdType.NotFound`）。
  - **默认不持久化命令对象** → 无需清理。`DescribeCommands` **不支持 `--MaxResults`**（报 `InvalidParameter.MaxResults`）。
  - 偶发返回空 `InvokeId`（马尼拉端点抖动）→ **原地重试一次**，不是权限问题。
- **集群 admin kubeconfig（CLI 可直接拉）**：
  `aliyun cs DescribeClusterUserKubeconfig --ClusterId <cid> --region <r> --PrivateIpAddress true` → `config` 字段即 YAML，**`server` 就是可用 SLB VIP**（马尼拉 = `10.0.22.182:6443`）。
  把 `certificate-authority-data` / `client-certificate-data` / `client-key-data` 各自 `base64 -d` 落成 PEM 后，**在节点内用 `curl --cert --key --cacert` 直连 REST API** —— 不需要 kubectl、不需要开公网端点、不需要堡垒机。权限 = cluster-admin，凭据只落节点 `/tmp`，用完删。
- 节点自带 `/usr/bin/kubectl` 用的 kubeconfig 是 `system:node:<name>`，**只读、且读不到 EndpointSlice** → 排查够用、修复不够。
- 通用执行器：`E:\WSL\np11_run_remote.sh <node> <body.sh> [loops]`（自动注入 `KCA`=`curl 凭据` 与 `KS`=`server` 两个变量）。

## ACK 节点池 / 控制面（2026-09-29 实测）

- ★ **控制面安全组必须放行 6443**：ACK 自动创建的 `sg-…`（名 `alicloud-cs-auto-created-security-group-<集群ID>`）**实测只有一条 ICMP 入方向规则** → 节点与 Pod 都连不上 apiserver ENI ⇒ ① 4/4 节点 `ensure_kube_version` 失败（`FailGetKubeVersion`，cloud-init 卡满 606s）；② Terway 经 ClusterIP 访问 API Server 超时 → `/etc/cni/net.d/` 空 → 永远 `NotReady`。
  - 修：`aliyun ecs AuthorizeSecurityGroup --SecurityGroupId <控制面SG> --IpProtocol tcp --PortRange 6443/6443 --SourceCidrIp <VPC CIDR>`。
  - **新建集群（含新加坡任务 24）第一件事就是核对这条规则**。控制面 ENI 反查：`aliyun ecs DescribeNetworkInterfaces --VpcId <vpc> --PrivateIpAddress.1 <ip>`（名字形如 `k8s-eni-*`、`type=Secondary`、**无 `InstanceId`**）。
  - 别把这两个地址当「坏 VIP」：**DNS 解析与 `kubernetes` EndpointSlice 都是对的**，它们就是真实 apiserver ENI。SLB VIP 能通是因为走 **ENI 后端模式不经过该 SG**。
- **口径铁律**：`ping` 通 **≠** 端口通（ICMP 可能在白名单里）；`curl (7) Connection timed out` **≠** DNS 问题（`(6)` 才是解析失败）→ **先测 TCP，再怀疑 DNS**。
- **控制台「失败」列 ≠ `failed_nodes`**：映射的是 `offline_nodes`；「正常」采 ESS 生命周期口径也会失真 → 节点可用性**必须用 `kubectl get nodes` 验证**。
- `DescribeClusterNodes` **不返回全部节点**（字段名是 `node_status`，可能 `Unknown`）→ 数节点用 `ess DescribeScalingInstances`。
- **ESS 会自动替换 bootstrap 失败的节点**（本次观测 2 轮：14:17 / 14:38）→ 修复时按「当前实际实例 ID」，台账历史 ID 会作废。
- **ESS 不严格按 `instance_types` 顺序取机型**（本次重建后 4 台全落 `g9ae`）→ 勿在文档里硬编码机型分布。
- **节点标签真源 = 节点池 `kubernetes_config.labels`**（ECS 资源 tag ≠ K8s node label）；只给 `track` 不给 `site` → `kubectl get nodes -l site=ph-mnl` **一台都选不到**。
- `ModifyClusterNodePool` 改 `kubernetes_config` 时**必须把 `user_data`（b64 原值）一并回传**；`DescribeClusterNodePools` **会返回 `user_data`** → 可回读校验是否丢失。
- **`pam_limits` 会把 nofile 向上取整到 2 的幂**：写 200000 → 登录 shell 实得 **262144**；systemd 侧不取整（仍 200000）。验收口径应写「**≥ 200000**」。
- ACK bootstrap **排在自有 `user_data` 之前**（`/var/lib/cloud/instance/user-data.txt` = ACK 段 → `set +e` → 我方段）⇒ 我方脚本改配置救不了当次 bootstrap。重跑用可执行副本 `/var/lib/cloud/instance/scripts/part-001`（会重复 `--auto-fdisk`，盘已挂载时报 `DiskinitError`，**无害**）。

## ACK 集群（两地已落地 · 任务 10 / 24）

- **马尼拉** `ack-newapi-mnl` = `cd57e40ce9a634c1698c2f5c5e09bd93c`：`ack.pro.small` / k8s `1.35.7-aliyun.1` / `ManagedKubernetes`+`profile=Default` / RG `rg-ph-mnl`；CNI `terway-eniip` v1.17.7（`ENITrunking=false`）· `ipvs` · ServiceCIDR `172.21.0.0/20`；私网端点 `https://10.0.22.182:6443`，**公网端点未开**；删除保护 on；自动升级 `stable` + 窗口周二 03:00–06:00（Asia/Manila，**API 可配**）。创建 3m39s，终验 28/28。
- RRSA on：`oidc_arn=acs:ram::5108890064395960:oidc-provider/ack-rrsa-<cid>`；**region 级资源 → 新加坡必须另建**。依赖资源（ACK 自建、继承集群 RG）：集群安全组 `sg-5tsaatp5w68vyqszezja` · 内网 SLB `lb-5ts6qwxumktojy2qs3omu`（**SLB 不是 ALB**）· SLS 审计 `k8s-log-<cid>`。台账 `deploy/ack_ledger.md` · 脚本 `deploy/task10_ack_mnl.sh`（`--dry-run` 幂等）。
- ★ **漏 `resource_group_id` → 静默落 default 组**（`rg-acfnssmgwnsb5oa`，无报错），且 **ACK 集群不支持资源组迁移** → **唯一解法是关删除保护后删除重建**。**删集群 ≠ 清干净**：内网 SLB / 集群安全组 / SLS 审计项目是独立资源；`DeleteCluster` **不删** `k8s-log-<旧cid>` → 须手工 `aliyun sls DeleteProject`。
- **新加坡** `ack-newapi-sg` = `ca75829e3492d491d9d434de087913798`：同规格 · RG `rg-aek4zvb3ldoiyua` · VPC `vpc-t4nimmwvruexbnene0a3r` · 双 vSwitch 1a/1b · **ServiceCIDR `172.22.0.0/20`（刻意错开，建后不可改）** · 160s running · 终验 12/12。密钥对 `newapi-sg`（跨 region 不共享；`DescribeKeyPairs` **不回读公钥体** → 只能 `ImportKeyPair`）。控制面 SG `sg-t4nevyfflaeo3tdvi510` **同构复现「只有 ICMP、无 6443」** → 建池前已提前放行。

## 节点池（两地已落地 · 任务 11 / 24）

- 马尼拉池 `npaad418131aa84c899be022b5463d13bf`（`np-mnl-app` / `rg-ph-mnl`）· ESS `asg-5tsd68ew4u0wutaqk5cy`（min4/max8 `BALANCE`）· 4 台 `ecs.g9ae.2xlarge` · 4/4 `Ready`，6a:2 / 6b:2 · 标签 `site=ph-mnl`+`track=stable` · 节点 SG `sg-5tsil3ca5dfkqefks1g9`。台账 `deploy/nodepool_ledger.md`；M2 证据 `deploy/d2/nodes-zones.txt`。
- 新加坡池 `npab9d46aefe3a4649b074543f36f32599`（`np-sg-ph-standby` / ESS `asg-t4ngzbg7m9u84y59dkxl`）· `min2/max12` · 1a:1 / 1b:1 · 终验 17/17。**机型顺序 `ecs.g9ae,ecs.g9i,ecs.g8ine` —— 两区都在售的排首位**（1b 无 g9i）。脚本 `deploy/task24_nodepool_sg.sh` 薄封装复用 `task11_nodepool_mnl.sh` 同一逻辑与 user_data。
- ★★ **跨区均衡是独立开关 `AzBalance`**：**`MultiAZPolicy=BALANCE` ≠ 开启跨区均衡**！ESS 有独立 bool `AzBalance`，**ACK 建池时不设置它** → 只设策略时创建阶段完全不均衡，会顺"有库存的交换机"全塞一区。该字段 **`DescribeScalingGroups` 不回读**，且**经 ACK 改池后可能被覆盖** → 只能**幂等重设 + 用实例可用区分布间接验证**，改池后要**再断言**。修复脚本 `deploy/nodepool_azbalance_fix.sh {mnl|sg}`（配套 `BalanceMode=BalancedBestEffort`、`AutoRebalance=true`）。
- ★ **删池竞态**：`Min/Max/Desired=0` 是**异步**的，实例先进 `Removing:Wait`，**实测 ~6–7 min** 才释放；ACK 删除流程已跑完 → 报 `ScalingGroup's instances not empty` → 池变 `delete_failed`。**必须轮询 `TotalCapacity==0` 再删**（+ `GroupDeletionProtection false`）。
- 回写工具 `deploy/patch_task11_nodepool.py` · `patch_task11_ledger.py` · `patch_task11_verify.py` · `patch_task24_nodepool.py`（均幂等，`--check`/`--apply` + 自动备份）。

## 安全组（5 个已落地 · 早于任务 22 排期）

`sg-mnl-alb`=`sg-5tsj1epvcjjv6jkg3zks`｜`sg-mnl-app`=`sg-5tsil3ca5dfkqefks1g9`｜`sg-mnl-db`=`sg-5tsawhljdqzwo2t0n4ut`｜`sg-sg-alb`=`sg-t4nbgfbh2cidnve88avf`｜`sg-sg-app`=`sg-t4n0qnhy8mxq9g733r67`。台账 `deploy/sg_ledger.md` · 幂等脚本 `deploy/task22_sg_bootstrap.sh`（`--verify`/`--dry-run`）。

- ⚠️ **入向/出向是两个 API**：`AuthorizeSecurityGroup` **只加持入向**，用它建出向**返回 RequestId 却一条不落** → 出向必须 `AuthorizeSecurityGroupEgress`；参数用 `Permissions.N.*`（flat 形式已 Deprecated）。
- 判成功**不能只 grep `"Code"`**：CLI 失败是 `ERROR: SDK.ServerError` + 文本行 `ErrorCode:`（非 JSON）。`Permissions.N.*` 下重复规则**静默去重、不报 Duplicate** → 只能**前置比对**区分「新增/已存在」。**查询失败绝不可当"不存在"**（v1 因此重复建了一个 `sg-mnl-app`）。
- 真正控制点 = **数据层侧入向组引用**（`sg-mnl-db in ← sg-mnl-app`）；出向到 RDS/Tair 用 `DestCidrIp`（托管实例 SG 云产品自管，绑不上即静默失效）。

## 镜像发布 `push.sh`（仓库根）

`./push.sh -n prod|pre|test|dev -t <tag>` = login→build→tag→push + 逐阶段计时；日志 `deploy/logs/`。
选项：`--open-endpoint` · `--allow-ip <cidr|auto|all>` · `--create-repo` · `-f <df>`/`--upstream` · `--npm-registry cn|official|<url>`（默认 cn）· `--go-proxy cn|aliyun|official|<url>`（默认 cn）· `--proxy <url|auto>` · `--no-proxy` · `--prune` · `--min-disk <GiB>` · `--skip-disk-check` · `--no-build`/`--build-only`/`--dry-run`。
**Dockerfile 自动选择**：未显式 `-f` 且存在 `Dockerfile.mac` → 用它（banner 标注）；登录失败自动分流诊断（连接层 vs 401，并核对入口 Enable + ACL 白名单）。交互式 `read -rs` 必须放在 `--dry-run` 早退之后。

## 阿里云工具链（WSL）

`aliyun` CLI **3.5.1** + `ossutil` **2.2.1** 装在 WSL `/usr/local/bin`；macOS 侧在 `~/.workbuddy/binaries/aliyun-cli/aliyun`。凭证走**配置文件**（`~/.aliyun/config.json` + `~/.ossutilconfig`，600，**root 与 fanyan 各一份**，`site=international`）—— **别依赖 `.bashrc` export**：Ubuntu `.bashrc` 非交互守卫提前 return ⇒ `bash -c`/`-lc` 读到 AK 长度 0，只有 `-lic` 才拿到。CLI 3.x 用 **kebab-case**；`safety-policy` 默认 `enabled=false`。脚本 `E:\WSL\setup-aliyun-toolchain.sh` · `configure-aliyun-creds.sh {china|international}`。

## ClickHouse 企业版（马尼拉日志库 · 2026-09-29 实测）

- **三个"只有"**：可用区**只有 `ap-southeast-6a`**（`DescribeRegions` 仅回 1 个，对照 SG 回 1a/1b/1c；官方地域表 Multi-AZ=**No**）· 存储**只有 OSS**（`ESSD_L0/L1/L2/L3/SSD` 在马尼拉不可售）· 计费**只有按量**（商品类型「企业版 Serverless & 社区兼容版**按量付费**」）。
- **API 可建**：`clickhouse CreateDBInstance`（API 2023-05-22）—— `Category=enterprise` · `DeploySchema=single_az`（合法值实测 `single_az`/`multi_az`，非法值报 `InvalidDeploySchema.Malformed`）· `ZoneId=ap-southeast-6a` · `VswitchId=vsw-5tswufq2pi26l4ahoiu84`（`vsw-mnl-data-a` 10.0.48.0/20）· `StorageType=oss`（**必须小写**，大写 `OSS` 被 CLI 拒并给 `did_you_mean`）· `NodeScaleMin` 4 / `NodeScaleMax` 8（CCU 区间；1 CCU = 1 vCore + 4 GiB）· `NodeCount` 2–16。**无 `PayType`/`Period`/`AutoPay`/`DryRun`** ⇒ **创建即计费，没有零成本试单**。
- 计费参数缺席的判定法：`clickhouse CreateDBInstance --help-search PayType` → `total: 0`。
- 报错分层（探针参考）：非法 AZ `ap-southeast-6x` → `relevantInspectionException: VPC or VSwitch is not valid.`；`multi_az` 只给 1 个 AZ → `The number of zones is not multi.`；不存在地域 → `InvalidRegion.NotFound`；`single_az` + 非法版本 → `COMMODITY.INVALID_COMPONENT`（说明 `single_az` 已过参数层）。
- **价格（官方，马尼拉）**：计算 `0.185350 USD/CCU·h` · 存储 OSS `0.000044 USD/GB·h` · **计算资源包 `0.03611 USD/CCU·H`，最小包 3000 CCU·H，预付 3 年、不可退订、可叠加、不可续费**；**地域抵扣因子（马尼拉）1.45**（抵扣包量 = 实际 CCU·h × 1.45）。4 CCU 常驻：按量 ≈541.22 USD/月 → 资源包等效 ≈152.89（=28.2%，省 71.8%）。海外地域用包的实际折扣远大于宣传值（因按量单价高于中国内地）。
- 官方原文：企业版**默认最新内核、不允许手动选版本**（向后兼容）；企业版**未开放售卖区的账号需提工单加白**（否则控制台无"企业版"选项）。
- 其它：双 AZ 账户下**企业版多可用区部署无额外成本**（存算分离），但马尼拉不提供多 AZ；社区版集群默认挂 CLB 并计费，**企业版是否挂 CLB/ARMS 尚未实测**。
- 脚本 `deploy/task9_ck_decision.sh`（`verify|probe|cost|create --yes|check|all`，探针末尾强制复核 `TotalCount` 未变）。


## 域名与 DNS（likha.hk · 阿里云云解析）

- **权威 NS**：`ns7.alidns.com` / `ns8.alidns.com`（**2026-10-06 已生效**，终结 10-05 的 NXDOMAIN）。域名 `DomainId 3b4321ce86d3436aa46e3a8ba96a6133`，`rg-acfnssmgwnsb5oa`，免费版（TTL 下限 **600s**）。
- **CLI 可管**：`aliyun alidns DescribeDomains` 能列出 likha.hk ⇒ 当前 AK 与域名同账号（DNS 服务全局，与 `--region` 无关；**alidns 无需 `--region`**）。
- **现行记录**：

| RR | Type | Value | 目标 AZ | TTL | RecordId |
|---|---|---|---|---|---|
| `@`（根域） | A | `8.212.161.49` | ap-southeast-6a | 600 | `2107459130738276352` |
| `@`（根域） | A | `8.212.183.7` | ap-southeast-6b | 600 | `2107459138178953216` |
| `www` | A | `8.212.161.49` | ap-southeast-6a | 600 | `2107455274482150400` |
| `www` | A | `8.212.183.7` | ap-southeast-6b | 600 | `2107455278295137280` |

- **★ 负缓存坑（2026-10-06 实测）**：改记录后**权威 + 公共递归（223.5.5.5 / 119.29.29.29 / 8.8.8.8）秒级生效**，但**本地递归（家用路由器）可能仍回空**——因域名此前是 NXDOMAIN，负缓存按 **SOA minimum TTL = 600s** 缓存（实测 `likha.hk` SOA `… 86400 600`）。症状 = `dig @<router>` 空 / `curl` 回 **000**；判**必须逐层对比上游**，别误判成"配置没生效"。解法：等 ≤600s，或重启路由器 / `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`（macOS）。

- **A 双记录 vs CNAME**：ALB 官方名 `alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com` dig 解出的**正是这两个 IP**（⇒ 两方案等价）。选 A 双记录的理由：可做 IPv4 健康检查分流；CNAME 的优势是 IP 变化自动跟随但无法做 A 级健康检查。**根域不能用 CNAME，`www` 可以。**
- **★ `likha.hk` / `www.likha.hk` 当前都靠「无 Host 兜底规则」命中主站**（`rule-b1t5tod05rdsfdua8n` → `sgp-j4qrgy3f7bcv1r67na`）。⚠ **ALB 上没有 `Host=www.likha.hk`（或 `likha.hk`）规则** ⇒ 证书到位加 443 时**必须补 Host 规则**（HTTPS 客户端必带 SNI/Host，兜底规则不构成合规的域名入口）。
- **未配**：`ops.likha.hk`、`*.likha.hk`。**443 不存在**（`https://` 不可用）。
- **脚本**：`deploy/manifests/dns-likha-hk.sh`（`status|add|del|verify`；`RR`/`IPS`/`TTL`/`LINE` 环境变量可覆盖；`add` 幂等）。
- **★ 规则 ID / 服务器组 ID 会漂移**：Controller 重建后 `rule-80-1/2` → `rule-0f7ru4csbcn41ygmb4` / `rule-b1t5tod05rdsfdua8n`，Prio1 后端由 `sgp-tqgwt413t19mum8oa9` 变 `sgp-j4qrgy3f7bcv1r67na`。**判路由一律实时查 API，勿引用历史 ID。**

## ALB / 任务 19（2026-10-05 只读复核）

- **现状（09-30 落地）**：ALB `alb-1riqckb1h8ezm0y7s9`（`alb-newapi-mnl`，Active/Internet/Standard，`2026-09-30T10:23:46Z`）· 双 AZ 6b `vsw-5ts1dygyh2x0daspwny2r` + 6a `vsw-5ts9tgdq1xz3picjgoqyu` · 访问日志 `sls-newapi-mnl/alb_access` · AlbConfig `mnl-alb`（`10:23:40Z`，仅声明 80=Redirect）· IngressClass `alb` · `Service/new-api-master`(0 ep) + `Ingress/new-api-verify`(host `ph-verify.internal.likha.hk`) · SLR `AliyunServiceRoleForAlb`（09-30T08:50:51Z）。
- **❌ 未完成**：V1b 超时（实测 idle=15/req=60，非 60/600）· 301 跳转（`DefaultActions[0].Type=ForwardGroup → sgp-fm7kdwz99wtzbffkfx` = `kube-system-fake-svc-80`，ServerCount=0，`HealthCheckEnabled=false`）· V2 健康检查（无 ServerGroup 承载 Ingress 注解）· V3/V4 443+TLS（无证书）。
- **⚠ 阻断：ALB Ingress Controller 集群内已无实例**（`get pods -A` 全量 48 个 + `get deploy/sts/ds -A` 均无 alb；仅剩 headless `Service/alb-ingress-controller` 与陈旧 `EndpointSlice alb-ingress-controller-2vr6n`，IP `7.8.75.74`/`7.8.167.212` 无对应 Pod）。**云端 `ListClusterAddonInstances` 仍报 `alb-ingress-controller active v3.1.1` ⇒ addon 元数据不可信，必须用集群内 Pod 实况校验组件**。重装前注意：ACK 组件卸载会级联清理 AlbConfig 及由其托管的 ALB（AlbConfig 带 finalizer `ingress.k8s.alibaba/resources`）。
- **CLI 口径（2026-10-05 实测）**：`alb` 无 `GetServerGroupAttribute`/`GetLoadBalancerAttribute` 之外的读接口时用 `ListServerGroups --ServerGroupIds.1 <sgp>`（`--LoadBalancerIds.1` **不合法**）；`ListRules` 参数是 `--ListenerIds`；`GetListenerAttribute`/`ListListeners` 用 `--ListenerId` / `--LoadBalancerIds.1`。
- **`aliyun cas` 必带 `--region`**：裸调默认取当前地域（ap-southeast-6）→ `unknown endpoint for region ap-southeast-6`（CAS 该地域无端点）。国际站查证书用 `--region ap-southeast-1`。~~`likha.hk` 2026-10-05 `dig NS` = NXDOMAIN~~ → **2026-10-06 20:55 已生效**：`NS = ns7/ns8.alidns.com`；云解析 `DomainId 3b4321ce86d3436aa46e3a8ba96a6133`（同账号，CLI 可管）。`www` 已配双 A → 见「域名与 DNS（likha.hk）」节。
- 报告：`deploy/Day2任务19_ALB_执行报告.md`。

### 任务 19 补：ALB 公网 IP 无证书直连（2026-10-06 实做，✅ 已通）

- **可用网址**：`http://8.212.161.49` / `http://8.212.183.7`（**仅 80**；443/8080 无监听器）。链路：ALB → `lsn-ihrgkty2sjdy8s5p4h`:80 → `sgp-fm7kdwz99wtzbffkfx`（**4 节点 Ecs:32656，健康检查关闭**）→ NodePort `newapi-np`(80:32656, Cluster) → Pod stable×4。实测两 IP `/api/status` 各 6 次 200、`/` = `<title>New API</title>`。
  - ⚠ **上述链路已作废（2026-10-06 20:00 任务 19 收口）**：现无 Host → `rule-80-2` → **Eni 组 `sgp-j4qrgy3f7bcv1r67na`**；`sgp-fm7kdwz99wtzbffkfx` 成员已**清空为 0**（不再承载流量）。且 19:20 实测时该直连入口**曾被 `Ingress/new-api-catchall-404` 遮蔽为 404**。详见 ⑨。
- **⚠ 组名误导**：`sgp-fm7kdwz99wtzbffkfx` 名为 `kube-system-fake-svc-80`，实际承载我方 4 节点 —— 判"当前路由指向"必须以 `GetListenerAttribute.DefaultActions` 为准，勿信组名。
- **★ 跨节点 NodePort 是 SG 问题，不是 kube-proxy 问题**：`externalTrafficPolicy=Cluster` 下 ALB 落到的节点要二次转发到别的节点 Pod。需三条同时成立（缺一即"部分 200"）：
  1. **节点 SG ingress 放行来自 ALB SG**（`sg-5tsj1epvcjjv6jkg3zks`）的 32656 —— 规则 `alb-to-nodeport-32656-newapi`（**删了访问即断**）；
  2. **节点 SG egress 放行到 Pod** —— `intra-vpc-tcp 1/65535 → 10.0.0.0/16`（**命脉**）；
  3. **Pod SG ingress 放行来自 VPC** —— `intra-vpc-tcp-to-pods 1/65535 from 10.0.0.0/16`（**命脉**）。**Terway Pod 有独立网卡 + 独立 SG**（`sg-5tsaatp5w68vyqszezja`），**节点 SG 放行 ≠ Pod 可达**。
- **★ Ip 型服务器组天然脆弱，勿用于长期**：`sgp-1zdipho1kpupp43v4m` 成员是 Pod IP，Pod 重建即失效（实测 4 个中 2 个变陈旧）⇒ 只有 NodePort/Ecs 型与 Pod 生命周期解耦。
- **★ Pod 东西向流量不受 Pod SG 约束**：删掉 Pod SG 的 `intra-vpc-udp 1/65535` 后，CoreDNS 仍持续收到**跨节点**（10.0.43.211 → 10.0.22.194 节点上的 coredns）UDP 53 查询并 NOERROR ⇒ 集群内 Pod↔Pod/DNS 不走该 SG。**故 Pod SG 无需为东西向开洞。**
- **★ nodePort 必须固化，且 ALB 不会跟随 Service 端口变化（2026-10-06 已固化）**：`newapi-np` 的 `nodePort=32656` 原为 k8s 从默认 **30000–32767 随机分配**，而 ALB 服务器组 `sgp-fm7kdwz99wtzbffkfx` 后端是**写死的「节点 IP:32656」** ⇒ 一旦 Service 删除后重建，极可能换号 → **4 个后端全部失效，ALB 侧却看不出异常（静默 502/超时）**。已显式声明 `nodePort: 32656`：权威副本 `deploy/manifests/newapi-np.yaml`、创建脚本 `task_alb_url_bodies/06-create-nodeport.sh`（带 `!=32656` 断言）。**若确需改端口，必须同时改服务器组后端**，只改 Service 必断。
- **★ 无证书直连的边界**：仅 HTTP 明文，**仅供内部验收，不得称上线**。⚠ 「ALB Ingress Controller 仍缺位 ⇒ 属临时手段」这句**已作废** —— Controller 是 ACK 托管形态、一直活着（见下方「更正：已挂是误判」）。
- **★★ 「没证书只能走 NodePort」是伪命题（2026-10-06 澄清）**：**证书只管 443，与后端类型无关**，ENI 型在 80 明文下完全可用。当时走 NodePort 的真实原因是两条：① **Ingress `new-api-verify` 把 `host` 写死** `ph-verify.internal.likha.hk` ⇒ Controller 只生成一条 Host 规则 `rule-80-1`，IP 直访 Host 不匹配 → 落 default，**ENI 组压根没机会被命中**；② **`AlbConfig mnl-alb` 声明 80 default = Redirect `www.likha.hk:443`**（域名 NS NXDOMAIN）⇒ 把 ENI 组设成 default 会被 reconcile 打回，且跳转目标是死路。
- **★ ENI 型 vs ECS/NodePort 型选型要点**：两组同为 `ServerGroupType=Instance`，差别在后端 `ServerType`（`Eni` vs `Ecs`）。**ENI**：端口=容器 3000、一跳直连、Controller watch EndpointSlice **自动增删**（HPA 友好）、**健康检查必须开**、`ConnectionDrain 120s` 已开、**Controller 独家管理（手工改会被覆盖）**、要求 Terway ENI 模式。**ECS/NodePort**：端口=32656、经节点二次转发、后端生命周期与 Pod 解耦、健康检查可关（当前 **false**）、手工可控、任意 CNI。**⚠ 常见误解**：ALB 是七层，**HTTP 监听下两型客户端 IP 都靠 `X-Forwarded-For`**（`XForwardedForEnabled` 默认开、不可关），**不存在「ENI 才有真实源 IP」** —— 那是四层 CLB/NLB 语境。⇒ 选型别拿"源IP"当 ENI 优势。**最佳场景**：ENI = 生产主路径（域名+Ingress+HPA）；ECS/NodePort = 兜底/应急/Controller 不可用/混合后端/网络诊断；**混合分流** = Host 规则走 ENI、default 走 NodePort（ALB **规则优先于 default**，故能并存，即当前架构）。
- **★ 想让 IP 直连走 ENI 型的正确做法**：**新增一个不带 `spec.rules[].host` 的 Ingress** ⇒ Controller 生成**无 Host 条件的 Path-only 规则**（优先级在 Host 规则后、default 前）⇒ IP 直访命中 ENI 组，且**不受 default action 被 reconcile 改回 Redirect 的影响**。⚠ 副作用：Path-only 规则会吃掉所有未被 Host 规则命中的流量。**不推荐**把 ENI 组直接设成 default（与 AlbConfig 声明冲突）。
- **★★ AlbConfig 两个反直觉坑（2026-10-06 调研，官方依据）**：
  1. **ListenerSpec 的 default action 字段官方名是 `defaultActions`**，本集群写的是 **`httpDefaultActions`**（ALB OpenAPI 风格名）—— 而 **`AlbConfig` CRD 是 `x-kubernetes-preserve-unknown-fields: true`（无 schema 校验）**，字段名写错**静默忽略、不报错** ⇒ 该声明**极可能从未生效**；反过来 **`defaultActions` 一旦被"修正"就会立刻生效** ⇒ 属**定时炸弹**，动它前必须先验证。
  2. **ALB Ingress Controller v2.11.0+ 不自动创建监听器**（本集群 v3.1.1），监听器**必须**在 AlbConfig 显式声明；且官方规定**「删除监听前必须移除该监听下全部 Ingress，否则报错」** ⇒ **删 `spec.listeners` 段是危险动作**（监听器会被删/报错，通道与路由一起断），且 `idleTimeout`/`requestTimeout` **只能**在 ListenerSpec 里配，删了就没地方配超时。
  ⇒ **修 AlbConfig 声明冲突的正确方案是「不碰 AlbConfig，加无 host Ingress」**（ALB **规则优先于 default**），而非删 `listeners` 或改 default 为 ForwardGroup（后者需引用 Controller 派生组，有悬空风险）。详见 `deploy/ALB后端类型选型_Eni-vs-NodePort型.md` §六之二。
- **★ 改这两个 YAML 的入口与坑（2026-10-06）**：
  - **AlbConfig 是 Cluster-scoped**（实测 `spec.scope=Cluster`）⇒ 命令**别带 `-n`**（带上不报错但误导）。用法：`kubectl get|edit|apply albconfig mnl-alb`。
  - **Ingress `new-api-verify` 的 `last-applied-configuration` 与实际 spec 漂移**：注解里记的 backend 是 **`new-api-master`**（0 endpoint），实际 spec 是 **`new-api-stable`** ⇒ 说明后来是 `patch/edit` 改的、**没回写文件**。**谁拿旧 yaml `kubectl apply` 一次，backend 立刻被打回 `new-api-master` → 规则 `rule-80-1` 全 502**。改前必须先把现状导出成唯一权威副本（`-o yaml > deploy/manifests/…`）再编辑。
  - **AlbConfig 有 finalizer** `ingress.k8s.alibaba/resources` ⇒ `kubectl delete albconfig mnl-alb` 会**级联删云上 ALB 实例**。可改，不可删。

### ★★★ AlbConfig 字段有效性 —— SG 侧实测定论（2026-10-06 任务 25，零风险实验）

**背景**：马尼拉 `mnl-alb` 的 80 监听器违和现象（声明 Redirect、实际 ForwardGroup；超时 15/60 未达 60/600）此前只能推测。**SG 侧全新建 `sg-alb` 得到干净的因果隔离**，结论如下（全部有云端回读证据）：

| 字段 | 有效性 | 证据 |
|---|---|---|
| `port` / `protocol` | ✅ | 建成 `lsn-qmi1hpyr3j83tq3z8j` :80 HTTP |
| **`idleTimeout` / `requestTimeout`** | ✅ **有效** | 写入 `60`/`600` → 回读 `IdleTimeout=60, RequestTimeout=600` |
| **`defaultActions`**（官方名） | ❌ **不生效** | 写入 `[{type: FixedResponse, fixedResponseConfig:{httpCode:"404"}}]` → k8s spec 保留，但云端 `DefaultActions` **仍是** `ForwardGroup → 占位组` |
| **`httpDefaultActions`**（马尼拉现用名） | ❌ 不生效 | 同上的另一形态；**不写的效果与写了一样** |
| `accessLogConfig.logStore` | ⚠️ **webhook 强制 `alb_` 前缀** | 见下 |

**① Controller 一律用自己的 ForwardGroup 覆盖 AlbConfig 的 default action**，指向它派生的占位服务器组 `{ns}-fake-svc-{port}`（tags `ingress_name={albconfig}-listener-{port}`、`service_name=fake-svc`、`service_ns=kube-system`）。**与字段名对错无关**。
⇒ **推论修正**：马尼拉那颗「谁把 `httpDefaultActions` 改成 `defaultActions` 就会激活 Redirect、当场打断直连 IP 通道」的**定时炸弹不存在** —— 正确名同样不生效。马尼拉 80=ForwardGroup 是**稳定态**；残余风险仅剩"有人直接在 ALB 控制台手改"。
⇒ 备站/主站想让 default 兜底某后端，**只能靠 Ingress 规则**（规则优先于 default），不能靠 AlbConfig。

**② 超时参数必须显式写，Controller 默认 `15`/`60`**。SG 写 60/600 → 生效。**马尼拉 V1b 未达标的根因 = 马尼拉 AlbConfig 从未写过这两项**（其 listeners 仅 port/protocol/httpDefaultActions）⇒ **不是"ALB 不支持"**，补一条 apply 即可。**✅ 马尼拉已于 2026-10-06 20:00 补齐**（`deploy/manifests/albconfig-mnl.yaml` → 云端回读 `IdleTimeout=60` / `RequestTimeout=600`，**V1b 由 ❌ 转 ✅**）；同时删除了 `httpDefaultActions`（三态漂移：last-applied=`Redirect→www.likha.hk`／live=`FixedResponse 404`／云端=`ForwardGroup`）—— 该字段既无效又制造"声明≠现实"的审计噪音。详见 ⑨。

**③ `logStore` 必须 `alb_` 前缀 —— admission webhook 硬校验**：
```
admission webhook "albconfig.alb.validate.k8s.io" denied:
  logstore name should start with alb_
```
⇒ `alb-access`（连字符）**不合规**。`sls-newapi-sg` 原本只有连字符版，已补建 `alb_access`（ttl=30 / shardCount=2 / standard，与 `sls-newapi-mnl/alb_access` 同参数）。这也解释了马尼拉项目里 `alb-access` 与 `alb_access` 并存。

**④ Controller 会自动创建监听器，命名 `ingress-auto-listener-{port}`**；AlbConfig 零 Ingress 时会建占位组并挂到 default，事件 `AlbconfigZeroIngress`（**预期，非故障**）。⇒ 先前记的"v2.11.0+ 不自动创建监听器"**证据不足，以实测为准**。

**⑤ 备站 SG ALB 落地实况（任务 25）**：`alb-amdwm60xmznh7s1nae`（`alb-newapi-sg`，Internet/Standard/PostPay/删除保护开）· 公网 `43.98.186.238`(1a) + `47.237.68.142`(1b) · 监听器 `:80` idle60/req600 · Ingress `new-api-ph-standby`(host `sg-standby.internal.likha.hk`) → 服务器组 `sgp-rlxs1mqishcxcfkx7u`（**Eni 型**，2 Pod IP:3000，健康检查 GET /api/status 6s/3s，drain 120s）→ Service `new-api-ph-standby`。**实测带 Host 200 / 无 Host 503，两 IP×6 全 200**。库内副本：`deploy/manifests/{ingressclass-sg,albconfig-sg,ingress-sg-standby}.yaml`；报告 `deploy/Day2任务25_新加坡ALB_执行报告.md`。
**⑥ ★ 无 Host 的 Ingress = 「IP 直访」的声明式解（2026-10-06 实做，✅ 已通）**

想让公网 IP 直接访问（浏览器输 IP / curl 不带 Host）——**不能靠 AlbConfig 的 default action**（⑤ 已证），**只能靠 Ingress 规则**：

```yaml
# rules[0] 故意不写 host
- http:
    paths: [{path: /, pathType: Prefix, backend: {service: {name: <svc>, port: {number: 80}}}}]
```

SG 实测（`new-api-ph-standby` + 追加件 `new-api-ph-standby-ip`）：

| 规则 | 优先级 | 条件 | 目标组 |
|---|---|---|---|
| `rule-80-1` | **1** | Host `sg-standby.internal.likha.hk` + Path `/*` | `sgp-rlxs1mqishcxcfkx7u` |
| `rule-80-2` | **2** | **仅 Path `/*`（无 Host）** | `sgp-8m8eknlyw0z1busl6r` |

⇒ **有 Host 的规则优先于无 Host 规则**（Priority 数字更小者优先），两者天然共存。实测无 Host 两 IP ×6 = **12/12 200**、带 Host 回归 **12/12 200**、`/v1/models` 401（鉴权正常）。
⚠ **副作用**：无 Host 规则会**吃掉所有未被 Host 规则命中的流量**。当前该 ALB 只此一个域名 ⇒ 无冲突；**将来加第二个域名必须重新评估**。
⚠ 多 Ingress 指向同一 Service 会产生**多个内容重复的服务器组**（本例 2 组、各挂同样 2 个 Pod）——冗余但非错误。
库内副本：`deploy/manifests/ingress-sg-standby-noHost.yaml`、`deploy/manifests/hosts-sg-standby.sh`（hosts 加/删，支持 `HOSTS_FILE` 覆盖自测）。

**⑦ ★★ 更正：马尼拉「IP 直连」的 drift 点搞错了**

旧表述「手工把 80 default 改成 ForwardGroup」**不准确**。真相：马尼拉 `DefaultActions → sgp-fm7kdwz99wtzbffkfx`，该组名为 **`kube-system-fake-svc-80`**、tags `service_name=fake-svc` / `ingress_name=mnl-alb-listener-80` ⇒ **它本就是 Controller 派生的占位组**（与 SG 侧 `sgp-p1qg1z0rqgbovj3yqd` 同类）。
⇒ default action **从未被手工改过**，一直是 Controller 的 ForwardGroup（**稳定态**）。
⇒ **真正的 drift 点是「手工往这个占位组里塞了 4 个节点 Ecs:32656 后端」** —— 成员是手工加的，Controller 某次 reconcile 可能把它清空 ⇒ 那才是直连通道失效的真实路径。**判风险要盯成员，不是盯 default action。**

**⑧ ★ `alb ListRules` 取「条件/动作」的字段名**

返回项是扁平结构，条件与动作为**复数数组**：

```
RuleConditions[] : { Type: "Host"|"Path"|..., HostConfig: { Values: [...] }, PathConfig: { Values: [...] } }
RuleActions[]    : { Order, Type: "ForwardGroup", ForwardGroupConfig: { ServerGroupTuples: [{ServerGroupId, Weight}] } }
```

❌ 用 `RuleCondition` / `RuleAction`（单数）取 ⇒ **恒空 `{}`，静默无报错**（本次踩过）。
❌ 传 `RuleIds.N` 过滤 ⇒ 回 `TotalCount: 0`（该参数在本版本不生效）⇒ **只能全量 `ListRules` 后本地筛**。
❌ `GetRuleAttribute` **不是有效 API**（CLI 回 `"is not a valid api"`）。
✅ 正解：`alb ListRules --region … --version 2020-06-16 ListenerIds.1=<lsn-…> MaxResults=100`，本地按 `Priority` 排序读 `RuleConditions`/`RuleActions`。

- **★ ActionTrail 在本账号不可用**：`actiontrail LookupEvents`（ap-southeast-6）**任意时间窗均返回 0 事件** ⇒ 未开通/未投递，**不能作为变更取证手段**。

### ★★ 更正：「ALB Ingress Controller 已挂」是误判（2026-10-06 实证）

**旧结论**（2026-10-05 只读复核）：集群内无 alb Pod/Deploy ⇒ 组件已挂、元数据不可信。**该结论错误。**

**真相**：`alb-ingress-controller v3.1.1` 是 **ACK 托管形态** —— webhook 与 reconcile 跑在**托管平面**，**不以 Pod 形式出现在用户集群**，集群内无 Pod 属正常。

**判活方法（节点的 TCP 探针会误判！）**：
| 方法 | 结论 | 说明 |
|---|---|---|
| ❌ 节点侧 `TCP connect 7.8.229.211:9443` | TCP-FAIL | **误导**。`7.8.x` 是托管平面地址，只有 **apiserver** 可达，节点不可达 |
| ❌ `kubectl get pods -A \| grep alb` | 空 | **误导**。托管形态本就没有 Pod |
| ✅ **server-side dry-run** | **活** | `kubectl -n new-api annotate ingress new-api-verify x=1 --dry-run=server --overwrite` → `annotated (server dry run)`；AlbConfig 同理。**apiserver 真调到了 webhook** |
| ✅ 托管资源 createtime | **活** | 组 `sgp-tqgwt413t19mum8oa9` CreateTime `2026-10-06T00:20:16Z`（北京 08:20，晚于最后一批 Pod 00:10:22Z） |
| ✅ 监听器/规则描述 | **活** | `ListenerDescription="ingress-auto-listener-80"` + `rule-80-1` 均为 Controller 自动创建 |

**⇒ 判 ACK 托管组件的死活，一律用 server-side dry-run，不要用「集群内有无 Pod」或「节点侧 TCP 探针」。**

### ★★ Gateway 双路径（2026-10-06 实测，同一 ALB 80 端口）

监听器 `lsn-ihrgkty2sjdy8s5p4h`（80，**`IdleTimeout=60` / `RequestTimeout=600` ✅** —— 2026-10-06 20:00 补齐）有**两条并存的出口**：

| 入口条件 | 目标服务器组 | 类型 | 与 Pod IP 的关系 | HPA 扩缩容 |
|---|---|---|---|---|
| 规则 `rule-80-1`：Host = `ph-verify.internal.likha.hk` + Path `/*` | `sgp-tqgwt413t19mum8oa9`（`new-api-new-api-stable-80`） | **Eni（Pod IP）** | 直接绑 Pod | **✅ 由 Controller 自动同步** |
| 其他 / 无 Host → `DefaultActions` | `sgp-fm7kdwz99wtzbffkfx`（`kube-system-fake-svc-80`） | **Ecs（节点 :32656）** | 解耦 | 无需同步（天然免疫） |

- **`sgp-tqgwt413t19mum8oa9` 的同步机制**：Controller 依据 **Ingress `new-api-verify` → backend `new-api-stable:80`**，watch Service `new-api-stable` 的 EndpointSlice（`new-api-stable-sbwkk`）→ Pod 增减即 `AddServers/RemoveServers`。组当前 4 成员 = EndpointSlice 4 个 ready IP。
- **摘除保护已开**：`ConnectionDrainConfig{Enabled=true, Timeout=120}`（缩容时先 drain 120s 再摘）。
- **健康检查**：`HealthCheckEnabled=true`、HTTP GET `/api/status`、interval 6s、healthy 2 / unhealthy 3 ⇒ 新 Pod 未就绪不转发。
- **✅ 已实测（2026-10-06 20:05 意外取证）**：「Pod 变 → 组变」由 Controller **自动完成**。当天 `new-api-stable` 发生滚动更新（ReplicaSet `7f96d6ff48` 4→3 逐渐被 `86d6ff48d7` 替换），两个 Eni 组（`sgp-tqgwt413t19mum8oa9` 与 `sgp-j4qrgy3f7bcv1r67na`）的成员**同步换成了新 Pod IP**（`10.0.43.214` / `10.0.43.217` / `10.0.22.219` / `10.0.43.206`），期间 **24/24 请求全 200，零中断** ⇒ 无需人工干预，也无需再跑 `scale --replicas=5` 验证法。
- **⚠ AlbConfig 声明与现实不一致（✅ 已收口 · 2026-10-06 20:00）**：此前 `AlbConfig mnl-alb` 声明 `listeners[0].port=80 → httpDefaultActions=Redirect to www.likha.hk:443`，实际 default 是 ForwardGroup；后 live 又漂成 `FixedResponse 404`。**SG 侧零风险实验已证：Controller 一律忽略 AlbConfig 的 default action 声明**（见下方 ★★★ 节 ①）⇒ **「会被 reconcile 改回 Redirect」的风险不存在**；本次已**直接删除该字段**，声明与云端（ForwardGroup）一致。
  ⇒ 另一处真实风险：default 指向的 `sgp-fm7kdwz99wtzbffkfx`（`kube-system-fake-svc-80`）是 Controller 派生的**占位组**，其 4 个 `Ecs:32656` 后端是**手工加**的 ⇒ **已按 ⑨ 清空为 0 成员**，隐患解除。**判风险盯成员，不盯 default action。**

### ⑨ ★★ 任务 19 收口：马尼拉对齐新加坡（2026-10-06 20:00，✅ 三项全部实做）

**触发**：用户「把菲律宾马尼拉的 alb 也类似配置」（对照同日完成的任务 25 新加坡 ALB）。

| # | 动作 | 结果 |
|---|---|---|
| 1 | `kubectl apply` 新 `AlbConfig mnl-alb`（listeners = `port`/`protocol` + `idleTimeout: 60` + `requestTimeout: 600`，**删 `httpDefaultActions`**） | 云端回读 **60/600 ✅**；generation 2→3；**改前改后各测全 200，无断流** |
| 2 | 新增 `Ingress/new-api-stable-ip`（**无 host**，`order: "50"`）→ `new-api-stable:80` | 生成 `rule-80-2` → 新 Eni 组 **`sgp-j4qrgy3f7bcv1r67na`**（`new-api-new-api-stable-80`，HC True）；**IP 直访 404 → 200** |
| 3 | `RemoveServersFromServerGroup` 摘除 `sgp-fm7kdwz99wtzbffkfx` 的 4 个 `Ecs:32656` | 成员 **4 → 0**（异步 `JobId c9d0c1c3-…`，先 `Removing` 后清空）。**零流量影响**（该组已被规则遮蔽） |

**规则终态（`order` 语义实测有效：1 < 50 < 100 ⇒ Prio 1/2/3）**：

| Prio | 条件 | 动作 | 来源 Ingress |
|---|---|---|---|
| 1 | Host=`ph-verify.internal.likha.hk` **AND** Path `/*` | ForwardGroup → `sgp-tqgwt413t19mum8oa9` | `new-api-verify`（order 1） |
| 2 | Path `/*`（**无 Host**） | ForwardGroup → **`sgp-j4qrgy3f7bcv1r67na`** | **`new-api-stable-ip`（order 50）← 本次** |
| 3 | Path `/*`（**无 Host**） | FixedResponse **404** | `new-api-catchall-404`（order 100，**沉底**） |
| — | default | ForwardGroup → `sgp-fm7kdwz99wtzbffkfx`（**现为空组**） | Controller 自管 |

**实测**：无 Host 两 IP ×6 = **12/12 200**；带 Host 两 IP ×6 = **12/12 200**（合计 24/24）；`curl --resolve ph-verify.internal.likha.hk:80:<IP>` = 200 / 2579B；路径覆盖 `/` 1047B · `/api/status` 2579B · `/healthz` 1047B · `/v1/models` **401** —— **与新加坡逐项一致**。

**★ 新知识**：

1. **`aliyun alb ListRules` 的参数是 `--ListenerIds.N`（复数）**。用 `--ListenerId`（单数）回 `"--ListenerId" is not a valid parameter or flag`，且 CLI 同时给 `did_you_mean: ["--ListenerIds"]` ⇒ 与 `RuleConditions`/`RuleActions` 复数坑同源。**遇 CLI 说参数名非法，先信 CLI。**
2. **`Ingress/new-api-catchall-404` 曾把裸 IP 也变成 404**（order 100、Path `/*` 无 Host）。实测 19:20 `http://8.212.161.49/api/status` = **404 / 9B "Not Found"** ⇒ 任务 19 报告 §七「IP 直连可用」当时已失效。**结论：同一 listener 上「无 Host 的 Path `/*`」只能有一条语义**（兜底 404 或转发业务），靠 `order` 决定优先级；本次业务放 order 50、404 沉到 order 100。
3. **`RemoveServersFromServerGroup --DryRun true`** = ALB 写操作的低成本校验器：回 `DryRunOperation` 即参数与资源校验全过、**零变更**。建议所有 ALB 写操作先干跑。
4. **⚠ 主站裸 IP 的代价（须知晓）**：`rule-80-2` 无 Host 条件 ⇒ **任意 Host**（含他人把自有域名解析到 `8.212.161.49`）都命中主站（实测陌生域 → **200**）。新加坡侧同构存在但备站无流量；**主站建议后续加 `SourceIp` 白名单**收紧（Ingress 注解 `alb.ingress.kubernetes.io/conditions.<svc>`）。

**交付**：`deploy/manifests/{albconfig-mnl.yaml, ingress-mnl-stable-ip.yaml, hosts-mnl.sh}` · `deploy/task19b_bodies/{00-recon,01-albconfig-timeout,02-nohost-ingress}.sh` · 报告 `deploy/Day2任务19_ALB对齐新加坡配置_执行报告.md`。

**回滚**：`kubectl -n new-api delete ingress new-api-stable-ip`（恢复 Prio 3 的 404 兜底）；drift 成员可用 `AddServersToServerGroup` 加回（4 节点清单见报告）。

**⚠ 遗留**：`newapi-np`（NodePort `32656`）**未动** —— 清 drift 后已无 ALB 侧引用，按任务卡保留至证书到位再退役。

### ★ ECS 安全组 API 参数形态（2026-10-06 血泪）

- **`RevokeSecurityGroup` / `AuthorizeSecurityGroup` 在国际站 ap-southeast-6 用「扁平参数」**，**不是** `SecurityGroupRule.N.*` 数组：
  ```
  aliyun ecs RevokeSecurityGroup --region ap-southeast-6 \
    --SecurityGroupId sg-xxx --IpProtocol TCP --PortRange 32656/32656 \
    --SourceCidrIp 10.0.0.0/16 --NicType intranet --Policy Accept --Priority 1
  aliyun ecs RevokeSecurityGroupEgress ... --DestCidrIp 10.0.0.0/16   # 出站用 Egress
  ```
- **误用数组参数的报错极具误导性**：传 `SecurityGroupRule.1.IpProtocol=TCP` → 回 **`InvalidIpProtocol.ValueNotSupported`**（"must be specified with case insensitive TCP..."），**看起来像值写错，实际是参数名不被识别**（服务端读到空值）。且 `aliyun_rpc.py --dry` 打印的请求参数**完全正确**，签名也通过（有 RequestId）⇒ **不能靠"参数打印正确 + 签名通过"判定参数名有效**。
- **CLI 直接暴露线索**：`--SecurityGroupRule.1.Direction` → `"is not a valid parameter or flag"`（CLI metadata 里该 API 无此参数）。**遇到 CLI 说参数名非法，先信 CLI**。
- **`RevokeSecurityGroupIngress` 在本地域不存在**（`is not a valid api`），只有 `RevokeSecurityGroup` / `RevokeSecurityGroupEgress`。
- **零风险探针**：用真实 SG + **不存在的规则**（如 `PortRange=19999/19999 --SourceCidrIp=10.99.0.0/16`）→ 回 `InvalidSecurityGroupRule.RuleNotExist` 即证明参数层已过，不会误删任何东西。

## 执行通道 `ack_remote.sh`（跨宿主注意）

- **`base64` 不是可移植的**：GNU 支持 `base64 -w0 <file>`；**BSD/macOS 只认 `base64 -i <file>`（无 `-w`）** → 在 macOS 上 `base64 -w0 file` 报 `invalid argument` 并**静默产出空 Body**（远端只回 `BODY START/END` 而无内容，极易误判为"远端没输出"）。已统一改 **python3 编码 + 空值校验**（`ack_remote.sh` / `task19_alb_mnl.sh` 的 `run_cloud_assistant`；`task46_jumphost.sh`、`task11_nodepool_mnl.sh` 的 `base64 -w0` 若要跑在 macOS 宿主需同样处理）。
- `ack_remote.sh <site> <body.sh> [node_id] [loops]`；kubeconfig 缓存在 `/tmp/ackctl-<site>/`（已缓存则不再签发，切集群须清缓存）；输出靠轮询 `DescribeInvocationResults`，长任务把 `loops` 调大（500s 级用 100+）。

## 日志库 DSN 注入口径（任务 17 · 2026-10-05 复核）

- **两地 `Secret/new-api-secrets` 已含 `LOG_SQL_DSN`**（mnl 6 键 / sg 3 键）；ConfigMap `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`。核验脚本 `deploy/task17_dsn_verify.sh [mnl|sg|both]`（只读；含端点口径断言 + 端到端鉴权，日志 `deploy/logs/task17_verify_<ts>/`）。
- **端点口径（关键，别写错）**：**mnl 走 VPC** `cc-5tsv2o51s1360b0pr-clickhouse.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（同区私网、不走 NAT）；**sg 走 PUBLIC** `cc-5tsv2o51s1360b0pr-public.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（跨区，09-30 裁定③；公网 IP `43.118.97.47`，白名单组 `sg_eip`）。**sg 若误填私网端点 → 跨区 TCP 9000 超时，备站日志必失败**（10-05 实测并修正）。
- 鉴权自检（节点内、口令不外泄）：`curl -fsS -m 10 -o f --user "$U:$P" "http://<host>:8123/?database=newapi_logs" --data-binary 'SELECT 1'` → `1`；`SHOW TABLES` → `logs`。CK HTTP 接口 8123 在 VPC 与 public 端点**均已开放**。
- 改 Secret：`kubectl -n new-api patch secret new-api-secrets --type merge --patch-file <json>`，json 用 `{"stringData":{"LOG_SQL_DSN":"..."}}`（免手工 base64；`--patch-file` 避免口令出现在 `ps`）。
- ⚠ **项目铁律重申**：**VPC 端点两端皆偶发抖动**（mnl 8123 实测同秒一次超时、一次成功）⇒ 一切 VPC 端点探活必须带重试。

## `ack_remote.sh` 写 body 的硬性纪律（血泪，2026-10-05）

- body 由 **不带引号的 heredoc** 组装 → 正文里：
  - **禁止反引号**（会被本地 shell 当命令替换执行，报 `-w: command not found` 之类）；
  - **禁止裸 `$1`/`$2`/`$VAR`**（本地 `set -u` 下报 `unbound variable`，且值会提前展开）→ 一律写 `\$1`/`\$VAR`。
  - 注释里写 `$1`/`-w '...'` 同样会中招（本次连环踩两次）。
- 远端 `curl -w '%{http_code}'` 在该环境**可能不回显**（得空串，假阴性）⇒ 用 `curl -fsS -m N -o file` + 退出码 + 响应体判定。
- 长任务：第 4 参 `loops` 调大（默认 24×5s=120s 会超时）。

## ACR / 任务 16（2026-10-05 只读复核）

- **实例**：`acr-newapi-mnl` / `cri-avfqy9xkqi5bj8ee` / `RUNNING` / `Enterprise_Basic`（ap-southeast-6）；新加坡 `ListInstance --RegionId ap-southeast-1` → **0**（单地域口径成立）。端点：公网 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com` / VPC `acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com`。
- **2b 未闭环**：`GetInstanceVpcEndpoint` → **`LinkedVpcs=[]`**（09-28 空、10-05 仍空）。后果实测：集群内 `getent hosts …-vpc…` **无输出**；`kubectl run` 用 `-vpc` 域名 → `ImagePullBackOff`，报 `dial tcp: lookup …-vpc…ap-southeast-6.cr.aliyuncs.com on 100.100.2.136:53: no such host`。**公网域名可用**（`ptest-pub` → `Succeeded` / `PULL_OK`）。修复：`cr CreateInstanceVpcEndpointLinkedVpc --InstanceId <id> --VpcId vpc-5tst1tgeessxn1azwasg2 --VswitchId vsw-5tswpyzfa8od6je95tdh`（**卡内明示属需负责人确认的写操作**）。
- **命名空间/仓库**：`newapi-prod|pre|test|dev`，`AutoCreateRepo=false` 全部；仅 `newapi-prod` 有仓：`newapi-master`(PUBLIC) / `newapi-slave`(PRIVATE) / `newapi-pg-bouncer`(PRIVATE)。RepoId：`newapi-master`=`crr-eo15b1p46wt8yeek`、`newapi-slave`=`crr-nnn8d8k0qmiwjx6d`、`newapi-pg-bouncer`=`crr-y00cmmfgut2nkdho`。
- **CLI 口径（实测坑）**：`cr ListRepoTag` 的唯一请求参数是 **`--RepoId`**（必需，配 `--InstanceId`）；`--RepoNamespaceName/--RepoName` **不合法**（报 `is not a valid parameter`）。取 RepoId 走 `cr GetRepository --RepoNamespaceName <ns> --RepoName <repo>` → `.RepoId`。
- **`cs DescribeClustersV1`**：**不带 `--RegionId` 返回跨地域全量集群**（实测一次列出 jkt-dev `ap-southeast-5` / sg / mnl 三个）；带 `--RegionId ap-southeast-6` 反而**返回空**（国际站该接口对 region 参数不敏感）⇒ **判集群一律用不带 region 的全量列表**。三集群真值：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c` · **sg `ca75829e3492d491d9d434de087913798`** · jkt-dev `cb0abf5bc06034f7bbdb991752f6f3e62`。⚠ 旧记的 sg `ca75829e…` 后缀缩写不足以调用 API。
- **集群内 helper / 免密**：mnl addon `managed-aliyun-acr-credential-helper` **active v24.01.29.1-5318af4-aliyun**；**SG 集群 addon 全量列表无任何 acr/credential 组件**（卡片要求"新加坡集群同样要装"未做）。聚合 Secret `acr-credential-secret-aggregation`（`kubernetes.io/dockerconfigjson`）**只挂到 `SA/new-api-app`**，`SA/default` 无（调试 Pod 必须 `--overrides` 指定 `serviceAccountName`）。
- **`new-api` ns 有 ResourceQuota `new-api-quota`**：`kubectl run` 不显式给 `requests/limits` 的 cpu+memory 会被直接拒（`Forbidden: failed quota`）。**调试 Pod 标准写法**：`kubectl run <n> --image=<img> --restart=Never --overrides='{"spec":{"serviceAccountName":"new-api-app","containers":[{"name":"<n>","image":"<img>","command":["sh","-c","echo PULL_OK"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'`。
- 报告：`deploy/Day1任务16_ACR_执行报告.md`。

## 阿里云 CLI 可执行路径（macOS 宿主）

- 本项目脚本在 **macOS/zsh** 下 `aliyun` **不在 PATH**（`command not found`）→ 用全路径 `/Users/yanxuewei/.workbuddy/binaries/aliyun-cli/aliyun`（3.5.1）。脚本内的 PATH 自愈 `case` 判断的是 `.workbuddy/binaries/aliyun-cli` 目录在 PATH 与否，macOS 上需显式导出该目录。

## ACR 任务 16 闭环（2026-10-05 18:15–18:25，写操作）

> ⚠ 本节覆盖上文「ACR / 任务 16」节里的 **2b 未闭环 / SG 无 helper / PUBLIC** 三项结论 —— 均已于 10-05 18:25 前修复。

- **2b 已关联**：`cr CreateInstanceVpcEndpointLinkedVpc --region ap-southeast-6 --InstanceId cri-avfqy9xkqi5bj8ee --VpcId vpc-5tst1tgeessxn1azwasg2 --VswitchId vsw-5tswpyzfa8od6je95td1h --ModuleName Registry` → `{"IsSuccess":true}`；回读 `[{Status:RUNNING, VpcId, VswitchId, Ip:10.0.22.220, DefaultAccess:true, Issue:NO_PRIVATE_ZONE_AUTHORIZED}]`。**`Issue=NO_PRIVATE_ZONE_AUTHORIZED` 不影响解析**（未开 `EnableCreateDNSRecordInPvzt`，但集群内 `getent hosts …-vpc…` 已返回 `10.0.22.220`）。
- **⚠ vSwitch ID 易错**：正确 `vsw-5tswpyzfa8od6je95td1h`（末端 `td1h`）。少写一个 `1`（`…tdh`）→ `VSWITCH_NOT_EXIST / VSwitch is not exist.`，**看起来像偶发抖动，实为 ID 打错**。判 vSwitch 真值用 `vpc DescribeVSwitches --RegionId ap-southeast-6 --VpcId <vpc>`。
- **SG helper 已装**：`cs InstallClusterAddons --ClusterId ca75829e3492d491d9d434de087913798 --region ap-southeast-1 --header "Content-Type=application/json" --body '[{"name":"managed-aliyun-acr-credential-helper","config":"<json 字符串>"}]'` → `task_id T-6ac37991fa7b0a01090030fb`，30s 后 `state=active`。**⚠ 必须带 `--header "Content-Type=application/json"`**，否则 400 `FAILED_TO_READ_REQUEST`；`--body.1.name=` 点式写法同样 400。config 与 mnl 一致即可。
- **`cr UpdateRepository` 参数**：`InstanceId` / `RepoId` / **`RepoType`** / **`Summary`（必填！）**，`RepoName`/`Detail` 可选。改 PRIVATE：`--RepoId crr-eo15b1p46wt8yeek --RepoType PRIVATE --Summary "master模块"` → `{"IsSuccess":true}`，回读 `RepoType=PRIVATE`。
- **实测耗时（§11 RTO 输入）**：mnl VPC 域名拉取 `ptest-vpc2` **5s**；SG 公网跨区拉 `ptest-sg` **11s**（78 MB 镜像，含调度+拉取+启动）⇒ 未触发「SG 补建 ACR + 同步规则」回退。
- **调试 Pod 标准写法**（`new-api` ns 有 ResourceQuota `new-api-quota`，缺 resources 直接 `Forbidden: failed quota`）：`kubectl run <n> --image=<img> --restart=Never --overrides='{"spec":{"serviceAccountName":"new-api-app","containers":[{"name":"<n>","image":"<img>","command":["sh","-c","echo OK"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'`。
- **§12 门禁判据（可复用）**：同镜像同 tag 双 SA 对照 —— `new-api-app` → 通、`default` → `ImagePullBackOff`，即门禁成立。

## 任务 30 · 备站→马尼拉 RDS 公网读写 + RTT 实测（2026-10-05 实做）

**判据 vs 实测（SG 侧一次性探针 Pod 内）**

| 判据 | 期望 | 实测 | 判定 |
|---|---|---|---|
| TCP RTT SG→MNL RDS | ≤45 ms | 建连 p50 **37** / p95 40 / max 41 ms；ICMP avg **35.54** ms | ✅ |
| `pgbench` 单连接 TPS | ≥20 | c1 **30.46**（lat 32.8 ms）；c16 **455.34** | ✅ |
| TLS 握手成功率 | 100% | 50/50 + 20/20 + 10/10（TLSv1.3 / AES256-GCM） | ✅ |
| 建连平均（含 TLS） | ≤200 ms → **≤300 ms** | p50 **276**（复测 280） | ⚠ **判据已修订（2026-10-05），修订后达标** |
| `sslmode=verify-full` | 卡口径 | SG 已切 `verify-full&sslrootcert=/etc/ssl/rds/ca.crt`；正例 3/3、负例 3/3 | ✅ **2026-10-05 闭环** |
| V1 读的是马尼拉主库 | — | `inet_server_addr()` **非 superuser 回 NULL** ⇒ 用 db/user/version/`pg_postmaster_start_time` 等价证据 | ⚠ |
| V2 主站写→备站读 | — | ✅ 写入后 51 s 读到同条，表结构一致 | ✅ |
| V3 连接预算 | — | 复测 `newapi_sg` **=1（探针自身）**，`idle 15` 已被托管池回收 | ✅ **2026-10-05 闭环** |
| V4 拔线自愈 | — | N=100 三段 **100% → 69.0% → 100%** | ✅ **2026-10-05 闭环** |

**★ 建连成本拆解（定位根因，全部 Pod 内实测）**：`psql --version` 纯进程启动 **19 ms** · 经池 6432 建连 **280 ms** · **直连 5432 建连 279 ms** · 单进程 20 次串行查询（1 次建连）**300 ms** · `pgbench -C`（每事务新建连接）latency **250.95 ms / 3.98 TPS** vs 复用连接 **35.45 ms / 28.21 TPS**。⇒ **池不增成本**（甲乙两路无差异）；~250 ms ≈ 19 + RTT 35 ms × 约 7 次往返（SSLRequest + TLS1.3 1-RTT + SCRAM 2-RTT + 后端 fork + 首查询）⇒ **200 ms 判据在该 RTT 下不可达**，改判据（≤300 ms）或强制连接复用（35 ms/查询）。

**★ `verify-full` 前提缺口**：5432 链 **2 张**（leaf `CN=…-pub…`，SAN 含域名、`checkhost` MATCH、2026-09-29→2027-09-29；中间 CA `CN=ApsaraDB ap-southeast-6 region CA`），**无根 CA**。`sslrootcert=system` → `certificate verify failed`（**RDS 非公有 CA 签**）；拿 leaf 当 rootcert 打 5432/6432 **都失败**。⇒ 必须另取阿里云 RDS 根 CA，或退 `verify-ca`。**5432 与 6432 同一张 leaf**（卡内「池复用同证书」成立）。

**★ 探针方法坑**：**`openssl s_client` 判不了 PgBouncer(6432) 的 TLS** —— 直打 6432 **10/10 失败**，但 `psql`（require）**50/50 成功**、`ssl=on`。PG/PgBouncer 的 TLS 需先 `SSLRequest` 协议协商，`openssl s_client` 直接起 TLS 对不上；而同手法打 **5432 却 OK**（RDS 代理层容忍）⇒ 极易误判「6432 链路坏了」。**判 PG 侧 TLS 一律用 `psql`；`openssl s_client` 只用来取证书链。**

**执行位口径**：SG `new-api` 命名面**零工作负载** ⇒ `deploy/new-api-ph-standby` 不在位，本卡只能靠一次性探针 Pod。Pod 模板（`new-api` ns 有 `ResourceQuota new-api-quota`，**必须显式给 resources**）：`postgres:17` + `serviceAccountName: new-api-app` + `env.valueFrom.secretKeyRef`（口令不进命令行）。body 脚本 `deploy/task30_bodies/03..10-*.sh`。**`ack_remote.sh` 单窗口约 5 min（`loops×5s`）⇒ 测量脚本必须拆段**（原 `02-sg-net.sh` 50×TCP+20×TLS 整体超时即反例）。证据 `deploy/logs/task30_drill_20261005-211909/`。


## RDS TLS 根 CA + 白名单拔线（任务 30 闭环，2026-10-05 21:45–22:07）

**根 CA 从哪来（不用控制台）**：`aliyun rds DescribeDBInstanceSSL --RegionId ap-southeast-6 --DBInstanceId <id>` 返回 `ServerCAUrl` = `https://apsaradb-public.oss-ap-southeast-1.aliyuncs.com/ApsaraDB-CA-Chain.zip`（**注意是 sg 的 OSS，全球通用包**）。`curl --noproxy '*'` 直连可下（191 KB），解压得 `ApsaraDB-CA-Chain.pem`（**69 张证书**）。

**★★ 坑：包内有 2 张同名 `CN=ApsaraDB Root CA`**
- `cert_001`：SKI `3C:30:27:8B:…`，2016-05-05 → 2036-04-30（**旧根，用它会 `error 20 unable to get local issuer certificate`**）
- `cert_027`：SKI `7F:D6:ED:5C:…`，2019-01-30 → **2039-01-25**，SHA256 `29:54:2B:04:…:04:B9`（**正确根**）
- 判据：leaf 的中间 CA（`CN=ApsaraDB ap-southeast-6 region CA`）的 **AKI = `7F:D6:ED:5C:…`** ⇒ 选 `cert_027`。
- **⚠ 假通过陷阱**：`openssl verify -CAfile 全包.pem -untrusted 全包.pem leaf.pem` 会返回 **OK**——因为 openssl 把中间 CA 直接当信任锚。**必须用「根作 -CAfile、中间作 -untrusted」严格验证**。
- 拆包法：`awk '/BEGIN CERTIFICATE/{n++} {print > sprintf("cert_%03d.pem", n)}' 全包.pem` 再逐张 `openssl x509 -noout -subject -issuer` 建索引。

**落地产物**：`deploy/certs/rds-apse6-ca.crt` = 根(cert_027) + 6 区中间(cert_058)，**4127 B**。
**Secret 口径**：`kubectl -n new-api create secret generic rds-ca-apse6 --from-file=ca.crt=<file> --dry-run=client -o yaml | kubectl apply -f -`；Pod 挂到 **`/etc/ssl/rds`**。
**DSN 口径**：`…?sslmode=verify-full&sslrootcert=/etc/ssl/rds/ca.crt`（`sslrootcert` 是**路径**，不支持内联；改 DSN 与挂 Secret **必须同批**）。
**patch 姿势**：`printf '{"stringData":{"SQL_DSN":%s}}' "$NEWJ" > /tmp/p.json && kubectl patch secret new-api-secrets --type merge --patch-file /tmp/p.json`（口令走文件，不进 `ps`）。
**负例可复现**：无 `sslrootcert` → `root certificate file "/root/.postgresql/root.crt" does not exist`；`sslrootcert=system` → `SSL error: certificate verify failed`（RDS 非公有 CA 签）。

**★ 白名单拔线自愈方法（可复用于任何 RDS 白名单验证）**
1. 探针：SG 节点内 `timeout 3 bash -c "exec 3<>/dev/tcp/<pub-host>/6432"` × N=100（**每连接独立 → 逼出 SNAT per-flow 哈希轮换**）。
2. 改白名单：`aliyun rds ModifySecurityIps --RegionId ap-southeast-6 --DBInstanceId <id> --DBInstanceIPArrayName sg_standby_eip --SecurityIps "<3个/32>" --ModifyMode Cover`（**必须 `--ModifyMode Cover`，否则是追加**）。
3. 观察 → 恢复（4 个 /32 全回）→ 复验。
4. 实测：**100% → 69.0% → 100%**（失败率 31% ≈ 理论 25%）。
5. **失败形态 = 3001 ms 超时（DROP，非 RST）** ⇒ 应用要有 `connect_timeout` + 重试；**ICMP 全程 0% 丢包 ⇒ ping 发现不了白名单问题**，必须 TCP 层拨测。
6. **白名单恢复即时自愈**（恢复后第 1 次探测即 OK，无残留）。
7. ⚠ 全程**不影响主站**（主站走 `mnl_vpc` 内网组），但**属云写，须授权**；改完必须回读 `DescribeDBInstanceIPArrayList` 比对四组。

**可复用 body**：`deploy/task30_bodies/11-sg-verifyfull.sh`（CA 落地+正负例）· `12-sg-dsn-verifyfull.sh`（DSN 切换+复验）· `13-sg-conn-probe.sh`（拔线三段，`sed` 注入 `TAG=`）· `14-sg-v3-conncount.sh`（连接账目）。
**V3 审计小技巧**：`pg_stat_activity` 对**非特权账号**也可见其他会话的 `usename`/`state`（敏感列隐藏）⇒ 查连接账目不需要 superuser。

**证据**：`deploy/logs/task30_v4_verifyfull_20261005-220047/`（12 文件含 `summary.json`）；报告 `deploy/Day1任务30_备站公网读写_RTT实测_执行报告.md` §七。

## golang-migrate 版本化迁移（任务 54 · 2026-10-05 实做）

**工具到位**：节点（mnl `i-5ts9wk588cliiweawind`）可直连 GitHub ⇒ `curl -fL .../v4.19.1/migrate.linux-amd64.tar.gz`（17,394,526 B；二进制 sha256 `2205d19c3f17a762d58ff63b64572c23b2d6d10f9366be4d04938a09d630df12`）；节点无 `psql`/`jq` ⇒ SQL 客户端用 `python3 -m pip install pg8000`（1.26.0，Python 3.6.8 可装）。

**★★★ 四条硬规则（踩过才懂）**

1. **`-- +migrate NoTransaction` 在 golang-migrate 里不存在**。那是 goose 的 `-- +goose NO TRANSACTION`；golang-migrate 的 `source/parse.go` / `source/migration.go` / `database/driver.go` **均无此符号**。写了会报 `CREATE INDEX CONCURRENTLY cannot run inside a transaction block in line 0: -- +migrate NoTransaction`，并把库钉在 `version N (dirty)` ⇒ 之后所有 `up` 都被 `Dirty database version N. Fix and force version.` 拒绝。恢复：`migrate force <上一个成功版本>`（只改 `schema_migrations`，不执行 DDL；**禁止手改表**）。
2. **`CREATE INDEX CONCURRENTLY` 必须独占一个迁移文件**。默认 `x-multi-statement=false` 时 postgres 驱动把**整个文件**作为**一条** statement 交给 `Exec`；多条语句挤进一次 `Exec` = 隐式事务块 ⇒ 文件里多一条语句就失败。`x-multi-statement=true` **不是**关事务开关（它把多语句显式拆开，事务语义更难推理）。官方 README 原话："put CREATE INDEX CONCURRENTLY in its own migration"。⇒ **加列（事务内）与建索引（事务外）必须是两个版本号**。
3. **★ 停在 `idle in transaction` 的连接会挂死 CIC**（CIC 要等所有并发事务结束才能取快照）。pg8000 / psycopg 默认每条 `execute` 后事务保持打开 ⇒ **观测/调试连接会让被观测的迁移自己卡住**（本卡实测：云助手任务停在 `Running`，只能 `StopInvocation` 强杀，`pg_stat_activity` 留下 `state=idle in transaction`）。修复：观测连接一律 **`autocommit=True`** + `statement_timeout` + daemon 线程 + 硬超时兜底。**生产同理**：连接池泄漏 / 挂在事务里的 DBA session 会让线上 CONCURRENTLY 迁移无限等待。
4. **迁移工作目录每轮清空**：migrate 对 `-path` 目录**全量扫描**（不看时间戳），残留旧 `000003_*.sql` 与新写同名版本号 ⇒ `duplicate migration file` 直接拒绝启动。

**dirty 诊断三步**：`migrate version` 看 dirty → `select pid,usename,state,query from pg_stat_activity where datname=current_database() and state='idle in transaction'`（→ `pg_terminate_backend`）→ `migrate force <上一个成功版本>`。

**锁观测方法（可复用）**：并发 writer（pg8000，`autocommit=True`，每条 `UPDATE` 计时）× N + 采样线程每 200ms 取 `count(*) from pg_stat_activity where wait_event_type='Lock'`；主线程 `subprocess` 跑 `migrate down K` + `migrate up`。判据：`lock_events=0` + writer p50 与无迁移时持平。**实测**：expand(加列 + CIC) / backfill(2000 行) / contract(删列) 全程 `lock_events=0`、`max_lock_wait=0`，写 p50 **6.33 ms** / p95 6.53 / max 7.34 ms。

**Python 3.6 坑（节点）**：`subprocess.run(capture_output=True, text=True)` 是 **3.7+** ⇒ 用 `stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True`；另 `select <单个表达式> … order by 1,2` 报 `ORDER BY position 2 is not in select list`（PG 42P10）。

**产物**：`migrations/`（`000001` 基线标记 · `000002` 加列 · `000003` CONCURRENTLY 独占 · `000004` 分批回填 500 行 + 10ms sleep + `FOR UPDATE SKIP LOCKED` · `000005` Contract 删列；+ `README.md`）· `deploy/task54_migrate_version.sh`（生成自包含 body → `ack_remote.sh` 下发）· `deploy/ci_check_migrate_versioned.sh`（5 项断言：up/down 配对 · 版本连续 · CONCURRENTLY 独占文件 · 不可逆标注 · AutoMigrate 关闭态）· `deploy/aliyun/ph/migrate-job.yaml`（`backoffLimit:0` + `newapi_migrate` DSN + ConfigMap 挂载；镜像 `migrate/migrate:v4.19.1`，节点可拉 docker.io）。

**载体注意**：卡片写的 `$DSN_PERF` 不存在 ⇒ 用同实例独立库 **`newapi_stage`**（`newapi_migrate`=ALL，零成本、不承载业务）。
**★ 去留裁定（2026-10-06 07:35，用户）：暂时保留、不 DROP** —— 转为**常驻演练载体**（每周 `up→down 1→up` 回归台 + 迁移 PR 预演；RDS 按实例计费、库不单独收费 ⇒ 零额外成本）。
**三条硬约束（防误用）**：① 生产 `SQL_DSN`/`SQL_DSN_MIGRATE` **永不得指向 `newapi_stage`**（现均指向 `newapi`，保持）；② 任何 CI/定时任务连它**只用 `newapi_migrate`** 账号（`newapi` 对该库无授权，RDS 侧 `GrantAccountPrivilege` 会被 `InvalidDBInfo.Malformed` 拒绝）；③ 与任务 45「同实例独立库=软隔离不达标」**不冲突但必须在案** —— 它是工具链演练库，不是生产环境。雅加达独立 RDS 就绪后载体迁走再评估。

**证据**：`deploy/logs/task54_migrate_20261005-151349/`（`10-run-full.out` 全量输出 + `summary.json` + 两次失败尝试 + 诊断 + `migrations.snapshot/`）；报告 `deploy/Day2任务54_迁移版本化_执行报告.md`。
