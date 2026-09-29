# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威文档（2026-09-28 用户指定，一切操作以此二者为准）**
> ① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（4648 行 · 4 天/单人/CLI-first · 含 F1–F11 最新修订 · 56 张任务卡 + 回滚预案 + 附录速查）
> ② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（7 表：说明与总览 / 账号与域名申请19项 / 资源清单-马尼拉39项 / 资源清单-新加坡20项 / 网络与安全规划 / 落地计划56任务+15时段+G1–G13门禁 / 里程碑与验收M1–M5+SLA+风险+裁剪）
> 二者冲突时 **以 ① 的 F9/F10/F11 与 §0.5 为准**（① 修订于 2026-09-27/28，晚于 ② 的 2026-09-24 编制）。
> 详版口径与全部坑 → `REFERENCE.md`；过程流水 → `YYYY-MM-DD.md`。
> 权限权威 `deploy/用户设置指南.md`；切换方案 `deploy/DCDN回源层切换_方案.md`。

## 两文档口径冲突（②落伍处，一律按 ① 执行）
| 项 | ② xlsx v2.3 | ① 指南 v2.0（采信） |
|---|---|---|
| 排期 | 2 人 × 5 天 × 3 段 = 120 人时 | 1 人 × 4 天 × 2 窗（A 日间 08:30–14:00 / B 午后 14:00–22:00）；顺延 backlog：任务 52/45 全量/39 全量/35 完整移交/Grafana 全量 → T+14 |
| 日志库 | 马尼拉 CK **社区版** + **新加坡 CK** | **F9**：仅马尼拉 CK **企业版单 AZ**；不建新加坡 CK；日志不入 SLA 证据链 + 写失败必须降级（未演练不得切流） |
| 镜像源 | 双地域 ACR（mln + sg 各一） | **单地域马尼拉 ACR**；SG 节点跨区走**公网端点**拉（已接受权衡，RTO 须含拉取耗时） |
| 连接收敛 | RDS 代理独享型 或 PgBouncer | **F10 自建 PgBouncer 3 副本**；**F11** 实测 `max_connections=800` 不可改 → 预算封顶 **640**；主站 `SQL_MAX_OPEN_CONNS=150`（日志库 50）、SG 备站 `10` 直连公网不经池 |
| 节点机型 | `g8i.2xlarge` | **F1 `ecs.g9i.2xlarge`**（g8i 马尼拉全系未上架），备 `g8ine.2xlarge`；Day 2 首动作 `DescribeAvailableResource` 复验 |
| ALB 超时 | requestTimeout 180s | **600s（上限）**；SSE 靠网关 15–20s ping 保活 |
| ACK | 1.31+ | **1.35**（1.31/1.33 已 EOL） |
| 备案证据目录 | `.deploy/evidence/` | `deploy/evidence/`（`.deploy/` 已改名 `deploy/`） |

## 执行环境（2026-09-28 起 · 优先级最高）
**本项目所有命令默认在 WSL Ubuntu 里跑**，不用宿主 Git Bash / PowerShell。
- 调用 `wsl -d Ubuntu -u root -- bash -c "..."`；**带引号/多行脚本先 Write 成文件再 `bash /mnt/e/.../x.sh`**（直传被 wsl.exe 拆坏）。
- ⚠️ **`/mnt/e` 文本是 CRLF** → `grep`/`awk`/命令替换读入残留 `\r` → 比对**必然假失败**（实测 `go.mod` 读成 `1.25.1\r`）→ **一律接 `tr -d '\r'`**；脚本写进 `/mnt/e` 后先 `sed -i 's/\r$//'`。
- ⚠️ **`bash -c` 不读 `/etc/profile.d/`**，`go env -w` 是 per-user → root 与 fanyan 各需一份。
- ⚠️ **`$?` 在 `bash -c "...; echo $?"` 里被吞成 0** → 判退出码用 `&& echo A || echo B`。`bash /mnt/e/x.sh`（不带 `-c`）会被 Git Bash 路径转换 → 必须 `bash -c "bash /mnt/e/..."`。
- ✅ Go 1.25.1（= `go.mod`）+ `GOPROXY=https://goproxy.cn,direct`，`bash -c` 下可用（`/usr/local/bin/go` 符号链接）。脚本 `E:\WSL\setup-wsl-dev-env.sh`（幂等）。
- ✅ **PATH 污染已清**：`/etc/wsl.conf` 加 `[interop] appendWindowsPath=false`（备份 `.bak-20260928-105604`）；`/mnt/` 条目 42→0，`cmd.exe` 不可调，`/mnt/c` 仍挂载；3 容器 `restart: always` 自动恢复。
- ⚠️ WSL 内**无 node/npm/bun/kubectl/helm**（`web/` 前端用 bun，需时装 Linux 版）。
- 路径：宿主 `E:\git_code\new-api-yxw` = WSL `/mnt/e/git_code/new-api-yxw`。**编译/装依赖别放 `/mnt/e`**（`/tmp` ext4 2.9 GB/s vs `/mnt/e` 421 MB/s，小文件差 78×）。
- 已就绪：git 2.34 · python3.10 · docker 29.8（compose v5.5）· curl/wget/rsync/unzip/make/jq/zip/tree。容器 `new-api`(:3000) · `postgres:15` · `redis`。

