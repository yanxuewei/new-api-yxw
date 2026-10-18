# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` ② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（冲突以 ① 为准）。**详版口径/全部坑 → `REFERENCE.md`**；成本细节 → `impl_deploy.md` §7.10（真源 `deploy/ops/gen_cost_table.py`）；流水 → `YYYY-MM-DD.md`。**新细节写 REFERENCE，勿堆本文。**

## 执行环境（最高优先级 · 2026-10-18 修正）

- **★ 跑任何命令前先判 OS，再选通道**：
  - **Windows** ⇒ 一律先 **WSL 进 Ubuntu** 再执行：`wsl -d Ubuntu -u root -- bash -c "..."`；多行/带引号/长中文 → 先 Write 成文件再 `bash /mnt/e/git_code/new-api-yxw/x.sh`；宿主 `E:\git_code\new-api-yxw` = `/mnt/e/git_code/new-api-yxw`,所有凭据优先查找ubuntu的环境变量或直接查看~/.bashrc。
  - **macOS** ⇒ **直接本机执行**，不进 WSL、不加 `wsl` 前缀。`aliyun` 3.5.1 + `kubectl` + python3 齐备，凭据在 `ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET`，`bash deploy/lib/ack_remote.sh <mnl|sg> <body.sh>` 开箱可用。
  - 判法：`uname -s` → `Darwin`=macOS 直跑 / `Linux`(WSL)=已在 Ubuntu / Windows 原生 shell 则先起 WSL。
- ⚠ 若某次 `wsl` 报 `SYSTEM TOOL DISABLED`（安全策略禁「系统级工具」），是**策略临时收紧**，不等于环境已变 → macOS 侧照常直跑即可，Windows 侧需去安全中心放开「系统级工具」。
- 产品名用 **`cs`**（`aliyun ack …` 报 `not a valid command or product`）。
- ⚠ CRLF（仅 WSL 侧）：`/mnt/e` 文本残 `\r` 比对假失败 ⇒ `tr -d '\r'`；`$?` 被吞 ⇒ `&& echo A || echo B`；**`bash -c` 内联 `$VAR`/循环变量不可靠 ⇒ 全写绝对路径或落脚本**；变量后紧跟中文标点被吞 ⇒ `${VAR}`。
- ★ **`ack_remote.sh` body 内 sleep 总和 ≤60s**：超了本地会被 SIGTERM（137），远端仍在跑 → 用「多次短探测」代替「一次长 sleep」。
- Go 1.25.1 + GOPROXY=goproxy.cn；`web/` 用 bun（WSL 无 node）；**本机不适合构建镜像**（WSL2 上行丢 SYN，`bun install` 永挂）⇒ 发版走 CI / macOS。

## 上游二次开发纪律（10-09 下达）
`new-api-yxw` = `QuantumNous/new-api` 二次开发分支（origin `git@github.com:yanxuewei/new-api-yxw.git`，`main`，**单人直推、无 PR 流程**）。
**五铁律**：① 能扩展不改源码 ② `UPSTREAM_CHANGES.md` 记清单、sync 前对照 ③ 自研代码放 `likha/{code,ops,doc}` 隔离 ④ 禁无意义格式化上游文件 ⑤ merge 冲突后跑全量测试、CI 不许 skip job。（落地物/唯一上游改动见 REFERENCE）

