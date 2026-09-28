# new-api 菲律宾部署 · 项目长期约定（索引版）

> 详版口径与全部坑 → `.workbuddy/memory/REFERENCE.md`；过程流水 → `YYYY-MM-DD.md`。
> 权限权威 `deploy/用户设置指南.md`；切换方案 `deploy/DCDN回源层切换_方案.md`。

## 执行环境（2026-09-28 起 · 优先级最高）
**本项目所有命令默认在 WSL Ubuntu 里跑**，不用宿主 Git Bash / PowerShell（fanyan 指定）。
- 调用：`wsl -d Ubuntu -u root -- bash -c "..."`；**带引号/多行脚本先 Write 成文件再 `bash /mnt/e/.../x.sh`**（直传会被 wsl.exe 拆坏）。cwd 自动继承并转换。
- ⚠️ **`/mnt/e` 下的文本是 CRLF** → WSL 里 `grep`/`awk`/命令替换读进来残留 `\r`，比对/拼接**必然假失败**（实测 `go.mod` 的 `go 1.25.1` 读成 `1.25.1\r`）。**一律接 `tr -d '\r'`**。
- ⚠️ **`bash -c` 不读 `/etc/profile.d/`**，且 `go env -w` 是 per-user（写 `$HOME/.config/go/env`）→ root 与 fanyan 各需一份。
- ✅ **Go 已开箱可用（2026-09-28 验收）**：`go1.25.1`（与 `go.mod` 完全一致）+ `GOPROXY=https://goproxy.cn,direct`；`bash -c` 下也能直接用（靠 `/usr/local/bin/go` 符号链接）。实测 `go get gin@latest` 拉全部依赖 **3.0s**（`proxy.golang.org` 则完全不通）。脚本 `E:\WSL\setup-wsl-dev-env.sh`（幂等）。
- ⚠️ **WSL 内暂无 `node`/`npm`/`bun`/`kubectl`/`helm`**（原生版未装）；关掉 Windows PATH 注入后，**Windows 侧那套 node/npm/bun 也不再「假可用」** → 需要时须装 Linux 版（`web/` 前端用 bun）。`aliyun` CLI / `ossutil` 同样只在 macOS 侧。
- ✅ **PATH 污染已清（2026-09-28）**：`/etc/wsl.conf` 已加 `[interop] appendWindowsPath = false`（备份 `/etc/wsl.conf.bak-20260928-105604`）；PATH 中 `/mnt/` 条目 **42 → 0**，`cmd.exe` 不再可调，`/mnt/c` 挂载仍保留。3 个容器 `restart: always`，WSL 重启后自动恢复。
- 路径：宿主 `E:\git_code\new-api-yxw` = WSL `/mnt/e/git_code/new-api-yxw`。
- **WSL 已就绪**：git 2.34 · python3.10 + pip26 · docker 29.8（含 compose v5.5）· curl/wget/rsync/unzip。已跑容器 `new-api`(:3000 healthy) · `postgres:15` · `redis`。
- ⚠️ **Go 已装在 `/usr/local/go`，但 `/usr/local/go/bin` 不在 PATH** → `go` 命令找不到；`GOPROXY` 也未设。
- ⚠️ **WSL 里 `proxy.golang.org` 彻底不通**（curl 返回 000）→ 构建**必须** `GOPROXY=https://goproxy.cn,direct`（与 macOS 侧 §Docker构建 同一个坑）。其余 github / npm / 阿里云镜像 / ACR 公网域名均 200。
- ⚠️ **PATH 被 Windows 严重污染**（`/etc/wsl.conf` 无 `[interop]` 段 → `appendWindowsPath` 默认 true，灌入 50+ 条 `/mnt/c|d|e/...`）：在 WSL 里 `npm` 会解析到 **Windows 版**、`node` 反而找不到。根治 = `/etc/wsl.conf` 加 `[interop] appendWindowsPath=false`（**需 `wsl --shutdown`，会重启上述容器**）。
- 缺：`make` `jq` `helm` `kubectl` `bun`。
- 磁盘：`/tmp`(ext4) 2.9 GB/s vs `/mnt/e` 421 MB/s；小文件差距更大（历史实测 78×）→ **编译/装依赖别放 `/mnt/e`**。宿主 28 核 / WSL 15 GiB。
- ✅ **阿里云工具链已在 WSL 就绪（2026-09-28）**：`aliyun` CLI **3.5.1** + `ossutil` **2.2.1**，均在 `/usr/local/bin/`。
  - 凭证：`~/.aliyun/config.json` + `~/.ossutilconfig`（权限 600），**root 与 fanyan 各一份**；`site=international`、默认 region `ap-southeast-6`。
  - ⚠️ **凭证别依赖 `.bashrc` 的 export**：Ubuntu `.bashrc` 第 6 行 `case $- in` 守卫会让**非交互 shell 提前 return** → 实测 `bash -c` / `bash -lc` 读到的 `ALIBABA_CLOUD_ACCESS_KEY_ID` 长度都是 **0**，只有 `bash -lic`（强制交互）才拿得到。**故一律走 CLI 配置文件**（与 shell 解耦）。
  - 实测通过：`sts get-caller-identity` → `acs:ram::5108890064395960:user/yanxuewei` · `resourcemanager list-resource-groups`（含 `rg-ph-mnl` = `rg-aek4nyivmmsb6iy`）· `bssopenapi query-account-balance` · `ossutil ls`（3 桶）。
  - **CLI 3.x 用 kebab-case**：`aliyun sts get-caller-identity`、`aliyun resourcemanager list-resource-groups`。`safety-policy` 默认 `enabled=false`（不阻塞脚本）。
  - 脚本：`E:\WSL\setup-aliyun-toolchain.sh`（装）· `E:\WSL\configure-aliyun-creds.sh {china|international}`（配，密钥不经命令行、不打印）。

