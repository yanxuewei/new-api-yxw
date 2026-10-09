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

### ⏱ 追加（2026-10-08）：时间字段精确到毫秒 —— `__time_ns_part__` 落地 ✅（两集群）

**需求**：控制台时间列只到秒，要 ms 级。

**机制（源码级取证）**：SLS 保留字段 `__time__` 恒为**秒**级；亚秒部分单独存 `__time_ns_part__`（0~999999999）。
LoongCollector `plugins/processor/gotime/processor_gotime.go`：
```go
if p.SetTime {
    log.Time = uint32(parsedTime.Unix())
    if config.LogtailGlobalConfig.EnableTimestampNanosecond {
        log.TimeNs = uint32(parsedTime.Nanosecond())   // ← 只有这里写 ns
    }
}
```
⇒ **纯采集不产 ns**：必须「global 开关 + 时间处理器 `SetTime`」两件套。前置：LoongCollector ≥1.8.0（实测 logtail-ds = **v3.3.3.1-aliyun** ✅）、仅 Linux。

**四处"开关带不进去"的实测坑**（从老式 CRD 到新 API 逐个排除）：

| 路径 | 结果 |
| --- | --- |
| 老式 `AliyunLogConfig` 的 `inputDetail.enable_timestamp_nanosecond` | ❌ 控制器翻译时剥键：CLI `GetConfig` 回读无此键 |
| 新 OpenAPI `aliyun sls UpdateConfig`（CLI 3.5.1，`--body` 全量回写） | ❌ 静默剥键（`lastModifyTime` 变、键回读 `null`） |
| python SDK `update_logtail_config`（**新 API 语义**，非老 REST） | ❌ 同上 |
| `ClusterAliyunPipelineConfig` 的 `spec.config` **顶级**同名键 | ❌ 被剥（SLS 回读无此键） |
| `ClusterAliyunPipelineConfig` 的 `spec.config.global` | ✅ **唯一可持久化位置** |

**最终清单**（`deploy/sls/clusterpipelineconfig-app-stdout.yaml` / `...-sg.yaml`）：新式 `ClusterAliyunPipelineConfig`，`spec.project.name` 必填、`spec.config.name` **不许自定义**（webhook 拦）。输入**沿用旧版 Go 插件 `service_docker_stdout`**（⚠ 不是原生 `input_container_stdio` —— 见下方「追加 2」，原生插件会把容器元数据写成 `__tag__:` 标签），`global` 两个开关 + `processor_gotime` 从容器 runtime 字段 `_time_` 解析高精度时间：

```yaml
global:
  EnableTimestampNanosecond: true     # 纳秒总开关（产 __time_ns_part__）
  UsingOldContentTag: true            # 保持 1.x tag 放置（容器元数据走普通字段）
inputs:
  - Type: service_docker_stdout       # 旧版 Go 插件：容器元数据写裸字段
    Stdout: true
    Stderr: true
    IncludeLabel: { io.kubernetes.container.name: new-api }
processors:
  - Type: processor_gotime
    SourceKey: _time_                                # 容器 runtime 时间戳，自带纳秒
    SourceFormat: "2006-01-02T15:04:05.999999999Z07:00"
    DestKey: event_time_ms
    DestFormat: "2006-01-02 15:04:05.000"
    SetTime: true                                    # ← 关键：回写日志时间才产 ns
    KeepSource: true
    NoKeyError: false
    AlarmIfFail: false
```
`processor_gotime` 四个参数 **SourceKey / SourceFormat / DestKey / DestFormat 全必填**（缺一个即 `ParameterInvalid`，如 `DestFormat is missing`）。

**验收**（`GetLogsV2 --region <R>`，`reverse:true` 取最新；注意 `--region` 必须显式传，否则查 sg 项目报 `ProjectNotExist` 假错）：

| 站点 | `__time__` | `__time_ns_part__` | `_time_` |
| --- | --- | --- | --- |
| mnl | 1791445261 | **377344812** | 2026-10-08T15:41:01.**377344812**+08:00 |
| sg | 1791445411 | **453783474** | 2026-10-08T15:43:31.**453783474**+08:00 |

