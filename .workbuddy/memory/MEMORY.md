# new-api 菲律宾部署 · 项目长期约定（索引版）

> **详版口径与全部坑 → `.workbuddy/memory/REFERENCE.md`**（体积超注入上限，按需 Read）。
> 权限权威源 `.deploy/用户设置指南.md`；切换方案 `.deploy/DCDN回源层切换_方案.md`；过程见 `YYYY-MM-DD.md`。

## 账号 / 端点
账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b），备 `ap-southeast-1`（新加坡）。
`aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（非交互 `zsh -i -c`）；OSS 用 `ossutil` v2。
**RAM / resourcemanager / bssopenapi 必须 `--region ap-southeast-1`**（6 无 endpoint）；VPC/ECS/CR/SLS 类必带 `--region`（只传 `--endpoint` 无效）。

## 高频坑（shell / CLI）
- 变量后紧跟中文或全角标点被 bash 3.2 吞进变量名 → 一律 `${VAR}`。
- `set -u` + bash 3.2：`local x y` 未赋值即 unbound → `local y=""`。
- 函数日志必须 `>&2`（否则 `ID=$(f)` 把日志吞进变量）。
- 禁用变量名：`GROUPS`（macOS=20，赋值静默忽略）· `UID` · `EUID` · `PPID` · `RANDOM` · `SECONDS` · `PIPESTATUS` · `FUNCNAME` · `BASH_*` · `LINENO` · `OPTARG` · `HOSTNAME`。
- macOS grep 用 `-E 'A|B'`（不认 `\|`）；`awk '$1=""'` 留脏空格 → 用 python 过滤。
- **权限探测严禁子串匹配**（`AccessDenied` 会出现在事件正文）；不能用不存在的资源 ID 探测（存在性校验先于鉴权）→ 用幂等写。
- 预演结论与人工核对矛盾时，先怀疑脚本/工具。

## 资源组
`rg-ph-mnl` `rg-aek4nyivmmsb6iy`｜`rg-sg` `rg-aek4zvb3ldoiyua`｜`rg-nonprod` `rg-aek4hk3prqgqjcy`｜`rg-shared` `rg-aek3yypouljf4ry`（ACR/ActionTrail/CMS）｜默认组禁止放 new-api 资源。
RG 须**创建时**指定（vSwitch 无参但继承 VPC 组；不可单独换组）；启用按 RG 授权后迁移与策略变更须同批发布。

## RAM 治理（要点）
- 策略全 Custom 前缀 `newapi-`：admin-identity · ops-operator · cicd-acr-push · iac-terraform · dev-program · enforce-mfa · audit-protect · prod-boundary · prod-oss-guard。
- **仅组级承载**：用户级绑定已全解 → **禁止再 `AttachPolicyToUser`**。
- 七类角色 → 6 组：管理人员 `admin_group`｜财务 `fin_group`｜开发(人) `dev_group`｜开发程序 `dev-program_group`（纯 AK）｜初级运维 `ops_group`（生产只读）｜运维 Leader `ops-prod_group`（生产可写不可销毁，唯一手工通道）。
- `enforce-mfa` 不管 AK；`prod-boundary`+`prod-oss-guard` 是生产写双重拦截。
- 组备注唯一真源 = `ram_group_annotate.sh` 的 `comments_for()`，**apply 会覆盖控制台手工改动**。

## ACR（马尼拉）
实例 `acr-newapi-mnl` = `cri-avfqy9xkqi5bj8ee` @ ap-southeast-6，Enterprise_Basic，RG `rg-aek3yypouljf4ry`；域名 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`。
命名空间 4 个：`newapi-prod` `crn-axx3yf91h9qi76v6` · `newapi-pre` `crn-gxr29wbcya6axf7q` · `newapi-test` `crn-4fmk61khwp8uuyrq` · `newapi-dev` `crn-vwhfmm9qid60vomq`。
- **ARN 铁律**：`acs:cr:$region:$account:repository/$instanceid/$namespacename[/$repo]`；资源类型只有 `*`/`instance`/`repository`/`chart`，**无 `namespace/` 前缀**。
- `newapi-cicd-acr-push` **2026-09-27 15:33 已修 → v2**（原 3 条 ARN 全永不匹配）；回退 `ram_cicd_acr_fix.sh rollback v1`。
- tag 不可变两层：命名空间 `DefaultRepoConfiguration.TagImmutability`（仅对自动建仓生效）+ 仓库自身 `TagImmutability`（**真正生效层**）。脚本 `.deploy/acr_tag_immutable.sh check|apply|verify|all [prod|all]`。
- 四命名空间 `AutoCreateRepo=false`；`cr:CreateRepository` 未授予 cicd。

## 配额
按节点池 **`max_size`** 申请（马尼拉 64 = 8×8 vCPU；新加坡 96 = 12×8），不按常态值（否则 `ScaleOutBlocked`）。状态值 `Agree`；两地分单；分钟级自动审批。机型 `g8i` 马尼拉**未上架** → `g9i.2xlarge`（备 `g8ine.2xlarge`）。地域必须用维度传（`--Dimensions.1.Key regionId`）。

## 成本
常态 **9,865.36 USD/月**（4+2 节点）· 接管峰值 15,322.51 · 备站冗余 623.90（6.32%）。单价常量在 `.deploy/gen_cost_table.py` 顶部（按量项 730 h/月）。ECS 询价**系统盘参数必填**；本 CLI 无 `InstanceChargeType`（拿不到包年包月）；BSS 只能走 `business.ap-southeast-1.aliyuncs.com`。

## 切换（SLA）
`0.9999^5≈0.9996` → 月不可用 17.28 min，仅余 4.32 min。GTM 判定 45–60s 可控，**DNS 传播 5–30 min 不可控** → 中位 RTO 6.3 min 已超支。GTM 是**主备 failover 不是分摊**；可用 IP 最小阈值 = **1**。正解 = **DCDN 回源层切换**（RTO 10–20s，+74 USD/月，见 `.deploy/DCDN回源层切换_方案.md`）。

## SLS
`sls-newapi-mnl`（6 / `rg-ph-mnl`）· `sls-newapi-sg`（1 / `rg-sg`），各 7 logstore（app-stdout · app-file · alb-access · waf-log · rds-audit · actiontrail ttl30 + app-file-audit ttl180）。`aliyun sls` 是 ROA 风格（无 `--ProjectName`、必带 `--region`）；`GetLogStore` 用 path 参数 `--logstore`。脚本 `.deploy/sls_init.sh`。

## 文档体系
「用户设置指南.md」单文件自包含（内联 SVG，GitHub 会过滤）；改图三步：`gen_guide_images.py` → 重生成 → `inline_svg_into_md.py --apply`。术语用「管理人员」+ **七类**角色；`.md` / `-ch.md` 双份必须同步改。

## 网络基线（勿改）
马尼拉 `10.0.0.0/16`（6 vSwitch）· 新加坡 `10.1.0.0/16`（4 vSwitch），完整 CIDR 见指南 §2.2。Terway 每 Pod 占真实 VPC IP → app 段免费 IP 基线 4092，低于 200 告警 P2。