## 账号 / 端点
账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b），备 `ap-southeast-1`（新加坡）。
`aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 `zsh -i -c`）；OSS 用 `ossutil` v2。
**RAM / resourcemanager / bssopenapi 必须 `--region ap-southeast-1`**；VPC/ECS/CR/SLS 必带 `--region`（只传 `--endpoint` 无效）。

## 高频坑
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`；`set -u` 下 `local x y` 未赋值即 unbound。
- 函数日志必须 `>&2`（否则 `ID=$(f)` 把日志吞进变量）；macOS grep 用 `-E 'A|B'`（不认 `\|`）。
- 禁用变量名（macOS 只读内建）：`GROUPS`(=20) · `UID` · `EUID` · `PPID` · `RANDOM` · `SECONDS` · `PIPESTATUS` · `BASH_*` · `LINENO`。
- **权限探测严禁子串匹配**（`AccessDenied` 会出现在事件正文）；不能用不存在的资源 ID 探测（存在性校验先于鉴权）→ 用幂等写。
- **NAT / EIP 口径（2026-09-28 实测）**：`CreateNatGateway` 必带 `--NatType Enhanced`（唯一合法值，漏掉报 `MissingParameter`）；`AssociateEipAddress` 的 `InstanceType` 必须是 **`Nat`**（写 `NatGateway` 会返回误导性的 `Invalid.DirectEip.BindType`）；`0.0.0.0/0 → NAT` 路由**由系统自动加**，勿手工加；VPC 系 API 分页用 `--PageSize`（不是 `--MaxResults`）；路由条目 next hop 在 `.NextHops.NextHop[0]`（非顶层）。
- ⚠️ **ap-southeast-6 端点偶发 `context deadline exceeded`** → 任何写操作必须包**重试 ≥3 次**并校验返回是合法 JSON，否则会**静默漏建资源**（实测 EIP 绑定、SNAT 查询、首条 SNAT 创建各失败过一次）。
- ⚠️ **脚本日志勿与 API 输出混流**：`say "+ cmd"` 若写进重定向文件会污染 JSON → jq 假失败。日志走 `exec 3>&2`，数据落文件。
- **`aliyun` CLI 3.5.1 命令口径（2026-09-28 全量实测，写命令前先看这里）**：
  - 参数名：**只有 `--ProductCode`**（`--Product` 报 not valid）；`quotas` 分页是 `--MaxResults`（`--PageSize` 报 not valid）；`--QuotaCategory` 合法值 **`CommonQuota`**（`Common` 报 `InvalidQuotaCategory`）。
  - **配额按产品码分流**：vCPU / 规格类配额在 **`--ProductCode ecs-spec`**（`q_ecs_enterprise_postpay_c` = vCPU 额度，马尼拉 64 · 新加坡 96）；`--ProductCode ecs` 只回 26 条通用配额，**查不到 vCPU**。两者都必须带 `--Dimensions.1.Key regionId --Dimensions.1.Value <region>`，否则回 `cn-hangzhou` 假数据。
  - **`Status: Agree` 只在 `ListQuotaApplications` 返回**（申请值字段是 `DesireValue`）；`ListProductQuotas` 的对象**没有 Status 字段**。用 `ListProductQuotas | select(.Status=="Agree")` 过滤 → 空集且 **exit 0**，脚本会**假通过**；巡检一律加 `jq -e` 或校验非空输出。
  - ClickHouse 列实例是 **`DescribeDBInstances`**，返回 `{"Data":{"DBInstances":[...],"TotalCount":n}}`；**不存在 `DescribeDBClusters`**（exit 2）。
  - jq 路径：`vpc DescribeVpcs` → `.Vpcs.Vpc[]`；`DescribeVSwitches` → `.VSwitches.VSwitch[]`；`quotas` → `.Quotas[]`（**不是** `.Quotas.Quota[]`）。跨字段必须 `[] | [a,b,c] | @tsv`，写成 `[][a,b]` 会报 `Cannot index object`。
  - 退出码：错 API 名 / 错参数名 = **2**；jq 语法错 = **3**；`jq`（无 `-e`）遇空集 = **0**（静默）。
  - `ram ListUsers` 是全局服务，不带 `--region` 也通；`resourcemanager` / `bssopenapi` 仍须 `--region ap-southeast-1`。

