# Day 3 · 任务 26｜日志服务 SLS / ARMS Prometheus / Grafana / 云监控站点监控 —— 执行报告（2026-10-06）

- **结论**：**部分交付** —— SLS 容器日志采集 ✅（两集群实测有数据）、ARMS Prometheus ✅（容器指标可查）；**云监控站点监控 ⛔ 阻塞（配额 0 / 产品未注册）**、**Grafana 工作区 ⛔ 阻塞（订单侧 601）**。
- **证据目录**：`deploy/logs/task26_20261006-152351/`
- **IaC 产物**：`deploy/sls/aliyunlogconfig-app-stdout.yaml`

---

## 一、SLS（步骤 1 / 2）✅ 已落地并实测

**Project / Logstore 现状（只读复核，均早于此卡存在）**：
- `sls-newapi-mnl`（ap-southeast-6）：**22** 个 Logstore，含卡内要求的 `app-stdout` / `app-file` / `alb_access` / `waf-log` / `rds-audit` / `actiontrail`（另含 `app-file-audit`、`alb_access-metrics*` 等）。
- `sls-newapi-sg`（ap-southeast-1）：**13** 个，同名族齐备。

**本次新增（声明式，两集群同构）**：`AliyunLogConfig/new-api-app-stdout`（`service_docker_stdout` + `IncludeLabel: io.kubernetes.container.name=new-api`，Stdout+Stderr）→ 两集群 `status: OK/200`，logtail 日志确认 `pipeline start: succeeded`。

**V1 实测（数据真的进来了）**：
- mnl：`app-stdout` 出现 `_pod_name_=new-api-stable-7f96d6ff48-llxr9` / `_container_name_=new-api` / `_namespace_=new-api`，含 `[GIN] … GET /api/status` 行（配合 10 次 `/api/status` 造流量）。
- sg：`app-stdout` 出现 `_pod_name_=new-api-ph-standby-5c6b78954-bkgkz`。

### ⚠ 关键事实纠正 1：容器日志落点是 **ACK 自管项目 `k8s-log-<clusterId>`**，不是 `sls-newapi-mnl`
- logtail 下发的 flusher 实测为 `Project=k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c`（sg 侧 `k8s-log-ca75829e3492d491d9d434de087913798`），项目内 Logstore：`app-stdout` / `coredns-log` / `audit-<cid>` / `k8s-event` / `config-operation-log` / `policyadmit-<cid>`。
- `AliyunLogConfig` CRD **无 `project` 字段**（实测 CR 与 CRD schema 均无）⇒ 项目由 logtail 附加组件安装时绑定，改指向需在维护窗口重装/重配该附加组件（控制台选"使用已有 SLS Project"）。
- **口径处置（2026-10-06 最终裁定 = A 方案：接受现状）**：容器 stdout/文件日志**永久以 `k8s-log-<cid>` 为准**（下游查询/告警/看板按此）；`sls-newapi-mnl`/`sls-newapi-sg` 继续承载**非容器**日志（ALB 访问日志、RDS 审计、ActionTrail、WAF）。**不重装/不重配 logtail 附加组件**（避免替换采集组件的窗口风险与被驳回的 B 方案）。**控制台查询路径**：SLS 左上「项目」下拉 → `k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c`（mnl）/ `k8s-log-ca75829e3492d491d9d434de087913798`（sg）→ 日志库 `app-stdout`。

**2026-10-06 复核实测（近 30min，用户报"控制台查不到"后定位）**：

| 项目 / 日志库 | count | 取样 |
| --- | --- | --- |
| `k8s-log-cd57…` / `app-stdout` | ≥1 | `_pod_name_=new-api-stable-7f96d6ff48-t8ptn`、`_container_name_=new-api`、`[GIN] … GET /api/status | 200` |
| `k8s-log-ca75…` / `app-stdout` | ≥1 | `_pod_name_=new-api-ph-standby-5c6b78954-clkzv` |
| `sls-newapi-mnl` / `app-stdout` | **0** | 空（控制台看到的"暂无内容"即此库） |
| `sls-newapi-mnl` / `alb_access` | 1 | ✅ ALB 访问日志在写 |
| `sls-newapi-mnl` / `rds-audit` | `IndexConfigNotExist` | 库在、**无索引**（查/告警前须先建索引） |
| `sls-newapi-mnl` / `waf-log`、`actiontrail` | 0 | WAF 未接入 / 近期无 ActionTrail 写入 |