## 账号 / 端点
账号 `5108890064395960`（国际站）；主 region `ap-southeast-6`（马尼拉，仅 6a/6b），备 `ap-southeast-1`（新加坡）。域名 `api.likha.com` / `ops.likha.com`，通配证书 `*.likha.com`。
`aliyun` CLI **3.5.1** + `ossutil` **2.2.1** 已装 WSL `/usr/local/bin`；macOS 侧在 `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 `zsh -i -c`）。
- 凭证走**配置文件**（`~/.aliyun/config.json` + `~/.ossutilconfig`，600，root+fanyan 各一份，`site=international`）——**别依赖 `.bashrc` export**：Ubuntu `.bashrc` 非交互守卫提前 return → `bash -c`/`-lc` 读到 AK 长度 0，只有 `-lic` 才拿到。
- **RAM / resourcemanager / bssopenapi 必须 `--region ap-southeast-1`**；VPC/ECS/CR/SLS 必带 `--region`（只传 `--endpoint` 无效）。
- CLI 3.x 用 **kebab-case**（`aliyun sts get-caller-identity`）；`safety-policy` 默认 `enabled=false`。
- 脚本：`E:\WSL\setup-aliyun-toolchain.sh` · `configure-aliyun-creds.sh {china|international}`。

## 高频坑
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`；macOS grep 用 `-E 'A|B'`。
- 禁用变量名（macOS 只读内建）：`GROUPS` `UID` `EUID` `PPID` `RANDOM` `SECONDS` `PIPESTATUS` `BASH_*` `LINENO`。
- 函数日志必须 `>&2`；**脚本日志勿与 API 输出混流**（`say "+ cmd"` 写进重定向文件会污染 JSON → jq 假失败）→ 日志走 `exec 3>&2`，数据落文件。
- **权限探测严禁子串匹配**（`AccessDenied` 会出现在事件正文）；不能用不存在的资源 ID 探测 → 用幂等写。
- **资源 ID 前缀不代表地域**（`5ts`=马尼拉 / `t4n`=新加坡 纯属 ID 池巧合）→ 判「残留/串区」必须实查 API。
- **NAT / EIP 口径**：`CreateNatGateway` 必带 `--NatType Enhanced`（唯一合法值，漏掉 `MissingParameter`）；`AssociateEipAddress` 的 `InstanceType` 必须 **`Nat`**（写 `NatGateway` 返回误导性 `Invalid.DirectEip.BindType`）；`0.0.0.0/0 → NAT` 路由**系统自动加**，勿手工加；VPC 系分页用 `--PageSize`（`DescribeEipAddresses` 亦然）；路由 next hop 在 `.NextHops.NextHop[0]`。
- **NAT 写入有秒级时序**：`AssociateEipAddress` 后立刻 `CreateSnatEntry` 报 `OperationUnsupported.EipInBinding`/`EipNatGWCheck`，数秒后可成 → 写操作一律包重试。
- ⚠️ **VPC 端点两端皆偶发抖动**（mnl + sg）→ 任何写操作必须**重试 ≥3 次**并校验返回是合法 JSON，否则**静默漏建资源**。脚本：`deploy/task6_nat_eip.sh` · `deploy/task12_nat_eip_sg.sh`（均已实跑通过）。
- **`aliyun` CLI 3.5.1 命令口径（写命令前先看）**：
  - 参数名**只有 `--ProductCode`**（`--Product` 报 not valid）；`quotas` 分页 `--MaxResults`（`--PageSize` not valid）；`--QuotaCategory` 合法值 **`CommonQuota`**。
  - **配额按产品码分流**：vCPU/规格类在 **`--ProductCode ecs-spec`**（`q_ecs_enterprise_postpay_c`：马尼拉 64 · 新加坡 96）；`--ProductCode ecs` 只回 26 条通用配额。两者都必须带 `--Dimensions.1.Key regionId --Dimensions.1.Value <region>`，否则回 `cn-hangzhou` 假数据。申请参数拼写 `--DesireValue`。
  - **`Status: Agree` 只在 `ListQuotaApplications` 返回**；`ListProductQuotas` 的对象**无 Status 字段** → 用 `select(.Status=="Agree")` 过滤得**空集且 exit 0（假通过）** → 巡检一律 `jq -e` 或校验非空。
  - ClickHouse 列实例是 **`DescribeDBInstances`**（**无 `DescribeDBClusters`**，exit 2）。
  - jq 路径：`DescribeVpcs`→`.Vpcs.Vpc[]`；`DescribeVSwitches`→`.VSwitches.VSwitch[]`；`quotas`→`.Quotas[]`。跨字段必须 `[]|[a,b,c]|@tsv`。
  - 退出码：错 API 名/参数名 = 2；jq 语法错 = 3；`jq`（无 `-e`）遇空集 = 0。
  - `ram ListUsers` 全局服务不带 `--region` 也通。
