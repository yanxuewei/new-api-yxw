# new-api 菲律宾部署 · 项目长期约定（索引版）

> 详版口径与全部坑 → `.workbuddy/memory/REFERENCE.md`（体积超注入上限，按需 Read）。
> 权限权威源 `.deploy/用户设置指南.md`；切换方案 `.deploy/DCDN回源层切换_方案.md`；过程见 `YYYY-MM-DD.md`。

## 账号 / 端点
账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b），备 `ap-southeast-1`（新加坡）。
`aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 `zsh -i -c`）；OSS 用 `ossutil` v2。
**RAM / resourcemanager / bssopenapi 必须 `--region ap-southeast-1`**；VPC/ECS/CR/SLS 类必带 `--region`（只传 `--endpoint` 无效）。

## 高频坑（shell / CLI）
- 变量后紧跟中文或全角标点被 bash 3.2 吞进变量名 → 一律 `${VAR}`。
- `set -u` + bash 3.2：`local x y` 未赋值即 unbound → `local y=""`。
- 函数日志必须 `>&2`（否则 `ID=$(f)` 把日志吞进变量）。
- 禁用变量名（macOS 内建只读）：`GROUPS`（=20，赋值静默忽略）· `UID` · `EUID` · `PPID` · `RANDOM` · `SECONDS` · `PIPESTATUS` · `FUNCNAME` · `BASH_*` · `LINENO` · `OPTARG` · `HOSTNAME`。
- macOS grep 用 `-E 'A|B'`（不认 `\|`）。
- **权限探测严禁子串匹配**（`AccessDenied` 会出现在事件正文）；不能用不存在的资源 ID 探测（存在性校验先于鉴权）→ 用幂等写。

## 资源组
`rg-ph-mnl` `rg-aek4nyivmmsb6iy`｜`rg-sg` `rg-aek4zvb3ldoiyua`｜`rg-nonprod` `rg-aek4hk3prqgqjcy`｜`rg-shared` `rg-aek3yypouljf4ry`（ACR/ActionTrail/CMS）｜默认组禁止放 new-api 资源。
RG 须**创建时**指定（vSwitch 无参但继承 VPC 组；不可单独换组）。

## RAM 治理（要点）
- 策略全 Custom 前缀 `newapi-`：admin-identity · ops-operator · cicd-acr-push · iac-terraform · dev-program · enforce-mfa · audit-protect · prod-boundary · prod-oss-guard。
- **仅组级承载**：用户级绑定已全解 → **禁止再 `AttachPolicyToUser`**。
- 七类角色 → 6 组：管理人员 `admin_group`｜财务 `fin_group`｜开发(人) `dev_group`｜开发程序 `dev-program_group`（纯 AK）｜初级运维 `ops_group`（生产只读）｜运维 Leader `ops-prod_group`（生产可写不可销毁）。
- `enforce-mfa` 不管 AK；`prod-boundary`+`prod-oss-guard` 是生产写双重拦截。
- 组备注唯一真源 = `ram_group_annotate.sh` 的 `comments_for()`，**apply 会覆盖控制台手工改动**。

## ACR（马尼拉）
实例 `acr-newapi-mnl` = `cri-avfqy9xkqi5bj8ee` @ ap-southeast-6，Enterprise_Basic，RG `rg-aek3yypouljf4ry`；公网域名 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`（VPC 域名加 `-vpc`）。
命名空间：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vwhfmm9qid60vomq`。
- **ARN 铁律**：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repo]`；资源类型只有 `*`/`instance`/`repository`/`chart`，**无 `namespace/` 前缀**。`newapi-cicd-acr-push` 已修 v2。
- tag 不可变两层：命名空间默认配置（仅对自动建仓生效）+ 仓库自身 `TagImmutability`（**真正生效层**）。
- 四命名空间 `AutoCreateRepo=false`；`cr:CreateRepository` 未授予 cicd。

### ⚠️ 本地 docker login/push 排障顺序（踩过两轮，务必按序查）
1. **公网入口**：默认 `Enable=false` → 域名无 DNS 记录、报 `Get "https://<域名>/v2/": EOF`。开：`cr UpdateInstanceEndpointStatus --EndpointType internet --Enable true`（异步 1–2 min）。
2. **公网 ACL**（第二轮真凶）：入口开启后系统预置 `127.0.0.1/32` **占位** → 只有 127.0.0.1 可连，真实 IP 全被拒（表现 EOF / 直连 **timeout，非 reset**）。**ACL 无总开关接口**（只有 Create/Delete 两个 API，`AclEnable` 恒 true）；**白名单为空 = 全放行**（官方口径 + 2026-09-27 实测：空名单 curl `/v2/` 返 401）；**拒收 `0.0.0.0/0`**（`INSTANCE_ACCESS_ACL_ENTRY_INVALID`）。
   控制台改法：实例详情 → **仓库管理 > 访问控制 > 公网** 页签（访问入口开关 + 添加公网白名单）；Helm Chart 走 **Helm Chart > 访问控制**。
   push.sh `--allow-ip all` 用 `0.0.0.0/1` + `128.0.0.0/1`（非破坏性，不动已有条目）。
