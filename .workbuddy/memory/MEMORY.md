# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` ② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（冲突以 ① 为准）。**详版口径/全部坑 → `REFERENCE.md`**；成本细节 → `impl_deploy.md` §7.10（真源 `deploy/ops/gen_cost_table.py`）；流水 → `YYYY-MM-DD.md`。**新细节写 REFERENCE，勿堆本文。**

## 执行环境（最高优先级）
- **命令默认 WSL Ubuntu**：`wsl -d Ubuntu -u root -- bash -c "..."`；多行/带引号/长中文 → 先 Write 成文件再 `bash /mnt/e/.../x.sh`；宿主 `E:\git_code\new-api-yxw` = `/mnt/e/git_code/new-api-yxw`。
- ⚠ CRLF：`/mnt/e` 文本残 `\r` 比对假失败 ⇒ `tr -d '\r'`；`$?` 被吞 ⇒ `&& echo A || echo B`；**`bash -c` 内联 `$VAR`/循环变量不可靠 ⇒ 全写绝对路径或落脚本**；变量后紧跟中文标点被吞 ⇒ `${VAR}`。
- Go 1.25.1 + GOPROXY=goproxy.cn；`web/` 用 bun（WSL 无 node）；**本机不适合构建镜像**（WSL2 上行丢 SYN，`bun install` 永挂）⇒ 发版走 CI / macOS。

## 上游二次开发五铁律（10-09）
能扩展不改源码 · `UPSTREAM_CHANGES.md` 记清单 · 自研放 `ours_likha/{code,ops,doc}` · 禁无意义格式化上游 · merge 后全量测试（CI 不许 skip）。origin `git@github.com:yanxuewei/new-api-yxw.git`，单人直推无 PR。

## 高频铁律（全文见 REFERENCE）
- 写操作先干跑：`--cli-dry-run` / ALB `--DryRun true`（托管 ALB 例外）；cs REST POST 必须 `--header "Content-Type=application/json"`。
- K8s `imagePullSecrets` 创建即固化不可变 ⇒ 排查看 Pod 实际字段、处置优先重建 Pod；`-o jsonpath` 不认 `{{}}`。
- CLI 3.5.1：配额 `--ProductCode / --MaxResults(≤100) / --QuotaCategory CommonQuota`；地域必须维度 `--Dimensions.1.Key regionId`；**CLI 说参数名非法就先信它**；巡检一律 `jq -e`；RDS 报价 `--PayType Prepaid --TimeType Month --Quantity 1`（无 `--Period`，按量 Postpaid 不带 TimeType）。
- 探针法：踩服务端校验点看错误落哪层；权限探测用幂等写（禁子串匹配/不存在 ID）；写操作重试 ≥3 次防 VPC 抖动静默漏建。
- 脚本日志与 API 输出分流（`exec 3>&2`，数据落文件）；一键复核 `deploy/verify_deploy_0_6.sh`，`WARN` ≠ 通过；`UID` 是 bash 只读变量。

## 资源与集群（细节见 REFERENCE / impl_deploy.md §7.10）
- 集群(3)：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(apse-6) · sg `ca75829e3492d491d9d434de087913798`(apse-1) · jkt dev `cb0abf5bc06034f7bbdb991752f6f3e62`(apse-5)。
- 实例：RDS `pgm-5tstdhko64x2c01w`（PG 17.0 2C8G/100G HA 包月，到期 2026-10-28 已自动续费）· Tair mnl `r-5tsf1fe16543e274` · Tair sg `r-gs5ltv3m4i3655besh` · ~~CK `cc-5tsv2o51s1360b0pr`~~（**2026-10-15 已释放**）· 日志库 MySQL `rm-5ts0ez22t67il9oz3`（x2.medium.2c 跨AZ HA 包月 $133.06/月）· jkt dev ALB `alb-4okmogghe7hbv5fwm6`（`dev.likha.hk`，10-15 落地，IaC `deploy/jakarta_dev/dev_ingress.yaml`）。
- 权限两套互不相通（RAM 管调 OpenAPI / K8s RBAC 管集群内）；`newapi-ops-operator`=v3；`cs GrantPermissions` 全量覆盖须读现状保全部集群；`bssopenapi` 一律 `--region ap-southeast-1`。
- 域名：GTM 3.0 已接管 `www.likha.hk`（10-13 任务 21）；DV 通配符 `606823-ap-southeast-1`（2027-03 前续签）；`_dnsauth` TXT 保留；加域名一条命令 `deploy/ops/add-domain.sh`。
- 节点池（10-14 起）：mnl `np-mnl-app` min2/max8 · sg `np-sg-ph-standby` min1/max10；**自动缩容结构性不会发生**（goatscaler `skip_nodes_with_system_pods:true`，每台节点都命中）⇒ 真缩用 `deploy/tasks/task42/shrink_nodepool.sh`。

## 成本与账务（真源 `gen_cost_table.py --apply`，勿手改 md）
- 生产两站 **3,352.18 USD/月**（含 jkt 3,679.48），日烧 ≈$110；流量 $0.124/GB 当前≈0；证书一次性 $212.07（OV $997 已退款）；数据盘 300G→100G 省 $221.80/月（未执行，云盘不支持原地缩容）。

## 日志库去 CK（2026-10-15 已实施并收口 → task58）
- 代码事实：`LOG_SQL_DSN` 支持 PG/MySQL/CK（`model/main.go:140-184`）；`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` 仅 CK 生效；清理走 system_task → `DeleteOldLogBatch`（`model/log.go:705`）。
- **★ GORM 硬差异（决定性）**：mysql driver v1.5.7 `DeleteClauses` 含 LIMIT ⇒ 批删生效；**postgres driver v1.5.9（`postgres.go:77`）不含 ⇒ PG 上 `Limit()` 被静默忽略 = 一次全删大事务**（长锁/膨胀），PG 日志库清理需运维侧兜底。
- **已实施 B 方案并收口**：专用 MySQL `rm-5ts0ez22t67il9oz3`（x2.medium.2c 跨 AZ HA，$133.06/月）；mnl 内网 / sg 公网 `newapi-logs-public`（SSL 已开）+ `tls=skip-verify`（知情偏离）；两站 0 错误。**CK 已于 10-15 释放（存量日志弃），回滚 = 重建 CK**。logs 表 TTL：system_task 一次性基线 + **Windows 计划任务 `newapi-log-cleanup`**（每日唤起，每月 2 号执行）→ WSL `/usr/local/bin/newapi_log_cleanup.sh`；root access_token 在 `/root/.deploy_secrets/ADMIN_API_TOKEN`（600）。细节/回滚 → `deploy/tasks/task58_log_mysql/README.md` + REFERENCE。

## 已打通通道（详见 REFERENCE）
`ack_remote.sh <mnl|sg> <body.sh>` · `deploy/lib/aliyun_rpc.py`（绕 CLI 嵌套参数）· `aliyun workorder --region ap-southeast-1` · 凭据 `/root/.deploy_secrets/`（600）。
