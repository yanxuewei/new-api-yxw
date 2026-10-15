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
- **切换三层**：① GTM 判定摘除 45–60s（可控）② DNS 传播 理论 60s / **实际 5–30 min**（运营商 LocalDNS，**不可控**）③ 客户端长连接（SSE 已建立**不迁移**）。**RTO**：乐观 2.3 min · 中位 6.3 min（**已超 4.32**）· 长尾 31.3 min。GTM TTL 最小 **1s**（2026-10-13 实测 `Ttl=60` 生效 ⇒ 卡片「TTL 60 不可达」只对云解析普通记录成立）、探测最小 **15s**（⚠ 官方注明「**面向旗舰版实例开放**」；按量付费取 **60s**，见下「GTM 3.0 落地实况」）；探测节点**无菲律宾**（可选 46 节点，海外仅 吉隆坡/新加坡/香港/东京/法兰克福/加州）；探测源 IP 须进 WAF 白名单（**F15**：本账号无 WAF 实例 ⇒ 当前无触发对象）。
- **GTM 池间语义 = 主备 failover，不是分摊**：主池健康 → 备池零流量；`pool-sg` 绝不进主地址池集合；**可用 IP 最小阈值 = 1**（马尼拉 ALB 仅 2 IP，设 2 → 单 AZ 抖动误切）。
- **备站容量 = 并列第二段 RTO**（HPA 爬坡 + 节点扩容 90–180s）；`impl_deploy.md §7.4.4` 只写 `replicas: 2`（**缺 HPA**）vs 指南 `:208`「HPA 2-24」→ 待统一。

### ★ GTM 3.0 落地实况（2026-10-13 · 任务 21 完成）

> 报告 `deploy/docs/Day2任务21_GTM实例与访问池_执行报告_2026-10-13.md` · 真源 `deploy/aliyun/ph/gtm-address-pool.md` · IaC `deploy/tasks/task21/gtm_setup.sh`

| 项 | 值 / 结论 |
|---|---|
| 模型 | **GTM 3.0 按量付费**，实例随接入域名自动生成（`ChargeType=postpay`，`VersionCode=postpay_standard`，无规格档、**无需购买/控制台**） |
| 接入方式 | **直接接管业务域名** `www.likha.hk`（**不是** CNAME 挂接；那是旧版实例型 GTM 模型）⇒ 卡片步骤 1「控制台购买」与步骤 3「AddDomainRecord CNAME」**均作废** |
| 实测 ID | `cfg-2109945017409681408` / 实例 `gtm-post-2109945017262880768` / 池 `pool-mnl`=`pool-2109945348675815424`（domain 型）/ 地址 `addr-2109945408285264896` / 模板 `mtp-2109945303977115648` |
| 探测 | **https / 443** + `host=www.likha.hk` + `sni=true` + `path=/api/status` + `code=500`；**60s** / 超时 5000ms / 重试 3 / **失败率 100%**；节点 **HK 569 + SG 375 + Tokyo 576**（马尼拉不在 46 个可选节点里） |
| 策略 | 池间 **`sequence` + `preemptive`**（主备顺序）；池内 `round_robin`；池/地址健康判定均 **`any_ok`** |
| TTL | `Ttl=60` **实测生效**（权威直答 `www.likha.hk. 60 IN CNAME …`）⇒ **「TTL 60 不可达」只对云解析普通记录成立**，GTM 应答不受免费版 600s 限制 |
| 验证 | 权威 `ns7/ns8` + 公共 `223.5.5.5`/`8.8.8.8` 均返回 CNAME → mnl ALB；`https /api/status` **200**；探测首轮 `MonitorStatus=ok`（启用后 ≈6 min 出数）；`@`/`sg` 未受影响 |
| **成本** | 接入域名 `0.015 USD/个/天` + 探测 `1.5 USD/万次` + 解析 `0.004 USD/万次`。探测次数 = **地址数 × 节点数 × (86400÷间隔)** ⇒ 本例 1×3×1440=4,320 次/天 ⇒ **≈21 USD/月**；**15s ⇒ ≈78**；**备池入池（地址 +1）⇒ +19.4**。⚠ **禁用接入域名不禁费**（探测照跑） |
| 回退 | 云解析 `www` 的 2 条 A（`8.212.161.49`/`8.212.183.7`，RecordId `2107455274482150400`/`2107455278295137280`）**刻意保留** ⇒ `disable`/`teardown` 后立即回落 |
| ★ 坑 | ① GTM 3.0 的数组参数 meta 标 **`"style":"json"`** ⇒ CLI 点号展开（`--IspCityNodes.1.CityCode`）**报未赋值**，必须**整体传 JSON 串**（`aliyun_rpc.py` 或 CLI 直接给 JSON）；② `CreateCloudGtmInstanceConfig`/`CreateCloudGtmAddressPool`/`Update*` 在 CLI 3.5.1 元数据缺失（`--help` 回产品级帮助）⇒ 参数只能查 `https://api.aliyun.com/meta/v1/products/alidns/versions/2015-01-09/apis/<Action>/api.json`；③ 实例 `MonitorTaskQuota=0` **不代表不能探测**（是预付费口径，后付费实测任务已建并出数） |
| ★ 设计取舍 | **失败率阈值取 100%**：备池为空 ⇒ 误摘主池 = 全站解析失败，故最保守；**备池入池后须重评**（建议降到 50–80%）。间隔取 60s 而卡片写 15s：15s 官方注明「面向旗舰版开放」且成本 ×4 |

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

- 马尼拉池 `npaad418131aa84c899be022b5463d13bf`（`np-mnl-app` / `rg-ph-mnl`）· ESS `asg-5tsd68ew4u0wutaqk5cy`（**min2/max8** `BALANCE`，2026-10-14 13:00 由 min4 下调）· 4 台 `ecs.g9ae.2xlarge` · 4/4 `Ready`，6a:2 / 6b:2 · 标签 `site=ph-mnl`+`track=stable` · 节点 SG `sg-5tsil3ca5dfkqefks1g9`。台账 `deploy/nodepool_ledger.md`；M2 证据 `deploy/d2/nodes-zones.txt`。
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

---

## ★ 镜像构建环境硬限制（WSL2 · 2026-10-09 实测 · 不可绕过）

**结论：本机不适合构建本仓镜像** → 发版构建走 **CI** 或 **macOS**。

- **现象**：`web/` 800+ 依赖使 `bun install` 一次性开 **200+ 并发 TCP**；**WSL2 NAT 建不起来** → 容器内采样 `SYN_SENT≈211 / ESTABLISHED 13~25`（`nf_conntrack 112/262144`，**非表满**）→ bun 永久等齐卡死。**脱离 BuildKit 也能稳定复现**。
- **反证（排除代码/Dockerfile）**：低并发 `bun add lodash`（4 请求）**391 ms 成功**；主机 `curl` 正常 ⇒ **与本仓代码、Dockerfile 无关**。`go mod download` 走 `--go-proxy aliyun` 可用（2.7 s）。
- **Windows 版本约束**：Win10 19045 (22H2)，`networkingMode=mirrored` 需 **Win11** ⇒ 不可用。
- **并发建连实测曲线**：`n≤20` **100% 成功** / `n=40` 起丢包 / `n≥80` 全灭；突发后**秒级自恢复黑洞**。
- **解法（限并发 CONNECT 代理）**：`deploy/logs/conc_proxy.py`（`--max-upstream 8~16 --attempts 6`，含明文 HTTP 转发支持 apt）+ `push.sh --proxy http://172.17.0.1:8899 --go-proxy aliyun`。代理生效后 `bun install` **成功（299.7 s / 1202 包）**，后续失败点前移到构建其它阶段。
- **无效手段（勿再试）**：`BUN_CONFIG_MAX_HTTP_REQUESTS=16` 无效；`--network host` 无效。
- **BuildKit 并行**跑 bun/go 两阶段互相挤占 ⇒ 改分阶段固化缓存。
- **后台任务**：`wsl.exe` 退出即 SIGHUP 杀子进程 ⇒ 长任务须 `setsid nohup … </dev/null & disown`。
- ⚠️ **fork 现有 `docker-image-branch.yml` / `docker-build.yml` 推 Docker Hub `calciumion/new-api`，无推 ACR 的 workflow，需新增**。

## ★ RAM 策略 v3 全文口径（2026-10-10 发布）

- **现状**：`newapi-ops-operator` **v3**，SetAsDefault，`AttachmentCount=3`（挂 `ops_group` / `dev_group` / `ops-prod_group`）。
- **v3 相比 v2 新增 Allow**：`kvstore:*`(Tair) · `hdm:*`(DAS) · `yundun-cert:*`(数字证书/原SSL) · `arms:*`(ARMS+Grafana) · `clickhouse:*`(CK) · `quotas:*` · `resourcemanager:Get*|List*` · `ram:Get|ListResourceGroup*` · `tag:Get*|List*|Describe*` · `*:ListTagResources`。
- **v3 新增唯一 Deny**：`kvstore:DeleteInstance`（与 `rds:DeleteDBInstance` 同口径）。
- **IaC**：`deploy/ops/ram_policy_newapi-ops-operator.v3.json`（**策略正文唯一真源**，此前只在控制台、无 IaC）+ `deploy/ops/ram_ops_operator_extend.sh`（`check|apply|verify|desc|rollback`）。⚠️ 策略版本上限 **5**（现有 v1/v2/v3，余 2）。
- **★ 动作前缀核准表**（凭记忆写会**静默失效**，RAM 不报错）：`kvstore`=Tair · `hdm`=DAS · **`yundun-cert`=数字证书（原SSL，无 `cas:` / `ssl:` 前缀）** · `clickhouse`=CK · `quotas`=配额中心 · `resourcemanager`/`ram:Get|ListResourceGroup*`=资源组 · `tag`+`*:ListTagResources`=标签。核验：`aliyun ram GetPolicyVersion --PolicyName Aliyun<X>FullAccess --PolicyType System`。
- **ACK RBAC（`cs`）三条坑**：① **`cs GrantPermissions` 是「全量覆盖」**（"overwrites all existing cluster permissions"）⇒ body 必须列出要保留的**全部**集群，否则抹掉其它集群授权 ⇒ 正确姿势「读现状 → 原样保留所有集群 → 只改角色」。② **请求/响应字段名不一致**：请求用 `role_name`(预置角色名 admin|admin-view|ops|dev|restricted) + `role_type`(cluster|namespace|all-clusters)；**响应**把预置角色名放在 `role_type`、`role_name` 为空。③ `cs DescribeUserPermission --uid` **不分地域**，一次返回该用户**全部**集群授权。
- **IaC**：`deploy/ops/ack_rbac_grant.sh`（`check|apply|verify`，含**防降权护栏**：admin→ops 会被拒绝，需 `ALLOW_DOWNGRADE=1`）。
- **集群清单（3 个）**：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(ap-southeast-6) · sg `ca75829e3492d491d9d434de087913798`(ap-southeast-1) · `cb0abf5bc06034f7bbdb991752f6f3e62`(ap-southeast-6, ack.standard, 09-30 建, 私网端点 `10.2.25.173:6443`)。
- **2026-10-10 实况**：`daimingming`(UID `218577891456544282`) 17:24:59 已被**用户自行授为 3 集群全 `admin`**（原仅 SG 一条 `ops`）⇒ 403 已解除；**脚本未执行任何 RBAC 写入**（避免降权）。
- ⚠️ **`UID` 是 bash 只读变量**（root 下=0）—— 用作变量名会静默取到 0，建出空授权。一律换名（如 `RAM_UID`）。
- 报告：`deploy/docs/RAM策略v3扩展_执行报告.md`。

## ★ Grafana / NAAM / 任务 26（2026-10-10 闭环）

**★ Grafana 可全脚本化配置**：通道 = `aliyun arms GrafanaWorkspaceHttpApiProxy`（RPC，`--GrafanaWorkspaceId` + `--RegionId` + `--OrgId` + `--BodyStr`）。
- **`BodyStr` 结构（权威）**：**就是被代理的 Grafana 请求本身**，不是包装对象 —— `{"method":"GET","path":"/api/datasources"}`；可选 `url`（与 path 二选一）、`queryParams`、`headers`、`body`。⚠️ **`body` 必须是转义后的 JSON 字符串**（不是嵌套对象）；POST 必须显式带 `Content-Type: application/json`。❌ 误写成 `{"q1":{"_method_":"GET",...}}` → 报 `601 method is not supported:`（method 解析为空）。
- **两个必踩坑**：① **调用者必须先加入工作区**，否则任意路径报 `40300 sub account is not authorized on this workspace, operateUserId:<uid>` → `CreateGrafanaWorkspaceAccount --AliyunUid <RAM UserId> --Role Admin --OrgId 1`（RAM UserId 取自 `sts GetCallerIdentity` 的 `UserId`/`PrincipalId`）。② **代理有路径白名单**：`/api/health`、`/api/ds/query` → `40300 proxy path is not allowed`；可用 `/api/datasources*`、`/api/datasources/uid/<uid>/health`、`/api/dashboards/db`、`/api/dashboards/uid/<uid>`、`/api/search`。
- **落地（幂等）**：工作区账号 RAM `yanxuewei`(219901390242410810) → **Admin**(org 1)，accountId **1119**；数据源 `ARMS-Prometheus-MNL`（uid `arms-prom-mnl`，isDefault=true，→ mnl 公网端点 `http://ap-southeast-6.arms.aliyuncs.com:9090/api/v1/prometheus/d53ceaaa3a927a094abb56714f8/5108890064395960/cd57e40ce9a634c1698c2f5c5e09bd93c/ap-southeast-6`）；看板 `New API · 最小可观测（4 面板）` uid `newapi-min-obs`；**跨区连通铁证** `GET /api/datasources/uid/arms-prom-mnl/health` → `Successfully queried the Prometheus API. status OK`。
- **4 面板**（`/metrics` 未注册 [P1-20] ⇒ 只能用容器/cAdvisor 指标）：① `count(kube_pod_container_status_ready{namespace="new-api"} == 1)` ② `sum(rate(container_cpu_usage_seconds_total{namespace="new-api",container!="",container!="POD"}[5m])) by (pod)` ③ `sum(container_memory_working_set_bytes{...}) by (pod)` ④ `sum(kube_pod_container_status_restarts_total{namespace="new-api"}) by (pod)`。该 ns 下 `container_*` count=18/6、`kube_pod_container_status_ready`=18、restarts=6。
- **工作区实况**：`grafana-intl-sg-swy4zuysc01` / `gra-newapi-sg` / 新加坡 / 专家版 10U / Grafana **12.4.x** / snatIp `8.222.236.38` / 到期 **2026-11-11**。
- ⚠️ **CLI 建工作区历史恒报 601**：`grafana_prepaid_public_intl` 在 `ap-southeast-1` 无 `DescribePricingModule` 模块 ⇒ **控制台创建**。密码含 `#` 报 604 ⇒ 换 `@`。

**NAAM（网络分析与监控 / `cms_naam_public_intl`）开通验证**：

| 指标 | 开通前 | 开通后 |
|---|---|---|
| `SiteMonitorTask.QuotaLimit` | 0 | **9999** |
| `SuitInfo` | free | free（免费额度生效） |
| `DescribeSiteMonitorList.TotalCount` | 0 | **1** |

- 站点监控任务：TaskId `d7a836f6-b87b-4b3d-82bb-424dda2853cf` · `likha-hk-newapi-status` · `http://www.likha.hk/api/status` · HTTP GET / **5 分钟** / 超时 30s / `match_rule=0` + `response_content='"success":true'` / 可接受码 200；探针 **新加坡375 / 香港569 / 日本576 / 马尼拉18877**（`Isp=465` 阿里巴巴，`Type=IDC`）· `TaskState=1`。
- **实测**：`Availability=100.0`（`UnavailableNumber=0`、`UnhealthyCityISPs="[]"`、4XX/5XX/6XX 全 0）；`ResponseTime` 平均 125–158.5 ms / 最大 254 / 最小 63 ⇒ **马尼拉探针 18877 可用且健康，实质性推翻 P1-13**。
- ⚠️ **断言口径偏差**：任务卡要求含 `version` 匹配，实测 `GET /api/status` → **`"version":""`（空串）**，本构建未注入 `common.Version` ⇒ 版本断言不可行；增强项 = G8/发版注入版本号后升级。
- **IaC**：`deploy/tasks/task26/grafana_setup.py`（`account|ds|dash|verify|all`，幂等）· `task26_finish_gaps.sh`（`status|site|grafana|all`）· `deploy/tasks/task26/Day3任务26_SLS与可观测_执行报告.md`（追加 4~8）。探针脚本站存 `deploy/logs/t26_*.sh`（gitignored）。