- 一键复核：`deploy/verify_deploy_0_6.sh`（8 项全走 `jq -e`，空即 FAIL；`STRICT=1` 门禁用；输出 PASS/WARN/FAIL，原始响应落 `deploy/logs/verify_0_6_<ts>/`）。**`WARN` ≠ 通过**。当前长期 WARN：CK 未建（任务 29）· RAM 遗留 `zhangzijun`/`xiangdong`。

## 资源组
`rg-ph-mnl` `rg-aek4nyivmmsb6iy`｜`rg-sg` `rg-aek4zvb3ldoiyua`｜`rg-nonprod` `rg-aek4hk3prqgqjcy`｜`rg-shared` `rg-aek3yypouljf4ry`｜默认组**禁放** new-api 资源。RG 须**创建时**指定（vSwitch 无该参数但继承 VPC 组，不可单独换组）。

## RAM 治理
策略全 Custom，前缀 `newapi-`：admin-identity · ops-operator · cicd-acr-push · iac-terraform · dev-program · enforce-mfa · audit-protect · prod-boundary · prod-oss-guard。
**仅组级承载**（用户级绑定已全解）→ **禁止再 `AttachPolicyToUser`**。`enforce-mfa` 不管 AK；`prod-boundary`+`prod-oss-guard` = 生产写双重拦截。
七类角色 → 6 组：管理人员 `admin_group`｜财务 `fin_group`｜开发(人) `dev_group`｜开发程序 `dev-program_group`（纯 AK）｜初级运维 `ops_group`（生产只读）｜运维 Leader `ops-prod_group`（生产可写不可销毁）。
组备注唯一真源 = `deploy/ram_group_annotate.sh` 的 `comments_for()`，**apply 会覆盖控制台手工改动**。

## ACR（马尼拉）
`acr-newapi-mnl` = `cri-avfqy9xkqi5bj8ee` @ ap-southeast-6；公网 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`（VPC 域名加 `-vpc`）。命名空间：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vhffmm9qid60vomq`。
- **ARN 铁律**：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repo]`，**无 `namespace/` 前缀**。`newapi-cicd-acr-push` 已修 v2。
- tag 不可变两层：命名空间默认配置（仅对自动建仓生效）+ 仓库自身 `TagImmutability`（**真正生效层**）。四命名空间 `AutoCreateRepo=false` → 仓库必须显式 Create；cicd 未授 `cr:CreateRepository`。
- ⚠️ **仓库口径不一致**：实况 `newapi-prod` 下按主备分仓 `newapi-master` / `newapi-slave`，且 **`newapi-master` = PUBLIC**（与「指向 `new-api` 单仓」口径冲突，且生产镜像公开可读）→ 待定口径 + 改回 PRIVATE。
- **VPC 端点尚未关联马尼拉 VPC**（`GetInstanceVpcEndpoint` → `LinkedVpcs=[]`）→ VPC 内拉取不通，任务 16 有欠写操作。

### ⚠️ docker login/push 排障顺序（踩过两轮，务必按序查）
1. **公网入口**默认 `Enable=false` → 无 DNS、报 `Get "https://<域名>/v2/": EOF`。开：`cr UpdateInstanceEndpointStatus --EndpointType internet --Enable true`（异步 1–2 min）。
2. **公网 ACL**（第二轮真凶）：入口开启后系统预置 `127.0.0.1/32` 占位 → 真实 IP 全被拒（EOF / 直连 **timeout 非 reset**）。**ACL 无总开关**（只有 Create/Delete）；**白名单为空 = 全放行**；**拒收 `0.0.0.0/0`**（`INSTANCE_ACCESS_ACL_ENTRY_INVALID`）→ `--allow-ip all` = `0.0.0.0/1` + `128.0.0.0/1`。控制台：实例详情 → **仓库管理 > 访问控制 > 公网**（Helm Chart 走 **Helm Chart > 访问控制**）。
3. 金标准：`curl -sv https://<域名>/v2/` 返 **401**。

## 镜像发布 `push.sh`（仓库根）
`./push.sh -n prod|pre|test|dev -t <tag>`，login→build→tag→push + 逐阶段计时；日志 `deploy/logs/`。
选项：`--open-endpoint` · `--allow-ip <cidr|auto|all>` · `--create-repo` · `-f <df>`/`--upstream` · `--npm-registry cn|official|<url>`（默认 cn）· `--go-proxy cn|aliyun|official|<url>`（默认 cn）· `--proxy <url|auto>` · `--no-proxy` · `--prune` · `--min-disk <GiB>` · `--skip-disk-check` · `--no-build`/`--build-only`/`--dry-run`。
**Dockerfile 自动选择**：未显式 `-f` 且存在 `Dockerfile.mac` → 用它；`--upstream` 强制上游原版。登录失败自动分流诊断（核对入口 Enable + ACL 白名单）。
坑：本机 `tee` ≈0.6s/次 → 逐行日志**不用 tee**（stderr + append）；交互式 `read -rs` 必须在 `--dry-run` 早退之后。