3. 修好后的金标准校验：`curl -sv https://<域名>/v2/` 返 **401 Unauthorized**（2026-09-27 18:52 实测通过）。

### 镜像发布脚本 `/push.sh`（仓库根目录，2026-09-27）
`bash push.sh -n prod|pre|test|dev -t <tag>`，login→build→tag→push 全流程 + 逐阶段计时汇总；日志 `.deploy/logs/push_<ns>_<tag>_<ts>.log`（git 已忽略）。
选项：`--open-endpoint`（自动开公网入口）· `--allow-ip <cidr,..|auto|all>`（auto=探测本机出口 IP；all=两个 `/1` 全放行）· `--create-repo` · `--no-build` / `--build-only` / `--dry-run`。
登录失败自动分流诊断（连接层 vs 401），连接层分支会核对**入口 Enable + ACL 白名单**。规范文档 §9.4 / §12 已同步。
- 坑：本机 `tee` 单次 ≈0.6s → 逐行日志**不能用 tee**（走 stderr + append）；交互式 `read -rs` 必须放在 `--dry-run` 早退之后。

### Docker 构建环境（本机 macOS，2026-09-27 起）
- **虚拟盘上限原为 16 GiB**（`~/Library/Group Containers/group.com.docker/settings-store.json` → `DiskSizeMiB`）→ 构建峰值 4–8 GiB 撞满 → `ResourceExhausted … no space left on device`（写 buildkit ingest）。**已扩到 65536 = 64 GiB**。
- 改配置顺序：`docker desktop stop` → 改文件 → `docker desktop start`。**沙箱内 `osascript quit` 报权限违例 -10004 → 用官方 CLI `docker desktop stop/start`**（数据全保留、容器自动恢复）。
- 镜像源在 **`~/.docker/daemon.json`**（不是 settings-store.json）：原 `docker.mirrors.ustc.edu.cn` + `hub-mirror.c.163.com` **均已停服**（http=000）→ 换 `docker.m.daocloud.io` / `docker.1ms.run` / `docker.1panel.live`（实测 401=活）；`defaultKeepStorage` 10GB → 3GB。
- VM 内剩余空间**无 CLI 直读** → 起探针容器 `docker run --rm --privileged --entrypoint sh alpine:3.20 -c 'df -Pk /'`。`Docker.raw` 的 `ls -l` 是 apparent（恒 = 上限），`du` 才是宿主真实占用。
- `Dockerfile` 已加 BuildKit cache mount：bun `BUN_INSTALL_CACHE_DIR=/root/.bun/install/cache`；go `GOMODCACHE=/go/pkg/mod` + `GOCACHE=/root/.cache/go-build`（`oven/bun:1.4.0` 默认 root / HOME=/root）。基础镜像 digest 固定不变（已在 daocloud 源验证可拉）。
- push.sh：build 前置磁盘水位检查 + `--prune` / `--min-disk <GiB>` / `--skip-disk-check`；构建失败按关键字分流诊断。

## 配额
按节点池 **`max_size`** 申请（马尼拉 64 = 8×8 vCPU；新加坡 96 = 12×8），不按常态值。状态值 `Agree`；两地分单。机型 `g8i` 马尼拉**未上架** → `g9i.2xlarge`（备 `g8ine.2xlarge`）；地域必须用维度传（`--Dimensions.1.Key regionId`）。

## 成本
常态 **9,865.36 USD/月**（4+2 节点）· 接管峰值 15,322.51 · 备站冗余 623.90（6.32%）。单价常量在 `.deploy/gen_cost_table.py` 顶部。ECS 询价**系统盘参数必填**；本 CLI 无 `InstanceChargeType`；BSS 只能走 `business.ap-southeast-1.aliyuncs.com`。

## 切换（SLA）
`0.9999^5≈0.9996` → 月不可用 17.28 min，仅余 4.32 min。GTM 判定 45–60s 可控，**DNS 传播 5–30 min 不可控**。GTM 是**主备 failover 不是分摊**；可用 IP 最小阈值 = **1**。正解 = **DCDN 回源层切换**（RTO 10–20s，+74 USD/月）。

## SLS
`sls-newapi-mnl`（6 / `rg-ph-mnl`）· `sls-newapi-sg`（1 / `rg-sg`），各 7 logstore（ttl30 ×6 + `app-file-audit` ttl180）。`aliyun sls` 是 ROA 风格（无 `--ProjectName`、必带 `--region`）；`GetLogStore` 用 path 参数 `--logstore`。脚本 `.deploy/sls_init.sh`。

## 文档体系
「用户设置指南.md」单文件自包含（内联 SVG，GitHub 会过滤）；改图三步：`gen_guide_images.py` → 重生成 → `inline_svg_into_md.py --apply`。术语用「管理人员」+ **七类**角色；`.md` / `-ch.md` 双份必须同步改。

## 网络基线（勿改）
马尼拉 `10.0.0.0/16`（6 vSwitch）· 新加坡 `10.1.0.0/16`（4 vSwitch），完整 CIDR 见指南 §2.2。Terway 每 Pod 占真实 VPC IP → app 段免费 IP 基线 4092，低于 200 告警 P2。