**遗留 / 边界**：
1. **只对新增日志生效**，存量日志不回填 ms；
2. `app-file` Logstore **拿不到 ms**（结构性）：文件采集无 `_time_` 字段，内容 `[GIN] 2026/10/08 - 15:43:43` 本身只有秒；要 ms 需 new-api 日志格式先带 ms（代码改动，未做）。stdout 主路已覆盖，file 属冗余留存，影响可忽略；
3. 老式 `AliyunLogConfig/new-api-app-stdout` 已在两集群删除（否则同容器双采集重复）；仓库老旧清单 `aliyunlogconfig-app-stdout.yaml` 已标废弃；
4. 排序须 `ORDER BY __time__, __time_ns_part__`（单看 `__time__` 仍并列）；SQL 若引用 ns 字段，需在 Logstore「查询分析属性」给 `__time_ns_part__` 建 long 索引。

### ⏱ 追加 2（2026-10-08）：修复容器元数据字段名回归（`_pod_name_`/`_image_name_` 变空）

**现象**：纳秒上线后，控制台/查询里 `_pod_name_`、`_image_name_`、`_container_ip_` 等列全部为空（只有 `content` 有值）。

**根因**（`GetLogsV2` 拉换配置前后同一条日志做字段集合对比）：

| 字段 | 旧配置（旧版 API `AliyunLogConfig`） | 换原生插件后（新版 API pipeline） |
| --- | --- | --- |
| pod 名 | `_pod_name_`（**普通字段**） | `__tag__:_pod_name_`（**系统标签**） |
| image / container_ip / namespace / container_name / pod_uid | 均为**裸字段** | 全部带 `__tag__:` 前缀 |

即 iLogtail 2.0 的「tag 归位」变更：**旧版 API 建的配置沿用 1.x 行为（tag 存普通字段）；新版 API 建的配置默认归位（tag 存 tag 位，SLS 侧渲染成 `__tag__:` 前缀）**。容器元数据从裸字段搬到了 `__tag__:` 标签 ⇒ 依赖裸字段名的控制台视图/查询全部落空。

**两条修正尝试**：
1. `global.UsingOldContentTag: true`（官方升级说明给出的"还原 1.x"开关）→ ❌ **对原生插件无效**，重启 logtail-ds 强制重载后仍为 `__tag__` 前缀（实测）；
2. **输入插件换回 `service_docker_stdout`**（`UsingOldContentTag: true` 保留作双保险）→ ✅ 立即恢复裸字段。

**验收**（两站点；纳秒与裸字段**同时**保留）：

| 站点 | `_pod_name_` | `_image_name_` | `__time_ns_part__` |
| --- | --- | --- | --- |
| mnl | `new-api-stable-f6f987798-m6g2m` | `…/newapi-master:20260928-26ac63233` | 946947518 |
| sg | `new-api-ph-standby-5ccf946c69-wt8jp` | 同上 | 490802677 |

**结论**：`__time_ns_part__` 与输入插件**无关**（由 `global.EnableTimestampNanosecond` + `processor_gotime SetTime` 决定）⇒ 完全可以用回 `service_docker_stdout`，不牺牲毫秒精度。原稿"老的 `service_docker_stdout` 不产 ns"是**误判**，已更正。另注意：`_node_name_`/`_node_ip_`/`_cluster_id_` 这类**节点级/环境 tag 一直是 `__tag__:` 前缀**（新旧一致），不属于本次回归。

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

---

### ⏱ 追加 3（2026-10-08）：app-file 迁移新式 pipeline —— 及"对齐 app-stdout"两处不可行的定论

**背景**：要求 app-file 做与 app-stdout 类似的修改（ms 精度 / 容器元数据裸字段）。

