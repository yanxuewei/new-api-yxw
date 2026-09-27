# new-api 菲律宾部署 · 项目长期约定（索引版）

> 详版口径与全部坑 → `.workbuddy/memory/REFERENCE.md`；过程流水 → `YYYY-MM-DD.md`。
> 权限权威 `deploy/用户设置指南.md`；切换方案 `deploy/DCDN回源层切换_方案.md`。

## 账号 / 端点
账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b），备 `ap-southeast-1`（新加坡）。
`aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 `zsh -i -c`）；OSS 用 `ossutil` v2。
**RAM / resourcemanager / bssopenapi 必须 `--region ap-southeast-1`**；VPC/ECS/CR/SLS 必带 `--region`（只传 `--endpoint` 无效）。

## 高频坑
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`；`set -u` 下 `local x y` 未赋值即 unbound。
- 函数日志必须 `>&2`（否则 `ID=$(f)` 把日志吞进变量）；macOS grep 用 `-E 'A|B'`（不认 `\|`）。
- 禁用变量名（macOS 只读内建）：`GROUPS`(=20) · `UID` · `EUID` · `PPID` · `RANDOM` · `SECONDS` · `PIPESTATUS` · `FUNCNAME` · `BASH_*` · `LINENO` · `OPTARG` · `HOSTNAME`。
- **权限探测严禁子串匹配**（`AccessDenied` 会出现在事件正文）；不能用不存在的资源 ID 探测（存在性校验先于鉴权）→ 用幂等写。

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
命名空间：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vwhfmm9qid60vomq`。
- **ARN 铁律**：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repo]`，**无 `namespace/` 前缀**；资源类型只有 `*`/`instance`/`repository`/`chart`。`newapi-cicd-acr-push` 已修 v2。
- tag 不可变两层：命名空间默认配置（仅对自动建仓生效）+ 仓库自身 `TagImmutability`（**真正生效层**）。四命名空间 `AutoCreateRepo=false`；cicd 未授 `cr:CreateRepository`。

### ⚠️ docker login/push 排障顺序（踩过两轮，务必按序查）
1. **公网入口**默认 `Enable=false` → 无 DNS 记录、报 `Get "https://<域名>/v2/": EOF`。开：`cr UpdateInstanceEndpointStatus --EndpointType internet --Enable true`（异步 1–2 min）。
2. **公网 ACL**（第二轮真凶）：入口开启后系统预置 `127.0.0.1/32` 占位 → 真实 IP 全被拒（表现 EOF / 直连 **timeout，非 reset**）。**ACL 无总开关**（只有 Create/Delete，`AclEnable` 恒 true）；**白名单为空 = 全放行**；**拒收 `0.0.0.0/0`**（`INSTANCE_ACCESS_ACL_ENTRY_INVALID`）。
   控制台：实例详情 → **仓库管理 > 访问控制 > 公网**（入口开关 + 添加公网白名单）；Helm Chart 走 **Helm Chart > 访问控制**。`push.sh --allow-ip all` = `0.0.0.0/1` + `128.0.0.0/1`。
3. 金标准校验：`curl -sv https://<域名>/v2/` 返 **401 Unauthorized**。

## 镜像发布 `push.sh`（仓库根目录）
`bash push.sh -n prod|pre|test|dev -t <tag>`，login→build→tag→push + 逐阶段计时汇总；日志 `deploy/logs/`。
**目录已改名：`.deploy/` → `deploy/`**（脚本/文档/规范都在 `deploy/`；旧 `.deploy` 只剩 `logs` 残壳）。`push.sh` 已 tracked。
选项：`--open-endpoint` · `--allow-ip <cidr|auto|all>` · `--create-repo` · `-f <dockerfile>` · `--npm-registry cn|official|<url>`（默认 cn）· `--proxy <url|auto>` · `--no-proxy <list>` · `--prune` · `--min-disk <GiB>` · `--skip-disk-check` · `--no-build` / `--build-only` / `--dry-run`。
登录失败自动分流诊断（连接层 vs 401），连接层会核对**入口 Enable + ACL 白名单**。
坑：本机 `tee` 单次 ≈0.6s → 逐行日志**不用 tee**（stderr + append）；交互式 `read -rs` 必须在 `--dry-run` 早退之后。

