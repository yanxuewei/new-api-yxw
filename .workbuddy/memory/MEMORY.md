# new-api 菲律宾部署 · 项目长期约定（索引版）

> **权威**：① `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` ② `deploy/菲律宾部署方案-v2.3-修订版.xlsx`（冲突以 ① 为准）。
> **详版口径/全部坑 → `REFERENCE.md`**；成本 → `impl_deploy.md` §7.10（真源 `deploy/ops/gen_cost_table.py`）；流水 → `YYYY-MM-DD.md`。
> **本文 2026-10-20 压缩**（原 15,090 字符全文见 `MEMORY-archive-2026-10-20.md`，信息零丢失）。**新细节写 REFERENCE，勿堆本文。**

## 执行环境（最高优先级）
- **先判 OS 再选通道**：`uname -s` → `Darwin`=macOS 直跑 / `Linux`=已在 WSL / Windows 原生 shell ⇒ 先进 WSL。
  - **Windows**：`wsl -d Ubuntu -u root -- bash -c "..."`；`E:\git_code\new-api-yxw` = `/mnt/e/git_code/new-api-yxw`。
  - **macOS**：不加 `wsl` 前缀；`aliyun`+`kubectl`+`python3` 齐备，凭据 `ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET`。
- ⚠ WSL 四大坑：① `/mnt/e` 文本残 `\r` ⇒ `tr -d '\r'`；Write 落盘的脚本先 `sed -i 's/\r$//'` ② `$?` 不可靠 ⇒ 用 `&& echo PASS || echo FAIL` ③ **`bash -c` 内联 `$VAR`/循环变量会被吞** ⇒ 全写绝对路径或落脚本再跑 ④ 变量后紧跟中文/全角标点被吞 ⇒ `${VAR}`。
- `wsl` 报 `SYSTEM TOOL DISABLED` = 安全策略临时收紧，非环境变更。
- 产品名用 **`cs`**（`aliyun ack …` 会报 not a valid command）。
- ★ `ack_remote*.sh` body 内 **sleep 总和 ≤60s**，超了本地 SIGTERM(137) 而远端仍在跑 ⇒ 用多次短探测。
- Go 1.25.1 + `GOPROXY=goproxy.cn`；`web/` 用 bun；**本机不适合构建镜像**（WSL2 上行丢 SYN）⇒ 发版走 CI / macOS。

## 上游二次开发纪律
`new-api-yxw` = `QuantumNous/new-api` 二次开发（origin `git@github.com:yanxuewei/new-api-yxw.git`，`main`，单人直推无 PR）。
**五铁律**：① 能扩展不改源码 ② `UPSTREAM_CHANGES.md` 记清单、sync 前对照 ③ 自研代码放 `likha/{code,ops,doc}` ④ 禁无意义格式化上游文件 ⑤ merge 冲突后跑全量测试、CI 不许 skip job。