## 高频铁律
- 变量后紧跟中文/全角标点被 bash 3.2 吞 → 一律 `${VAR}`。**PATH 自愈**：脚本头加 `case ":${PATH}:"` 兜底。
- **脚本日志勿与 API 输出混流**：日志走 `exec 3>&2`、数据落文件（污染 JSON → jq 假失败）。`tee` ≈0.6 s/次 → 逐行日志不用 tee。
- **★ 采集组件「装了」≠「能用」**（2026-10-16 jkt）：ACK 组件 `state=active` 只代表清单下发；`loongcollector-operator` 这类 **Deployment 形态的 CR 翻译器会因节点满而 Pending**，此时 `kubectl apply` CR 会成功但**永不翻译**。判据 = 查 **SLS 侧 `GetLogtailPipelineConfig --configName <CR名>`** 是否有 global/processors，并看 CR `.status.message`。★ 同源事故：装附加组件（3×DS + operator）把 **3×2C 的 jkt dev 集群**压到 `2 Insufficient cpu, 2 Too many pods`，**打掉 `new-api-dev-slave` ⇒ `dev.likha.hk` 503**。修法（零成本）= 降 `arms-prometheus-ack-arms-prometheus` 的 `requests.cpu` 1000m→300m **并重建其 Pod**（新 requests 需重建才计入）⇒ `.153` 98%→77%。
- **★ 写操作先干跑**：`--cli-dry-run` / ALB `--DryRun true` → `DryRunOperation` 即全过（⚠ 托管 ALB 例外）。
- **★ K8s `Pod.spec.imagePullSecrets` 创建即固化、不可变** ⇒ 「SA 上现在有凭据」≠「这个 Pod 拉得动」；查拉取失败必须看 **Pod 的实际字段**，处置优先**重建 Pod**（详见 REFERENCE「凭据晚于 Pod 创建」节）。`-o jsonpath` **不认 `{{}}`**（那是 go-template）。
- **CLI 3.5.1**：配额只有 `--ProductCode`、`--MaxResults`（上限 **100**）、`--QuotaCategory CommonQuota`；vCPU 在 `ecs-spec`；地域**必须用维度** `--Dimensions.1.Key regionId`；**`Agree` 只在 `ListQuotaApplications` 返回** ⇒ 巡检一律 `jq -e`；**CLI 说参数名非法就先信它**。
- **探针法**：踩**服务端**校验点看错误落哪层；**禁用 CLI 已声明 enum/range 的参数当"必失败点"**；跑完复核资源数未变。权限探测**严禁子串匹配**、**不能用不存在的资源 ID**（存在性先于鉴权）→ 用幂等写。**资源前缀不代表地域**。
- **★ `newapi-enforce-mfa` 会盖住 `*-console:*` 动作**（先 `cr:*`、后 `dms-console:*`，2026-10-16）：**控制台网关的评估不带 MFA 上下文**，而浏览器 SPA 的普通 API 调用带（`MFAPresent=true`）⇒ 其它调用全正常，**极易误判「已排除」**。判别式 = **同组挂 enforce-mfa 的用户全挂、不挂的（super_group）正常**；修法 = 动作补进 `NotAction`。**门检报错文案（如 "policy is not attached"）别当真去挂策略** —— 门检评估的是动作有效权限。且 **DMS/控制台网关判定完全不落 ActionTrail**，零痕迹 ≠ 没问题。
- **VPC 端点两端皆偶发抖动** → 写操作**重试 ≥3 次**并校验合法 JSON，否则**静默漏建**。
- 一键复核 `deploy/verify_deploy_0_6.sh`。**`WARN` ≠ 通过**。⚠️ **`UID` / `GROUPS` 是 bash 内建保留变量**（root 下 `UID`=0、`GROUPS`=`(0)` 数组；赋值**静默失效** ⇒ 用 `GROUPS=()` 建自己的数组会恒非空、元素为 `0`）→ 一律换名。**★ 只读查询必须三态**（有 / 确认没有 / 查询失败）：`2>/dev/null` 静默吞错会把 API 抖动误判成「没有」，进而重复写或漏判。