**现状实测（迁移前，`GetLogsV2` 字段对比）**：app-file 的容器元数据**一直是** `__tag__:_pod_name_` / `__tag__:_image_name_` / `__tag__:_container_ip_`（今日与昨日窗口完全一致）⇒ **不是回归**；`__time__` 为**采集时刻**且无亚秒。

**已做迁移（两站点 ✅）**：老式 `AliyunLogConfig` → 新式 `ClusterAliyunPipelineConfig`
（`input_file` + `EnableContainerDiscovery: true` + `ContainerFilters.IncludeContainerLabel` + `global.{EnableTimestampNanosecond,UsingOldContentTag}`），
老 CRD `new-api-app-file` 两集群已删。迁移后采集正常（`__tag__:__path__` / `__user_defined_id__` / 容器元数据齐全，新日志时间连续），**无回归**。清单：`deploy/sls/clusterpipelineconfig-app-file.yaml` / `…-sg.yaml`；老清单 `deploy/sls/aliyunlogconfig-app-file.yaml` 已标废弃。

**结论 1 —— 容器元数据变裸字段：文件采集不可行 ❌**
文件输入（`input_file`，无论老 CRD 的 `common_reg_log` 还是新 pipeline）把容器元数据写入 **LogGroup Tag** ⇒ SLS 侧渲染为 `__tag__:` 前缀；`global.UsingOldContentTag: true` 实测**无效**（对原生插件同样无效，见「追加 2」）。app-stdout 的裸字段来自**旧版 Go 插件 `service_docker_stdout`**，文件采集无对应插件 ⇒ 结构性差异，配置层面无法消除。

**结论 2 —— 时间精确到 ms：文件采集不可行 ❌（除非改代码）**
`__time_ns_part__` 只由 `processor_gotime` 在 `SetTime=true` 时写入，且需要**亚秒时间源**。文件日志既无 `_time_` 类容器 runtime 字段，内容 `[GIN] 2026/10/08 - 18:31:49 | …` 也**只有秒** ⇒ 无源可用；`EnableTimestampNanosecond` 单开不产 ns（与 stdout 结论一致）。**要出 ms 必须先让 new-api 日志格式带毫秒**（`common/logger` + GIN 格式，代码改动，未做）；改完后本新式配置 + `processor_gotime(SourceKey=content, 带 ms 的 pattern)` 即可生效——本次迁移正是为此铺路。

> ⏭ **2026-10-09 已按方案 A 实现**（用户裁定"要真出 ms"）：日志格式已带毫秒（代码改动）、SLS 侧 `processor_regex + processor_gotime` 已加 → **见下方「追加 4」**。本节的"不可行"结论**仅在"不改代码"前提下**成立。

**关键坑 —— 容器去重使"探针法"失效**：曾用独立 logstore `app-file-probe` + 平行 pipeline 配置试探，结果 **0 条**。原因：老配置 `new-api-app-file` 已占用该容器/路径，新配置默认**不重复采集同一容器**（`AllowingIncludedByMultiConfigs` 默认 false）⇒ 必须"删老配置 → 上新配置"才能接管。探针 logstore 已删除（`DeleteLogStore`），项目 logstore 数回到 7。

**证据**：`deploy/logs/sls_dump_appfile.sh`（迁移前字段对比）、`sls_newest_appfile.sh` / `…_sg.sh`（迁移后验收）、`probe_create.sh` / `probe_index.sh` / `probe_check3.sh`（探针，含踩坑记录）。

---

### ⏱ 追加 4（2026-10-09）：app-file 毫秒**已实现** —— 代码侧改日志格式 + SLS 侧加解析处理器

> 本节**推翻「追加 3 · 结论 2」的"不可行"**：那个判断本身没错（文件日志确无 ms 源），但用户裁定走**方案 A —— 改 new-api 日志格式带毫秒**，从根上造出亚秒时间源。

#### 一、代码改动（3 个上游文件 5 处，最小化原地补丁）