### Docker 构建环境（macOS，2026-09-27 固化）
- 虚拟盘上限 = `settings-store.json` 的 `DiskSizeMiB`（原 16 GiB 撞满 → `ResourceExhausted`，**已扩 64 GiB**）；改配置须 `docker desktop stop` → 改 → `start`（沙箱 `osascript` 报 -10004）。
- 镜像加速器在 **`~/.docker/daemon.json`**：USTC / 163 **已停服** → 用 `docker.m.daocloud.io` + `docker.1ms.run` + `docker.1panel.live`。
- **上游 `Dockerfile` 保持原版勿改**；本地增强在 **`Dockerfile.mac`**（`ARG NPM_REGISTRY` + `ARG GOPROXY` + bun/go cache mount），默认自动选用（冷构建 7m17s / 缓存命中 46.8s–1m19s，镜像 222 MB）。
- ⚠️ **Go 模块源 = 本地构建最常见硬失败点**：无 `GOPROXY` → 走 `proxy.golang.org`（`storage.googleapis.com` 承载）→ 直连超时，`RUN go mod download` 报 **`…": EOF`（不是 403，极易误判为构建逻辑问题）**。修：加 `ARG GOPROXY=https://goproxy.cn,direct`。对照：**npm 官方源只是慢（1041s 能成），Go 官方源是直接失败**。
- `--proxy auto` = 注入 Docker **预定义 ARG**（`HTTP(S)_PROXY`/`NO_PROXY`，**免声明**）= 零改动换源；`NPM_REGISTRY`/`GOPROXY` 这类**自定义变量必须 `ARG` 声明**才生效。

## Day 1 进度 · 任务 4 RDS（2026-09-28 实测）
- **包年包月口径**：`PayType=Prepaid` + **`Period=Year` / `UsedTime=1`**（= 12 月）。⚠️ **月付周期上限 <12** → `Period=Month`+`UsedTime=12` 报 `Order.PeriodInvalid`（文案不提"上限"，极易误判为参数名错）。三产品计费参数名**不同**：ECS `InstanceChargeType` · Tair `ChargeType` · RDS `PayType`。
- **规格/价（ap-southeast-6）**：`pg.x4.2xlarge.2c` = **16核64GB（独享）**；PG 16.0；100G ESSD PL1。标价 **15134.47 USD/年 → 实付 10594.13**（折扣 4540.34 ≈30%，月均 882.84）；月单价 1261.21；按量 2.63232 USD/h（月 1921.59）→ **包年包月省 ≈54%**（≠ECS 的 18%）。
- **可售**：Prepaid 规格 73 个（6a/6b 各 73）；`cloud_essd`/`essd2`/`essd3` 各 73，**`cloud_ssd`/`local_ssd` = 0**；PG 17.0/16.0/15.0 各 73。
- ⚠️ **RDS 无配额闸门**：配额中心 `--ProductCode rds` 报 `PARAMETER.ILLEGALL`（`CommonQuota` 也不行，指南原写 `CommonConfig` 非法）→ 改用「Prepaid 可售规格 + 存量实例」双验。
- ⚠️ **`DescribePrice` 的 `CommodityCode` 会反转口径**：`bards`=按量码，给 Prepaid 查询会强制按量计价（三档价全等于小时价 2.63232，看着像"无折扣"）；`Postpaid` **不带** `CommodityCode` 则 `PriceInfo` 全 `null`（静默）。正确：Prepaid 用 `--CommodityCode rds`（`rds_intl`），Postpaid 用 `bards`（`bards_intl`）；自校 `.chargeType`（1=订阅/2=按量）。
- ⚠️ **`AutoPay=false` 下单成功 ≠ 实例创建**：返回含预分配 `DBInstanceId` 但 `DescribeDBInstances` 查不到（**正好可作零成本试单**）。`CreateDBInstance` 必填 **9 参数**（含易漏的 `DBInstanceNetType`）；`--AutoRenewPeriod` **不是合法参数**。`ClientToken` 只对同 token 幂等 → 脚本须另查 `QueryOrders ... Unpaid` 拒绝重复下单。
- **风控差异（重要）**：余额 0 时 **RDS 下单不被拦**（只有 ACK 服务开通被 `RISK.RISK_CONTROL_REJECTION` 拦）→ 任务 4 解除路径 = 充值后直接支付订单，无需先解风控。
- 产物：脚本 `deploy/task4_rds_mnl.sh`（`verify|price|create|create-pay|check|tag|all`，双重幂等闸门 + PATH 自愈）· 报告 `deploy/Day1任务4_RDS_PostgreSQL_执行报告.md`。**未创建任何计费资源**；产生 1 张未支付订单 `518158947970481`（应付 10594.13），预分配 `pgm-5ts8mee1iiw13m89`。
- ⚠️ **F11 口径待裁决**：官方规格表标 `pg.x4.2xlarge.2c` 的 `max_connections = 6400`，与 F11 的 800 差 8 倍 → 实例 Running 后必须 `SHOW max_connections;` 定论（若 6400，任务 41 的 640 预算过度保守）。
- ⚠️ **Tair 实况与指南不符（本轮查订单时发现）**：`r-5tsf1fe16543e274` `tair-mnl-newapi` **已购且已转 PrePaid**（订单 `518158662490481` Convert 64.63 USD 已支付），但 ① 只买 **1 个月**（到期 **2026-10-28**，2026-11-27 释放）非 12 月；② 规格是 **企业版 amber 逻辑多线程 1G/2DB/6proxy**（指南写"标准版 4GB 主从"）；③ 仅 `ap-southeast-6a`，未见 6b 备。**待用户确认口径**。