CLI 等价（注意 `--region` 必须显式传）：
```bash
aliyun sls GetLogs --project k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c --logstore app-stdout \
  --region ap-southeast-6 --body '{"from":<epoch-1800>,"to":<epoch>,"query":"*","line":3}'
```

### ⚠ 关键事实纠正 2：SLS `GetLogs` 需先建索引
- 无索引时返回 `IndexConfigNotExist`。本次为 mnl `app-stdout` 建了全文索引（`ttl=30`，分隔符含中英标点；sg 侧原已有索引）。

### 🔧 索引补项与"投递真因"（2026-10-06 补项，用户授权执行）

**结论：索引已补齐；但 `rds-audit` / `actiontrail` 无数据的真因是「投递没开」，不是索引问题。**

| 项 | 改动前 | 改动后 / 真因 |
| --- | --- | --- |
| `sls-newapi-mnl/rds-audit` | 无索引（`GetIndex` `ttl=None`）；`GetLogs` 报 `IndexConfigNotExist` | ✅ 已建**全文索引**：`ttl=30`、`keys={}`、分词器复用 `actiontrail` 口径（26 token）；近 7 天 `count=0` ⇒ 真因 = **RDS SQL 审计 `Disabled`** |
| `sls-newapi-sg/rds-audit` | 同上（无索引） | ✅ 同上已建（两站同构）；RDS 仅马尼拉一台（`pgm-5tstdhko64x2c01w`），sg 库预期长期为空 |
| `sls-newapi-mnl/actiontrail` | 已有索引（`ttl=30`） | 索引无需改；近 7 天 `count=0` ⇒ 真因 = **ActionTrail 投递 OSS（`newapi-audit-trail` → `oss-newapi-mnl`，`SlsProjectArn="/"`），不投 SLS** ⇒ 该 Logstore 为**预留占位** |
| `sls-newapi-sg/waf-log` | 无索引（`ttl=None`） | **故意不建**：WAF 未接入（`count=0`），避免给空 Logstore 付索引存储；任务 20 接入后把该行加回 `create_index_audit.sh` 的 `TARGETS` 即可 |
| `sls-newapi-mnl/{waf-log,app-stdout}` | 已有索引 | 未动 |

**IaC 产物**：`deploy/sls/create_index_audit.sh`（默认干跑，`EXEC_MODE=apply` 才写；幂等，已有索引自动 skip）。
**证据目录**：`deploy/logs/task26_sls_index_20261006-165435/`（`index_state.txt` / `create_index_dryrun.txt` / `create_index_apply.txt` / `verify.txt` / `actiontrail.txt` / `rds.txt`）。

**审计类日志查询口径（固定）**：
```bash
# 按需换 --logstore rds-audit|actiontrail|waf-log|alb_access；sg 项目换 --region ap-southeast-1
aliyun sls GetLogs --project sls-newapi-mnl --logstore rds-audit --region ap-southeast-6 \
  --body '{"from":<epoch-86400>,"to":<epoch>,"query":"*","line":3}'
```
> 坑：**`GetLogs` 前先 `GetIndex` 断言有索引**（无索引直接 `IndexConfigNotExist`，会被误读成"没数据"）；**`--region` 必须显式传**，否则默认 `ap-southeast-6` 查 sg 项目会得到误导性结果。

**⇒ 待授权写操作（本卡不擅自开）**：① 开启 RDS SQL 审计并投递 `sls-newapi-mnl/rds-audit`（`ModifySQLCollectorPolicy` + 投递关联；RDS 写 + 少量索引/存储费）；② 若确需 SLS 侧 ActionTrail，另加 trail 的 SLS 投递（与 OSS 路线重复，非必需）。

---

### 🔎 app-file 取证：卡内方案三处不成立（2026-10-06，只读取证）