| 文件:行 | 影响的日志行 |
|---|---|
| `middleware/logger.go:38` | `[GIN]` 访问日志 |
| `common/sys_log.go:20 / 27 / 34` | `[SYS]` / `[SYS]`(err) / `[FATAL]` |
| `logger/logger.go:113` | `[INFO] / [WARN] / [ERR] / [DEBUG]` |

统一 `2006/01/02 - 15:04:05` → `2006/01/02 - 15:04:05.000`。

**为什么是"改源码"而非"扩展"**：GIN 访问日志格式由 `middleware.SetUpLogger` 内的**闭包**决定，无 env / 配置项可覆盖；且该函数还承载**私有脱敏** `redactTaskArtifactAccessQuery`（任务产物访问 query 脱敏），在 `main.go` 侧整体替换会**丢脱敏** ⇒ 确无扩展点，按 fork 纪律第 1 条的例外做**最小化原地补丁**（仅动格式串，不碰控制流、无格式化噪音）。

**fork 二次开发纪律落地**（用户 2026-10-09 下达 5 条；与 `deploy/git开发-发布-值班规范.md §4.3` **同源**，两处口径已对齐）：
- 根目录新增 **`UPSTREAM_CHANGES.md`** —— 定制清单（逐条：上游文件/改动/原因/提交号）+ "不动的地方"反例表
- 新增 **`ours_likha/{code,ops,doc}`** —— 自研与上游**物理隔离**（含 `ours_likha/.gitattributes` 固化行尾）
- `ours_likha/ops/patches/0001-log-ms-precision.patch` —— 复现补丁（`git apply` 可直接回放）
- `ours_likha/ops/verify-upstream-changes.sh` —— **定制在位校验**（sync 前后必跑，退出码非 0 即有定制被覆盖）
- `ours_likha/ops/local-ci.sh` —— 本地复现 `ci.yml` **全量** job（backend + frontend）

#### 二、SLS 侧（app-file，两站点已 apply ✅）

在原 pipeline 上加了两个 processor（`GetLogtailPipelineConfig` 回读确认**已持久化**，CRD `success: true`）：

```yaml
processors:
  - Type: processor_regex        # ① 从整行 content 抓出毫秒时间戳子串
    SourceKey: content
    Regex: '^\[[A-Z]+\]\s+(\d{4}/\d{2}/\d{2} - \d{2}:\d{2}:\d{2}\.\d{3})'
    Keys: ["log_ts"]
    FullMatch: false             # ★ 默认 true 要求**整字段**匹配 ⇒ 必须显式 false，否则全抓不到
    KeepSource: true
    NoMatchError: false
  - Type: processor_gotime       # ② 解析 log_ts 并 SetTime 回写 → 触发 TimeNs
    SourceKey: log_ts
    SourceFormat: "2006/01/02 - 15:04:05.000"
    SetTime: true
    NoKeyError: true
```

- **为什么不能只给 `gotime`**：它对 `SourceKey` 做**整字段**解析，而 `content` 是整行（`[GIN] 2026/10/09 - 12:06:31.123 | api | …`）⇒ 必须先 regex 抽出子串。两步缺一不可。
- **兼容旧行**：改造前写入的行没有 `.000`，regex 不命中（`NoMatchError:false` 不报错、不丢日志），`gotime` 因 `NoKeyError:true` 跳过 ⇒ 这些行退回**采集时刻**、无 `__time_ns_part__`。属预期降级，历史数据不回填。
- **探针法在此依然失效**（容器去重，见「追加 3」关键坑），故直接改**现有同名 CRD** `new-api-app-file-ns`，不新建平行配置。

#### 三、验证

| 项 | 结果 |
|---|---|
| `go vet ./...`（root + relaykit） | ✅ 通过 |
| `go build ./...`（root + relaykit） | ✅ 通过 |
| `make test`（全部包） | ✅ **全绿**（`ours_likha/ops/local-ci.sh` → PASS=5 FAIL=0） |
| 两站点 SLS `processors` 持久化 | ✅ `success: true`（回读一致） |
| 前端 job（`bun typecheck` / `bun test`） | ⚠ 本机 WSL 无 bun 未跑；改动**纯后端**，由 PR 的 CI 覆盖（CI 不 skip 任何 job） |

