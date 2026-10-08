# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威文档（2026-09-28 用户指定）**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（4 天/单人/CLI-first · F1–F11 · 56 任务卡）② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（7 表 · 任务/人时/验收唯一源）。二者冲突 **以 ① 为准**（① 修订 2026-09-27/28，晚于 ② 的 09-24）。
> **详版口径 + 全部坑 → `REFERENCE.md`**（已覆盖账号/CLI/权限/RG/RAM/ACR/配额/询价/容灾/SLS/文档/网络/Docker/私网通道/ACK 节点池）。过程流水 → `YYYY-MM-DD.md`。权限权威 `deploy/用户设置指南.md`；切换方案 `deploy/DCDN回源层切换_方案.md`。
> **本文只留：执行环境 + 文档冲突 + 高频铁律 + 当前状态**。写细节请写 REFERENCE。

## 执行环境（2026-09-28 起 · 优先级最高）
**所有命令默认在 WSL Ubuntu 跑**，不用宿主 Git Bash / PowerShell。
- 调用 `wsl -d Ubuntu -u root -- bash -c "..."`；**带引号/多行脚本先 Write 成文件再 `bash /mnt/e/.../x.sh`**（直传被 wsl.exe 拆坏）。宿主 `E:\git_code\new-api-yxw` = WSL `/mnt/e/git_code/new-api-yxw`。
- ⚠️ `/mnt/e` 文本是 **CRLF** → `grep`/`awk`/命令替换读入残 `\r` → 比对**必然假失败**（实测 `go.mod` 读成 `1.25.1\r`）→ **一律接 `tr -d '\r'`**。
- ⚠️ `bash -c` 不读 `/etc/profile.d/`；`go env -w` per-user → root 与 fanyan 各一份。`$?` 在 `bash -c "...; echo $?"` 里被吞成 0 → 用 `&& echo A || echo B`。
- ✅ Go 1.25.1（= `go.mod`）+ `GOPROXY=https://goproxy.cn,direct`；`web/` 前端用 bun（WSL 内**无 node/npm/bun/kubectl/helm**，需时装 Linux 版）。
- ✅ PATH 污染已清：`/etc/wsl.conf` 加 `[interop] appendWindowsPath=false`（`/mnt/` 条目 42→0，`cmd.exe` 不可调）。**编译/装依赖别放 `/mnt/e`**（`/tmp` 2.9 GB/s vs `/mnt/e` 421 MB/s）。
- 容器 `new-api`(:3000) · `postgres:15` · `redis` 均 `restart: always`。

## 两文档口径冲突（一律按 ①）
| 项 | ② xlsx v2.3 | ① 指南（采信） |
|---|---|---|
| 排期 | 2 人×5 天 = 120 人时 | 1 人×4 天×2 窗（A 08:30–14:00 / B 14:00–22:00）；backlog 顺延 T+14 |
| 日志库 | 马尼拉 CK 社区版 + 新加坡 CK | **F9** 仅马尼拉 CK **企业版单 AZ**；不建新加坡 CK；日志不入 SLA 证据链 + 写失败必须降级 |
| 镜像源 | 双地域 ACR | **单地域马尼拉 ACR**；SG 走公网端点拉（RTO 须含拉取耗时） |
| 连接收敛 | RDS 代理独享型 | **F10 已撤销**（2026-09-29 实测改用 RDS PG **内置托管 PgBouncer**，实例上早已启用）；**F11** `max_connections=800` 不可改 → 预算 640 |
| 机型 | `g8i.2xlarge` | **F1 `ecs.g9i.2xlarge`**（g8i 马尼拉全系未上架），备 `g8ine` |
| ALB 超时 | 180s | **600s（上限）**；SSE 靠 15–20s ping 保活 |
| ACK | 1.31+ | **1.35**（1.31/1.33 已 EOL）；实测可建 `1.35.7-aliyun.1` |
| 证据目录 | `.deploy/evidence/` | `deploy/evidence/`（`.deploy/` 已改名 `deploy/`） |