## Day 2 进度（2026-09-28 实测）
- **任务 10 未做**：两地 ACK 集群 `total_count=0` → 任务 11 无 `cluster_id`。脚本 `deploy/task10_11_ack_mnl.sh {verify|keypair|cluster|nodepool|kubeconfig|check|all}`（幂等 + 计时日志 `deploy/logs/task10_11_*.log`）；节点 `user_data` = `deploy/task11_node_init.sh`（nofile 三处 + 数据盘兜底）。报告 `deploy/Day2任务11_ACK节点池_执行报告.md`。
- 任务 11 Step 1 ✅：`ecs.g9i.2xlarge` **6a+6b 双 AZ 可售**（备 g8ine/g9ae 亦双区）；配额 64 `Agree`；**Terway Pod 容量 = (EniQuantity-1)×IPs：g9i=45 · g8ine=75 · g9ae=45**。
- ⚠️ **指南 C1 校正**：`kubernetes_version` 写 `1.35.0-aliyun.1` **已不可创建** → 马尼拉 creatable 仅 `1.36.2-aliyun.1` / **`1.35.7-aliyun.1`** / `1.34.10-aliyun.1`（ACK 规则：同 minor 出新 patch 后旧 patch 禁建）。
- ⚠️ **CS CLI 传参**：`DescribeKubernetesVersionMetadata` 必须用 **`--Region`**（`--region`/`--RegionId` 均报 `MissingRegion`）；其余 CS API 用 `--region`。
- ⚠️ **建簇两处指南漏项（2026-09-28 实跑 400 实测）**：① `pod_vswitch_ids` **必填**（漏 → `MissingPodVswitchIds`，Terway 下 Pod 网络须有 vSwitch；且该错误与其它错误**同时**出现在 `data[]` 数组，排查勿只看首条）；② 须先开通 ACK 服务 → `aliyun cs OpenAckService --type propayasgo`（**仅 `propayasgo` / `edgepayasgo` 两个合法值**），未开通报 `ErrorNotEnabled: please enable cskpro`。脚本已加开通预检硬门禁。
- ⛔ **余额 0 的第一道墙 = 风控，不是欠费**：`OpenAckService` 返回 `RISK.RISK_CONTROL_REJECTION`（*"your order is suspended… contact Customer Service"*）→ 付费服务开不出来，比资源创建失败更早一步，文案**不明说余额**。处置：充值 + 必要时联系客服。
- ECS 密钥对已建 `newapi-mnl`（指纹 `732340d017cd1b1297b4d2c547327520`，私钥 `~/.ssh/newapi-mnl.pem` 600）——**地域级资源，新加坡需另建**。
- ⚠️ 脚本坑复现：`say "...：$pem（..."` 全角括号紧贴变量 → bash 3.2 并入变量名报 `unbound variable`（3 处）。**写法先行全脚本扫描**（python 正则查 `\$VAR` 后跟 `>127` 字符）。