## 高频铁律
- **写操作先干跑**：`--cli-dry-run` / ALB `--DryRun true`（`DryRunOperation` 即全过；托管 ALB 例外）。
- **只读查询必须三态**（有 / 确认没有 / 查询失败）：`2>/dev/null` 静默吞错会把抖动误判成「没有」。
- **`UID`/`GROUPS` 是 bash 内建保留变量**（root 下赋值静默失效）⇒ 一律换名。
- `-o jsonpath` **不认 `{{}}`**（那是 go-template）；K8s 判「IaC 与集群是否一致」用 `kubectl diff`（`rc=0`），**不看 `apply` 输出的 `configured`**（后者被陈旧注解干扰）。
- **采集组件「装了」≠「能用」**：组件 `state=active` 只代表清单下发；Deployment 形态的 CR 翻译器（如 `loongcollector-operator`）会因节点满 Pending，此时 `kubectl apply` CR 成功但**永不翻译** ⇒ 判据查 SLS 侧 `GetLogtailPipelineConfig` + CR `.status.message`。
- **附加组件能压垮小集群**：jkt dev 装 3×DS+operator 曾打出 `Insufficient cpu` ⇒ `dev.likha.hk` 503；零成本修法 = 降 prometheus `requests.cpu` 1000m→300m **并重建 Pod**。
- **`Pod.spec.imagePullSecrets` 创建即固化不可变** ⇒ 「SA 上有凭据」≠「这个 Pod 拉得动」；查拉取失败看 **Pod 实际字段**，处置优先重建 Pod。
- **CLI 3.5.1**：配额只有 `--ProductCode`/`--MaxResults`(≤100)/`--QuotaCategory CommonQuota`；vCPU 在 `ecs-spec`；地域必须 `--Dimensions.1.Key regionId`；`Agree` 只在 `ListQuotaApplications` 返回。
- **探针法**：踩服务端校验点；禁用 CLI 已声明 enum/range 的参数当「必失败点」；权限探测**严禁子串匹配**、**不能用不存在的资源 ID**；**资源前缀不代表地域**。
- **`newapi-enforce-mfa` 会盖住 `*-console:*`**：控制台网关评估不带 MFA 上下文、浏览器 SPA 的普通 API 带 ⇒ 极易误判「已排除」。判别式 = 同组挂 enforce-mfa 的全挂、不挂的正常；修法 = 动作补进 `NotAction`。门检报错文案别当真去挂策略；DMS/控制台网关判定**不落 ActionTrail**。
- **VPC 端点两端偶发抖动** ⇒ 写操作重试 ≥3 次并校验合法 JSON，否则静默漏建。
- 脚本日志勿与 API 输出混流（`exec 3>&2` + 数据落文件）；`tee` ≈0.6s/次，逐行日志不用。
- 一键复核 `deploy/verify_deploy_0_6.sh`。**`WARN` ≠ 通过**。