## 资源组
`rg-ph-mnl` `rg-aek4nyivmmsb6iy`｜`rg-sg` `rg-aek4zvb3ldoiyua`｜`rg-nonprod` `rg-aek4hk3prqgqjcy`｜`rg-shared` `rg-aek3yypouljf4ry`｜默认组**禁放** new-api 资源。
RG 须**创建时**指定（vSwitch 无该参数但继承 VPC 组；不可单独换组）。

## RAM 治理
策略全 Custom，前缀 `newapi-`：admin-identity · ops-operator · cicd-acr-push · iac-terraform · dev-program · enforce-mfa · audit-protect · prod-boundary · prod-oss-guard。
**仅组级承载**（用户级绑定已全解）→ **禁止再 `AttachPolicyToUser`**。`enforce-mfa` 不管 AK；`prod-boundary`+`prod-oss-guard` = 生产写双重拦截。
七类角色 → 6 组：管理人员 `admin_group`｜财务 `fin_group`｜开发(人) `dev_group`｜开发程序 `dev-program_group`（纯 AK）｜初级运维 `ops_group`（生产只读）｜运维 Leader `ops-prod_group`（生产可写不可销毁）。
组备注唯一真源 = `deploy/ram_group_annotate.sh` 的 `comments_for()`，**apply 会覆盖控制台手工改动**。

## ACR（马尼拉）
`acr-newapi-mnl` = `cri-avfqy9xkqi5bj8ee` @ ap-southeast-6；公网域名 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`（VPC 域名加 `-vpc`）。
命名空间：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vhffmm9qid60vomq`。
- **ARN 铁律**：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repo]`，**无 `namespace/` 前缀**；资源类型只有 `*`/`instance`/`repository`/`chart`。`newapi-cicd-acr-push` 已修 v2。
- tag 不可变两层：命名空间默认配置（仅对自动建仓生效）+ 仓库自身 `TagImmutability`（**真正生效层**）。四命名空间 `AutoCreateRepo=false`；cicd 未授 `cr:CreateRepository`。

### ⚠️ docker login/push 排障顺序（踩过两轮，务必按序查）
1. **公网入口**默认 `Enable=false` → 无 DNS 记录、报 `Get "https://<域名>/v2/": EOF`。开：`cr UpdateInstanceEndpointStatus --EndpointType internet --Enable true`（异步 1–2 min）。
2. **公网 ACL**（第二轮真凶）：入口开启后系统预置 `127.0.0.1/32` 占位 → 真实 IP 全被拒（表现 EOF / 直连 **timeout，非 reset**）。**ACL 无总开关**（只有 Create/Delete，`AclEnable` 恒 true）；**白名单为空 = 全放行**；**拒收 `0.0.0.0/0`**（`INSTANCE_ACCESS_ACL_ENTRY_INVALID`）→ `push.sh --allow-ip all` = `0.0.0.0/1` + `128.0.0.0/1`。
   控制台：实例详情 → **仓库管理 > 访问控制 > 公网**；Helm Chart 走 **Helm Chart > 访问控制**。
3. 金标准校验：`curl -sv https://<域名>/v2/` 返 **401 Unauthorized**。