### Docker 构建环境（macOS，2026-09-27 固化）
- 虚拟盘上限 = `~/Library/Group Containers/group.com.docker/settings-store.json` 的 `DiskSizeMiB`；原 16 GiB 撞满 → `ResourceExhausted`。**已扩到 65536（64 GiB）**。改配置须 `docker desktop stop` → 改 → `start`（沙箱 `osascript` 报 -10004）。
- 镜像源在 **`~/.docker/daemon.json`**（不是 settings-store）：USTC / 网易 163 **均已停服** → 用 `docker.m.daocloud.io` + `docker.1ms.run` + `docker.1panel.live`；`defaultKeepStorage` 10GB → 3GB。
- **上游 `Dockerfile` 保持原版，勿改**；本地增强在 **`Dockerfile.mac`**（`ARG NPM_REGISTRY` + bun/go cache mount）→ `bash push.sh … -f Dockerfile.mac`（实测冷构建 7m17s、缓存命中 **1m19s**，镜像 222 MB）。
- **Docker 预定义 ARG 免声明**：`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`（含全小写）**无需 `ARG` 声明**即注入构建环境 → `--proxy auto`（`http://host.docker.internal:7890`，容器内实测可达）。**自定义变量（如 `NPM_REGISTRY`）必须 `ARG` 声明**，否则 BuildKit 只打 `not consumed` 警告、不注入（push.sh 已自动检测并跳过）。
- `bun install` 1202 包实测：npmmirror **101s** ＜ Clash 代理走官方源 **889s** ＜ 官方源直连 **1041s**（**三者均成功** → **不改 Dockerfile 也能构建**，换源只是提速 10 倍）。
- VM 内剩余空间无 CLI 直读 → `docker run --rm --privileged --entrypoint sh alpine:3.20 -c 'df -Pk /'`；`Docker.raw` 的 `ls -l` 是 apparent（恒＝上限），`du` 才是真实占用。

## 配额 / 成本
配额按节点池 **`max_size`** 申请（马尼拉 64 = 8×8 vCPU；新加坡 96 = 12×8），不按常态值；状态值 `Agree`；两地分单。机型 `g8i` 马尼拉**未上架** → `g9i.2xlarge`（备 `g8ine.2xlarge`）；地域须用维度传（`--Dimensions.1.Key regionId`）。
常态 **9,865.36 USD/月**（4+2 节点）· 接管峰值 15,322.51 · 备站冗余 623.90（6.32%）。单价常量在 `deploy/gen_cost_table.py` 顶部。ECS 询价**系统盘参数必填**；BSS 只能走 `business.ap-southeast-1.aliyuncs.com`。

## 切换（SLA）
`0.9999^5≈0.9996` → 月不可用 17.28 min，仅余 4.32 min。GTM 判定 45–60s 可控，**DNS 传播 5–30 min 不可控**；GTM 是**主备 failover 不是分摊**；可用 IP 最小阈值 = **1**。正解 = **DCDN 回源层切换**（RTO 10–20s，+74 USD/月）。

## SLS / 文档 / 网络
- SLS：`sls-newapi-mnl`（`rg-ph-mnl`）· `sls-newapi-sg`（`rg-sg`），各 7 logstore（ttl30 ×6 + `app-file-audit` ttl180）。`aliyun sls` 是 ROA 风格（无 `--ProjectName`、必带 `--region`）；`GetLogStore` 用 path 参数 `--logstore`。
- 文档：`deploy/用户设置指南.md` 单文件自包含（内联 SVG；GitHub 网页版会过滤）；改图三步 `gen_guide_images.py` → 重生成 → `inline_svg_into_md.py --apply`。术语用「管理人员」+ **七类**角色；`.md` / `-ch.md` 双份必须同步改。
- 网络（勿改）：马尼拉 `10.0.0.0/16`（6 vSwitch）· 新加坡 `10.1.0.0/16`（4 vSwitch）。Terway 每 Pod 占真实 VPC IP → app 段免费 IP 基线 4092，低于 200 告警 P2。