## 资源与集群（细节见 REFERENCE / impl_deploy.md §7.10）
- 集群(3)：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(apse-6) · sg `ca75829e3492d491d9d434de087913798`(apse-1) · jkt dev `cb0abf5bc06034f7bbdb991752f6f3e62`(apse-5)。
- 实例：RDS `pgm-5tstdhko64x2c01w`（PG 17.0 2C8G/100G HA 包月，到期 2026-10-28 已自动续费）· Tair mnl `r-5tsf1fe16543e274` · Tair sg `r-gs5ltv3m4i3655besh` · ~~CK `cc-5tsv2o51s1360b0pr`~~（**2026-10-15 已释放**）· 日志库 MySQL `rm-5ts0ez22t67il9oz3`（x2.medium.2c 跨AZ HA 包月 $133.06/月）· jkt dev ALB `alb-4okmogghe7hbv5fwm6`（`dev.likha.hk`，10-15 落地，IaC `deploy/jakarta_dev/dev_ingress.yaml`）。
- 权限两套互不相通（RAM 管调 OpenAPI / K8s RBAC 管集群内）；`newapi-ops-operator`=**v7**、`newapi-enforce-mfa`=**v4**、`newapi-dev-program`=v6（**RAM 策略版本上限 5 ⇒ 加版本须先删最老非默认版**）；`cs GrantPermissions` 全量覆盖须读现状保全部集群；`bssopenapi` 一律 `--region ap-southeast-1`。
- 域名：GTM 3.0 已接管 `www.likha.hk`（10-13 任务 21）；DV 通配符 `606823-ap-southeast-1`（2027-03 前续签）；`_dnsauth` TXT 保留；加域名一条命令 `deploy/ops/add-domain.sh`。
- **DMS 新用户接入**：RAM 层（`enforce-mfa` v4 + 3 组挂同名 `AliyunDMSLoginConsoleAccess`）**一次性继承**；DMS 侧 per-user 三步（`RegisterUser` → `UpdateUser --UserNick` → `GrantUserPermission LOGIN` ×N，**DMS 无组级授权**）⇒ 一键 `deploy/ops/onboard-dms-user.sh <RAM用户> [--group G]... [--dry-run|--revoke]`（幂等）。⚠ `ops_group` 原**未挂** DMS 控制台策略，2026-10-16 11:13 已补挂 Custom 一条（`AttachPolicyToGroup` 必填 `--PolicyType`）；该组仅 `ops` 一个成员，且**尚未注册进 DMS**。细节 → REFERENCE「新用户接入」节。
- 节点池（10-14 起）：mnl `np-mnl-app` min2/max8 · sg `np-sg-ph-standby` min1/max10 · **jkt dev `np-jkt-dev-app` desired=3/max=3 且未开自动伸缩**；**自动缩容结构性不会发生**（goatscaler `skip_nodes_with_system_pods:true`，每台节点都命中）⇒ 真缩用 `deploy/tasks/task42/shrink_nodepool.sh`。
- **SLS 容器日志三站落点（10-16 jkt 补齐）**：一律 **ACK 自管 project `k8s-log-<cid>`**（不是 `sls-newapi-*`，后者只放云产品侧日志）。mnl/sg 用 `logtail-ds` v3.3.3.1 + CRD `ClusterAliyunPipelineConfig`（翻译器 `alibaba-log-controller`）；**jkt 用 `loongcollector` v3.3.10.0（DS）+ `loongcollector-operator`**（Deployment 形态，**必须能调度**）。logstore 参数照抄 mnl：`app-stdout` ttl180/17 键 · `app-file` ttl30/纯全文。★ **输入过滤口径因容器名而变**：生产按 `io.kubernetes.container.name: new-api`，**jkt 必须按 `io.kubernetes.pod.namespace: newapi-dev`**（dev 三个负载容器名各不相同，否则漏掉 slave）。IaC：`deploy/sls/jkt_provision.sh` + `apply_pipeline_ns.sh ... [mnl|sg|jkt]`。

## 成本与账务（真源 `gen_cost_table.py --apply`，勿手改 md）
- 生产两站 **3,352.18 USD/月**（含 jkt 3,679.48），日烧 ≈$110；流量 $0.124/GB 当前≈0；证书一次性 $212.07（OV $997 已退款）；数据盘 300G→100G 省 $221.80/月（未执行，云盘不支持原地缩容）。

## 日志库去 CK（2026-10-15 已实施并收口 → task58）
- 代码事实：`LOG_SQL_DSN` 支持 PG/MySQL/CK（`model/main.go:140-184`）；`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 仅 CK 生效；清理走 system_task → `DeleteOldLogBatch`（`model/log.go:705`）。
- **★ GORM 硬差异（决定性）**：mysql driver v1.5.7 `DeleteClauses` 含 LIMIT ⇒ 批删生效；**postgres driver v1.5.9（`postgres.go:77`）不含 ⇒ PG 上 `Limit()` 被静默忽略 = 一次全删大事务**（长锁/膨胀），PG 日志库清理需运维侧兜底。
- **已实施 B 方案并收口**：专用 MySQL `rm-5ts0ez22t67il9oz3`（x2.medium.2c 跨 AZ HA，$133.06/月）；mnl 内网 / sg 公网 `newapi-logs-public`（SSL 已开）+ `tls=skip-verify`（知情偏离）；两站 0 错误。**CK 已于 10-15 释放（存量日志弃），回滚 = 重建 CK**。logs 表 TTL：system_task 一次性基线 + **Windows 计划任务 `newapi-log-cleanup`**（每日唤起，每月 2 号执行）→ WSL `/usr/local/bin/newapi_log_cleanup.sh`；root access_token 在 `/root/.deploy_secrets/ADMIN_API_TOKEN`（600）。细节/回滚 → `deploy/tasks/task58_log_mysql/README.md` + REFERENCE。

## 已打通通道（详见 REFERENCE）
`ack_remote.sh <mnl|sg> <body.sh>` · `deploy/lib/aliyun_rpc.py`（绕 CLI 嵌套参数）· `aliyun workorder --region ap-southeast-1` · 凭据 `/root/.deploy_secrets/`（600）。