| 卡内写法 | 实测 / 代码事实 |
| --- | --- |
| 给 Deployment 挂 `/app/logs` emptyDir | **`/app` 目录在镜像里不存在**；容器 WORKDIR = **`/data`**，文件日志实际落 `/data/logs/oneapi-20261005232506.log`（实测 **8.66 MB / 66,066 行**，mtime 实时，无任何 emptyDir 挂载 ⇒ 在 overlay 可写层） |
| 环境变量 `LOG_DIR` | **代码没有这个 env**：开关是 CLI 参数 `-log-dir`（`common/init.go:22`，默认 `./logs`）；容器 cmdline 实测 `/new-api`（**未传参** ⇒ 走默认 `./logs`，相对 `/data` 解析） |
| 采集价值（卡内 V1 期望 `json_log` + `Query "level"`） | 日志是**纯文本**两类行（`[LEVEL] 2026/… \| id \| msg` 与 `[GIN] …`），**非 JSON**；且 `logger/logger.go:67-68` 把 `gin.DefaultWriter = io.MultiWriter(os.Stdout, fd)` ⇒ **文件内容 = stdout 子集**，同刻尾 3 行与 `kubectl logs` 逐字一致（已比对） |

⇒ **结论（2026-10-06 更新）：取证三点全错，但按用户裁定「纠正版落地」** —— 三个前置条件（`-log-dir=/data/logs`、emptyDir 挂 `/data/logs`、容器路径发现）已全部实装并取证；文件侧相对 stdout 仍属**冗余留存**，价值是按文件/轮转边界可查（stdout 主路不可省）。**落地证据**：两站 `k8s-log-<cid>/app-file` 有真实行、`__path__=/data/logs/oneapi-<ts>.log` 等容器字段齐全；滚动 `mnl 4/4`、`sg 2/2` 均 `successfully rolled out`；CR `new-api-app-file` `status OK/200`。**验证方法已升级为**：`aliyun sls GetLogs --project k8s-log-<cid> --logstore app-file --region <R>`（**不是** `sls-newapi-mnl`）。 —— stdout 主路已 100% 覆盖（且 stdout 额外含 stderr 与启动段），文件侧零新增信息量，却要付一次 prod 滚动（mnl 4 + sg 2 副本）+ 每 Pod 最高 ~130 MB（100 万行轮转）overlay 占用 + 重启即丢。
**已实装的纠正口径（与卡内三点偏差）**：`args: ["-log-dir=/data/logs"]` · emptyDir（1Gi）挂 `/data/logs` · CRD 用 `inputType: file` + **`dockerFile: true`**（⚠ **不是 `containerFile`**——后者被 CRD 翻译丢弃，生成的 pipeline 只有 `EnableContainerDiscovery: true` 时才会按容器内路径解析；首轮用 `containerFile` 采到 0 行，改 `dockerFile` 后立即出数）。

证据：探针 `deploy/logs/task26_appfile_probe.sh`，输出 `deploy/logs/task26_sls_index_20261006-165435/appfile_probe_mnl.out`（mnl；sg 同镜像同结论，未单独探）。

---

## 二、ARMS Prometheus（步骤 3）✅

- 实例在册：`ack-newapi-mnl`（`id=994912`，`remote-write-prometheus`，`POSTPAY_GB`，`isClusterRunning=true`）；组件 `arms-prom/arms-prometheus-ack-arms-prometheus` 1/1、`node-exporter` 4/4、`kube-state-metrics` 1/1。
- **V2 实测**：`count(container_memory_working_set_bytes{namespace="new-api"})` = **15**（`HttpApiInterUrl` 公网端点，实测 **AuthFree** 可查，无需 Token）。
- 端点清单（供 Grafana/黑盒引用）：`HttpApiInterUrl = http://ap-southeast-6.arms.aliyuncs.com:9090/api/v1/prometheus/d53ceaaa3a927a094abb56714f8/5108890064395960/cd57e40ce9a634c1698c2f5c5e09bd93c/ap-southeast-6`（另有 `-intranet` 与 RemoteRead/Write、PushGateway、OTel 端点）。
- **降级口径不变**：`/metrics` 未注册（G8），ServiceMonitor 暂无对象可抓，当前只有容器/cAdvisor/kube-state 指标。

## 三、云监控站点监控（步骤 5）⛔ 阻塞

- 探测点实测可用（`DescribeSiteMonitorISPCityList`，Alibaba 探针）：**新加坡 375**（2 探针）、**香港 569**（5）、**日本 576**（3）、**马尼拉 18877**（2）⇒ **推翻 P1-13「马尼拉探测点未确认」**，马尼拉可用。
- 建任务被拦：
  - `CreateSiteMonitor` → **`ExceedingQuota`**（配额面：`SiteMonitorOperatorProbe QuotaLimit=0`、`SuitInfo=free`、`ExpireTime=2026-10-06`；`DescribeSiteMonitorQuota` 的 `SiteMonitorTaskQuota=200` 与资源配额面不一致）。
  - `CreateInstantSiteMonitor` → **`Forbidden: Please register NAAM product code to use this API`**（产品未注册）。