## 付费方式（2026-09-28 用户指令修订）
**ECS 节点池 + Tair 实例 = 包年包月（`PrePaid`，1 年 + 自动续费）**；**ACK 集群管理费官方口径「不支持转为包年包月」** → 等价手段 = **ACK 资源包**抵扣（小型 720 集群小时 / 大型 8,640 集群小时）。
- **配额口径整体切换**：包年包月 `q_ecs_enterprise_prepay_c`（马尼拉 **100** / 新加坡 **100**，实测默认值、无需工单）vs 按量 `q_ecs_enterprise_postpay_c`（64 / 96，工单 `Agree`，**现仅作对照**）——**两套独立计量、互不抵扣**；新加坡 96/100 **仅余 4 vCPU**。
- 实测价（ap-southeast-6）：`ecs.g9i.2xlarge` 包月 **217.17 USD/台/月** + 系统盘 100G ESSD PL1 15.20 + 数据盘 300G 45.60 → 4 台 1 月 **1111.88 USD**（按量约 1136/月，**包月省 ≈18%**）；Tair 4GB `redis.master.stand.default` 包月 **58.75 USD/月**（`r-kvstore DescribePrice --ChargeType PrePaid --Period 1 --Capacity 4096`）。
- **新坑（已写进指南任务 11）**：① 节点池付费类型决定扩容实例计费 → **HPA 扩容即按 12 个月预付、缩容不退款**（最坏 8 台×1 年）；② 包年包月库存池与按量**不共享** → 机型可售查询必须 `--InstanceChargeType PrePaid`；③ ACK 官方：**已存在数据盘勿勾选转包年包月**（"包年包月云盘无法支持容器应用重启"），转包月只转实例/系统盘。
- 指南 `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` **原地修订 18 处**，备份 `.bak-20260928-214157`；修订记录 `deploy/付费方式修订记录-2026-09-28.md`。顺手修正两处硬错误：K8s `1.35.0-aliyun.1` → **`1.35.7-aliyun.1`**（同 minor 出新 patch 后旧 patch 禁建）、建簇 body 缺 **`pod_vswitch_ids`**（实测 400 `MissingPodVswitchIds`）。
- 脚本 `deploy/task10_11_ack_mnl.sh` 同步 PrePaid + 新增 **PATH 自愈**（直接 `./deploy/...` 可跑，不依赖调用者 export）。

## 配额 / 成本
配额按节点池 **`max_size`** 申请（马尼拉 64 = 8×8 vCPU；新加坡 96 = 12×8，v2.3 版拟降 64——**以 ① 指南为准仍 96**）；状态 `Agree`；两地分单。机型 `g9i.2xlarge`（g8i 未上架）；地域须用维度传。
常态 **9,865.36 USD/月**（4+2 节点）· 接管峰值 15,322.51 · 备站冗余 623.90（6.32%）。单价常量在 `deploy/gen_cost_table.py` 顶部。ECS 询价**系统盘参数必填**；BSS 只能走 `business.ap-southeast-1.aliyuncs.com`。**账户余额 0.00 USD**（欠费回收 EIP 风险真实）。

## 切换（SLA）
`0.9999^5≈0.9996` → 月不可用 17.28 min，仅余 4.32 min。GTM 判定 45–60s 可控，**DNS 传播 5–30 min 不可控**；GTM 是**主备 failover 不是分摊**；可用 IP 最小阈值 = **1**。正解 = **DCDN 回源层切换**（RTO 10–20s，+74 USD/月）。

## 安全组（SG）★ 已提前落地（2026-09-29）
5 个业务 SG **已建**（早于任务 22 排期 D5）；台账 `deploy/sg_ledger.md`、幂等脚本 `deploy/task22_sg_bootstrap.sh`（`--verify` 核对 / `--dry-run` 空跑）。
`sg-mnl-alb`=`sg-5tsj1epvcjjv6jkg3zks`｜`sg-mnl-app`=`sg-5tsil3ca5dfkqefks1g9`｜`sg-mnl-db`=`sg-5tsawhljdqzwo2t0n4ut`｜`sg-sg-alb`=`sg-t4nbgfbh2cidnve88avf`｜`sg-sg-app`=`sg-t4n0qnhy8mxq9g733r67`。
⚠️ **入向/出向是两个 API**：`AuthorizeSecurityGroup` **只加持入向**，用它建出向**返回 RequestId 却一条不落** → 出向必须 `AuthorizeSecurityGroupEgress`；参数用 `Permissions.N.*`（flat 形式已 Deprecated）。
判成功**不能只 grep `"Code"`**：CLI 失败是 `ERROR: SDK.ServerError` + 文本行 `ErrorCode:`（非 JSON）。`Permissions.N.*` 下重复规则**静默去重、不报 Duplicate** → 区分「新增/已存在」只能**前置比对**。查询失败**绝不可当"不存在"**（v1 因此重复建了一个 `sg-mnl-app`）。
真正控制点 = 数据层侧**入向组引用**（`sg-mnl-db in ← sg-mnl-app`）；出向到 RDS/Tair 用 `DestCidrIp`（托管实例 SG 云产品自管、绑不上就是静默失效）。