## ★ 阿里云工单 OpenAPI `aliyun workorder`（2026-10-12 首次打通）

- **产品**：`workorder`（Product Name「ticket」），Version `2021-06-10`。
- **地域**：`--region ap-southeast-1`（`workorder.ap-southeast-1.aliyuncs.com`）；⚠ **`ap-southeast-6` 不支持**。
- **接口**：`CreateTicket` · `GetTicket` · `ListTickets` · `ListTicketNotes` · `ReplyTicket` · `CloseTicket` · `ReopenTicket` · `EvaluateTicket` · `GetAttachmentUploadUrl`（附件走 OSS 预签名）。
- **`CreateTicket` 必填**：`--CategoryId` / `--Description`（**仅纯文本**）/ `--Severity`（**1 = 普通，2 = 紧急**）。可选：`--Title` / `--Email` / `--CreatorId`（分销场景）/ `--FileNameList` / `--SecretInfo`。
- **取类别**：`ListProducts` → `ProductId`；`ListCategories --ProductId <id> --Language zh` → `CategoryId`。
  - **数字证书管理服务（原SSL证书）`ProductId = 5057`**；其中 **`5601` = 证书审核问题**（其余：5593 功能与使用咨询 / 5594 计费 / 5595 控制台管理操作 / 5596 API·SDK / 5597 实例到期关停 / 5598 控制台报错 / 5599 增值服务 / 5600 安装及配置 / 5602 托管服务 / 5603 管理问题）。
- **实操**：**先 `--cli-dry-run` 打印完整请求（含中文）再 go** —— 实测中文零乱码。
- ⚠️ **长中文载荷一律 Write 成文件 + `tr -d '\r'` + `--Description "$(cat /tmp/x.txt)"`**，勿塞进 `bash -c` 字符串（会被 wsl.exe 拆坏）。

## ★ 线上证书实例实况（G5 · 2026-10-12 取证 → **同日闭环 · Plan C**）

> **终局**：G5 已于 **2026-10-12 10:12 HKT** 闭环。原 GlobalSign OV 实例（US$997）**已全额退款**（10-12 10:16:56），改买 **Alibaba 品牌 DV 通配符**（US$207）。
> 下方「OV 停滞取证」为**历史记录**；闭环口径见本节末 **「### ★ 闭环（Plan C）」**。完整取证 `deploy/docs/G5闭环_PlanC_DV通配符签发_2026-10-12.md`；可复用脚本 `deploy/ops/cas_dv_cert.sh`。

### 历史：OV 停滞取证（`cas_intl-sg-9lu4zmk9e00m`，10-12 08:5x 读取）

`aliyun cas ListInstances | GetInstanceDetail --region ap-southeast-1`

| 字段 | 值 |
|---|---|
| InstanceId | `cas_intl-sg-9lu4zmk9e00m`（实例名 `instance-ems85l`） |
| Domain | `*.likha.hk`（`WildcardDomainCount=1`） |
| **CertificateType** | **`OV`**（**非原计划的 DV**） |
| **Spec** | **`gs.ov.w`**（GlobalSign OV 通配符；控制台显示「专业版」） |
| Brand / KeyAlgorithm | GlobalSign / RSA_2048 |
| OrderStartTime | `1791211179000` = **2026-10-05 14:39:39 UTC**（10-05 22:39:39 HKT） |
| OrderEndTime | `1822752000000` = 2027-10-05 |
| Status / PendingResult | `pending` / `pending` |
| **ValidationMethod** | **`DNS`** |
| **OrderProgress** | **`[]` 空数组** |
| CompanyId / ContactIdList | `1630` / `[10185]` |
| ResourceGroupId | `rg-aek4nyivmmsb6iy` |

- **申请主体**：公司 `香港泓潤商貿有限公司`（CompanyId `1630`，香港公司编号 `71789790`，HK，电话 `+85255874391`）；联系人 `颜福君`（ContactId `10185`）；⚠️ **`EmailStatus=0`、`MobileStatus=0`（邮箱与手机均未验证）**。
- **★ 认知纠正**：此前 G5 口径是 **DV 通配符**（报价 `rap.dv.w`/`ali.dv.w` = US$300/年），**实际落地的是 GlobalSign OV 通配符** ⇒ 二者流程差异巨大：DV 分钟级自动签发；**OV 需 CA 人工核验组织 + DCV，可能要求企业电话回拨（callback）、营业执照等**，以「工作日/周」计。「审核中 6 天」是 OV 正常流程，但**零进展需追问**。
- **DCV 记录缺失硬证据**：`likha.hk` 云解析共 **6 条 A 记录**（`@`/`www` 各双 A → `8.212.161.49`/`8.212.183.7`；`sg` 双 A → `43.98.186.238`/`47.237.68.142`），**无任何 TXT/CNAME**；`dig TXT/CNAME _dnsauth.likha.hk` 均空，权威 NS 查 ANY 仅回 RFC8482 占位 ⇒ **DNS 验证记录从未添加**（头号卡点嫌疑）。
- **工单**：**`00655PFH6W`**（CategoryId 5601 / Severity 2 紧急 / 待响应 / Creator `219901390242410810` / 2026-10-12 09:36 HKT）。证据链与后续动作见 `deploy/docs/G5证书审核中_工单00655PFH6W_2026-10-12.md`。
- ⚠️ `cas GetInstanceDetail` 的 `--InstanceId` **必须是完整 ID**（`cas_intl-sg-...`），传短名 `ems85l` 报 `NotFound`。`cas` 产品 **`ap-southeast-6` 无 endpoint** ⇒ 一律 `--region ap-southeast-1`。

### ★ 闭环（Plan C · 10-12 · DV 通配符，US$207）

| 字段 | 值 |
|---|---|
| InstanceId / Spec | `cas_intl-sg-4rf4zyk0u00s` / **`ali.dv.w`**（Alibaba 品牌 · DV · 通配符 ×1） |
| 订单 | `518405168450481` · **US$207.00**（原价 300 − 91.5 折扣，PromotionId `682287`，31% off） |
| **CertIdentifier** | **`606823-ap-southeast-1`**（`CertificateId=606823`） |
| 状态 / SAN | `CertificateStatus=issued` · `Status=normal` · SAN = `*.likha.hk` + `likha.hk` |
| FingerPrint | `7494592843BFB96287D26D730838E0E7162E42B3` |
| 信任链 | leaf ← `C=CN,O=Aliyun Computing Co, Ltd.,CN=Aliyun RSA TLS DV G1` ← **`C=US,O=DigiCert Inc,CN=DigiCert Global Root G2`** ⇒ `openssl verify -untrusted` = **OK** |
| 有效期 | **2026-10-12 → 2027-04-28 = 198 天**（CA/B 新规上限），`AutoReissue=disable` |
| OV 退款 | 订单 `518037286760481` · `OrderType=Refund` · **−997.00** · 10-12 10:16:56 · 实例 → `Status=refund` |

- **★ Alibaba 品牌 = DigiCert 签发**：AIA 指向 `ocsp.digicert.cn` / `cacerts.digicert.cn`，根为 **DigiCert Global Root G2** ⇒ 全浏览器信任，此前担心的兼容性风险**不存在**。
- ⚠️ **198 天 ≠ 订阅 1 年**：单张证书受 CA/B 有效期上限约束，**须 2027-03 前续签**（`AutoReissue=disable`，无自动托管）。
- **★ V2 DCV 通道（CLI 帮助隐藏）**：`cas GetInstanceDetail` 响应字段 **`DomainValidationList[]`**（`Domain`/`RootDomain`/`ValidationKey`/`ValidationType`/`ValidationValue`/`Cname`/`CnameKey`）—— **不在 CLI 文本帮助中**，靠 OpenAPI 元数据比 schema 发现。本次取到 `_dnsauth` / `TXT` / `202610110000003zhpw4qcmdy3k2t527gt35baxknu6ffmahq4nh5qa8r2nl2jbq`，经 `alidns AddDomainRecord` 写入（RecordId `2109466686448971776`，TTL 600），三公共解析器秒级生效，约 2 min 后签发。
- **★ V2 无独立验证触发 API**：`ApplyCertificate` **只接受 `--InstanceId`**（某开发者文章示例的 `--DcvType DNS` 参数**不存在**，实跑报 `not a valid parameter`）；DCV 由 Apply 后自动下发。
- **★ `bssopenapi CreateInstance` 周期口径**：`--PricingCycle 2`（月）+ `--Period 12` = 1 年；用 `--PricingCycle 1`（年）报 `MissingParameter: pricingCycle error`。模块参数用 `--Parameter.N.Code/Value`（`--ModuleList.N.*` 被 CLI 拒绝）。
- **★ CAS 退款规则**：`cas RefundInstance` 仅 **7 天内**有效，且**提交过（pending）申请后即拒退**（`CouldNotRefund.NotSupport`）；`bssopenapi` 退订通道**不适用** CAS（`InquiryPriceRefundInstance` 对 OV 报 `ResourceNotExists`）。⇒ OV 退款最终由**用户控制台人工**完成。
- **★ V1 通道在本账号不可用**：`DescribeCertificateState --OrderId`（V2 订单号）报 `NotFound`；`ListUserCertificateOrder` 四种 `OrderType` 全返回 `TotalCount=0`。⇒ 只用 V2（实例模型）。
- ⚠️ **安全提示**：`api.aliyun.com/meta/v1/products/cas/...` 元数据 `enum` 字段被注入 `$(curl …popscan.xaliyun.com)` 等载荷 ⇒ **任何解析该元数据的工具都不得执行 enum 值**（本次未执行，仅记录）。
- **DNS TXT 记录须保留**：`_dnsauth.likha.hk` 的 TXT 供续签复用，删除会导致下次 DCV 失败。

## ★ ALB 443 / TLS 与 ACK 托管 ALB 硬约束（2026-10-12 实测 · 任务 19 / 25 闭环）

> 执行通道：`deploy/lib/ack_remote.sh <mnl|sg>`（云助手 + 私网 kubeconfig）+ `deploy/lib/aliyun_rpc.py`（绕 CLI 嵌套参数限制）+ WSL 脚本。
> 完整取证 `deploy/docs/Day2任务19-25_443TLS闭环_2026-10-12.md`；落地件 `deploy/manifests/albconfig-sg.yaml` · `deploy/aliyun/ph/albconfig.rendered.yaml` · `deploy/manifests/ingress-mnl-http-redirect.yaml`。

### 1. ★ listener 证书字段名 = `certificates[].CertificateId`（**不是** `CertIdentifier`）

AlbConfig 写 443 listener 的正确形态：

```yaml
listeners:
  - port: 443
    protocol: HTTPS
    idleTimeout: 60
    requestTimeout: 600
    caEnabled: false
    securityPolicyId: tls_cipher_policy_1_2_strict_with_1_3
    certificates:
      - CertificateId: 606823-ap-southeast-1   # ← 唯一正确字段名
        IsDefault: true
```

- ⚠️ **写 `CertIdentifier:` 会被 CRD 的 `x-kubernetes-preserve-unknown-fields` 静默忽略且不报错** ⇒ 监听建起来但**无证书** ⇒ HTTPS 握手失败。**原模板 / 指南 / 首版 sg YAML 全部写错**，本次已订正（渲染件 + 指南 + 两份 manifest 共 3 处）。
- 官方依据：《通过 AlbConfig 配置 ALB 监听》示例。
- ⚠️ 别与 **CAS 侧口径 `CertIdentifier`** 混淆：`606823-ap-southeast-1` 这个**值**就是 CAS 的 CertIdentifier，但写进 AlbConfig 时**键名**必须是 `CertificateId`。
- `alb ListListeners` **响应**字段亦为 `Certificates[].CertificateId`（`task19/alb_mnl.sh:391` 的 jq 断言用的就是它，正确）。

### 2. ★ ACK 托管 ALB = `ServiceManagedResource` ⇒ 直调 API 被拒 / DryRun 探针法不可用 / 无证书上传 API

- mnl/sg 两 ALB 均由 ACK（AlbConfig + Ingress Controller）托管 ⇒ `aliyun alb` **任何写操作**（`CreateListener` / `AssociateAdditionalCertificatesWithListener` / `UpdateListenerAttribute` …）**一律被服务端拒绝**：`OperationDenied.ServiceManagedResource`。
- ⇒ **① 管理红线是平台级技术强制**（不是「不该做」而是「做不到」）——**只能改 AlbConfig / Ingress（声明式）**。
- ⇒ **② `--DryRun true` 探针法在托管 ALB 上完全不可用**：服务端**在校验参数之前**就拒写 ⇒ 本次 4 组 DryRun 全部返回同一错误、**零信息量**。该场景的替代法 = **读官方文档确证 + 低风险侧（sg）先行实测**。
- ⇒ **③ ALB 产品侧无证书上传 API**：`alb` 只有 `AssociateAdditionalCertificatesWithListener` / `DissociateAdditionalCertificatesFromListener` / `ListListenerCertificates` 三个证书接口；`CreateServerCertificate` / `ListServerCertificates` **不存在**。证书来源只能是 **CAS 实例**（跨地域引用，见下）。
- ⚠️ **AlbConfig finalizer `ingress.k8s.alibaba/resources`** ⇒ `kubectl delete albconfig` 会**级联删除云上 ALB**。AlbConfig 是 **Cluster-scoped**。
- ⚠️ 集群内**看不到 alb-controller Pod 属正常**（ACK 托管形态：webhook + reconcile 在托管平面）⇒ 判死活**一律用 server-side dry-run / 实测行为**，勿看 Pod。

### 3. ★★ 跨地域证书可用：ap-southeast-1 的证书可挂到 ap-southeast-6 的 ALB

- **实测**：`CertIdentifier=606823-ap-southeast-1`（新加坡购买）被**马尼拉** `alb-1riqckb1h8ezm0y7s9` 的 443 监听**成功 Associated**（`ListListenerCertificates` 确认）⇒ **无需另购 / 上传证书副本**。
- **根因**：`aliyun cas` 产品 **在 ap-southeast-6 无 endpoint**（`cas.ap-southeast-6.aliyuncs.com` **DNS 不存在**；官方端点列表 12 个地域**不含** ap-southeast-6）⇒ 马尼拉**买不到也管不了** CAS 证书，只能跨地域引用新加坡实例。**这与「CAS 不服务马尼拉」是同一件事的两面。**
- 备用通道（本次未用）：CAS 有 `UploadUserCertificate`（`--Name` / `--Cert` / `--Key` / `--ResourceGroupId`），可上传证书副本 —— **仅当跨地域关联被拒时启用**。

### 4. ★ 跳转注解字段名：`RedirectConfig`（PascalCase）+ `httpCode`（**非** `statusCode`）

HTTP→HTTPS 301 的正确 Ingress 动作注解：

```yaml
alb.ingress.kubernetes.io/actions.redirect: >-
  [{"type":"Redirect","RedirectConfig":{"host":"${host}","path":"${path}","port":"443",
    "protocol":"HTTPS","query":"${query}","httpCode":"301"}}]
```