- 解除动作：**开通/购买云监控站点监控套餐**（国际站付费项；⚠ 账户可用余额 0，交易侧可能同证书/Tair 一样拒单）。
- 兜底不变：三重拨测里 GTM 探测（任务 21 未建）与自建 blackbox（T+14 顺延项）仍是独立通道。

## 四、Grafana（步骤 4）⛔ 阻塞

- `ListGrafanaWorkspace`（ap-southeast-1）= 空，无工作区。
- 创建尝试：`CreateGrafanaWorkspace(GrafanaWorkspaceEdition=personal_edition, GrafanaVersion=10.0.x, Duration=1, PricingCycle=Month)` → **`601 create commonBuy Order failed: 调用账号服务错误`**（账号/订单侧，与余额/支付家族同源）。
- **数据源口径已确认可用**（解决卡内坑 4）：ARMS Prometheus 的**公网** `HttpApiInterUrl` 实测 AuthFree ⇒ 新加坡 Grafana 跨区直读可行，不需要马尼拉内网端点/CEN。
- **4 张最小面板**：阻塞于工作区创建；解除后按 SLO 口径补（并入任务 32 口径）。

## 五、V 项判定

| 项 | 结果 |
| --- | --- |
| V1 日志真的进来了 | ✅ 两集群 `app-stdout` 均有实测数据（`_pod_name_` 取证） |
| V2 Prometheus 有系统指标 | ✅ `container_memory_working_set_bytes{namespace="new-api"}` = 15 |
| V3 三重拨测各自独立 | ⚠ 部分：站点监控 ⛔（配额/未注册）、GTM 探测 ⛔（任务 21 未建）、blackbox ⛔（T+14） |

## 六、遗留与后续

1. **站点监控**：购买/开通套餐（账号侧）→ 复跑 `CreateSiteMonitor`（过渡目标=ALB DNS+Host 头；正式目标 `https://www.likha.hk/api/status` 待 G4/G5）。
2. **Grafana**：账号/订单侧修复后创建（新加坡，personal_edition 起）→ 数据源=ARMS 公网端点 → 4 张最小面板。
3. ~~**项目归属决策**~~ → **已裁定（2026-10-06）：维持现状 / A 方案（用户确认）**。容器日志不迁 `sls-newapi-mnl`，不重配 logtail 附加组件；下游查询口径**固定**为 `k8s-log-<cid>`（mnl `cd57e40ce9a634c1698c2f5c5e09bd93c` / sg `ca75829e3492d491d9d434de087913798`），`sls-newapi-mnl` 仅作云产品侧日志。后续告警/看板/拨测引用此口径，不再讨论迁移。
4. ~~**app-file 文件采集**：需给 Deployment 挂 `/app/logs` emptyDir + `LOG_DIR`~~ → **2026-10-06 已按纠正版落地并取证通过**（`-log-dir=/data/logs` + emptyDir 1Gi + CRD `dockerFile: true`；两站 `k8s-log-<cid>/app-file` 有真实行），详见 §一末尾「app-file 取证」。
5. **/metrics（G8）**：合并后 apply ServiceMonitor（`path: /metrics, interval: 30s`）。
6. **测试口径坑（复用任务 47 教训）**：宿主 `http_proxy` 会污染 curl 结论；SLS/ARMS 的 region 参数必须显式传（否则默认 ap-southeast-6 会找错项目）。
7. **审计类索引/投递（2026-10-06）**：两站 `rds-audit` 索引**已建**（IaC `deploy/sls/create_index_audit.sh`，全文 `ttl=30`）；但 RDS SQL 审计 `Disabled`、ActionTrail 投递 OSS ⇒ 两库 `count=0`，**开启投递属 RDS 写、待授权**。`sls-newapi-sg/waf-log` 索引**待任务 20 接入 WAF 后**再加回脚本 `TARGETS`（避免为空 Logstore 付索引存储）。
8. **审计类查询口径**见 §一末尾代码块：`GetLogs` 前先 `GetIndex` 断言（无索引报 `IndexConfigNotExist` 会被误读为"没数据"）。