#### 四、发布状态（⛔ 待用户一步）

- **提交**：`9fff2aa47`（`feat(log)`）+ `373c1d580`（`chore(ours_likha)`）（+ 清单回填/脚本/报告随后的 `chore` 提交），分支 **`feature/log-ms-precision`**（PR 待开）。
- **目标镜像**：`acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20261009-373c1d580`（tag 不可变，新 tag 合规）。
- ⛔ **未推送**：ACR 访问凭证（开通服务时设置的密码）本机未配置，`push.sh` 需交互输入 ⇒ 待提供后执行 `bash push.sh -n prod -t 20261009-373c1d580`。
- ⛔ **未部署**：按规范 §7.1「集群内任何变更必须体现为 ops 仓库一次 commit，禁止手工 `kubectl set image`」——建议走 release 通道，或**至少先过 canary**（`deploy/aliyun/ph/canary-deployment.yaml` 已存在）验证 ms 再接全量。

**本地构建镜像失败（两次，环境问题非代码问题）**

| 次 | 源 | 结果 |
|---|---|---|
| 1 | `Dockerfile.mac` 默认（goproxy.cn） | `go mod download` → `dial tcp 59.34.197.45:443: i/o timeout`，2m01s 失败 |
| 2 | `--go-proxy aliyun` | Go 依赖 OK（2.7s，阿里云源通）；**前端 `bun install` 跑 1395s 后被终止**（exit 143），23m23s 失败 |

**容器出网探针（`deploy/logs/net_probe.sh`，同一时刻两个镜像结果相反）**：

| 目标 | tools 镜像 | alpine:3.20 |
|---|---|---|
| `registry.npmmirror.com` | **FAIL** | OK |
| `registry.npmjs.org` | OK | OK |
| `mirrors.aliyun.com/goproxy` | OK | **FAIL** |
| `goproxy.cn` | OK | OK |

⇒ **WSL 内 Docker 容器出网间歇抖动**（非墙、非代码）：两次构建分别在 Go 源与 npm 源上卡死，形态与探针互相矛盾的结果吻合。
⇒ **结论：本机不具备稳定构建镜像的条件**。发版应走 **CI（`release.yml`，tag 触发）** 或在出网稳定的主机上构建；`push.sh` 自身参数已就绪（`--npm-registry official` 可绕 npmmirror，但官方源实测慢约 10 倍）。

### ⏱ 追加 5（2026-10-09）：毫秒改动**运行时证据已取得**；构建卡点精确定位（修正「追加 4」的口径）

#### 一、代码侧：运行时自检通过 ✅（不再只有静态校验）

新增 `ours_likha/code/cmd/logms-check`（自研目录，不依赖 DB/Redis/Docker），把 `gin.DefaultWriter`
重定向到内存 buffer 后，**真实调用**三条被改路径并机械断言：

```
[SYS]  2026/10/09 - 12:45:09.668 | ms-probe: sys log line
[SYS]  2026/10/09 - 12:45:09.668 | ms-probe: sys error line
[INFO] 2026/10/09 - 12:45:09.668 | SYSTEM | ms-probe: info line
[WARN] 2026/10/09 - 12:45:09.668 | SYSTEM | ms-probe: warn line
[ERR]  2026/10/09 - 12:45:09.668 | SYSTEM | ms-probe: err line
[GIN]  2026/10/09 - 12:45:09.670 | web |  | 200 |  6.7µs | 127.0.0.1 | GET /probe
────────────────────────────────
ms 命中 = 6   秒级行 = 0   → RESULT=MS_CONFIRMED
```

其中 `[GIN]` 行是经 `middleware.SetUpLogger` 的**真实 formatter**（含 `redactTaskArtifactAccessQuery` 中间件）
发真实 HTTP 请求产生的 ⇒ **6/6 行带 `.mmm`、0 行秒级**，改动确认生效。