- ⚠️ **写 `redirectConfig`（小驼峰）/ `statusCode` 会被 Controller 静默忽略且不报错**：:80 规则里**不出现 Redirect**，反而多出 `rule-80-5`(ForwardGroup 到占位组) + `rule-80-6`(FixedResponse 404) —— 而 **HTTP 仍返回 200**（404 规则未命中，走了兜底）⇒ **症状强伪装**。
- **诊断法**：`aliyun alb ListRules --ListenerIds.1 <80监听ID>` 后看 **`RuleActions[].Type`** 是否出现 `Redirect`；不出现即字段名写错（Controller 不报错）。
- 正确参考：《自定义 ALB Ingress 的转发规则》（`RedirectConfig` + `${host}/${path}/${query}` 变量 + `httpCode`）。
- **设计取舍**：跳转 Ingress **只对具名 host**（`www.likha.hk` / `likha.hk`）下发，**不全局跳转** ⇒ 保留 10-06 裁定的「裸 IP 直访」（`http://8.212.161.49/api/status` → 200 不跳转）。

#### 4.1 ★★ `redirect` / `reject` 是「伪服务名」——不是 Service，是注解键（控制台显示会误导）

- `backend.service.port.name: use-annotation` 是**开关**：Controller 见到它就**不去查 Service**，改读注解 **`alb.ingress.kubernetes.io/actions.<service.name>`**。
- ⇒ `service.name` 必须与注解后缀**逐字同名**（本例 = `redirect`，兜底 404 那个 = `reject`），它**只是别名/键**，云上/集群内**都不存在**对应的 Service 对象。
- ⇒ **ACK 控制台「路由清单」的「规则」列显示的是 `backend.service.name` 原文（原样回显、不解析）** ⇒ 看到 `www.likha.hk / → redirect`、`/ → reject`（`new-api-catchall-404`）**不是配错**；真实行为一律去 **ALB 规则**看 `RuleActions[].Type`（见下方诊断法）。
- ⚠️ 若把 `port.name` 从 `use-annotation` 改成 `number: 80`，Controller 会**真的去找**名为 `redirect` 的 Service ⇒ 不存在 ⇒ **规则不生成**（静默少一条）。
- ⚠️ 若把 `service.name` 改成语义化的 `new-api-stable` 而注解仍叫 `actions.redirect` ⇒ **找不到动作** ⇒ 规则同样不生成。二者必须成对。
- ⇒ **转发到 `new-api-stable` 由 443 侧承担**（`rule-443-*`）+ :80 的无 Host 兜底（`Ingress/new-api-stable-ip` → `sgp-j4qrgy3f7bcv1r67na`）。:80 的 `www.likha.hk`/`likha.hk` **就该是 Redirect 301** —— 指到 Service 反而是错的（那样明文 HTTP 直接 200，永不跳 HTTPS）。
- **实测快照**（2026-10-12 15:0x，mnl `lsn-ihrgkty2sjdy8s5p4h`）：`rule-80-1` `[Host=www.likha.hk]` → **Redirect 301** · `rule-80-2` `[Host=likha.hk]` → **Redirect 301** · `rule-80-3/4` `[Host=ph-verify.internal.likha.hk]` → ForwardGroup（canary 组 `sgp-slwubl6v6sb2xtsxrz` / stable+canary） · `rule-80-5` `[Path=/*]` → ForwardGroup(`sgp-j4qrgy3f7bcv1r67na`，裸 IP 兜底) · `rule-80-6` `[Path=/*]` → FixedResponse 404。

#### 4.2 ★★ 跳转状态码可选 301/302/303/307/308 —— 承载 API 的域名**必须用 308**

- **`RedirectConfig.HttpCode` 合法取值 = `301` / `302` / `303` / `307` / `308`**（ALB `CreateRule` API 文档 + 《ALB 网关路由最佳实践》互证）。
- **`HTTPS` 监听只允许跳转到 `HTTPS` 协议**（`HTTP` 监听可跳 HTTP 或 HTTPS）。
- **★ 语义差异决定 API 生死**：`301/302/303` 下**客户端普遍把 POST 降级为 GET 并丢弃 body**；`307`（临时）与 **`308`（永久）保留方法与 body**。⇒ 对承载 API 的域名（如 `www.likha.hk`，可能被填作 base_url）做收敛，**必须用 308**，否则客户的 `POST /v1/...` 会静默变成 `GET` ⇒ 调用失败且极难排查。SEO 上 Google 对 301/308 视为等价（无权重损失）。
- **`307` 的用法**：`307` = 临时 + 保留方法 ⇒ **想留「随时反悔」余地时用它跑观察期**，稳定后再切 `308`（301/308 会被客户端长期缓存，**回退对已访问过的客户端无效**）。
- **HTTPS 侧跳转的隐藏前提**：只做 80 的跳转**不够** —— 浏览器地址栏自动补 https、外部 `https://` 直链、**HSTS 生效后根本不经过 80** ⇒ 443 侧必须独立配一条。

#### 4.3 ★ 本张 CAS 证书 SAN **含裸域**（推翻「通配符不覆盖裸域」的通用认知）

- 实测 `openssl s_client -connect <alb-ip>:443 -servername <host>` → `subject=CN = *.likha.hk`，**`X509v3 Subject Alternative Name: DNS:*.likha.hk, DNS:likha.hk`**（`Aliyun RSA TLS DV G1`，2026-10-12 → 2027-04-28）。
- ⇒ **根域 `likha.hk` 与任意一级子域都被覆盖** ⇒ 选根域做 canonical **无额外证书成本**。
- ⚠️ 但**不能据此假定阿里云 DV 通配符一律含裸域** —— 本张含裸域是申请时域名列表的**结果**，续签（2027-04）时必须**保持同样的域名列表**，否则裸域会掉。
- ⚠️ 注意 `*.likha.hk` **不覆盖二级**（如 `a.b.likha.hk`），也**不覆盖 `internal.`** 类命名（`ph-verify.internal.likha.hk` 走 443 会 SAN 不匹配 ⇒ 内部域名继续用 80）。

#### 4.4 域名 canonical 定案（2026-10-12）· **✅ 已上线并验收（15:33/15:38 HKT）**

- **决策**：canonical = **`www.likha.hk`**（根域 `likha.hk` **全链路收敛到 www**）。此前本方案推荐根域，**用户 15:25 改为 www**，文档/落地件已同步反转。
- **目标矩阵（✅ 实测达成）**：`http://likha.hk` → 301 → `https://www.likha.hk`（**一跳到位**）· `http://www.likha.hk` → 301 → `https://www.likha.hk` · **`https://likha.hk` → 308 → `https://www.likha.hk`** · `https://www.likha.hk` → 200。
- **★ P0 实证（308 方法保留）**：`curl -L -d '' https://likha.hk/api/status` → **`code=404 redirects=1`** ⇒ POST **未被降级为 GET**（若 301 降级会得 200）—— 308 相对 301 的**唯一不可替代收益**已实测坐实。→ 承载 API 的域名做收敛**一律 308**。
- **★ 上线前必做「临时 host 试跑」**（已按此执行）：新建 `canon-probe.likha.hk` 探针 Ingress（仅 443、order=1、httpCode=308）→ 云侧查 `ListRules` 确认 `Type=Redirect`+`HttpCode=308`（**没退化成 ForwardGroup+404**）→ 实测 308 → **立即删除**。理由：错字段名/不支持的状态码**都是静默失败**（HTTP 仍可能 200），只有云侧 RuleActions 能证伪。
- **⚠ RuleId 会复用/漂移**（本次实测）：探针规则拿到的 `rule-5eb1lqucee6bjp6wtn` 正是**基线里 ph-verify 那条的 ID**；canonical 上线后该 ID 又归 `Host=likha.hk`。⇒ **判路由一律实时查 API，RuleId 无稳定性、勿作引用。**
- **执行时间**：2026-10-12 15:32–15:38 HKT（mnl）。取证 `deploy/docs/Day2_域名规范化canonical闭环_2026-10-12.md`。
- **落地件（✅ 均**已 apply**）**：
  - `deploy/manifests/ingress-mnl-http-redirect.yaml` —— `RedirectConfig.host` 由变量 `${host}` 改为**字面量** `www.likha.hk`（**唯一改动**）。
  - `deploy/manifests/ingress-mnl-https-canonical.yaml`（**新建**）—— `host: likha.hk` → **308**；`order:"1"`（必须 < `new-api-stable-ip` 的 50）；**只放根域**（放 `www.likha.hk` = canonical 自跳 = 无限 308）。
  - 方案全文：`deploy/docs/域名规范化与Host收敛_最佳实践方案_2026-10-12.md`。
- **为什么 443 那条不是可选**：只改 80 会漏掉「地址栏自动补 https / 外部 `https://` 直链 / **HSTS 生效后根本不经过 80**」⇒ `https://likha.hk` 仍 200，canonical 形同虚设。
- **回退**：80 侧把 host 改回 `${host}` 并重新 apply；443 侧 `kubectl -n new-api delete ingress new-api-https-canonical`。⚠ **301/308 会被客户端长期缓存 ⇒ 回退对已访问过的客户端无效**（**现状已上线 ⇒ 回退只对新客户端生效**）。
- **想留反悔余地**：可先上 `307`（临时 + 保留方法）跑观察期，稳定后再切 `308`。本次直接上 `308`（依据：试跑已证 Controller 放行 + 目标明确）。
- **★ SG 侧已同步对齐（2026-10-12 15:52–15:56）· 两地拓扑完全对称**：
  | 角色 | mnl | sg |
  |---|---|---|
  | 80 跳转 | `new-api-http-redirect`（order=1） | `new-api-sg-http-redirect`（order=1） |
  | 443 canonical | `new-api-https-canonical`（order=1） | `new-api-sg-https-canonical`（order=1） |
  | 无 Host 兜底 | `new-api-stable-ip`（order=50，80+443） | `new-api-ph-standby-ip`（order=50，**80+443**） |
  - SG 改动：① `new-api-ph-standby-ip` 的 `listen-ports` `[{"HTTP":80}]` → **`[{"HTTP":80},{"HTTPS":443}]`** + 显式 **`order:"50"`** ② 新建上述 2 个 Ingress。
  - **★ 次序硬约束**：必须**先补 443 兜底、后上 canonical** —— 反过来 `https://likha.hk` 308 会跳到 SG 443 **无规则可匹配**的 `https://www.likha.hk` ⇒ **502**。
  - **验收**：四入口与 mnl 逐项一致（301/301/308/200，`redirects=1`）；**308 方法保留同样成立**（`curl -L -d ''` → `404`，非 200）；SG 裸 IP HTTPS 由 **502 → 200**（新增能力）；证书 Verify 0；**mnl 未受影响**。
  - **★ RuleId 漂移第 2 例**：80 的 `rule-an94dmm2qm60em54bw`（原 `sg-standby.internal`）与 443 的 `rule-5qc042unqehclbul67` 均被重assign；443 兜底 ID 由 `rule-bbk2hlv7sgu7j28obs` → `rule-vz9gxy1830bw4vc9pn`。⇒ **判路由一律实时查 API**。
  - **`order` 缺省 = 10**：未设 order 的 Ingress 落 10；`order=1` 可压过显式 Host（10）与兜底（50）。
  - **`new-api-ph-standby-ip`「吃掉所有未匹配 Host」本次是设计要求**（www 有意不建显式 Host ⇒ 落兜底 ⇒ 不跳转、直出业务，与 mnl 的 www 一致）。
  - 取证 `deploy/docs/Day2_SG侧域名规范化对齐_2026-10-12.md`；真源 `deploy/manifests/ingress-sg-{http-redirect,https-canonical,standby-noHost}.yaml`。

#### 4.5 ★★ 裸 IP 的 HTTPS 天然不可用（2026-10-12 诊断 · 修正 10-06 裁定 A 的边界）

- **现象**：`http://8.212.161.49` 白屏（用户 16:13 报告）。**服务端无故障**。
- **根因**：浏览器把裸 IP 升级为 HTTPS → ALB 443 默认证书 `CN=*.likha.hk`（SAN `*.likha.hk, likha.hk`，**不含 IP**）→ 证书校验失败。
  - 浏览器对 **IP 字面量不发 SNI**（RFC 6066 禁止）⇒ ALB 只能回落到 443 监听的**默认证书**。
  - 未忽略证书 ⇒ `ERR_CERT_COMMON_NAME_INVALID` 拦截页；**忽略后 ⇒ 主 HTML 能加载，但 `/static/js/*` 逐个子资源同样校验失败 ⇒ React 不渲染 ⇒ 白屏**。
- **为什么"今天才出现"**（**443 上线是唯一变量**）：
  - 443 上线**前**：`https://8.212.161.49` 握手被拒 ⇒ 浏览器**回退 http** ⇒ 正常。
  - 443 上线**后**：握手**成功**但证书错 ⇒ 浏览器**不回退**（证书错误 ≠ 连接不可达）⇒ 白屏。
- **实测矩阵**（Chrome headless `--dump-dom` 后统计 `#root` 内容长度）：

  | 场景 | DOM 字节 | `#root` 长度 | 判定 |
  |---|---|---|---|
  | `http://8.212.161.49/` | 67,152 | **49,880** | ✅ 正常 |
  | `https://8.212.161.49/` | **0** | 0 | ❌ 证书错误，页面未加载 |
  | `https://8.212.161.49/` + `--ignore-certificate-errors` | 1,053 | **0** | ❌ **白屏** |
  | `https://www.likha.hk/` | 67,152 | **49,880** | ✅ 正常 |

  **http 与 https-www 的 DOM 字节数、`#root` 长度完全一致** ⇒ 页面本身对 IP / 域名**无任何差异化逻辑**，唯一变量就是 HTTPS 证书。
- **可解性：无解（这不是配错）**。CAS DV **不签发 IP SAN**；IP 证书需 OV + IP 所有权证明，而 ALB 的 IP 是**共享资产**；自签名/私有 CA 浏览器不信任；ALB 的 HTTPS 监听**必须有默认证书**，不支持"拒绝未知 SNI"以触发浏览器回退；关掉 443 会废掉任务 19/25。
- **⇒ 修正 10-06 裁定 A**：**「保留裸 IP 直访」仅限 HTTP**（`http://8.212.161.49` 服务端完全正常：200 + 完整 SPA + `/api/status` 200 + 静态资源可达 + **无 HSTS / 无 Location**）。**对外口径一律 `https://www.likha.hk`**，**勿把裸 IP 作为任何交付入口**（浏览器残留的 HSTS / 证书例外会让老访问者继续撞墙）。
- **关联**：任务 47（Host 收敛）若删掉无 Host 兜底，裸 IP 直访将**整体消失** ⇒ 届时须与用户确认是否彻底放弃该入口。
- 取证 `deploy/docs/裸IP直访白屏_诊断_2026-10-12.md`；复现脚本 `deploy/logs/t_ipwhite.sh`（服务端+证书）+ `t_dom.sh`（Chrome headless 渲染对比）。

### 5. 附：`httpDefaultActions` / `defaultActions` 在 AlbConfig 中均不生效（实测）

- 两种字段名**都试过**，Controller **一律用自己的 ForwardGroup 覆盖派生占位服务器组**（`kube-system-fake-svc-<port>`）⇒ **无法用 AlbConfig 配「HTTP 默认兜底跳转」**。
- ⇒ 想让 80 默认兜底**只能靠 Ingress 规则**（见第 4 条）。
- 与 10-06 SG 侧结论一致（`idleTimeout`/`requestTimeout` ✅ 有效；`defaultActions`/`httpDefaultActions` ❌ 无效）；另 `accessLogConfig.logStore` **必须 `alb_` 前缀**（webhook 硬校验）。

### 6. 附：HEAD vs GET —— 一次「全站 404」误判的教训

- 排查时用 `curl -sSI http://www.likha.hk/api/status`（**HEAD**）→ **404**，一度判定「跳转破坏了生产」并**执行了回滚**。
- **真因**：new-api `/api/status` **只注册 GET**，gin 对 HEAD 返回**应用层 404**（响应头 `Content-Type: application/json` + `X-Oneapi-Request-Id`）。
- **区分法**：ALB FixedResponse 404 是 `text/plain` 且无应用头；应用层 404 是 `application/json` + `X-Oneapi-Request-Id`。
- ⇒ **验收一律用 `curl -sS -o /dev/null -w '%{http_code}'`（GET）**，勿用 `-I`（HEAD）。本次回滚**无必要**（但无害）。

### 7. 验收实测（任务 19 V1–V5 / 任务 25）