## 资源与集群
- 集群(3)：mnl `cd57e40ce9a634c1698c2f5c5e09bd93c`(apse-6) · sg `ca75829e3492d491d9d434de087913798`(apse-1) · jkt `cb0abf5bc06034f7bbdb991752f6f3e62`(apse-5)。
- 实例：RDS `pgm-5tstdhko64x2c01w`（PG17 2C8G/100G HA 包月，已自动续费）· Tair mnl `r-5tsf1fe16543e274` · Tair sg `r-gs5ltv3m4i3655besh` · 日志库 MySQL `rm-5ts0ez22t67il9oz3`（$133.06/月）· jkt 共享 Tair `r-d9j5iy2q82p1ugiwrt`（dev `/0`、pre `/1`、perf `/2`）· jkt ALB `alb-4okmogghe7hbv5fwm6`。~~CK `cc-5tsv2o51s1360b0pr`~~ 2026-10-15 已释放。
- 权限两套互不相通（RAM 调 OpenAPI / K8s RBAC 集群内）。策略版本：`newapi-ops-operator`=v7、`newapi-enforce-mfa`=v4、`newapi-dev-program`=v6（**上限 5 ⇒ 加版本先删最老非默认版**）；`cs GrantPermissions` 全量覆盖须读现状保全集群；`bssopenapi` 一律 `--region ap-southeast-1`。
- 域名：`likha.hk` 托管阿里云 DNS，GTM 3.0 接管 `www`；DV 通配符 `606823-ap-southeast-1`（实测至 2027-04-28）；加域名 `deploy/ops/add-domain.sh`。jkt 域名族（CNAME → `alb-4okmogghe7hbv5fwm6.ap-southeast-5.alb.aliyuncsslbintl.com`）：`dev`/`dev-yxw`/`dev-zzj`/`dev-xd`/`pre`/`perf`。⚠ dev ns=`newapi-dev`（**无横线**），pre/perf=`new-api-pre`/`new-api-perf`（**有横线**）。
- 节点池：mnl `np-mnl-app` 2–8 · sg `np-sg-ph-standby` 1–10 · jkt 现为 **`np-jkt-dev-x4c`**（2×g9i.xlarge，开弹性；`np-jkt-dev-app` 已被整体替换，**勿写死实例 ID**）。**自动缩容结构性不会发生**（goatscaler `skip_nodes_with_system_pods:true`）⇒ 真缩用 `deploy/tasks/task42/shrink_nodepool.sh`。
- **DMS 新用户接入**：RAM 层一次性继承（enforce-mfa v4 + 3 组挂 `AliyunDMSLoginConsoleAccess`）；DMS 侧 per-user 三步（`RegisterUser`→`UpdateUser --UserNick`→`GrantUserPermission LOGIN`，**无组级授权**）⇒ 一键 `deploy/ops/onboard-dms-user.sh <用户> [--group G] [--dry-run|--revoke]`。
- 通道：`deploy/lib/ack_remote.sh <mnl|sg> <body.sh>`（生产）· `deploy/lib/ack_remote_jkt_dev.sh <body.sh>`（jkt，15min 临时 kubeconfig，**命令体 ≤15000 字节硬门禁**）· `deploy/lib/aliyun_rpc.py`（绕 CLI 嵌套参数）。凭据 `/root/.deploy_secrets/`（600）。
- **GitOps（jkt dev，2026-10-26 落地）**：清单真源 = 独立私有仓 **`yanxuewei/new-api-yxw-ops`**（`bases/newapi` + `overlays/{jkt-dev,jkt-pre,jkt-test,jkt-prod}`，**永不进 Secret/AlbConfig**）；CD = **ArgoCD v3.5.6** 装在 jkt dev 集群 `argocd` ns（controller 是 **StatefulSet**、`--insecure`、关 dex/notif/appset），UI **`https://argocd.likha.hk`**（复用 dev ALB，Ingress order 60）。bootstrap 全走 `deploy/gitops/bootstrap/*.sh`（install-argocd / add-repo-secret / apply-app / expose-ui / set-secrets / verify）。AppProject `newapi` 只许 `newapi-dev` + clusterResourceWhitelist 仅 Namespace。细节与 6 个踩坑见 `deploy/docs/GitOps开发流水线_雅加达dev_执行报告_2026-10-26.md`。★ **旧 `new-api-config`（无 hash）不可删**：`yxw-*` 个人负载仍引用它。

## 目录结构与命名（2026-10-20 两轮整理定稿）
- `deploy/jakarta_{dev,pre,perf}/` 同构：`manifests/`（**唯一真源 IaC**）+ `scripts/`（本地执行器）+ `sql/` + `bodies/`（云助手 body），旧物进 `manifests/legacy/`；各目录有 `README.md`，`jakarta_pre/DEPRECATED.md` 是旧链路索引。
- **跨环境件归 `deploy/ops/`**：pre+perf 共用或与环境无关的 13 个 body 进 `deploy/ops/bodies/`；6 个 jkt 公共工具（`jkt_nodes`/`poll_invocation`/`secret_scan`/`set_addon_scope`/`set_rds_pooler`/`find_rds_conn_metric`）平铺 `deploy/ops/`。
- `pre_deploy.sh` 的 `run_body()` 有回落（先 `bodies/` 再 `deploy/ops/bodies/`）；执行器用 `ENVDIR="$(cd "$HERE/.." && pwd)"` 定位，**`scripts/*.sh` 不能拷到别处单跑**。
- 历史台账写的是整理前的平铺路径，属当时记录，**未回改**。