用法：`go run ./ours_likha/code/cmd/logms-check`（已并入 `UPSTREAM_CHANGES.md` 的同步流程第 4 步与「相关文档」）。
`go vet ./ours_likha/...`、`go test ./ours_likha/...` 均通过；`local-ci.sh` 仍 **PASS=5 FAIL=0**（backend 全绿）。

#### 二、构建卡点：是**高并发出网塌陷**，不是随机抖动（修正「追加 4」结论）

「追加 4」把两次构建失败归为「间歇抖动」。追加 5 用**隔离复现**把口径收紧为**确定性**结论：

| 实验 | 结果 | 排除的可能 |
|---|---|---|
| 脱离 BuildKit、不用 cache mount，容器内用**仓库真实 `bun.lock`** 跑 `bun install` | **稳定复现卡死**（240s 无进展、无输出） | ❌ 不是 BuildKit / cache mount 死锁 |
| 同一次复现中采样容器 netns 的 `/proc/<pid>/net/tcp` | **SYN_SENT ≈ 211，ESTABLISHED 仅 13~25**，且 200 条长挂 SYN_SENT 不消退 | ❌ 不是 DNS、不是"墙" |
| `nf_conntrack_count / max` | `112 / 262144` | ❌ 不是 conntrack 表满 |
| 全新容器 `bun add lodash`（4 个请求） | **391ms 成功** | ❌ 容器出网**本身**没坏 |
| `go mod download`（aliyun goproxy） | **2.7s 成功** | ❌ Go 侧无问题 |

⇒ **根因**：本仓库 `web/` 有 800+ 依赖，`bun install` 会一次性开出 **200+ 并发 TCP**；
**WSL2 的 NAT 在此时刻只能建立十几条、其余 SYN 永久无应答** → bun 永久等齐 → 卡死。
低并发（`lodash`）与主机侧 `curl`（单连接）都正常，所以此前的"探针一正一反"其实是**并发度差异**，
并非源站差异。

⇒ **结论（收紧）**：**本机 Windows/WSL2 环境不适合构建本仓库镜像**（并发出网受限），
与我们的代码 / Dockerfile 无关。可选出路：
1. **CI 构建**（首选，符合规范 §7.1「集群变更走仓库」）：但注意 fork 现有
   `.github/workflows/docker-image-branch.yml` / `docker-build.yml` **推的是 Docker Hub `calciumion/new-api`**，
   **没有**推我们 ACR 的 workflow ⇒ 需新增一个「推 `acr-newapi-mnl-registry.../newapi-prod/newapi-master`」的 workflow。
2. **在 macOS（日常主力机，网络正常）执行**：`bash push.sh -n prod -t 20261009-373c1d580`（需 ACR 密码）。
3. 本机降并发重试（降低 `bun install` 并发度 / 预热全量 bun 缓存后再构建）——属绕行，不推荐作为发版通道。

#### 三、状态汇总

| 环节 | 状态 |
|---|---|
| 代码改动（5 处毫秒） | ✅ 已提交 `9fff2aa47` / 收尾 `a6af4ae85`，分支 `feature/log-ms-precision` |
| 运行时自检 | ✅ `RESULT=MS_CONFIRMED`（6/6 带 ms、0 秒级） |
| 静态在位校验 | ✅ `verify-upstream-changes.sh` PASS=6 FAIL=0 |
| 本地全量后端 CI | ✅ `local-ci.sh` PASS=5 FAIL=0（frontend 因无 bun 计 FAIL，由 PR CI 覆盖） |
| 补丁可干净回放 | ✅ `git apply --check` on `main` 通过 |
| 两站点 SLS pipeline | ✅ `success: true`（回读一致） |
| 镜像构建 | ⛔ 本机 WSL2 并发出网受限（见上），改走 CI 或 macOS |
| 推 ACR / 部署 | ⛔ 待用户提供 ACR 密码；部署按规范 §7.1 走 release（或先 canary） |


