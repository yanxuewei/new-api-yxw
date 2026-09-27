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
**生产 vs 非生产 = RG 权限边界；站点 = 标签 `site` + K8s 命名空间。** 铁律：① RG 须**创建时**指定（`CreateVpc --ResourceGroupId`；`CreateVSwitch` 无此参数但**继承 VPC 的组**）→ 先 VPC 后 vSwitch；② **vSwitch 不可单独换组**（`MoveResources` → `UnsupportedOperation`），迁 VPC 级联；③ OSS 换组 `ossutil api put-bucket-resource-group`，ACR 用 `cr ChangeResourceGroup --ResourceRegionId`（**非** `--RegionId`）；④ 启用按 RG 授权后，迁移与策略变更**同批发布**；⑤ `resourcemanager ListResources` **不索引 vSwitch** → 盘点走 `vpc DescribeVSwitches`。

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

## 询价
- ECS：`ecs DescribePrice --RegionId <r> --ResourceType instance --InstanceType <t> --PriceUnit Hour|Month --Amount 1 --InstanceNetworkType vpc --SystemDisk.Category cloud_essd --SystemDisk.Size 100`。**系统盘参数必填**；**本 CLI 无 `InstanceChargeType`** → 取不到包年包月价，`Month` 是月度档价 **≠ Hour×720**。
- 磁盘 `--ResourceType disk --DataDisk.1.*`（**只支持 Hour**，参数带序号）。Tair：`r-kvstore DescribePrice … --ChargeType PostPaid --OrderType BUY`（**OrderType 必填**）。**报价可查 ≠ 可下单**（`g8i.2xlarge` 有价无库存：`DescribeAvailableResource` 为空）。
- BSS：`GetPayAsYouGoPrice --endpoint business.ap-southeast-1.aliyuncs.com --ProductCode <p>`（RDS 需 `--ProductType bards`）+ `ModuleList.1.Config="k1:v1,k2:v2"`。⚠️ **RDS PG 规格费 / ESSD 存储价 / KMS / ACR 现价 官网未公示**。
- 单价与站点成本 → `.deploy/gen_cost_table.py` 顶部常量（按量项统一 **730 h/月**）+ `.deploy/资源配额申请_执行报告.md`。常态 **9,865.36 USD/月**；接管峰值 15,322.51；备站冗余 623.90（6.32%）。

## 容灾与切换
- **SLA 链**：`0.9999^5 ≈ 0.9996` → 月不可用 **17.28 min**；预算 21.6 min → 仅余 **4.32 min**。
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