## ACK 集群（马尼拉 + 新加坡 · 任务 10 / 24 已落地）
`ack-newapi-mnl` = **`cd57e40ce9a634c1698c2f5c5e09bd93c`** @ ap-southeast-6；`ack.pro.small` / k8s `1.35.7-aliyun.1` / `ManagedKubernetes`+`profile=Default` / RG `rg-ph-mnl`；CNI `terway-eniip` v1.17.7（`ENITrunking=false`）· `ipvs` · ServiceCIDR `172.21.0.0/20`；私网端点 `https://10.0.22.182:6443`，**公网端点未开**（`PublicSLB=false`）；删除保护 on；自动升级 `stable` + 维护窗口周二 03:00–06:00（Asia/Manila，**API 可配，无需控制台**）。创建 3m39s，终验 28/28 PASS。
- **RRSA on**：`oidc_arn=acs:ram::5108890064395960:oidc-provider/ack-rrsa-cd57e40ce9a634c1698c2f5c5e09bd93c`；`issuer` 在 `oidc-ack-ap-southeast-6.oss-…aliyuncs.com/<cid>`。**region 级资源 → 新加坡必须另建一套**（任务 17 用）。
- 依赖资源（ACK 自建，**均继承集群 RG**）：集群安全组 `sg-5tsaatp5w68vyqszezja` · 内网 SLB `lb-5ts6qwxumktojy2qs3omu`（名 `ManagedK8SSlbIntranet-<cid>`，**是 SLB 不是 ALB**）· SLS 审计项目 `k8s-log-<cid>`。
- 台账 `deploy/ack_ledger.md` · 脚本 `deploy/task10_ack_mnl.sh`（幂等 `--dry-run`，body 写死 RG + 终验资源组断言）· 回写工具 `deploy/patch_ack_task10.py`。
- **★ 硬坑 1｜漏 `resource_group_id` → 静默落 default 组**（`rg-acfnssmgwnsb5oa`，**无任何报错**），且 **ACK 集群不支持资源组迁移**（`MoveResources` → `UnsupportedOperation.MoveResources`，四种 Service/ResourceType 组合全拒）→ **唯一解法是关删除保护后删除重建**。空集群重建零成本，已建节点池则完全不同。
- **★ 硬坑 2｜删集群 ≠ 清干净**：内网 SLB / 集群安全组 / SLS 审计项目是独立资源；带对 RG **重建**才会继承（实测三项全进 rg-ph-mnl），且 `DeleteCluster` **不删** `k8s-log-<旧cid>`，须手工 `aliyun sls DeleteProject`。
- **★ SLA 口径更正（重要）**：ACK SLA（生效 2023-04-01）§1.4/§1.5 —— **regional = 地域 AZ 数 ≥3**、**zonal = AZ 数 ≤2**、§2.2 承诺 99.95% / **99.50%**。**马尼拉只有 2 个 AZ → 恒为 zonal、控制面 99.50%（月不可用上限 ≈3.6h），没有任何创建选项能提升**；且 ACK 控制面**不在** §8.2 五项串联链（`impl_deploy_fix.md:751-772`）内 → 8.2 不受影响。原指南「选 regional 得 99.95%，否则 8.2 从根上错」**双重误判，已在 4 份文档更正**。对冲：控制面停摆不影响已跑 Pod，但部署/扩缩容/HPA 会停。
- **新加坡（任务 24）**：`ack-newapi-sg` = **`ca75829e3492d491d9d434de087913798`** @ ap-southeast-1；同规格（`ack.pro.small` / k8s `1.35.7-aliyun.1` / terway `ENITrunking=false` / ipvs）· RG `rg-aek4zvb3ldoiyua` · VPC `vpc-t4nimmwvruexbnene0a3r` · 双 vSwitch 1a/1b · **ServiceCIDR `172.22.0.0/20`（刻意与马尼拉错开，建后不可改）** · 160s running · 终验 12/12 PASS。密钥对 `newapi-sg`（跨 region 不共享，`DescribeKeyPairs` 不回读公钥体 → 只能 `ImportKeyPair`）。`AliyunOOSLifecycleHook4CSRole` 是**账号级** → 两地共享。控制面 SG `sg-t4nevyfflaeo3tdvi510` **同构复现「只有 ICMP、无 6443」** → 建节点池前已提前放行（报障补充材料用）。

## 节点池（马尼拉 + 新加坡 · 任务 11 / 24）+ 私网运维通道 ★