| 项 | 任务 19（mnl · `alb-1riqckb1h8ezm0y7s9`） | 任务 25（sg · `alb-amdwm60xmznh7s1nae`） |
|---|---|---|
| V1 双 AZ | `[ap-southeast-6b, ap-southeast-6a]` ✅ | — |
| V2 443 监听 | `Idle=60 / Req=600` ✅ | `lsn-iqn5i233mvv7eu4u6w` Running ✅ |
| V3 TLS 协商 | `TLSv1.3 / TLS_AES_128_GCM_SHA256` ✅；`-tls1_1`/`-tls1` → 服务端回 `tlsv1 alert protocol version`(70) ✅ | openssl **Verify 0 (ok)** ✅ |
| V4 HTTP→HTTPS | `www.likha.hk` / `likha.hk` → **301**，`-L` 终到 **200** ✅ | 未做（保留 80） |
| V5 后端健康 | SG `sgp-j4qrgy3f7bcv1r67na` 4 ENI（`10.0.43.202`/`10.0.43.218`/`10.0.22.219`…）`:3000` 全 Available ✅ | `rule-443-1`(Host `sg-standby.internal.likha.hk`) → `sgp-rlxs1mqishcxcfkx7u` ✅；`curl --resolve :443:{43.98.186.238,47.237.68.142}` → **200 / 200** ✅ |
| 回归 | 裸 IP 直访 200 不跳转 ✅ · `ph-verify.internal.likha.hk:80` 200 ✅ · canary 优先级不变 ✅ | — |

- ⚠️ **弱版本反例的正确观测**：`openssl s_client -tls1_1` 在 OpenSSL 3 客户端需加 `-cipher 'DEFAULT@SECLEVEL=0'`，否则是**客户端自报** `no protocols available`（不算服务端拒绝）；**正确的服务端拒绝现象**是回 `tlsv1 alert protocol version`。

### 8. ⚠️ CLI 参数形态坑（本轮新增）

- `alb ListListeners` 必须用**复数 flat** `--LoadBalancerIds.1 <id>`（`--LoadBalancerId` 报非法；`--LoadBalancerIds <id>` 报 `Illegal parameter serialization format. Flat format is required`）。
- `alb ListRules` 用 **`--ListenerIds.1 <id>`**（复数）。
- **嵌套对象参数被 CLI 拒绝**：`--DefaultActions.1.ForwardGroupConfig.ServerGroupTuples.1.ServerGroupId` 报非法 ⇒ 改用自建 `deploy/lib/aliyun_rpc.py`（RPC SigV1 签名 + 点号扁平明文）。
- 多层 JMESPath 引号在 shell 中被拆 ⇒ **原始 JSON 落盘 + `python3` 解析**（比 `--cli-query` 稳）。

### 9. ★★ 443「无匹配 Host ⇒ 502」—— `sg.likha.hk` 故障与修复（2026-10-12）

- **现象**：`https://sg.likha.hk` → **502**（页脚 `alb`）；`http://sg.likha.hk` **正常**。
- **根因**：443 监听上**只有** `Host=sg-standby.internal.likha.hk` 一条规则 ⇒ `sg.likha.hk` 不匹配 ⇒ 落**监听器默认动作** ⇒ 派生占位组 **`kube-system-fake-svc-443`**（后端 = **节点 IP:3000**、`HealthCheckEnabled=off`）⇒ 无服务监听 ⇒ **502**。
- **★ 托管 ALB 的「默认动作」是占位组，不是业务兜底**：`ListListeners` 的 `DefaultActions` 指向 `sgp-*` 名字为 `kube-system-fake-svc-<port>` 的组，健康检查 off、后端是**节点 IP** ⇒ **任何未匹配请求必 502**。想让某 Host 可用**必须显式建规则**。
- **为什么只挂 HTTPS**：80 端口有历史遗留的**无 Host 兜底 Ingress**（`new-api-ph-standby-ip`，`listen-ports=[{"HTTP":80}]`）⇒ 任意 Host 命中兜底；而它**没开 443** ⇒ HTTPS 缺口现形。**⇒ 验收必须 HTTP/HTTPS 各测一遍。**
- **修复**：给 `Ingress/new-api-ph-standby` 用 JSON patch 追加一条 host（只动 `/spec/rules`，**不碰注解**）：
  `kubectl -n new-api patch ingress new-api-ph-standby --type=json -p='[{"op":"add","path":"/spec/rules/-","value":{"host":"sg.likha.hk","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"new-api-ph-standby","port":{"number":80}}}}]}}}]'`
  ⇒ 443 生成 `rule-443-2`(Host=`sg.likha.hk`) → `sgp-rlxs1mqishcxcfkx7u`（2 台 ENI 全健康）⇒ **200**。
- **诊断法**：`ListRules --ListenerIds.1 <LSN>` 看 `RuleConditions[].HostConfig.Values` 是否含目标 Host；`GetListenerHealthStatus --ListenerId <LSN> --IncludeRule true` 区分「规则缺失」与「后端不健康」（本次 `NonNormalServers=[]` ⇒ 纯规则缺失）。集群内 `curl http://<svc>/api/status` 得 200 也可排除应用层。
- **★ `RuleName` 会重新编号**：本次 nohost 兜底由 `rule-80-2` 变为 `rule-80-3`，新 Host 规则占 `rule-80-2` ⇒ **判路由只信实时 API 的 `Host`/`Priority`/`ServerGroupId`**。
- **★ 漂移教训**：10-12 上线 443 时只 annotate 了集群，未回写 `deploy/manifests/ingress-sg-standby.yaml`（仍写 `[{"HTTP":80}]`）⇒ 本次已对齐。**改配置必须同步真源文件。**
- **遗留**：443 仍无无-Host 兜底（SG 侧仅显式 Host 可达，符合任务 47 收敛方向）；`sg-standby.internal.likha.hk` 走 443 会 SAN 不匹配（通配符不含 `.internal.`）⇒ 内部域名继续用 80。
- 完整取证：`deploy/docs/SG站sg.likha.hk_502修复_2026-10-12.md`。

### 10. ★★ 新增域名转发配置：**只改 Ingress / AlbConfig，禁止手动改 ALB 规则**（2026-10-12 实测）