## 镜像发布 `push.sh`（仓库根目录）
`./push.sh -n prod|pre|test|dev -t <tag>`，login→build→tag→push + 逐阶段计时汇总；日志 `deploy/logs/`（`.deploy/` 已改名 `deploy/`）。
选项：`--open-endpoint` · `--allow-ip <cidr|auto|all>` · `--create-repo` · `-f <df>` / `--upstream` · `--npm-registry cn|official|<url>`（默认 cn）· `--go-proxy cn|aliyun|official|<url>`（默认 cn）· `--proxy <url|auto>` · `--no-proxy` · `--prune` · `--min-disk <GiB>` · `--skip-disk-check` · `--no-build` / `--build-only` / `--dry-run`。
**Dockerfile 自动选择**：未显式 `-f` 且存在 `Dockerfile.mac` → 用它（banner 标注）；`--upstream` 强制上游原版；CI 显式 `-f` 不受影响。
登录失败自动分流诊断（连接层 vs 401），连接层会核对**入口 Enable + ACL 白名单**。
坑：本机 `tee` 单次 ≈0.6s → 逐行日志**不用 tee**（stderr + append）；交互式 `read -rs` 必须在 `--dry-run` 早退之后。

### Docker 构建环境（macOS，2026-09-27 固化；详见 REFERENCE + 规范 §9.4）
- 虚拟盘上限 = `settings-store.json` 的 `DiskSizeMiB`（原 16 GiB 撞满 → `ResourceExhausted`，**已扩到 64 GiB**）；改配置须 `docker desktop stop` → 改 → `start`（沙箱 `osascript` 报 -10004）。
- 镜像加速器在 **`~/.docker/daemon.json`**（不是 settings-store）：USTC / 网易 163 **均已停服** → 用 `docker.m.daocloud.io` + `docker.1ms.run` + `docker.1panel.live`。
- **上游 `Dockerfile` 保持原版勿改**；本地增强在 **`Dockerfile.mac`**（`ARG NPM_REGISTRY` + `ARG GOPROXY` + bun/go cache mount），**默认自动选用**（冷构建 7m17s / 缓存命中 46.8s～1m19s，镜像 222 MB）。
- ⚠️ **Go 模块源 = 本地构建最常见的硬失败点**：两份 Dockerfile 原先都无 `GOPROXY` → 走 `proxy.golang.org`（`storage.googleapis.com` 承载）→ 直连超时，`RUN go mod download` 报 `…": EOF`。**是 EOF 不是 403，极易误判为构建逻辑问题**。修：`Dockerfile.mac` 加 `ARG GOPROXY=https://goproxy.cn,direct` + `ENV GOPROXY=${GOPROXY}`；`--go-proxy` 可切 aliyun/官方。<br>对照：**npm 官方源只是慢（1041s 能成），Go 官方源是直接失败**。
- `--proxy auto` = 注入 Docker **预定义 ARG**（`HTTP(S)_PROXY`/`NO_PROXY`，**免声明**）= 一个文件都不改的换源手段；而 `NPM_REGISTRY`/`GOPROXY` 这类**自定义变量必须 `ARG` 声明**才生效（push.sh 已自动检测）。

## 配额 / 成本
配额按节点池 **`max_size`** 申请（马尼拉 64 = 8×8 vCPU；新加坡 96 = 12×8），不按常态值；状态值 `Agree`；两地分单。机型 `g8i` 马尼拉**未上架** → `g9i.2xlarge`（备 `g8ine.2xlarge`）；地域须用维度传（`--Dimensions.1.Key regionId`）。
常态 **9,865.36 USD/月**（4+2 节点）· 接管峰值 15,322.51 · 备站冗余 623.90（6.32%）。单价常量在 `deploy/gen_cost_table.py` 顶部。ECS 询价**系统盘参数必填**；BSS 只能走 `business.ap-southeast-1.aliyuncs.com`。

## 切换（SLA）
`0.9999^5≈0.9996` → 月不可用 17.28 min，仅余 4.32 min。GTM 判定 45–60s 可控，**DNS 传播 5–30 min 不可控**；GTM 是**主备 failover 不是分摊**；可用 IP 最小阈值 = **1**。正解 = **DCDN 回源层切换**（RTO 10–20s，+74 USD/月）。

## SLS / 文档 / 网络
- SLS：`sls-newapi-mnl`（`rg-ph-mnl`）· `sls-newapi-sg`（`rg-sg`），各 7 logstore（ttl30 ×6 + `app-file-audit` ttl180）。`aliyun sls` 是 ROA 风格（无 `--ProjectName`、必带 `--region`；`GetLogStore` 用 path 参数 `--logstore`）。
- 文档：`deploy/用户设置指南.md` 单文件自包含（内联 SVG，GitHub 网页版会过滤）；改图三步、术语口径、双份同步要求见 REFERENCE。
- 网络**勿改**：马尼拉 `10.0.0.0/16`（6 vSwitch）· 新加坡 `10.1.0.0/16`（4 vSwitch）；Terway 每 Pod 占真实 VPC IP → app 段免费 IP 基线 4092，**低于 200 告警 P2**。完整 CIDR 见 REFERENCE / 指南 §2.2。