## 高频铁律（写命令前必看）
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`。**写完全脚本扫描**（python 正则查 `\$VAR` 后跟 `>127` 字符）。
- **脚本日志勿与 API 输出混流**：日志走 `exec 3>&2`，数据落文件（`say "+ cmd"` 混进重定向文件会污染 JSON → jq 假失败）。本机 `tee` ≈0.6s/次 → 逐行日志**不用 tee**。
- **PATH 自愈**：脚本头部加 `case ":$PATH:" in *".workbuddy/binaries/aliyun-cli:"*) ;; *) export PATH=... ;; esac`（否则 `./deploy/x.sh` 报 `aliyun: command not found`）。
- **CLI 3.5.1 口径**：配额参数**只有 `--ProductCode`**、分页 `--MaxResults`、类别 `--QuotaCategory CommonQuota`；vCPU 配额在 **`--ProductCode ecs-spec`**；地域**必须用维度** `--Dimensions.1.Key regionId`（否则静默回 `cn-hangzhou`）；**`Status: Agree` 只在 `ListQuotaApplications` 返回**（`ListProductQuotas` 无 Status → `select(.Status=="Agree")` 得空集且 **exit 0 假通过**）→ 巡检一律 `jq -e`。错 API/参数名 = exit 2；jq 语法错 = 3。
- **探针法（零成本确证能力）**：故意踩**服务端**校验点，看错误落在哪一层 → 落点在"商品校验/多 AZ 数量"即为参数层已过。**禁用 CLI 已声明 enum/range 的参数当"必失败点"**（会在 CLI 本地被拦，到不了服务端，报错无判别力）；跑完必须复核资源数未变。
- 权限探测**严禁子串匹配**（`AccessDenied` 会出现在事件正文）；**不能用不存在的资源 ID 探测**（存在性先于鉴权）→ 用幂等写。**资源 ID 前缀不代表地域**（`5ts`/`t4n` 纯属 ID 池巧合）→ 判残留必实查 API。
- **VPC 端点两端皆偶发抖动**（mnl + sg）→ 写操作**重试 ≥3 次**并校验返回是合法 JSON，否则**静默漏建资源**。
- 一键复核 `deploy/verify_deploy_0_6.sh`（8 项全走 `jq -e`，空即 FAIL）。**`WARN` ≠ 通过**。

## 付费方式（2026-09-28 用户指令 + 2026-09-29 CK 补丁）
| 产品 | 口径 | 计费参数名 |
|---|---|---|
| ECS 节点池 | 包年包月 1 年 + 自动续费 | `instance_charge_type: PrePaid` |
| Tair | 包年包月 12 月 | `ChargeType: PrePaid` |
| RDS PG | 包年包月 **1 年** | `PayType: Prepaid` + **`Period=Year`/`UsedTime=1`** |
| ACK 集群管理费 | **不支持包年包月** → ACK 资源包 | — |
| ClickHouse 企业版 | **只能按量**（Serverless）→ **计算资源包**（马尼拉**抵扣因子 1.45**） | 无 `PayType` 参数 |
- ⚠️ **月付周期上限 <12**：`Period=Month`+`UsedTime=12` 报 `Order.PeriodInvalid`（文案不提"上限"）。
- 配额口径切换：包年包月 `q_ecs_enterprise_prepay_c`（马尼拉 **100** / 新加坡 **100**，默认值无需工单）vs 按量 `postpay_c`（64/96，仅对照）——**两套独立计量**；SG 96/100 **仅余 4 vCPU**。
- 坑：节点池付费类型决定扩容计费 → **HPA 扩容即按 12 个月预付、缩容不退款**；包月/按量**库存池不共享**（查可售须 `--InstanceChargeType PrePaid`）；**已存在数据盘勿转包年包月**（ACK 官方：无法支持容器重启）。

## 任务 9｜日志库 CK = 马尼拉企业版（✅ 2026-09-30 已接线，日志库可用）
**三个"只有"**：① 可用区**只有 `ap-southeast-6a`**（官方 Multi-AZ=No）⇒ 单 AZ 是产品事实非取舍；② 存储**只有 OSS**；③ 计费**只有按量**。
- **实例**：`cc-5tsv2o51s1360b0pr`（enterprise/single_az/6a/oss/POSTPAY；状态字段企业版= **`ACTIVATION`**；内核 **26.2.1.698_1** 不可手选；引擎实测 **`SharedMergeTree`**；`NodeScaleMax` 实际 32 非计划 8，成本复核注意；VPC 端点 `…clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`，无公网端点）。
- **接线已完成**：白名单组 `mnl_app`=`10.0.16.0/20,10.0.32.0/20` · 库 `newapi_logs` · 账号 `newapi` · 端到端验证全过（认证/建表/INSERT/TTL90/TRUNCATE）。日志表 schema **以代码 `model/main.go` 为准**（文档旧 DDL 基线作废）；TTL 由 `LOG_SQL_CLICKHOUSE_TTL_DAYS` 控制（0=永久，方案 90）。
- **★ 坑：`DmlAuthSetting` 授权映射不生效**（JSON 数组是唯一被接受编码，仍回读空、SQL 层无数据权限）→ 绕行：`ckadmin`(SuperAccount) 从 VPC 内 `GRANT ALL ON newapi_logs.* TO newapi`；已固化 `deploy/task9_ck_wiring.sh --apply` 步骤 4b。
- **★ 坑：国际站 KMS 凭据管家须先购 KMS 实例**（`CreateSecret`→`UnsupportedOperation`，`ListKeys=0`）→ **阻塞任务 17 全部 8 个凭据**；DSN 暂存 WSL root `/root/.deploy_secrets/{LOG_SQL_DSN,CK_ADMIN_DSN}`（600，仓库外）。
- RAM 策略 `new-api-kms-readonly` v2（默认）已含 LOG_SQL_DSN 两地 ARN；坑：`ListPolicyVersions` 字段 `IsDefaultVersion`（非 `IsDefault`），List 自带 PolicyDocument。
- **成本（马尼拉官方）**：计算 `0.185350 USD/CCU·h` · 资源包 `0.03611 USD/CCU·H`（最小 3000、预付 3 年、不可退订，马尼拉抵扣因子 1.45，省 71.8%）。**日志库若 3 年内可能裁撤就别买包**（B3 待用户裁定）。
- 脚本 `deploy/task9_ck_wiring.sh`（`--check|--apply|--verify`）· 报告 §七 · 指南任务 9 执行记录 2 + 坑 10–12。
- 备站→CK 跨区写路径未裁定（无公网端点：`CreateEndpoint` 开公网 vs 备站落 PG vs CEN）。

## 当前状态与阻塞
- **五项裁定（2026-09-30 15:29）**：① **KMS 实例不买**（价格过贵）→ 凭据走手工 Secret 注入，已落地（见下）② **CK 计算资源包不买**（B3 关闭，CK 走按量）③ **备站→CK 走 CreateEndpoint 公网**（已落地）④ **ALB 现在买**（待执行）⑤ **GTM 挂起**（域名未到位）。
- **任务 17 Secret 已注入（2026-09-30）**：两地 `new-api-secrets`（马尼拉 6 键 / 新加坡 3 键）+ ConfigMap `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`；工具 `deploy/task17_secret_inject.sh`。DSN 已能进集群 ⇒ 任务 41 I-1 可切 CK 分支。待补：PAYMENT_PRIVATE_KEY、TLS_WILDCARD（用户提供）；SG REDIS（SG Tair 未建）。
- **凭据保管新格局**：`/root/.deploy_secrets/`（root 600）= RDS 三账号新口令（09-30 轮换，原密码无保管记录）+ CK 两个 DSN + SESSION_SECRET×2；Tair 密码在 `deploy/.env`（gitignored，任务 17 后期统一收进保管目录）。`newapi_ops` 在 `/home/fanyan/.newapi_rds_ops_password`。
- **CK 公网端点已开**（备站跨区写实测通过）：`…-public.clickhouseserver…`（43.118.97.47）；⚠ DescribeEndpoints 回读 `NetType="PUBLIC"` 大写。CK 白名单组：`mnl_app`（主站两段）+ `sg_eip`（SG 4 出口 EIP）。
- **账户余额 0.00 USD**；未支付订单 `518158947970481`（RDS，10594.13 USD，预分配 `pgm-5ts8mee1iiw13m89`）。
- **既有实例实况**：RDS `pgm-5tstdhko64x2c01w`（`rds-mnl-newapi`，`pg.n4.2c.2m`，主 6b / 备 6a，Prepaid，**到期 2026-10-28**）；Tair `r-5tsf1fe16543e274`（`tair-mnl-newapi`，**企业版 amber 1G/2DB/6proxy**、仅 6a、**只买 1 个月**）—— 两者周期/规格与指南口径不符，**待用户裁定**。
- **CK 实例已建成并接线**（`cc-5tsv2o51s1360b0pr`，2026-09-30，见任务 9 段）⇒ 任务 41 I-1 的 PG 分支连接数窗口关闭。
- **集群侧已落地（09-30）**：`new-api` namespace/SA/ResourceQuota/ConfigMap 两地 · RRSA 角色 `new-api-rrsa-kms-mnl/-sg` + 注入链路实测通 · 节点 SG 补 kubelet 10250 · 通道 `deploy/ack_remote.sh`。
- 已落地：VPC/vSwitch · SG 5 个 · NAT/EIP · ACR（**VPC 端点未关联、`newapi-master` 仍 PUBLIC**）· SLS 两项目 · ACK 两集群（mnl `cd57e40c…` / sg `ca75829e…`）+ 节点池 · 私网运维通道。
- ⚠️ **F11 待裁决**：官方规格表标 `pg.x4.2xlarge.2c` `max_connections=6400`，与 F11 的 800 差 8 倍 → 实例 Running 后 `SHOW max_connections;` 定论。
- 仍未闭环门禁：G1 实名 · G4 NS · G5 证书 · G6 模板 PR · **G7 产品开通（含 CK 企业版白名单）** · **G8 代码补项（/healthz·/readyz·/metrics + 限流降级放行）** · G11 连接预算表 · G12 SLA 签字 · G13 staging · 上游 8 EIP 白名单。