- 节点池 `npaad418131aa84c899be022b5463d13bf`（`np-mnl-app` / ess / `rg-ph-mnl`）· ESS `asg-5tsd68ew4u0wutaqk5cy`（min4/max8 `BALANCE`）· 4 台 `ecs.g9ae.2xlarge`（8C32G）· **4/4 `Ready`，6a:2 / 6b:2** · 节点标签 `site=ph-mnl`+`track=stable` · 节点 SG `sg-5tsil3ca5dfkqefks1g9`。台账 `deploy/nodepool_ledger.md`；M2 证据 `deploy/d2/nodes-zones.txt`、`deploy/d2/node-fd-limit.txt`（`ulimit -n`=**262144** ≥200000）。
- ★★ **控制面安全组必须放行 6443**：ACK 自建的 `sg-5tsaatp5w68vyqszezja`（**即集群安全组**，名 `alicloud-cs-auto-created-security-group-<cid>`）实测**只有一条 ICMP 入方向规则** → ① 4/4 节点 bootstrap 全挂（`FailGetKubeVersion`，卡满 606s）；② Terway 经 ClusterIP 连不上 API Server → 永远 `NotReady`。修 = `AuthorizeSecurityGroup` 放行 `TCP 6443 ← <VPC CIDR>`。**任务 24（新加坡）建完集群第一件事就核对这条**。工单文本 `deploy/工单_ACK马尼拉控制面安全组缺失.md`。
- ★ **私网通道（替代「等任务 46 堡垒机」）**：① **云助手** `aliyun ecs RunCommand --Type RunShellScript --ContentEncoding Base64`（**不是 `Shell`**）→ `DescribeInvocationResults`（`Output` 需 b64 解码；默认不持久化命令对象，无需清理；马尼拉偶发空 `InvokeId` → 重试一次）；② **admin kubeconfig** `aliyun cs DescribeClusterUserKubeconfig --ClusterId <cid> --PrivateIpAddress true` → `server` = 可用 VIP，解 `ca/crt/key` 落 PEM 后**在节点内用 curl 直连 REST API**。通用执行器 `E:\WSL\np11_run_remote.sh <node> <body.sh> [loops]`。
- **口径铁律**：`ping` 通 **≠** 端口通（ICMP 可能在白名单里）；`curl (7) timed out` **≠** DNS 问题（`(6)` 才是）；节点可用性**必须**用 `kubectl get nodes` 验证 —— 控制台「失败」列映射的是 `offline_nodes`，**不是 `failed_nodes`**（配置项全绿 ≠ 功能可用，本卡踩过）。
- 回写工具：`deploy/patch_task11_nodepool.py` · `deploy/patch_task11_ledger.py` · `deploy/patch_task11_verify.py`（均幂等，`--check` / `--apply` + 自动备份）。
- **新加坡（任务 24）**：池 `npab9d46aefe3a4649b074543f36f32599`（`np-sg-ph-standby` / ess `asg-t4ngzbg7m9u84y59dkxl`）· `min2/max12` · 1a:1 / 1b:1 · 终验 17/17 PASS。**机型顺序 `ecs.g9ae,ecs.g9i,ecs.g8ine` —— 两区都在售的必须排首位**（1b 无 g9i）。封装脚本 `deploy/task24_nodepool_sg.sh` **薄封装复用 `task11_nodepool_mnl.sh` 同一份逻辑与 user_data**；标签 `site` 直接写进建池 body。终验阈值已参数化（`MIN_PER_ZONE` MNL=2 / SG=1）。
- ★★ **跨区均衡的独立开关 `AzBalance`（两集群通用坑，2026-09-29）**：**`MultiAZPolicy=BALANCE` ≠ 开启跨区均衡**——ESS 有**独立 bool `AzBalance`**，**ACK 建池时不设置它**；只设策略时创建阶段**完全不跨区均衡**，会顺「有库存的交换机」全塞一个区。该字段 **`DescribeScalingGroups` 不回读**（48 个返回字段里没有）且**经 ACK 改池后可能被覆盖** → 只能**幂等重设 + 用实例可用区分布间接验证**，改池后要**再断言**。马尼拉其实也是关的（6a:2/6b:2 纯属运气），已一并补正。修复：**`deploy/nodepool_azbalance_fix.sh {mnl|sg}`**。配套：`BalanceMode` 取 `BalancedBestEffort`（可用性优先）；`AutoRebalance=true` 可对已失衡分布再均衡（实测 ~3 min 收敛）。
- ★ **删节点池竞态**：`MinSize/MaxSize/DesiredCapacity=0` 是**异步**的，实例先进 `Removing:Wait`，**实测 ~6–7 min** 才释放；ACK 删除流程早已跑完 → 报 `ScalingGroup's instances not empty` → 池变 `delete_failed`。**必须轮询 `TotalCapacity==0` 再删**（+ `GroupDeletionProtection false`，ROA DELETE 不能带 `--force`）。

## SLS / 文档 / 网络
- SLS：`sls-newapi-mnl`（`rg-ph-mnl`）· `sls-newapi-sg`（`rg-sg`），各 7 logstore（ttl30 ×6 + `app-file-audit` ttl180）。`aliyun sls` 是 ROA 风格（无 `--ProjectName`、必带 `--region`；`GetLogStore` 用 path 参数 `--logstore`）。
- 文档：`deploy/用户设置指南.md` 单文件自包含（内联 SVG，GitHub 网页版会过滤）；改图三步、术语口径、双份同步要求见 REFERENCE。
- 网络**勿改**：马尼拉 `10.0.0.0/16`（6 vSwitch）· 新加坡 `10.1.0.0/16`（4 vSwitch）；Terway 每 Pod 占真实 VPC IP → app 段免费 IP 基线 4092，**低于 200 告警 P2**。完整 CIDR 见 REFERENCE / 指南 §2.2。