- **硬证据（3/3）**：对两地 ALB 监听直调 `CreateRule`（`--DryRun true` 零变更）→ **mnl 443 / mnl 80 / sg 443 全部** `OperationDenied.ServiceManagedResource`「the current resource is managed resource」。⇒ **不是建议，是平台级技术强制**。
- **归属证明**：ALB 标签 `ack.aliyun.com=<集群ID>` + `ingress.k8s.alibaba/albconfig=kube-system/mnl-alb` + `ingress.k8s.alibaba/resource=ApplicationLoadBalancer` ⇒ 实例/监听/**规则/服务器组全由 ACK Controller 派生**，控制台那一列是**渲染结果**。
- **控制台表现**：转发规则页「插入新规则 / 排序 / 批量删除」为**灰态不可点**（与 API 行为一致）。
- **即使能改也不该改**：① Controller 持续 reconcile ⇒ 手改规则**静默消失** ② **RuleId 无稳定性**（会跨 Host 复用/重编号）③ 造成 IaC 漂移 ⇒ "神秘回滚"。
- **正确姿势五步**：① 定 Host / 端口 / 后端 Service:port ② 选载体（转发 → 加进已声明 `listen-ports` 的 Ingress 或新建；跳转 → `actions.<伪名>` + `RedirectConfig` + `httpCode`）③ 定 `order`（**要压过兜底必须 < 50**；跳转类用 1）④ 443 证书覆盖（通配符 `*.likha.hk` + 裸域覆盖 www/sg/根域；**不含 `.internal.`、不含多级域、不含 IP**）⑤ **验收两步**：先 `ListRules` 看 `RuleActions[].Type/HttpCode/HostConfig.Values`（错字段名会静默失败且 **仍回 200**），再 curl **HTTP/HTTPS 各一遍** ⑥ 回写真源。
- **★ 两地 Ingress 地图（2026-10-12 实测，权威）**：
  - **mnl**（6 个）：`new-api-http-redirect`(order1, 80, www+根域→301) · `new-api-https-canonical`(order1, 443, 根域→308) · `new-api-canary-weight`(45, 80) · `new-api-canary-header`(46, 80) · **`new-api-stable-ip`(order50, 80+443, `(无Host)`→stable 兜底)** · `new-api-catchall-404`(order100, FixedResponse 404)。
  - **sg**（4 个）：`new-api-sg-http-redirect`(order1, 80) · `new-api-sg-https-canonical`(order1, 443) · `new-api-ph-standby`(默认10, 80+443, 内部域+`sg.likha.hk`) · **`new-api-ph-standby-ip`(order50, 80+443, `(无Host)` 兜底)**。
- **★ 静默失败清单**：`httpDefaultActions`/`defaultActions` 不生效 · `CertIdentifier`→须 `CertificateId` · `redirectConfig`/`statusCode`→须 `RedirectConfig`/`httpCode` · `service.name` 与 `actions.<name>` 必须同名 · `port.name` 改 `number` 会去找不存在的 Service · **漏 `listen-ports` ⇒ 该端口完全无规则** · 443 无匹配 Host ⇒ **502**。
- **★ 两条操作细则（本次修正/新增）**：
  - **DryRun 探针法的准确边界**：参数**齐备**才回托管拒绝；参数**不齐**会**先回参数校验错**（实测 `MissingRuleActions.1.Order`）⇒ 看起来像"未被拦截"，**极易误判**。结论不变：DryRun **无法预演参数**，仅能确证托管拒绝。
  - **`ListRules` 偶发返回空**：本次 80 监听计数一度 **6→0**，重试 1 次即恢复（301 规则完好）⇒ 计数/断言**必须重试 ≥3 次 + 校验合法 JSON**。
- **★ Ingress ↔ ALB 规则对账模型（2026-10-12 实测 · 原始 ID 级）**：**1 个 Ingress → N 条规则**，`N = (host×path 组合数) × listen-ports 数`。控制台「路由」页按 **Ingress 聚合**、ALB「转发规则」页按 **规则平铺**（**不带 Ingress 归属**）⇒ **非 1:1**，这是"看着对不上"的唯一原因（典型例：`new-api-stable-ip` 2 path × 2 端口 = 4 条 → 443 上就是 `rule-443-2`(具名 host) + `rule-443-3`(无 Host)）。
  - 实测展开：**mnl 443 = 3**（`https-canonical` 1 + `stable-ip` 2）· **mnl 80 = 6**（`http-redirect` 2 + `canary-header` 1 + `canary-weight` 1 + `stable-ip` 1 + `catchall-404` 1）· **SG 443 = 4**（`sg-https-canonical` 1 + `ph-standby` 2 + `ph-standby-ip` 1）· **SG 80 = 5**（`sg-http-redirect` 2 + `ph-standby` 2 + `ph-standby-ip` 1）。**SG 侧完全 1:1 展开、无合并 ⇒ 最干净的验证样本**。
  - **RuleName = `rule-<port>-<该监听内序号>`** ⇒ 与「第几个 Ingress」**无关**，**不可作对账锚点**（RuleId 更会跨 Host 复用）。
  - **★ 服务器组同名不同 ID**：`new-api-new-api-canary-80` 有 2 个 ID（`sgp-slwubl6v6sb2xtsxrz` header 用 / `sgp-1eevkvsn0c32t3e1ya` weight 用）；`new-api-new-api-ph-standby-80` 有 2 个 ID（`sgp-rlxs1mqishcxcfkx7u` 显式 Host 用 / `sgp-8m8eknlyw0z1busl6r` **无 Host 兜底**用）⇒ **一律按 `ServerGroupId` 引用，勿按名字**。命名规则 `<ns>-<svc>-<port>`。
  - **★ MNL 80 只有 6 条（非 7）**：`stable-ip` 的 `Host=ph-verify` path 与 canary-weight 规则**条件相同被合并**（目标组 canary w5 + stable w95 = `canary-weight=5` 的语义）——**推断**，依据是条件相同 + 目标组内含 stable。
  - **★ `order` ≠ 最终优先级**：`order` 与 `Priority` 大体同向（1 最先 / 50 居中 / 100 最后），但 **canary 那一对相反**（`canary-header` order=46 排在 `canary-weight` order=45 **之前**）⇒ **必须实查 `ListRules` 的 `Priority`**。
- **★★ 服务器组派生粒度 = Ingress（2026-10-12 定论）**：**组数 = 引用该 Service:Port 的「不同 Ingress 数」** —— **同 Ingress 内多条 rule 复用一组；跨 Ingress 各派生一组**（哪怕 backend 完全相同）。
  - 判定归属**只看标签 `ingress.k8s.alibaba/ingress_name`**（组名 `<ns>-<svc>-<port>` 会撞车，**同名必不同 ID**）。
  - 实证：SG `new-api-ph-standby-ip`(`sgp-8m8eknlyw0z1busl6r`) vs `new-api-ph-standby`(`sgp-rlxs1mqishcxcfkx7u`) 两组**后端/协议/调度/健康检查/VPC 全同**（`10.1.19.127:3000` + `10.1.38.123:3000`，各 w100），唯一差异就是 `ingress_name`。mnl 侧对应形态**放在同一个 Ingress** `new-api-stable-ip`（`hosts=ph-verify.internal.likha.hk,(无 Host)`）⇒ **只有 1 个组** `sgp-j4qrgy3f7bcv1r67na`。差异纯属任务 19 / 任务 25 落地形态不同，**功能等价**。
  - **★ 托管服务器组删不掉（三重拦截）**：① `DeleteServerGroup` 先撞 **`ResourceInUse.ServerGroup`**（被规则引用）；② 标签 `ack.aliyun.com` + `ingress.k8s.alibaba/*` ⇒ 托管派生，写操作回 `ServiceManagedResource`；③ 绕过也**被 reconcile 重建**。⚠ `DryRun` 在 ① 就短路，**不能反推「非托管就能删」**。删掉 = 该组承载规则立刻 **502**。
  - **★ 合并多 rule 时 `order` 是 Ingress 级**：含「无 Host」rule 的 Ingress **必须用默认 order**（或确保整组排在具名规则之后），否则无 Host rule 会**吃掉全部流量**。合并路径 = 把 noHost rule 挪进具名 Ingress → **先 apply 合并版（瞬时 3 组）再 delete 旧的** → GC 回落 1 组，规则布局与合并前**逐条等价**。
- 完整口径与证据：`deploy/docs/新增域名转发配置口径_Ingress优先_2026-10-12.md`（§7 四张对账表）+ `deploy/docs/服务器组同名重复_成因与处置_2026-10-12.md`（成因/删除可行性/合并 SOP）。

## ★ 云助手回传通道的两个硬限制（2026-10-12 实测 · 做工具时踩到）

1. **`RunCommand` 的 `Output` 有 ~24 KB 上限，且截断是「掐中间」**（保留头尾、丢掉中间一段）：
   - 实测 A（真实数据）：节点侧 `NODE_SIZE=25236` → 本地收 `24371`，**行数 424/424 完全一致**，但中间丢了 865 字节 ⇒ JSON 报 `Expecting ':' delimiter`，**极易误判成集群数据损坏**。
   - 实测 B（规律数据复现）：节点侧 30040 B（5×6008）→ 本地收 24386 B，**第 2 行整段消失、第 1 行被拼接变长**。
   - ⇒ **铁律：经 `ack_remote.sh` 回传的载荷一律压到 < 2 KB**；需要结构化数据时用 `kubectl -o go-template` 打**紧凑 TSV**（一行一条），**不要 `-o json`**。
2. **`kubectl get <名字> -o go-template='{{range .items}}'` 静默输出空**：指定资源名时 kubectl 返回**单个对象**、无 `.items` ⇒ range 空转，**不报错、退出码 0**。回读一律 `kubectl get ingress`（不带名字）。
3. **`kubectl -o custom-columns` 取不到带 `/` 的注解键**：`…:.metadata.annotations.alb\.ingress\.kubernetes\.io/listen-ports` 实测**全输出 `<no value>`/`<none>`**（静默失败）⇒ 改用 `go-template` + `{{with .metadata.annotations}}{{index . "alb.ingress.kubernetes.io/listen-ports"}}{{end}}`。

## ★ 工具 `deploy/ops/add-domain.sh`（2026-10-12 建 · 加域名一条命令）

`plan | apply | verify | ls | delete`，封装「生成真源 → 预检 → apply（云助手）→ 云端对账 → 回写真源」。
- **预检 8 项**：order<50 · 证书覆盖（`*.likha.hk`+裸域）· 跳转目标**三态可达性**（explicit/fallback/missing）· 目标 host 已存在规则 · **Service 存在性（远端 apply 前拦截，零变更，9 s 返回）** · 真源冲突 · 自跳死循环 · 非法状态码/IP。
- **对账 3 项**（只看 curl 不够）：`Host=` 规则存在 · 该规则 `Priority < 兜底 Priority`（否则**永不命中**）· `RuleActions[].Type` 未被静默降级。
- 默认 `forward` 的 `--order 40` / `redirect` 的 `--order 1`；redirect 一律 80→**301**、443→**308**；真源写 `deploy/manifests/ingress-<site>-<prefix>-{forward,http-redirect,https-canonical}.yaml`（**须 git commit**）。
- 调试：`ADD_DOMAIN_KEEP=1` 保留远端原始输出并打印路径。
- **附带确证**：每个新 Ingress 派生**独立服务器组**（同名不同 ID 的成因）；**删 Ingress 后 Controller 会 GC 该组**（实测 6→5）。
- 全文与自测矩阵：`deploy/docs/域名加配置_一条命令_add-domain_2026-10-12.md`。

## ★ 两文档口径冲突对照表（② xlsx v2.3 vs ① 指南 · 一律按 ①）

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

## ★ G0 门禁全量复核 + 任务 1、2 收口（2026-10-12）

**结论（2026-10-12 二次裁定后口径）**：**任务 2 ✅ 完成 · 任务 1 ✅ 本卡收口**；G0 门禁 **11 项过 10 / 仅 G11 未过**；**G6·G7 复核闭合**、**G8 移出门禁（T+14 后补）**、**G13 移出门禁（转 Day 3）**、**G9 经裁定闭合（降权不做 · 知情接受）**。报告 `deploy/docs/Day1任务1_2_G0收口与NS复核_执行报告_2026-10-12.md`（**§七 = 裁定登记与遗留风险**）。⚠ 原「13 项过 7 / 未过 6」与「门禁 12 项过 8 / 未过 4」两版口径**均已作废**。**门禁终态 = 11 项**（G1–G7 / G9–G12；G8、G13 移出）。

### 本卡实测（三步全过）
- 配额工单：`ListQuotaApplications` → mnl `b140e263-685…` = 64 / sg `e117bf2b-e8e…` = 96，**均 `Status=Agree`**
- 可用区：`ap-southeast-6a` / `6b`（仅两个）
- 机型：`ecs.g9i.2xlarge` 在 6a/6b **均 `WithStock`**；备用 **`ecs.g8ine.2xlarge` 同** ⇒ ⚠ **`ecs.g9ine.2xlarge` 查无此机型**（勿再引用）
- NS：权威 `DescribeDomainInfo` 与递归 `dig` **双验一致**

### 未过 1 项 + 复核闭合 2 项 + 移出门禁 2 项 + 裁定闭合 1 项（2026-10-12 二次裁定）

| 项 | 实测 | 归属 |
|---|---|---|
| G6 模板 PR | ✅ **复核闭合**：`deploy/aliyun/ph/` **14 件全部入库**（提交 `b713cce5e`，10-12），**本地 = `origin/main`（未推送 0）、工作树干净**；单人 fork 直推 `main` ⇒「PR 链接」要件**不适用**。⚠ 上一轮记的「2 件未提交」已在归档提交中消除 | 已收口 |
| G7 产品开通 | ✅ **复核闭合**：**全部实例已建成 = 已开通**（CK `cc-5tsv2o51s1360b0pr` ⇒ 企业版售卖区白名单**实际已通**——无白名单建不出实例；RDS/Tair/ACK×3/ALB×2/ACR/SLS/ARMS 同）；「白名单书面确认」经裁定**不作门禁要件** | 已收口 |
| G11 连接预算表 | ❌ **唯一未过**；未产出，现存答疑用 **16C64G / 800 / HPA16**，与实况 **2C8G / HPA13** 不符 | 任务 41 |
| ~~G8 探针~~ | ⏸ **移出门禁 → T+14 后补**（实测 `healthz`/`readyz` 0 命中、`/metrics` 未注册）。过渡口径：探针用 `/api/status`+TCP；Tair 故障 **fail-closed**（全站 429/503 风险 + P1 告警）；`MIGRATE_MODE` 不生效；`G8-EV-1` 邮件闸门滞后 | **后补项**（不阻塞 G0） |
| ~~G13 staging~~ | ⏸ **移出门禁 → 转 Day 3 计划内**（`deploy/docs/` 内暂无 staging/perf 文档） | **后补项**（不阻塞 G0） |
| ~~G9 降权~~ | ✅ **裁定「本轮不做」⇒ 知情接受闭合**（ActionTrail `Enable` + MFA 4 台已达成）。风险：主账号仍持 `AdministratorAccess`，日后收紧须先确认无自动化依赖其 AK | 已收口 |

### 四处口径偏差（已就地修订指南正文）
1. **prepay 配额过时**：实测 `q_ecs_enterprise_prepay_c` = mnl **1024** / sg **5120**（旧写 100/100）⇒ 按量 `postpay_c` 64/96 仍是唯一核量口径，prepay 仅对照。
2. **按量配额已占一半（扩容门禁）**：`TotalUsage` → mnl **32/64**（= 4 节点 × 8 vCPU）、sg **16/96**（= 2 节点 × 8）⇒ **mnl 仅余 4 个 `ecs.g9i.2xlarge` 的额度**，是 HPA 的硬顶。
3. **NS 名写错**：卡内期望 `ns*.aliyuncs.com` → 实为 **`ns*.alidns.com`**。
4. **「改记录后 SOA 序列号递增」判据不成立**：10-05 之后新增 `_dnsauth` TXT 与 `sg` 两条记录，序列号**仍为 `2026100517`** ⇒ 验记录生效**只能逐条 `dig` 目标记录名**。

### 任务 2 的顺延项（非遗漏）
- `ops`（前置 = 堡垒机/VPN = 任务 46）· `static`（前置 = DCDN 未启用）—— **不建悬空记录**，随前置落地时补建。
- ~~`www` **TTL 60 不可达**（免费版下限 600s，实测 600）；`www` 形态由 CNAME→GTM 改为 **A→ALB**（GTM 已挂起）。~~
  → **2026-10-13 更新**：**GTM 已解挂**（任务 21 完成），`www.likha.hk` 由 **GTM 3.0 直接接管**（权威直答 `60 IN CNAME alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com`）；「TTL 60 不可达」仅对**云解析普通记录**成立。云解析残留 2 条 A **保留作回退兜底**。

### 附带确认（工具口径）
- `quotas ListProductQuotas --MaxResults` **上限 100**（传 300 报 `INVALID.MAX.RESULTS`）。
- `aliyun ram GetAccountSummary` **不是合法 API**（国际站 CLI 报 "not a valid api"）⇒ 查 RAM 用 `ListUsers` / `ListVirtualMFADevices` / `ListPoliciesForUser`。
- 集群实况：**mnl 4 节点 / sg 2 节点**（`cs DescribeClusterNodes`）。

## ★ G11 连接数预算表 —— 线上实况核实（2026-10-12）

**交付物**：`deploy/docs/G11连接数预算表_线上核实_2026-10-12.md`（正式预算表 + 偏差登记 + ActionTrail 追溯）

### 实测左端输入（**禁止手填**，全部取实况）

| 项 | 值 |
|---|---|
| RDS 实例 | `pgm-5tstdhko64x2c01w` · PG 17.0 · `pg.n4.2c.2m`(2C8G) · HA · `PGBouncerEnabled=true` · `MaxConnections=800` |
| 池参数 | `max_client_conn=2000` · `default_pool_size=50` · **`pool_mode=session`** · `stats_users=newapi_ops` · `ignore_startup_parameters=extra_float_digits` · `query_wait_timeout=120` · `server_idle_timeout=600` · `ConfigParameters=空`（全生效） |
| mnl Pod 内生效 | `SQL_MAX_OPEN_CONNS=100` / `SQL_MAX_IDLE_CONNS=50`（**来自 CM `new-api-config`，env 未覆盖**）· `SQL_DSN` 端口 `6432`（stable/canary）· master `5432` · `LOG_SQL_DSN` 端口 `9000`=CK |
| sg Pod 内生效 | `OPEN=10` / `IDLE=5`（**Deployment env 覆盖 CM 的 100/50**）· `SQL_DSN` 端口 `6432` · `LOG_SQL_DSN` 端口 `9000` |
| 副本/HPA | mnl stable 4→13 · canary 1 · master 1；sg standby 2→16（任务 44 将抬 20） |
| 服务端实况连接数 | `ConnectionUsage` ≈ **2%（≈16 条）**（零负载） |

### 三不变量 + 新增 I-4

| 不变量 | 算式 | 判定 |
|---|---|---|
| **I-1** 客户端 ≤ 2000 | `13×100 + 1×100 + 20×10 = 1600`（保守上界 16/24 口径 = 1840） | ✅ 余量 400 |
| **I-2** 服务端 ≤ 640 | 池 `(newapi,newapi)` ≤50 + `(newapi_sg,newapi)` ≤50 + master 直连 ≤100 + 预留 20 = **≤220** | ✅ 余量 420 |
| **I-3** 迁移旁路 | master `SQL_DSN` 端口实测 `5432` | ✅ |
| **I-4** 并发服务能力（**本次新增**） | 接管态 `1300 client : 50 server` = **26:1** 排队；`query_wait_timeout=120s` ⇒ 超时报错。session 下 client 独占 server **直到断开**（非事务结束） | ⚠️ **不成立** |

### ★ 核心发现：`pool_mode` 未登记变更（ActionTrail 实证）

近 35 天全部 `ModifyParameter`：

| 时间（HKT） | 操作者 | 参数 | 登记 |
|---|---|---|---|
| 2026-09-29 11:47 | `root` | `default_pool_size=50`、`max_client_conn=2000` | ✅ |
| 2026-09-29 16:25 | `yanxuewei` | `ssl_min_protocol_version=TLSv1.2` | ✅ |
| 2026-09-29 18:31 | `yanxuewei` | `stats_users=newapi_ops` | ✅ |
| **2026-09-30 09:33** | **`root`** | **`pool_mode=session`** | ❌ **未登记** |

⇒ 任务 41 卡 09-30 执行记录「**未执行任何 `pool_mode` 写操作**，实例仍为 `transaction`」**与事实冲突**（该行已就地更正）。**教训**：读参数模板 flag 证明"能热改" ≠ "没改过"；运行值只能用 `RunningParameters` 读，且须配 ActionTrail 追溯。

### ★ 修正任务卡一处错误论断

任务 41 卡原写「session 模式下 client 独占 server，`default_pool_size=50` **不再是上限**」⇒ **不准确**。`default_pool_size` 在任何 `pool_mode` 下都是每池 `(user,db)` 的 server 连接上限；session 的真实后果是 **client 排队**。故 **I-2 在两种模式下数值相同且均成立**（≤220），真正被 session 打破的是新增的 **I-4**。

### 其他偏差

| 项 | 文档 | 实况 | 处置 |
|---|---|---|---|
| HPA CPU 目标 | `65%`（F14 取证 + 真源 YAML） | **`70%`**（mnl/sg 两侧） | 真源 drift；疑似任务 23 V4 测试临时降 1% 后恢复写成 70 ⇒ 回改 65 或同步真源 |
| sg HPA 上限 | `2–20`（F12 连带） | `2–16` | 待办（任务 44 / Day 3），非缺陷 |
| ConfigMap 名 | `newapi-config`（卡内命令） | **`new-api-config`** | 文档笔误（已在本节更正） |
| `SQL_MAX_LIFETIME` | 「必须显式给值」 | 未设置（代码默认 60s = 期望值） | 等效，登记 |

### RDS 到期风险（同库，非 G11 范围）

`ExpireTime = 2026-10-28T16:00:00Z` ⇒ **距今 16 天**。生产库到期停服 ⇒ 到期前必须完成续费或迁移决策。

### ★ 2026-10-13 裁定落地（三项裁定 + 一项新增判定）

| # | 事项 | 裁定（2026-10-13） | 落地 |
|---|---|---|---|
| 1 | `pool_mode` 回切 `transaction` | **先不切** ⇒ 维持 `session` | 登记为**知情接受的持续偏离**；**I-4 继续不成立**；复核触发 = 真实流量压测前 / 任务 44 接管演练前 / HPA 打到 `maxReplicas` 的时段 |
| 2 | HPA CPU 目标 65 vs 70 | **回改** | ✅ 两地已 patch → `cpu@65%`（`hpa-new-api-stable` 4/13 · `hpa-new-api-ph-standby` 2/16）。⚠ **备站 HPA 此前无任何 IaC 真源**（现网对象无 `last-applied` 注解）⇒ 已在 `deploy/aliyun/ph/standby-deployment.yaml` **末尾补写 HPA 块**（与 live 一致；**无 `behavior`**，与主站的自定义 behavior 不同） |
| 3 | RDS 到期 / 续费 | **已设自动续费** | ✅ `bssopenapi QueryAvailableInstances` → `RenewStatus=AutoRenewal`、`RenewalDuration=1 M`（10-28 停服风险解除；仍须保余额）。⚠ **`bssopenapi` 无 ap-southeast-6 端点**（须 `--region ap-southeast-1`）；**`--Region`（大写）= API 参数、`--region`（小写）= CLI 地域开关**，写错会静默用 profile 地域报 `unknown endpoint` |
| 4 | **备站 conns 覆盖 `10/5` 被删** | ✅ **已恢复**（用户 10-13 17:1x 裁定「恢复」并执行） | 2026-10-13 10:56 备站 Deployment 移除 `SQL_MAX_OPEN_CONNS=10` / `SQL_MAX_IDLE_CONNS=5` ⇒ Pod 回落 CM 的 `100/50`。**删后 worst-case I-1 = `1300+100+20×100 = 3400 > 2000` ⛔**；且备站与主站**共用同一 PgBouncer**（`…pub.pgsql…:6432`），`(newapi_sg,newapi)` 池 server 侧仍被 `default_pool_size=50` 封顶 ⇒ **抬 client 槽位不增吞吐、只增排队与挤占**；`IDLE 5→50` 还让每 Pod 常驻 50 条空闲连接（16 副本=800 条）。**恢复后**：generation `6→7`、RS `5f8484cffb` 2/2、两 Pod `10/5` 实测、跨 AZ 1a/1b、HPA `2–16@65%`、自探 reachable ⇒ **I-1 回 `1600≤2000`** |

**备站 conns 覆盖恢复命令**（幂等，需在集群内或经 `deploy/lib/ack_remote.sh sg <body>`；**已于 2026-10-13 17:1x 执行**）：
```bash
kubectl -n new-api patch deploy new-api-ph-standby --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"SQL_MAX_OPEN_CONNS","value":"10"}},
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"SQL_MAX_IDLE_CONNS","value":"5"}}]'
```
⚠ **`add …/env/-` 是顺序敏感操作**：真源 `standby-deployment.yaml:118-127` 恰好把两个 conns 排在 `NODE_TYPE`/`GOMAXPROCS` **之后**，故恢复后与真源逐序一致、`apply` 无 diff；若真源顺序不同，功能等价但 apply 会因**数组原子比较**产生 diff ⇒ **改 env 前先对齐真源顺序**。

### 复核命令

```bash
aliyun rds DescribeDBInstanceAttribute --DBInstanceId pgm-5tstdhko64x2c01w --RegionId ap-southeast-6
aliyun rds DescribeParameters          --DBInstanceId pgm-5tstdhko64x2c01w --RegionId ap-southeast-6
kubectl -n new-api exec deploy/new-api-stable -- sh -c 'env | grep -E "^(SQL_|LOG_SQL)"'   # CM 名是 new-api-config
aliyun rds DescribeDBInstancePerformance --Key ConnectionUsage --DBInstanceId <id> --region ap-southeast-6 --StartTime <ISO> --EndTime <ISO>
aliyun actiontrail LookupEvents --LookupAttribute.1.Key EventName --LookupAttribute.1.Value ModifyParameter --StartTime <ISO> --EndTime <ISO>
```

## ★ 任务 56 挂起裁定 —— 上游 IP 白名单（2026-10-13 · 按需再做）

**裁定**：Day 3 · 任务 56「上游供应商 IP 白名单提交与生效确认」**挂起 · 按需再做**（项目负责人 2026-10-13）。不进执行队列、不设固定窗口、**不阻塞任何里程碑**。

**移出范围**：G0 欠项「上游 8 EIP 白名单提交」· Day 3 泳道 A 出口门禁 · Day 3 排期块 · M3 判据。

**理由**：① 本卡是**外部等待项**（对方审批 1-3 天），我方无主动权，放 4 天窗口里只能空等；② 当前**未向上游发真实渠道流量**（正式发布 = Day 4 任务 34），未加白**不产生线上故障** —— 白名单只在**上游侧**生效，我方探活 `000/超时` 与白名单无关（先排 SNAT/EIP）；③ 上游侧真正需白名单的只有**企业专属渠道 / Azure OpenAI（`ipRules`）/ 自建私有化上游**，头部厂商普遍不做入向白名单 ⇒ 覆盖面比卡标题暗示的窄。

**重启触发（满足任一）**：① Day 4 正式发布前确定使用的渠道中存在需 IP 白名单者 ⇒ **必须先确认生效再进流量**；② 任一渠道稳定 403 / 间歇失败且已排除 SNAT/EIP 侧；③ 上游主动要求提交或回执。

**8 个 EIP 台账**：`deploy/eip_ledger.md`（mnl `8.212.146.47` / `8.220.142.77` / `8.220.184.250` / `8.212.176.29`；sg `47.84.184.246` / `47.84.29.162` / `47.84.83.76` / `47.84.126.214`；全部 `InUse`）。

> ⚠ **★ 该表不可作为人工注记载体（2026-10-13 实测踩到）**：`deploy/tasks/task6/nat_eip.sh:228-252` 用 `{ ... } > "$LEDGER"` **整表重建** —— 每次运行都会重写**生成时间**、**待办段**（恢复模板原文）、mnl 4 行（`InUse` 为**硬编码**、非回读值），并把 sg 4 行先写成「未建」占位；随后 `deploy/tasks/task12/nat_eip_sg.sh:241-265` 用 awk 把 sg 4 行替换为真实值。⇒ **任何人工勾选/注记会在下一次 task6 运行时被冲掉**（本轮 18:15:53 亲历：台账注记被覆盖、生成时间被刷新）。
> ⇒ 结论修正：**「已交供应商?」列全空 `☐` ≠ 未提交**，不能用它判定提交是否发生过（该列由模板固定输出）。任务 56 的挂起注记已写进 **task6 脚本模板本身**（唯一持久点，已加待办行标注 + 一行「本表由脚本整表重建」警示）。
> ⇒ 另一处口径：`deploy/jakarta_dev_ledger.md` 声明「只记录**实测回读值**」，而本表 mnl 行的 `InUse` 是**硬编码** ⇒ 与「实测回读」声明不符，已知瑕疵（不影响当前结论：实测状态确为 `InUse`）。

**落点**：指南 6 处（§0.4 任务表行 150 · §0.3 Day3 排期块 · Day3 泳道位移声明 · 任务 56 卡标题+前置 · 泳道 A 出口清单 · §0.6 G0 欠项段）+ 任务 52 卡前置解耦（不再以「任务 56 完成」为前置）；xlsx「落地计划」行 59 `AC`=⏸挂起、`Y`=裁定说明；`deploy/eip_ledger.md` 待办项标注。

## ★ §7.10 成本结构 —— 线上实测口径（2026-10-14 全面重算）

**触发**：fanyan 要求按线上实际使用量 + 阿里云国际站官方价，精确更新 `impl_deploy.md §7.10`。

**真源**：`deploy/ops/gen_cost_table.py`（**已重写为实测口径**；`--apply` 回写 `impl_deploy.md` + `impl_tech.md` 的 §7.10，自动备份到 `.workbuddy/backup/cost_<ts>_*.md`）。⇒ **改成本先改脚本，勿手改 md**（旧「规划口径」模型可从 git 取回）。

**取证三板斧**：
1. `aliyun ecs|rds DescribePrice`（实例类，含磁盘参数；⚠ ECS 必须给 `--SystemDisk.Category cloud_essd`，否则 `InvalidSystemDiskCategory`；⚠ `rds DescribePrice` **无 `--Category`**，用 `--InstanceUsedType/--PayType/--TimeType/--UsedTime`；⚠ `r-kvstore DescribePrice` 传 `--NodeType` 报 `InvalidParameter`）
2. `aliyun bssopenapi DescribeInstanceBill --BillingCycle YYYY-MM --Granularity MONTHLY --MaxResults 300 --region ap-southeast-1` ⇒ **按实例 + `ServicePeriod` 反推日率，最准**
3. `aliyun bssopenapi QueryBillOverview --BillingCycle YYYY-MM`（按产品汇总）
⚠ `DescribeSplitItemBill` 本账号**返 0 行**（不可用）。

**结论表（USD/月，730 h/月；日率项 ×30.4167）**：

| 站 | 小计 | 主要构成 |
|---|---|---|
| 马尼拉 ap-southeast-6 | **3,205.48** | ECS 4×323.04 + 盘 4×55.45 · CK **1,082.44（最大单项）** · RDS 168.26 · ACR 157 · Tair 64.63 · ACK 65.70 · CLB 13.05 · ALB 13.29 · NAT 26.77 · EIP 6×3.65 · ops 48.25 · SLS 11.41 · KMS 10.52 · GTM 6.72 · CMS 1.55 · OSS 0.03 |
| 新加坡 ap-southeast-1 | **1,095.71** | ECS g8ine 392.97 + g9ae 363.04 + 盘 2×55.45 · Tair 88.02 · ACK 65.70 · CLB 13.05 · ALB 13.29 · NAT 26.80 · EIP 6×3.65 |
| 雅加达 dev ap-southeast-5 | **327.30** | ECS g9ae.large+g9i.large 173.05 · RDS dev 110.11 · NAT 26.71 · CLB 13.05 · EIP 4.38 |
| **生产两站** | **4,301.19** | 日烧钱 ≈ **152.17 USD/天** |
| **含 jkt dev** | **4,628.49** | — |

**实测单价表**：

| 资源 | 单价 | 来源 |
|---|---|---|
| ECS `g9ae.2xlarge`+100G（mnl） | **$0.44252/h** → $323.04/台·月 | DescribePrice |
| ECS `g9ae.2xlarge` / `g8ine.2xlarge`+100G（sg） | **$0.49732 / $0.53832 /h** | DescribePrice |
| ECS `g9ae.large` / `g9i.large`（jkt） | $0.124328 / $0.112728 /h | DescribePrice |
| ESSD PL1 300G 数据盘 | **$0.07596/h** → $55.45/月（两地同价） | DescribePrice |
| `ecs.c9i.large`+40G（包月） | $48.25/月 | DescribePrice |
| RDS `pg.n4.2c.2m` 2C8G HA + 100G ESSD PL1 | **$168.26/月** | DescribePrice = 09 月实付 |
| Tair 企业版主备（mnl） | $64.63/月 | 09 月实付 |
| Tair 集群版（sg） | $88.02/月 | 10 月实付 |
| ACR 企业版基础版 | **$157.00/月** | 09 月实付（旧记 $113 作废） |
| ACK Pro 控制面 | $0.09/集群·h（$2.16/天） | 账单反推 |
| ALB 标准版（实例+LCU） | $0.437/天 | 账单反推 |
| NAT 增强型（实例+CU） | $0.880 ~ 0.881/天 | 账单反推 |
| EIP 保有费 | $0.120/天·IP（≈$0.005/h） | 账单反推 |
| ACK 内网 CLB | $0.429/天 | 账单反推 |
| ClickHouse 企业版 | **$35.587/天** | 账单反推 |
| KMS 3.0 / GTM 3.0 | $0.346 / $0.221 /天 | 账单反推 |

**与 09-27 规划口径差异（9,865.36 → 4,301.19，↓56.4%）**：① **WAF 未开通 −2,800**；② **CK 2 站包月 → 1 站按量 −2,374**；③ **RDS 参照值虚高 17× −2,777**；④ 流量类（NAT CU / EIP 出口 / DCDN）+ 拨测 −约 700；⑤ GTM 旗舰版订阅 → 3.0 按量 −133。**升幅**：ECS 包月 → 按量 +363、新增 ops 节点/内网 CLB/KMS +98。
**未开通**（账单 + API 双证）：WAF 3.0（`waf-openapi DescribeInstance` 空）、DCDN（`DcdnServiceNotFound`）、付费 DNS（`DescribeDnsProductInstances` 0）、ARMS 应用监控。

**账单实付**：2026-09 全账期 **588.72**（09-24 起，含搭建期临时实例约 $48）· 2026-10（10-01~10-14）**2,131.31**（`QueryBillOverview` 口径 2,137.82）。**一次性**：DV 通配符 `*.likha.hk` **$207**（至 2027-04-28）· 域名注册 $18。

**⚠ 三个必须跟进的点**：
1. **余额 380.33 USD**（10-12 为 699）⇒ 2 天 ≈$319、**≈160/天**，**仅够约 2.4 天** ⇒ 立即充值 / 设预算告警（清单 #39）。
2. **$997 证书订单悬案**：`cas_intl-sg-9lu4zmk9e00m`（`ItemName=新购`）在实例账单中存在，但 `cas ListCertificates` **无对应证书** ⇒ 疑未支付/已取消/已退款，**须控制台核实**，勿计入预算。
3. **流量口径缺口**：EIP 行**只含保有费**；2026-10 账单「云数据传输 CDT」与 EIP 流量项均 ≈$0 ⇒ **当前无真实业务出口流量**（未对上游发量）。**上量后必须重算**：$0.081/GB（EIP）+ $0.043/CU（NAT）⇒ **每 1 TB/月 +$127.02**。

**清点副产物（与既有记忆的修正）**：① **sg 有 Tair** `r-gs5ltv3m4i3655besh`（修正「Tair SG 0 实例」）；② **第 3 个 ACK 集群 `ack-newapi-jkt-dev`（ap-southeast-5）**，2 节点，**账单未见计费**（疑首集群免费额度，待确认）＝原「staging/perf」；③ **sg 两节点规格不一致**（`g8ine.2xlarge`+`g9ae.2xlarge`，多规格池 `np-sg-ph-standby`）；④ **每集群自动 1 个内网 CLB**；⑤ CK 实为企业版/按量/单 AZ/2 server 节点/OSS；⑥ RDS 实为 2C8G/100G（非常 16C64G）；⑦ 拨测仅 1 任务、**间隔 5 min**、PC 组（实测 $1.55/月 vs 规划 $145.15）。

## ★ §7.10 成本结构「更新 2」—— 四项指示落地（2026-10-14 11:0x）

**背景**：fanyan 就 §7.10 下 4 条指示 ⇒ 全部落进真源 `deploy/ops/gen_cost_table.py` 后 `--apply`。

| # | 指示 | 落地 |
|---|---|---|
| ① | 准备充值中 | 余额行保留 380.33 实测值 + 追加「**已安排充值（受理中）**」⇒ 「仅够 2.4 天」告警**解除**；告警阈值建议改「余额 < 1,000 USD / 日耗 > 250 USD」 |
| ② | 已退 OV 换 DV | **997 悬案闭合**：账单实证 OV 订单 `cas_intl-sg-9lu4zmk9e00m` = 新购 +997.00 / **退款 −997.00**（净 0）；DV `cas_intl-sg-4rf4zyk0u00s` = 207.00 + 5.07 = **212.07** ⇒ 证书一次性**净支出 212.07**，较 OV 省 **784.93** |
| ③ | 按上量后 100 MB/天估算流量 | 7.10.1 新增「出口流量（上量后估算 100 MB/天）」行 = **$0.37/月**；7.10.8 新增**流量单价表 + 流量成本标度表**；7.10.2 注备站 $0 |
| ④ | 7.10.1/7.10.2/7.10.3 按 USD/月 降序 | `table()` 加 `sorted(rows, key=lambda x: -x[5])`（0 值/免费行自然落末） |

**★ 流量类官方单价（阿里云国际站官网公开定价页，2026-10-14 查证）**：

| 项 | 单价 | 备注 |
|---|---|---|
| EIP **出方向**流量（BGP 多线） | **$0.081/GB** | **新加坡 / 菲律宾马尼拉同价**；雅加达 $0.090、东京 $0.087、吉隆坡 $0.077；中国内地 $0.123、香港 $0.153；BGP 精品线路马尼拉 $0.452 |
| EIP 保有费（公网 IP 配置费） | **$0.006/h·IP = $0.144/天** | 官方页；**本表仍用账单实数 $0.120/天·IP**（官方注「以购买页为准」）。⚠ 绑 ECS（账号配额 ≤2000）免保有费；绑 NAT/SLB 照收 |
| NAT 增强型 **CU** | **$0.043/CU**（跨 AZ）· **$0.034**（单 AZ，0~100 万 CU） | **1 CU = 处理流量 1 GB**（入 + 出**均计**）；**2025-09-26 起 CU 只按处理流量**，此前取 `max(新建连接/1万, 并发/2万, 流量/1GB)` |
| NAT 实例费 | 跨 AZ 0.3 CNY/h · 单 AZ 0.15 CNY/h | 与 CU 分开计，两者合计即账单观测的 $0.88/天 |
| ⇒ **生产合计** | **$0.124/GB** | EIP $0.081 + NAT CU $0.043 |

**流量成本标度表**（mnl/sg 口径；折月 30.4167 天，1 GB = 1,024 MB）：

| 出口流量 | 折月 | 成本/月 |
|---|---|---|
| **100 MB/天（本次口径）** | 2.97 GB | **$0.37** |
| 1 GB/天 | 30.42 GB | $3.77 |
| 10 GB/天 | 304.17 GB | $37.71 |
| 100 GB/天 | 3.04 TB | $377.14 |
| 1 TB/月 | 1,024 GB | $127.02 |

⇒ 日均 ≤10 GB ⇒ ≤$38/月，**不改变成本结构**（仍由 CK + ECS 主导）；破 $100/月需日均 >27 GB（届时考虑 NAT 资源包，按量→包约省 20–30%）。

**新总数**：mnl **3,205.85** · sg **1,095.71** · **生产两站 4,301.55** · 含 jkt dev **4,628.85** USD/月（日烧 ≈**152.18 USD/天**）。

**校验**：段落边界 7.9→7.10→八 完好；三表降序实测通过；两文档 §7.10 **同源（各 14,665 B、逐字节相同）**。备份 `.workbuddy/backup/cost_20261014_105915_*.md`。


---

## ★ ECS 数据盘 300G → 100G 降配论证（2026-10-14 · 只读取证，未执行）

**问题**：把 ECS 数据盘由 300G 降到 100G 能省多少？

### 一、单价（`aliyun ecs DescribePrice`，2026-10-14 实测，ESSD PL1）

| 容量 | USD/h | USD/台·月（×730h） |
| --- | --- | --- |
| 300G | 0.07596 | **55.45** |
| **100G** | **0.02532** | **18.48** |
| 200G | 0.05064 | 36.97 |
| 50G | 0.01266 | 9.24 |

⇒ **线性计价 $0.0002532/GiB·h，两地（apse-6 / apse-1）同价**；100G = 300G 的 **1/3**。
⚠ **取价坑**：`--ResourceType disk` 必须同时给 `--RegionId` + `--ZoneId`，否则 trace 全 None；返回结构是 `PriceInfo.Price.TradePrice`（**不是** `PriceInfo.TradePrice`，后者是 instance 类型的旧路径）；带 `.1.` 的写法 `--DataDisk.1.Size` 可用，但 `--SystemDisk.1.Category` **非法**（系统盘无索引，须 `--SystemDisk.Category`）。

### 二、降配空间（线上实测 imagefs 占用，kubelet summary API）

取数方式（**只读、零副作用**）：`kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary`（经 `ack_remote.sh` 下发）。

| 站 | 节点 | 实例 | AZ | imageFs 容量 | imageFs 已用 | 使用率 |
| --- | --- | --- | --- | --- | --- | --- |
| mnl | .22.194 | g9ae.2xlarge | 6a | 289.5 GiB | 4.6 GiB | 1.6% |
| mnl | .22.195 | g9ae.2xlarge | 6a | 289.5 GiB | 3.5 GiB | 1.2% |
| mnl | .43.200 | g9ae.2xlarge | 6b | 289.5 GiB | 4.1 GiB | 1.4% |
| mnl | .43.201 | g9ae.2xlarge | 6b | 289.5 GiB | 4.0 GiB | 1.4% |
| sg | .19.103 | g9ae.2xlarge | 1a | 289.5 GiB | 4.8 GiB | 1.7% |
| sg | .38.113 | g8ine.2xlarge | 1b | 289.5 GiB | 4.4 GiB | 1.5% |

⇒ **两地 6 台全部仅用 3.5–4.8 GiB（1.2–1.7%）**。降到 100G（≈96.6 GiB）后：使用率 ≈5%，扣 kubelet image GC 阈值 85%（≈82 GiB）仍有 **17 倍余量**。
（对照：`rootfs` 用 5.0–7.9 GiB；数据盘同时承载 containerd data root 与 `/var/lib/kubelet`。）

### 三、节省额

| 口径 | 原 | 降后 | 省 |
| --- | --- | --- | --- |
| mnl ×4 | 221.80 | 73.93 | **147.87/月** |
| sg ×2 | 110.90 | 36.97 | **73.93/月** |
| **两地合计** | **332.70** | **110.90** | **221.80/月**（年化 **2,661.6**，占生产两站 **5.16%**） |

### 四、执行约束（重要）

1. **云盘不支持原地缩容**（阿里云只支持扩容）⇒ 不能改盘，只能**替换节点**。
2. ACK 节点池 `scaling_group.data_disks[].size` 修改**只对新建节点生效** ⇒ 必须**逐台轮转**：改节点池配置 → `cordon` → `drain` → 删除节点 → 节点池自动补一台 100G 盘新节点 → 验证 → 下一台。
3. ⚠ **须确认新节点仍把数据盘挂给 containerd**：现网 `scaling_group.disk_init = []`（空），说明依赖 **ACK 默认挂载**（实测生效：imageFs 容量 289.5 GiB 证明数据盘已是 containerd data root）。任务 11 报告曾记录「数据盘不给 containerd → 系统盘写满 → `disk-pressure` 驱逐雪崩」⇒ **改前须灰度 1 台验证 `imageFs.capacity` 仍 ≈96.6 GiB**，否则立即回滚节点池配置。
4. 拓扑：mnl 4 台跨 2 AZ（6a×2 / 6b×2）、sg 2 台跨 2 AZ（1a×1 / 1b×1）⇒ sg **每 AZ 仅 1 台**，轮转时该 AZ 短暂无节点；须按 PDB + 跨 AZ 分布逐台进行，勿一次 drain 同 AZ 两台。
5. 节点池为**多规格池**（`g9i/g8ine/g9ae`），修改 `data_disks.size` 不影响实例规格选择逻辑。

### 五、其他档位备选（若担心余量）

| 目标容量 | 每台月费 | 6 台合计 | 相对 300G 省 |
| --- | --- | --- | --- |
| 100G | 18.48 | 110.90 | **221.80/月** |
| 200G | 36.97 | 221.80 | 110.90/月 |
| 50G | 9.24 | 55.45 | 277.35/月（不推荐：余量降至 ~8 倍且 GC 更频） |

⇒ **100G 是最优档**：既省 2/3，又留 17 倍余量。

**取证脚本**：`deploy/logs/t_disk_price3.sh`（取价）· `t_disk_nodepool.sh`（节点池配置）· `t_disk_stats.sh`（imagefs 占用，经 `ack_remote.sh <site>`）。
**落点**：`gen_cost_table.py` 新增常量 `DISK100_H` + 7.10.8 降本表**首行**；已 `--apply` 回写两份文档（§7.10 同源 15,040 B）。
**状态**：仅论证与登记，**未执行任何生产变更**。


---

## ★ ACK 数据盘挂载机制与 disk_init 显式化评估（2026-10-14 · 只读，未变更）

### 一、现状：挂盘是 ACK 内置行为，不是我们的配置

**问题起点**：节点池返回里 `data_disks[0].disk_name = null`、`scaling_group` 无 `disk_init` 字段（**API 从不返回该字段**，此前记作「`disk_init=[]`」不准确），`kubernetes_config.user_data` 是**nofile 调优脚本**（任务 11 Step 3，Linux 句柄数），与挂盘无关。那么数据盘是谁挂的？

**答案（实测证据）**：`/var/log/ack-deploy.log` 中 `[step=diskinit]`（代码 `auto_disk.go`）：

```
[step=diskinit] running command: udevadm info --query=symlink --name=/dev/nvme1n1
[step=diskinit] running command: sed -i '\|/dev/disk/by-uuid/<uuid>    /var/lib/container     ext4    defaults        0 0|d' /etc/fstab
[step=diskinit] running command: mount /dev/nvme1n1 /var/lib/container/
[step=diskinit] running command: mount -a
```

**落盘结果**（`/etc/fstab`，节点实测）：

| 行 | 内容 |
| --- | --- |
| 1 | `UUID=b5301f19-…  /var/lib/container  ext4  defaults  0 0`（数据盘本体，nvme1n1 = 300G ESSD） |
| 2 | `/var/lib/container/kubelet    /var/lib/kubelet    none bind,slave,shared` |
| 3 | `/var/lib/container/containerd /var/lib/containerd none bind` |
| 4 | `/var/lib/container/log        /var/log/pods       none bind` |

**⇒ 结论**：ACK 的 `diskinit` 步骤每次节点初始化都会**自动探测未使用数据盘 → ext4 格式化 → 挂 `/var/lib/container` → bind 三目录 → 写 fstab（sed 先删同项，幂等）**。6 台节点（mnl 4 + sg 2）全部如此，`ack-deploy-trace.log` 里 `fdisk:… / fdiskDone:…` 为固定步骤。
**⚠ 重要修正**：数据盘**同时承载 `/var/log/pods`（容器本地日志）**，不只是 containerd ⇒ 容量评估应看**整盘 used**（实测 **7.9 GiB / 290 GiB = 2.7%**），而非仅 imageFs 的 4.4–4.8 GiB。降 100G 后使用率 ≈ 8.2%（仍 ≈12 倍余量）。

### 二、若要显式化：`disk_init` 的精确契约（OpenAPI meta，2026-10-14）

`ModifyClusterNodePool` / `CreateClusterNodePool` 的 `scaling_group` **含 44 个字段，其中确有 `disk_init`**（type=array，非必填）。

`components.schemas.DiskInit`：

| 字段 | 类型 | 必填 | 说明（原文） |
| --- | --- | --- | --- |
| `disk_name` | string | **是** | 唯一标识该节点池中的一块盘。当 `local_disk=false` 时，**必须与 `scaling_group.data_disks` 中的某一个 `disk_name` 匹配** |
| `mkfs_type` | string | — | 自动格式化文件系统的类型。**留空表示不格式化** |
| `mount_target` | string | — | 挂载目录，**留空则不挂载** |
| `mount_for_runtime` | boolean | — | **容器运行时数据存储到该盘** |
| `local_disk` | boolean | — | 本地盘配置（与本场景无关） |

⚠ `data_disks[].disk_name` 现状为 **`null`** ⇒ **要配 `disk_init` 必须同时给数据盘命名**（如 `data-1`），否则 disk_name 无法匹配。
⚠ `mount_target` 留空是否等于"不挂载"、与 `mount_for_runtime=true` 如何组合，**官方未文档化**（meta 与帮助页均无说明）。

### 三、修改的生效范围（官方原文）

> 节点池编辑过程中，**不会影响节点池内已有节点和业务的运行**。节点池配置更新后，后续节点池中新增的节点都将默认使用该配置。
> **重要**：节点池配置更新后，除特殊说明场景外（例如同步更新存量节点的 ECS 标签、同步更新存量节点的污点及节点标签），**不会修改节点池已有节点的配置，仅作用于新增节点**。

⇒ **改 `disk_init`/`data_disks` 不会重建存量 6 台节点**（要滚动 kubelet 的是另一个接口 `ModifyNodePoolNodeConfig`，本场景不使用）。

### 四、评估结论：**不必补（收益为负）** ⇒ 2026-10-14 裁定「保持现状」

| 维度 | 判断 |
| --- | --- |
| 现状是否缺陷 | **否**。ACK 内置 `diskinit` 是产品基线行为，6 台节点已按同一套逻辑正常挂载 |
| 补的收益 | 仅"把隐式默认显式化"，防的是 ACK 改变默认行为的理论风险 —— 而 `ack-deploy` 的 diskinit 是 ACK 核心引导路径，变更会先影响全量客户 |
| 补的成本/风险 | ① `disk_init` 一旦存在，ACK 走**显式路径**（覆盖默认）；② `disk_name` 必填 ⇒ 必须同时改 `data_disks`；③ `mount_target`/`mount_for_runtime` 组合语义**无文档**，写错 ⇒ 新节点 containerd 落 100G 系统盘 ⇒ **disk-pressure 驱逐雪崩**（即任务 11 坑 3）；④ `scaling_group` 传参是增量还是全量覆盖**未文档化**（最坏情况清空其他字段，影响下次扩容，但不影响存量节点） |

**⇒ 结论（2026-10-14 负责人裁定 · 方案 A「保持现状」）**：**不补 `disk_init`，线上零变更**；本机制已写死进 **IaC 真源 `deploy/tasks/task11/nodepool_mnl.sh` 文件头**（+ dry-run / 建池两处分支注释；task24 薄封装指向同一处，防口径漂移），成本表 7.10.8 同步标注「挂盘由 ACK 内置 `[step=diskinit]` 完成，**无需改 `disk_init`**」⇒ 后续维护者不会误判为「漏配」而补它。若将来确要显式化，**必须与"新建 1 台节点灰度验证 `fstab` 四行 + `df`"绑定**，不可只改不验。

**灰度验证成本参考**：mnl ASG 现 `min_instances=2 / max_instances=8`（2026-10-14 13:00 由 4 下调），实际 4 台 ⇒ 可临时 scale-out 1 台（~$0.44/h × 数小时 ≈ $1 内），验 `fstab` 四行与 `df` 后缩回；或在 dev 集群（jakarta `ack-newapi-jkt-dev`）先建临时节点池验证语法。

**取证脚本**：`deploy/logs/t_diskinit_pool.sh`（节点池全字段）· `t_diskinit_ud.sh`（解 user_data）· `t_diskinit_meta2.sh`（OpenAPI meta）· `t_diskinit_node.sh` + `t_diskinit_trace.sh`（节点侧 fstab/ack-deploy 溯源，经 `ack_remote.sh <site>`）。
**落点（方案 A）**：真源注释 `deploy/tasks/task11/nodepool_mnl.sh`（头 + 2 处分支）· `deploy/tasks/task24/nodepool_sg.sh`（指回头部）· 成本表 `deploy/ops/gen_cost_table.py` 7.10.8 首行 · 本节结论。
**状态**：**2026-10-14 已裁定 = 方案 A「保持现状」，线上零变更**（仅文档 + IaC 注释；`bash -n` PASS、`--dry-run` 渲染一致）。

---

## ★ 节点池伸缩边界调整（2026-10-14 · 成本表「更新 3」）

**输入**：负责人称「对 ECS 进行了缩容」，要求按**线上实际实例**更新成本结构。

**实测结论：ECS 未发生任何缩容** —— 实例数量（mnl 4 + sg 2 + jkt 2 + ops 1）、机型、磁盘（300G 数据盘 + 100G 系统盘）与 **`CreationTime`（全部 2026-09-29 / 09-30）** 均与建站时一致，**无节点替换、无磁盘变更**。

**实际变更 = 两次节点池伸缩下限调整**（`actiontrail LookupEvents` + `--LookupAttribute EventRW=Write` 过滤实证）：

| 时间（UTC / HKT） | 集群 | API | 请求体 / 变更 |
| --- | --- | --- | --- |
| `04:59:20Z` / **12:59:20** | sg `ca75829e…` | `ModifyClusterNodePool` | `{"auto_scaling":{"enable":true,"max_instances":10,"min_instances":1}}` ⇒ **min 2→1 / max 12→10** |
| `05:00:02Z` / **13:00:02** | mnl `cd57e40c…` | `ModifyClusterNodePool` | `{"auto_scaling":{"enable":true,"max_instances":8,"min_instances":2}}` ⇒ **min 4→2 / max 8** |

同时刻配套 `Ess ModifyScalingGroup`（MinSize/MaxSize）与 `ModifyScalingConfiguration` —— 后者的 **`DataDisk.1.Size` 仍为 300**，确证**只改了伸缩边界、未动磁盘**。

**⚠ ActionTrail 用法坑**：`LookupEvents` 的 `MaxResults` 上限是 **50**（传 100 报 `InvalidParameterValue: invalid MaxResults(100)`）；**`--region` 决定事件地域**，ap-southeast-1 与 ap-southeast-6 数据独立（两个地域都要查，且 ap-southeast-6 端点偶发 timeout → 重试 ≥3 次）。CLI 点号参数 `--LookupAttribute.1.Key/.Value` 在本产品上**可用**（与 GTM 的点号数组不同）。

**成本口径（已落 `gen_cost_table.py`）**：
- **常态表数字不变**（按实际 4 + 2 台计）⇒ 7.10.1 / 7.10.2 / 7.10.3 与 7.10.4「常态」行均未变。
- 新增 **7.10.4「目标态」行**：mnl 4→2 + sg 2→1 ⇒ 生产两站 **3,096.15 USD/月**（较常态 4,301.55 省 **1,205.41/月**，**−28.02%**）。
- 新增 **7.10.8 两条降本行**：mnl 按新下限常态 2 台省 **$756.98/月**（单台 `g9ae.2xlarge`+300G = $378.49）；sg 按新下限常态 1 台省 **$418.49 ~ $448.42/月**。

**⚠ 三个必须记住的约束**：① **改下限 ≠ 立即缩容** —— 是否真缩由 ACK 按负载利用率判定；② mnl 跨 AZ 将由 2/2 变 **1/1**，**失去「单 AZ 故障仍余 2 台」的冗余**；③ sg 缩到 1 台即**单 AZ 单节点**，备站接管 RTO / 容量须重评。

**IaC 同步（防重跑覆盖线上）**：`task11/nodepool_mnl.sh` `MIN_NODES` **4→2**；`task24/nodepool_sg.sh` `MIN_NODES` **2→1** / `MAX_NODES` **12→10**；台账 `deploy/nodepool_ledger.md`（§1 容量/ESS 行）与 `deploy/nodepool_ledger_sg.md`（§1 ESS 行）同步为现值。

**取证**：`deploy/logs/t_ecs_shrink_check.sh`（实例/磁盘/节点池三查）· `t_ecs_age.sh`（`CreationTime`）· `t_trail_write.sh` / `t_trail_hourly.sh` / `t_trail_mnl2.sh` / `t_trail_mnl3.sh`（ActionTrail 分层扫描）。

---

## ★★ 节点缩容机制：为什么「改 min」不会缩，以及怎么真正缩到 mnl=2 / sg=1（2026-10-14 实测）

### 一、结论：自动缩容在本集群**结构性不会发生**

1. **autoscaler 存在**，是 **`ack-goatscaler`（GOATScaler，节点即时弹性）**，**不在用户集群内可见 Pod**（控制面托管）—— 但节点标签 `goatscaler.io/managed=true`、kube-system `lease/ack-goatscaler`、事件 `LeaderElection ack-goatscaler-…became leader` 三处可证。
   ⚠️ 因此 **`kubectl get pods -A | grep autoscal` 查不到 ≠ 没有 autoscaler**（曾据此误判过一次）。
2. **它不会自动缩容**，真因写在 `kube-system/autoscaler-meta`（ConfigMap，15d 未变）：
   ```json
   {"scaler-type":"goatscaler","unneeded_duration":"10m","cool_down_duration":"10m",
    "utilization_threshold":"0.5","scale_down_enabled":true,"scan_interval":"60s",
    "expander":"least-waste","skip_nodes_with_system_pods":true,
    "skip_nodes_with_local_storage":true,"scale_up_from_zero":true}
   ```
   **`skip_nodes_with_system_pods: true`** ⇒ 载有 kube-system **非 DaemonSet** Pod 的节点**永不参与缩容**。
   实测两集群**每一台**节点都命中（mnl：`.194` 载 **13** 个 + `logtail-statefulset-0`；`.195` 载 2；`.200` 载 1；`.201` 载 4；sg 同构）⇒ **无一台是候选**。
3. 事件 `ScaleDownLimited: blocked by nodepool minsize limit`（mnl `.194`，`04:58:18Z`）只是**最外层**门槛；**放开 min 之后仍缩不动**（因为还有 skip 系统 Pod 这一层）。⇒ 「改下限 ≠ 立即缩容」的**真正原因**不是"ACK 按利用率判定"，而是这条 skip 规则。
4. `ScaleClusterNodePool` **只支持扩容**（meta 原文：「扩容节点数量…当前 2 个扩容 2 个后变成 4 个」，`count` 只能加）⇒ **不能**用它缩容。

### 二、要真正缩，只有显式路径

| 路径 | 命令 | 评价 |
| --- | --- | --- |
| **A. ACK 原生移除（推荐）** | `cs RemoveNodePoolNodes --instance_ids '["i-x","i-y"]' --release_node true --drain_node true --concurrency false` | 精准选节点、自带 drain、会同步 ESS 期望数；`instance_ids` 是 **`style:json`**（与 GTM 同坑：`--instance_ids.1` 会报"未赋值"，必须整体传 JSON 串） |
| **B. 压 max 触发 ESS 缩容** | `cs ModifyClusterNodePool --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":N,"max_instances":N}}'` → 收敛后回填 max | 官方警告语「最大实例数不要小于当前节点池中的节点数，否则会直接导致节点池缩容」；但**挑哪台由 ESS 决定**，不可控 |
| C. 调 GOATScaler 配置 | 需在 ACK 控制台组件管理改 `SkipNodesWithSystemPods` / `ScaleDownOnlyEmptyNodes`，或把系统 Pod 用 nodeAffinity 钉到固定节点 | 改动面大（涉及系统组件调度），收益仅"自动"，**不推荐** |

> 工具：**`deploy/tasks/task42/shrink_nodepool.sh <mnl|sg> [--target N] [--keep ...] [--apply]`**（幂等；**默认 dry-run 只出计划**；plan 阶段即校验 `target ≥ ACK min` 与 `target ≥ ESS MinSize`；`--apply` 逐台串行 + 轮询释放；含 `--target` 参数化，mnl 默认 2 / sg 默认 1）。
> 实测计划：mnl 保留 `i-5ts9wk588cliiweawind`(6a) + `i-5tsawhljdqzwqhmadqv0`(6b)（**刻意保留系统 Pod 最多的 `.194`，把迁移量压到最小**），移除 `.195` + `.201`；sg 保留 `i-t4nb4aj0ssltm7jjawuv`(1a)，移除 `i-t4nha3jicbebtvf3tr7v`(1b)。

### 三、★ 容量硬约束（缩之前必须先过这一关）—— 实测 requests 账

节点可分配：**7910m CPU / 30.2 GiB**（`ecs.g9ae.2xlarge`，g8ine 同）。每节点 DaemonSet 开销 ≈ **0.78 C**；集群级非 DaemonSet 系统 Pod（coredns/gatekeeper/metrics-server/csi-provisioner/ack-cost-exporter/pod-identity-webhook…）两地各 ≈ **3.2 C**（其中 arms-prom 占 ~1.0 C）。

| | 现状 | 缩后 | 判定 |
| --- | --- | --- | --- |
| **mnl** | 4 台 = 31.64 C；请求 16.91 C（41/63/61/46%） | 2 台 = 15.82 C；请求 ≈ **15.35 C = 97.0%** | ⚠ **能装下但零余量** |
| **sg** | 2 台 = 15.82 C；请求 8.81 C | 1 台 = 7.91 C；请求 ≈ **8.03 C = 101.5%** | ❌ **装不下** |

- **sg 必须先降副本**：`new-api-ph-standby` **2 → 1**（−2 C）⇒ 6.03 C / 7.91 C = **76%** 才成立。否则 Pod 起不来 → GOATScaler 会**补回第 2 台**（白折腾）。
- **mnl 2 台**稳态能容：`new-api-stable` 4×2C + `new-api-canary` 1×2C + `new-api-master` 0.5C + 系统 4.8C ≈ 15.3C。但 **HPA `maxReplicas=13` 在 2 台时不可能达成**（13×2C=26C）⇒ 2 台后 HPA 上限实际上被节点数接管：**稳态满、扩容只能靠 GOATScaler 加节点**（`scale_up_from_zero=true`，扩容路径**不受** skip 规则影响，所以弹性仍在，只是从"热备"变"冷启"）。
- 若不想这么紧：**mnl 留 3 台**（23.73 C，请求 ≈ 16.1 C = **68%**，省 $378.49/月）是"保留缓冲"的中间态；或 2 台 + 撤 `new-api-canary`（−2C ⇒ 84%）。
- 冗余代价：mnl 由跨区 **2/2 → 1/1**（单 AZ 故障只剩 1 台，R15「单 AZ 故障仍余 2 副本」不再成立）；sg 变**单 AZ 单节点**（备站 RTO 依赖 GOATScaler 冷启 + 镜像拉取）。

### 四、取证脚本
`deploy/logs/t_shrink_cloud.sh`（节点池/ESS/实例三查）· `t_shrink_k8s{,2,3}.sh`（容量/HPA/PDB/DS/ns 汇总）· `t_shrink_auto.sh`（ESS 伸缩活动 + RAM 角色）· `t_shrink_goat.sh`（autoscaler 痕迹）· `t_shrink_cfg.sh`（autoscaler-meta + 事件 + lease）· `t_shrink_syspod.sh`（kube-system 非 DS Pod 落点，**缩容阻塞判定**）。
**状态**：**2026-10-14 裁定「暂不动」** —— mnl 保持 4 台、sg 保持 2 台（不降副本、不摘节点）；仅取证 + dry-run 计划 + 脚本落库，**线上零变更**。需要时执行 `deploy/tasks/task42/shrink_nodepool.sh <mnl|sg> --apply`。

## K8s 免密拉取：「凭据晚于 Pod 创建」时序坑（10-14 · jakarta dev 实证）

**★ 可泛化判据**：`Pod.spec.imagePullSecrets` 由 **ServiceAccount 准入控制器在 Pod 创建那一刻**写入，**Spec 不可变** ⇒
**「SA 上现在有凭据」不能推出「这个 Pod 拉得动」**。排查顺序必须是
`Pod 的 spec.imagePullSecrets（实际值）` → `Pod 的 SA` → `SA.imagePullSecrets` → `Secret 在不在/新不新`，
**而不是**先看 SA 或先看 Secret（这与「Secret 存在 ≠ Pod 拿得到」是同一条约束的两端）。
- 症状：同 ns、同镜像、同 tag 的另一个 Pod 正常，本 Pod 报 `insufficient_scope: authorization failed`。
- 真因：凭据是**后来**才挂到该 SA 上的（改 helper 配置 / helper 下一个同步周期 / 手工补 Secret）。
- 处置：**只重建 Pod**（`rollout restart`）即可；**不需要**改 SA，也**不需要**动 Secret。
- 对照：若 SA 上**始终没有**凭据（helper 配置没圈到它）⇒ 换 SA（`new-api-app`），**重建无用**。
- 工具：`deploy/jakarta_dev/bodies/fix_pull_restart.sh` + `dev_deploy.sh --fix-pull-restart <deploy>`（默认 `APPLY=0` 只出计划；
  闸门含"生效 SA 必须已有免密 Secret，否则提示改走 `--fix-pull-sa`"）。
- ⚠ **helper 配置读取**：`cs GET /clusters/{id}/addon_instances` **不返回 `config`**，必须走带组件名的
  `…/addon_instances/managed-aliyun-acr-credential-helper`；`DescribeAddonInstance` / `GetAddonInstance` /
  `DescribeClusterAddonInstance` 三个具名 API 在 **CLI 3.5.1 元数据缺失**（报 `invalid flag --ClusterId`）。
- ⚠ **kubectl jsonpath 不认 `{{}}`**：`{{.spec.x}}` 是 **go-template** 语法，误用在 `-o jsonpath` 会报
  `unrecognized character in action: U+007B`；jsonpath 一律单花括号 `{.spec.x}`。
- 现状口径（10-14）：jkt dev helper 的 `serviceAccount` = **`new-api-app,default`**（安装时为 `new-api-app`，17:14:53 由负责人
  经控制台重提，附带占位符 `notifyEmail: xxx@aliyun.com`）⇒ `default` SA 也带上了 EE 免密凭据，**控制台手建负载不再必然拉不到**；
  代价是 `newapi-dev` 内任何用 default SA 的 Pod 都持有 **EE 实例级**凭据（覆盖含 `newapi-prod` 的全部命名空间）。全文见 `deploy/jakarta_dev_ledger.md` §14。

## jkt dev 对外入口 dev.likha.hk（2026-10-15 落地 · 全文见 jakarta_dev_ledger.md §15）

四项裁定：① slave DSN 收权（`SQL_DSN_MIGRATE`→`SQL_DSN`，strategic merge patch 按 env name 合并，新 Pod `7fd87f877d-n74bw`）② helper 保留 default 作用域（ACR EE 贵）③ 只买 1 个 ALB ④ 加 dev.likha.hk。

**链路**：DNS `dev` CNAME（RecordId `2110572139455158272`，TTL 600）→ ALB **`alb-4okmogghe7hbv5fwm6`**（alb-newapi-jkt-dev，Internet，公网 `147.139.241.96`(5a)/`8.215.59.192`(5b)）→ Ingress 443 → `newapi-dev/new-api-dev-slave`（ClusterIP→3000）；80→301（actions.redirect，order=1）；443 证书 **`606823-ap-southeast-1` 跨地域复用**（mnl/sg/jkt 三实证）。

**IaC/工具**：`deploy/jakarta_dev/dev_ingress.yaml`（AlbConfig `jkt-alb`+IngressClass `alb`+Service+双 Ingress，五构件一文件；zoneMappings=vsw-jkt-dev-pub-5a/5b）· `dev_deploy.sh --apply-ingress`（载荷 INGRESS_B64）/ `--fix-dsn`（均默认 APPLY=0）。`dns-likha-hk.sh` 扩展 `TYPE=CNAME`。

**新坑**：
- 装 `alb-ingress-controller`：jkt 建集群时未随装 → `POST /clusters/<id>/components/install` **必须 `--header "Content-Type=application/json"`**，缺头报 `FAILED_TO_READ_REQUEST`（body 正确也失败）；CLI 3.5.1 无 `--addons` 具名参数。轮询 GET `/clusters/<id>/addon_instances` 过滤 name。
- AlbConfig 带 finalizer `ingress.k8s.alibaba/resources` ⇒ `kubectl delete albconfig jkt-alb` **级联删云上 ALB**（与 mnl-alb 同红线）。
- ALB zoneMappings 用了 VPC 现成 `vsw-jkt-dev-pub-5a/5b`（10.2.0.0/24、10.2.1.0/24）——建 VPC 时预留的 pub 段，未新购交换机。

**验收**：权威 ns7/ns8 CNAME 应答 ✅ · https 3/3 200（双 IP 轮询 1.1–1.4s）✅ · `CN=*.likha.hk` verify ok ✅ · 80→301 ✅ · `/api/status` 正常 ✅。

**挂账**：§7.10 成本表未含 jkt ALB（按量，预计个位数 USD/月；下次 gen_cost_table.py 加行）；跨区公网拉镜像冷缓存耗时仍未验（§13.10）。

## ★★ 日志库去 ClickHouse → 专用 RDS MySQL（2026-10-15 实施 · task58）

**选型依据（GORM 源码实锤）**：`DeleteOldLogBatch`（`model/log.go:705`）`.Limit(limit).Delete()` —— mysql driver v1.5.7 `DeleteClauses` 含 LIMIT（`mysql.go:64`）⇒ 批删生效；**postgres driver v1.5.9 无 LIMIT（`postgres.go:77`）⇒ PG 上被静默忽略 = 一次全删大事务** ⇒ PG 路线（含「并入现役 PG」）全排除。CK $1,082.44/月 → MySQL `mysql.x2.medium.2c` $133.06/月（跨 AZ HA），**净省 $949.38/月**。

**落地物**：实例 **`rm-5ts0ez22t67il9oz3`**（newapi-logs-mysql，包月至 2026-11-15，vpc-5tst1tgeessxn1azwasg2，主 6b/备 6a，100G cloud_essd）；内网串 `rm-5ts0ez22t67il9oz3.mysql.ap-southeast-6.rds.aliyuncs.com:3306`（10.0.64.1）；公网串 **`newapi-logs-public.mysql.ap-southeast-6.rds.aliyuncs.com:3306`**（43.123.80.14，**已开 SSL** CAType=aliyun）；白名单 mnl_vpc + sg_standby_eip（照抄现役 PG）；库/号 `newapi_logs`（ReadWrite）；口令 `/root/.deploy_secrets/RDS_PW_newapi_logs`；DSN `MYSQL_LOG_DSN_{MNL,SG}`；**CK 回滚留档 `CK_LOG_DSN_{MNL,SG}`**。

**接线（14:3x–14:5x 完成）**：`Secret new-api-secrets` 单键 `LOG_SQL_DSN` merge patch + 滚动重启——mnl 三部署（stable/master/canary）→ 内网串无 TLS；sg（new-api-ph-standby）→ 公网串 `?tls=skip-verify`。两站应用日志实证 `using PostgreSQL as database` + `using MySQL as database`、0 DB 错误；应用 AutoMigrate 自动建 `logs`+`audit_logs`。`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 保留（回滚需要）。**CK 实例未释放**（回滚窗口 3–7 天，释放后跑 gen_cost_table.py）。

**新坑**：
- ⚠ **`ModifyDBInstanceSSL` 连接串上限 64 字符**：原名 65 字符报 `ConnectionStringLengthExceeded` ⇒ 用 `ModifyDBInstanceConnectionString` 改前缀为 `newapi-logs-public`（57 字符）后再开 SSL。
- ⚠ **RDS MySQL 云端证书不在公共信任链**：`VERIFY_IDENTITY` 报 `CA certificate is required`；go-sql-driver DSN 不支持自定义 CA（需上游 `RegisterTLSConfig`，违反铁律①）⇒ sg 采用 **`tls=skip-verify`（知情偏离：传输加密保留、身份校验关闭）**。强校验须上游改造。
- 首次实建 `CreateDBInstance` **超时但实际成功** ⇒ 重试前必须 `DescribeDBInstances` 防重复下单。
- RDS 实例刚 Running 时 `CreateAccount` 瞬时 `IncorrectDBInstanceState`（重试即过）；`DescribeDatabases/DescribeAccounts` 响应结构是 `Databases.Database`/`Accounts`（无 `Items.*` 包裹，JMESPath 别照抄）。
- CK DSN 格式不匹配 MySQL 正则 ⇒ switch body 的 python 解析改为**解析失败即原样 patch**（回滚任意格式 DSN 通用）。

**脚本**：`deploy/tasks/task58_log_mysql/`（provision.sh · switch.sh（含 probe 模式）· verify_body.sh · README.md 含回滚一条链路）。