## jkt master/slave 双角色
- `NODE_TYPE=slave` ⇒ `IsMasterNode=false`（`common/init.go:89`）⇒ **跳过全部 DB migration**（`model/main.go:215/262`）与主节点后台任务。
- slave 与 master 四差异：`SQL_DSN` 取 secret key **`SQL_DSN`**（master 取 `SQL_DSN_MIGRATE`）、`preStop sleep 15`、liveness `initialDelay 40/period 15`、readiness `initialDelay 10/period 5`。configmap 里 `NODE_TYPE: master` 但**容器 env 优先于 envFrom**。
- **命名**：`{pre,perf}-new-api-{master,slave}`（master **无 svc**，slave 有 svc 且是 Ingress 唯一后端）；dev 仍是 `new-api-dev`/`new-api-dev-slave`。**切换顺序**：建新 slave → 等 Ready → 切 Ingress → 删旧 slave → 换 master（反了 503）。
- **selector 单键 `app=<deployment 名>`**：K8s 禁止两个 controller 的 selector 重叠，否则 ReplicaSet 互认 Pod 并互删；`env/project/site/track/role` 只进 labels 不进 selector。⚠ selector 不可变 ⇒ 改名/改 selector 只能 `delete deploy` 重建（每环境约 30s 无后端）。
- pre/perf secret 4 key（含 `REDIS_CONN_STRING`），**缺 `LOG_SQL_DSN`** ⇒ 日志库回落主库。`*-quota` 的 `spec` 为空 ⇒ 实际无资源上限（fanyan 2026-10-20 裁定不恢复）。

## 管理员凭据
- **perf**：唯一账号 **`perfroot`**（id=2, role=100，argon2id 哈希 97 字符），**库里没有 `admin`**（登录报错的常见原因就是用户名填错）。口令真源 = Secret `perf-load-test-credentials`（`admin_username`/`admin_password`/`token_id`/`token_key`，base64），取法见 `deploy/jakarta_perf/README.md`。**明文不落仓库**（`deploy/ops/secret_scan.sh` 会扫）。
- 登录 `POST /api/user/login` 默认收**明文**（`PASSWORD_LOGIN_ENCRYPTION_ENABLED` 默认 false）；登出是 `POST /api/user/auth/logout`（**不是** `/api/user/logout`）；`DELETE /api/user/sessions/<sid>` 删 current 会让 token 立即失效 ⇒ 批量删要把 current 排最后。
- 口令全丢的恢复路径：删 `users`(+`setups`) 的 root 行 → `rollout restart` → `/api/setup` 门禁重开重设 → 立刻写回 Secret（台账 `jakarta_dev_ledger.md:1484`）。

## 成本 / 日志库 / SLS（结论）
- 成本真源 `gen_cost_table.py --apply`，**勿手改 md**：生产两站 **3,352.18 USD/月**（含 jkt 3,679.48），日烧 ≈$110；流量 $0.124/GB 当前≈0；数据盘 300G→100G 省 $221.80/月（未执行，云盘不支持原地缩容）。
- **日志库已去 CK**：专用 MySQL `rm-5ts0ez22t67il9oz3`，mnl 内网 / sg 公网 `newapi-logs-public`（SSL）+ `tls=skip-verify`（知情偏离）；**CK 2026-10-15 已释放，回滚=重建 CK**。TTL 清理 = system_task 基线 + Windows 计划任务 `newapi-log-cleanup`（每月 2 号）→ WSL `/usr/local/bin/newapi_log_cleanup.sh`。
- ★ **GORM 硬差异**：mysql driver 的 `DeleteClauses` 含 LIMIT（批删生效）；**postgres driver（`postgres.go:77`）不含 ⇒ PG 上 `Limit()` 被静默忽略 = 一次全删大事务** ⇒ PG 日志库清理需运维兜底。
- SLS 一律落 **ACK 自管 project `k8s-log-<cid>`**（`sls-newapi-*` 只放云产品侧）。mnl/sg = `logtail-ds` + `ClusterAliyunPipelineConfig`；jkt = `loongcollector` + `loongcollector-operator`。★ 输入过滤口径：生产按 `io.kubernetes.container.name`，**jkt 必须按 `io.kubernetes.pod.namespace`**。IaC `deploy/sls/`。
