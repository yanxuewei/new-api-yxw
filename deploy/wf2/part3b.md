## Day 3 · 泳道 B：可观测、HPA 容量与灰度/故障演练

> 本泳道参数基线（§2.1）：主 region `ap-southeast-6`（马尼拉，仅 6a/6b）、备 region `ap-southeast-1`（新加坡）、域名 `api.likha.com` / `ops.likha.com`、命名空间 `new-api`、服务端口 `3000`、K8s 1.35 + Terway。节点池机型 `g9i.2xlarge`（g8i 未上架马尼拉）；HPA 上限对应配额已批：**MNL 64 vCPU = 8 节点、SG 96 vCPU = 12 节点**。
>
> **⚠ 探针降级口径（贯穿全泳道，每个涉及探针的卡都必须带）**：当前仓库**没有** `/healthz`、`/readyz`、`/metrics`，唯一状态接口为 `GET /api/status`（`router/api-router.go:26`）。G8 代码补项未完成前，所有基于自定义指标 HPA、ServiceMonitor 抓取、P95 首字延迟门禁均为降级运行，**SLA 承诺应相应下调**，并在 §12 证据链中如实记录。ARMS APM 马尼拉可用性未确认（P1-12），**不纳入证据链**。

### Day 3 · 任务 26｜日志服务 SLS / 可观测监控 Prometheus 版 / 可观测可视化 Grafana 版 / 云监控站点监控（人员B，2.5 人时，09:00–11:30）

**前置/状态**：任务 21（ACK 集群）与任务 24（ALB Ingress）已完成，`kubectl --context mnl get nodes` 全部 Ready；SLS/RDS 审计日志授权角色 `AliyunServiceRoleForSLS` 已建。
**依赖警示（探针降级口径）**：`/metrics` 未注册（P1-20），ServiceMonitor 现在**没有对象可抓**；G8 落地前 Prometheus 侧只能采容器/cAdvisor 指标。

**操作步骤（CLI-first）**：

1. 建两站 SLS Project 与 Logstore（成本与合规口径不同，`sys`/`audit` 必须分 store）：

```bash
aliyun sls CreateProject --ProjectName sls-newapi-mnl --Description "new-api prod mnl"
aliyun sls CreateProject --ProjectName sls-newapi-sg  --Description "new-api prod sg"
for LS in app-stdout app-file alb-access waf-log rds-audit actiontrail; do
  aliyun sls CreateLogStore --ProjectName sls-newapi-mnl --LogStoreName $LS --Ttl 30
done
aliyun sls CreateLogStore --ProjectName sls-newapi-mnl --LogStoreName audit --Ttl 180 || \
  aliyun sls CreateLogStore --ProjectName sls-newapi-mnl --LogStoreName app-file-audit --Ttl 180
```

期望输出：

```
（CreateProject/CreateLogStore 均无错误返回；空输出即成功）
$ aliyun sls ListLogStores --ProjectName sls-newapi-mnl
{"count":7,"logstores":["app-stdout","app-file","app-file-audit","alb-access","waf-log","rds-audit","actiontrail"]}
```

2. 采集用 `logtail-ds` + `AliyunLogConfig` CRD **声明式下发**（别在控制台手工配，无法回归）：

```bash
kubectl --context mnl apply -f deploy/sls/aliyunlogconfig-app-file.yaml
kubectl --context mnl get aliyunlogconfig -n kube-system
```

期望输出：

```
NAME                 PROJECT          LOGSTORE   AGE
new-api-app-file     sls-newapi-mnl   app-file   12s
```

3. 可观测监控 Prometheus 版：确认 ACK 组件已装，`http-metrics` 抓取先只覆盖容器指标：

```bash
kubectl --context mnl get ds,deploy -n arms-prom
# 期望：arms-prometheus-agent Running；G8 后再 apply new-api ServiceMonitor（path: /metrics, interval: 30s）
```

4. 【控制台】可观测可视化 Grafana 版：工作区**建在新加坡**（P1-11，Managed Grafana 不在马尼拉），数据源指向可观测监控 Prometheus 版马尼拉实例的**公网可读端点 + Token 鉴权**（跨区读，不可用马尼拉内网端点）；SLO 看板留到任务 32。
   `[图 D3-B-26a｜拍摄对象：Managed Grafana 工作区列表（新加坡）与马尼拉 Prometheus 数据源配置页；打码：账号 UID、数据源 Token、公网端点 URL]`
5. 云监控站点监控：探测点选可用的（新加坡/东京/香港），断言响应含 `"success":true` 且 `version` 匹配：

```bash
aliyun cms DescribeSiteMonitorList --Keyword api.likha.com
```

**马尼拉探测点未确认（P1-13），必须叠加三重兜底**：云监控站点监控（外部）+ ACK 内 `blackbox-exporter` 多 region 自拨 + GTM 健康探测。

**验证方法**：

```bash
# V1 日志真的进来了（不要只看 logtail 状态）
aliyun sls GetLogs --ProjectName sls-newapi-mnl --LogStoreName app-file \
  --From $(date -d '5 minutes ago' +%s) --To $(date +%s) --Query "level" --Line 3
# 期望：返回 JSON 行，且 __source__ 是 Pod IP
# V2 Prometheus 有系统指标
curl -s "${ARMS_PROM_ENDPOINT}/api/v1/query?query=container_memory_working_set_bytes{namespace=\"new-api\"}" | jq '.data.result|length'   # >0
# V3 三重拨测各自独立产生结果（任一失效不会误判可用）
```

**不通过时修复**：
- 现象：GetLogs 为空 → 诊断：`kubectl logs -n kube-system -l app=logtail-ds | grep new-api-app-file`，常见为 `LOG_DIR` 落容器可写层未挂卷 → 修复：`LOG_DIR` 挂 `emptyDir`，logtail 走容器 stdout 双路，文件日志仅作补充。
- 现象：Grafana 看板空白 → 诊断：数据源测试连通失败，多为跨区走马尼拉内网端点 → 修复：改公网端点 + Token，或走云企业网。
- 现象：站点监控无数据 → 诊断：`DescribeSiteMonitorList` 里任务状态 `disabled` 或探测点全选在马尼拉 → 修复：改选新加坡/东京/香港探测点，马尼拉缺位由 blackbox 补。

**坑**：
- 坑 1｜Pod 重启即丢文件日志。现象：重启后 `app-file` 断档。后果：审计链断裂。改进：stdout 双路采集（上面已做）。
- 坑 2｜SLS 成本失控。现象：debug 级 + 180 天 + 全量 ALB 访问日志。后果：月账单可超服务器成本。改进：`ERROR_LOG_LEVEL=warn`；ALB 访问日志只留 30 天 + 采样。
- 坑 3｜把 Prometheus 当唯一告警源。现象：集群故障时监控一起瞎。后果：P1 无人知晓。改进：站点不可用类 P1 必走云监控站点监控/GTM 外部视角，双通道。
- 坑 4｜Grafana 在新加坡却配了马尼拉内网数据源端点。后果：跨区不通、看板空白。改进：公网端点 + Token 鉴权（见步骤 4）。

### Day 3 · 任务 32｜SLO / 错误预算看板 + 告警与值班（P1 走电话）（人员B，1.5 人时，11:30–13:00）

**前置/状态**：任务 26 完成，Prometheus/Grafana/SLS 三源可查；云监控联系人/联系人组已建。
**依赖警示（探针降级口径）**：延迟 P95 SLO 与请求成功率指标依赖网关 `/metrics`（G8 未落地）；当前可用性 SLO 只能靠三源外部拨测 + ALB 日志代理计算，**SLA 承诺应下调**并在 §12 记录口径缺口。

**操作步骤（CLI-first）**：

1. SLO 定义（与 §12 口径一致），写入 Grafana（新加坡工作区）看板：

| SLO | 指标 | 目标 | 窗口 |
| --- | --- | --- | --- |
| 可用性 | 外部拨测成功率（GTM + 站点监控 + blackbox 三源） | 99.95% | 月 |
| 请求成功率 | 5xx 比例（排除 4xx 与限流 429） | ≥ 99.9% | 5min 滑窗 |
| 延迟 | 首字延迟 P95 | ≤ 800 ms | 5min（需 G8） |
| 网关链路 | 上游 5xx 比例 | 单独曲线，**不计入自身 SLO** | 月 |
| DB | 慢查询 >1s 数 | 阈值告警 | 5min |

2. 错误预算：99.95% = **21.6 分钟/月**；PromQL 多窗口燃烧率（1h/6h/24h/72h），5min 粒度评估：

```promql
# 燃烧率示例（rapid burn，触发 P1/P2）
(sum(rate(alb_upstream_5xx{host="api.likha.com"}[1h])) / sum(rate(alb_requests_total{host="api.likha.com"}[1h])))
  / 0.0005 > 2
```

3. 告警分级与路由：P1（站点不可用、备站不可接管、DB 不可写、密钥泄露）→ **电话** + 群 + 短信，5 分钟响应；P2（燃烧率 >2x、P95 超标 10 分钟、HPA 打满 max、节点池扩容失败）→ 群 + 短信 30 分钟；P3（单副本重启、慢查询、证书 30 天到期）→ 群，下个工作日。

```bash
aliyun cms DescribeContactList   # 期望：含 2 名值班 + 项目负责人，电话已验证
```

4. 【控制台】云监控告警规则绑定联系人组并勾选**电话通道**；值班表 2 人轮换 + 项目负责人升级路径；`ops.likha.com` 只对内网/堡垒开放。
   `[图 D3-B-32a｜拍摄对象：云监控报警规则的通知方式（电话+短信+钉钉群）与联系人组页；打码：值班人员手机号、钉钉群 webhook]`
5. 发布冻结决策接入燃尽曲线：月累计预算消耗 >25% → 只允许修复类变更；>50% → 冻结，需架构负责人签字例外；解冻条件为连续 7 天燃烧率 <1 且复盘关闭。

**验证方法**：

```bash
# V1 告警通路自证：制造一次可控 P1
kubectl --context mnl -n new-api scale deploy/new-api-stable 0
# 期望：≤3 分钟内 P1 电话 + 群消息触达 2 名执行人 + 项目负责人（截图 + 通话记录留证）
kubectl --context mnl -n new-api scale deploy/new-api-stable 4
# V2 静默与收敛：一次故障只产生 1 条 P1，关联告警折叠不刷屏
# V3 看板数字与 SLS/Prometheus 原始查询抽查 3 个面板一致
```

**不通过时修复**：
- 现象：P1 只到群没打电话 → 诊断：云监控国际站电话告警通道可用性未实测 → 修复：改用 ARMS 或第三方值班（on-call）服务，并在 §12 记录实际通道；不许留"邮箱告警"。
- 现象：接管/峰值期告警风暴或集体哑火 → 诊断：阈值按日常流量绝对量设定 → 修复：全部改**比率/燃烧率**阈值。
- 现象：预算被上游故障烧穿 → 诊断：`upstream_error`（上游 5xx/429）混进自身 5xx → 修复：`router` 层区分自身错误与上游错误指标，上游单独曲线，不计入自身 SLA（§12 排除项），但单独看板必须存在，避免"预算没烧完却整站不可用"的误判。

**坑**：
- 坑 1｜告警用邮箱。现象：夜间 P1 无人响应。后果：错误预算烧穿。改进：P1 电话强制，通道实测留证。
- 坑 2｜阈值按日常流量设。现象：接管后立刻失真。后果：漏报或刷屏。改进：比率/燃烧率。
- 坑 3｜上游 429/5xx 算进自身可用性。后果：SLA 判定被上游绑架。改进：指标分类 + §12 排除项③。
- 坑 4｜看板没人复核口径。后果：对外承诺与对内数据打架。改进：任务 34 检查表加"SLA 口径三方（开发/运维/商务）签字"。

### Day 3 · 任务 43｜主站 HPA 4–16 落地 + 探针与单实例容量基线 C（人员A，2 人时，09:00–11:00）

**前置/状态**：任务 42（cluster-autoscaler）完成，MNL 节点池 `g9i.2xlarge` max 8（64 vCPU 配额已批）；压测在 `new-api-perf` 命名空间，同规格 request 2C4G / limit 4C8G。
**依赖警示（探针降级口径）**：无 `/readyz` 可用作就绪探针、无 `/metrics` 供自定义指标 HPA；唯一状态接口 `GET /api/status`。G8 未完成则本卡按降级方案执行，**SLA 承诺应下调**。

**操作步骤（CLI-first）**：

1. 单实例容量基线 C——**必须实测，不是估算**（所有容量推导的地基）：

```bash
hey -z 120s -q <rate> -c <conc> -m POST -H "Content-Type: application/json" \
  -D /tmp/req.json https://api.likha.com/v1/chat/completions
```

在 perf 环境按 100/250/500/800/1200 并发 SSE 逐档记录 CPU p50、内存、FD、p95 首字延迟、5xx；取"p95 仍满足 SLO 且 5xx<0.1%"的最大并发 = **C**。峰值 1,500 并发 ⇒ 需 `ceil(1500 / C)` 副本 ≤ 16，否则升规格/优化或申请 max 24（配额联动 §3.4）。

2. **容量预算三不变量必须先验**（超限则 HPA 越大越危险）：
   - I-1：`SQL_MAX_OPEN_CONNS × 实例数 ≤ RDS max_connections × 0.8`；
   - I-2：**16 实例时必须部署 PgBouncer**（transaction 模式），否则 RDS 连接必爆；
   - I-3：节点池可调度容量 ≥ HPA max × 副本 request。

```bash
kubectl --context mnl -n new-api exec deploy/new-api-stable -- printenv SQL_MAX_OPEN_CONNS
psql "host=${RDS_HOST} user=${DBA_USER} dbname=newapi" -c "SHOW max_connections;"
# 期望：200 × 16 ≤ max_connections × 0.8 不成立 ⇒ PgBouncer 上线为切流前置（任务 11 已部署则复核）
```

3. HPA 落地（G8 后加自定义指标 `new_api_active_sse_connections`；**过渡期用内存利用率 60–70% of request**，SSE 是 IO 密集，只靠 CPU 明显滞后）：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: hpa-new-api-stable, namespace: new-api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: new-api-stable}
  minReplicas: 4
  maxReplicas: 16
  metrics:
  - type: Resource
    resource:
      name: memory
      target: {type: Utilization, averageUtilization: 65}
```

4. 探针降级配置（警示口径见上）：readiness/liveness 暂用 `GET /api/status:3000`；**liveness 不做 DB 依赖检查**（`/api/status` 不查库即可满足），避免 DB 故障时误杀 Pod。内存 request=limit（Guaranteed），CPU 可 burstable。

**验证方法**：

```bash
kubectl --context mnl -n new-api describe hpa hpa-new-api-stable   # 无 FailedGetResourceMetric
# 压测驱动扩容：期望 CPU/内存过 65% → 4→6→9→13→16 阶梯，无 Pending，压测 5xx 不升高
watch -n2 'kubectl --context mnl -n new-api get hpa,pods -l track=stable --no-headers | head'
# 缩容：撤压后 5 分钟稳定窗内回落且不低于 min 4
kubectl --context mnl -n new-api get pdb -o wide   # 缩容期间 ALLOWED DISRUPTIONS ≥1
```

**不通过时修复**：
- 现象：扩到 16 但 Pod Pending → 诊断：节点池 max 8 不够（§9.4 坑 1）→ 修复：升节点池 max 或降副本 request，复核 I-3。
- 现象：HPA 不动 → 诊断：`describe hpa` 见 `FailedGetResourceMetric`（metrics-server 缺失）/ `scaleTargetRef` 名错 / 被 `kubectl scale` 手工设过 replicas 短期锁住（看 `behavior` 事件）→ 修复：装 metrics-server、改引用名、删除手工 scale。
- 现象：连接打满 CPU 却 30% → 诊断：SSE 场景 CPU 是坏指标 → 修复：内存 HPA + 外部指标适配器 + 手动扩容 Runbook（§13.6）保底。

**坑**：
- 坑 1｜SSE 下 CPU HPA 失效。现象：内存/FD 上升而 HPA 不扩。后果：用户超时——**本方案容量层最大风险**。改进：见上条修复。
- 坑 2｜`/api/status` 作 liveness 在 DB 故障时误杀 Pod。后果：全站点闪断。改进：G8 补 `/healthz`（轻量）+`/readyz`（含依赖）；预案 §13.2。
- 坑 3｜request≠limit 内存超卖。现象：节点 OOMKill 随机挑 Pod。后果："偶发重启"谜案。改进：内存 Guaranteed。
- 坑 4｜`BATCH_UPDATE_ENABLED=true` 时扣费批量落库，Pod 崩溃窗口内**最多丢 ≤5s 扣费（红线）**。后果：对账差异、收入损失。改进：该红线必须写入任务 37/43 的额度对账判据；对账 Job master-only 运行。

### Day 3 · 任务 44｜备 region HPA 2–24 + 1.5× 接管容量验证（人员A，1.5 人时，13:30–15:00）

**前置/状态**：任务 43 得出实测单实例容量 C；新加坡节点池 `g9i.2xlarge` `min:2, max:12`（96 vCPU 配额已批）；**演练前硬门禁**：`aliyun ecs DescribeAccountAttributes --RegionId ap-southeast-1` 复核 vCPU 配额，未批复禁止演练。

**操作步骤（CLI-first）**：

1. HPA `min:2, max:24` 落地（指标同任务 43 降级方案）。12 节点 × 8C 按 request 2C/副本理论可容 36 副本 ≥ 24，但要扣系统预留与 PDB 窗口，以实测为准。
2. 接管必须按 **扩容 → Ready → 再切流** 顺序，绝不能"先切流再等扩容"：

```bash
# 演练窗口内验证扩容上限（切流之前）
kubectl --context sg -n new-api patch hpa hpa-new-api-ph-standby --type=merge \
  -p '{"spec":{"minReplicas":24}}'
kubectl --context sg -n new-api wait --for=condition=available deploy/new-api-ph-standby --timeout=15m
kubectl --context sg get nodes
```

期望输出：

```
deployment "new-api-ph-standby" condition met   # 记录从 min=2 抬到 24 全 Ready 总耗时 = warmup 时长（RTO 关键组成）
# 演练完立即复位：
kubectl --context sg -n new-api patch hpa hpa-new-api-ph-standby --type=merge -p '{"spec":{"minReplicas":2}}'
```

3. 容量判据换算：`备站 24 副本 × 实测 C ≥ 1.5 × 主站峰值并发`；四项资源维度（cpu/mem/fd/上游配额）**取最紧**做判据，不能只按 vCPU。
4. 抬升完成后、切流之前，先做 §11.4 Tair/DB warmup（冷连接池 24 副本一起向跨区主库发起 300 连接会打爆）。

**验证方法**：

```bash
kubectl --context sg -n new-api get pods -l app=new-api --no-headers | awk '$2!=1/1 && $3!="Running"||$2!~/Ready/{c++} END{print c+0}'
# 期望：0（24 副本全部 Running & Ready）；warmup 耗时 ≤6 分钟（>10 分钟则 RTO 承诺需重谈）
kubectl --context mnl -n new-api get hpa   # 抬升期间主站无 5xx 上升
# 备站连接池复核不变量 I-1/I-2：跨区接管同样受 RDS max_connections ×0.8 约束（PgBouncer 前置）
```

**不通过时修复**：
- 现象：打到一半 `QuotaExceeded` → 诊断：SG 96 vCPU 配额未生效 → 修复：终止演练（M4 判不过），走 §3.4 出口补配额，清理半起节点。
- 现象：24 副本中部分 Pending → 诊断：内存维度不足（24×4Gi=96Gi，节点机型内存若与假设不同即紧）→ 修复：以实测四项最紧约束重定 max。
- 现象：扩容成功但切流后 DB 慢查询飙升 → 诊断：冷缓存/冷池冲击 → 修复：warmup 三步顺序（扩容量 → Tair/DB warmup → 切流）写死进 Runbook。
- 现象：节点缩容与 HPA 互相拉扯 → 诊断：cluster-autoscaler `scale-down` 与 HPA 打架 → 修复：缩容冷却 ≥10min；演练期间 `kubectl annotate` 节点池临时关缩容。

**坑**：
- 坑 1｜按 vCPU 算容量忽略内存/FD。后果：判据虚高、真接管时 OOM。改进：四项取最紧。
- 坑 2｜配额没批复就演练。后果：伸缩失败 + 半起节点残留。改进：`DescribeAccountAttributes` 前置复核。
- 坑 3｜连接池/缓存冷启动打爆跨区主库。改进：warmup 顺序固化。
- 坑 4｜autoscaler 与 HPA scale-down 打架。改进：接管演练窗口关闭缩容。

### Day 3 · 任务 27｜canary Deployment + 独立 Service/Ingress（权重 5）（人员B，2 人时，13:30–15:30）

**前置/状态**：任务 26 观测面可用（canary 独立告警需要它）；候选镜像已推 ACR；stable 正常运行。
**依赖警示（探针降级口径）**：canary 就绪判定暂用 `GET /api/status`，无 `/readyz`；灰度门禁的 P95 首字延迟指标依赖 G8 `/metrics`，未落地前该门只能人工看 ALB 日志近似——**SLA/发布承诺应下调**。

**操作步骤（CLI-first）**：

1. canary Deployment（1 副本、独立 label `track: canary`、反亲和到不同节点）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-api-canary, namespace: new-api}
spec:
  replicas: 1
  strategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}
  selector: {matchLabels: {app: new-api, track: canary}}
  template:
    metadata: {labels: {app: new-api, project: new-api, site: ph-mnl, track: canary, env: prod}}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - {topologyKey: kubernetes.io/hostname, labelSelector: {matchLabels: {app: new-api, track: canary}}}
      containers:
      - name: new-api
        image: ${ACR_MNL_PREFIX}:<candidate-sha>
        env: [{name: NODE_TYPE, value: "slave"}, {name: CANARY, value: "true"}]
```

2. 独立 Service + 两条 Ingress 指向同 host，canary 用独立 Ingress 承载权重注解 `alb.ingress.kubernetes.io/canary-weight`（初始 5）与 header 强制路由：

```yaml
# stable Ingress
alb.ingress.kubernetes.io/canary: "false"
# canary Ingress
alb.ingress.kubernetes.io/canary: "true"
alb.ingress.kubernetes.io/canary-weight: "5"
alb.ingress.kubernetes.io/canary-by-header: "x-canary"
alb.ingress.kubernetes.io/canary-by-header-value: "1"
```

```bash
kubectl --context mnl apply -f deploy/canary/
kubectl --context mnl -n new-api get deploy,svc,ingress -l 'track in (stable,canary)'
```

3. 副本数校验（J48 负荷公式）：canary 必须能独立扛住 `权重 × 峰值 QPS`，5% 峰值 ≈ `ceil(0.05 × 峰值 / 单实例容量 C)`，C 取任务 43 实测值。
4. 给 canary 配**独立告警**（错误率、P99），小样本阈值放宽但绝对量兜底（如 5xx>3 即告警）。

**验证方法**：

```bash
# V1 头流量强制进 canary
curl -sS -H "x-canary: 1" https://api.likha.com/api/status | jq -r .version   # 期望：candidate 版本号
# V2 权重比例统计（1000 次采样，canary 版本占比 ≈5%）
for i in $(seq 1 1000); do curl -s https://api.likha.com/api/status | jq -r .version; done | sort | uniq -c
# V3 权重归零即时生效（最快回滚通道，秒级）
kubectl --context mnl -n new-api annotate ingress new-api-canary alb.ingress.kubernetes.io/canary-weight="0" --overwrite
# 期望：≤30s 后 V2 统计 canary 占比为 0；验完改回 "5"
```

**不通过时修复**：
- 现象：注解改了权重不动 → 诊断：ALB Ingress Controller 未完成调谐，或两条 Ingress 同名 host 冲突：`kubectl -n new-api get events | grep alb` → 修复：修正 Ingress 命名/规则，等待 reconcile。
- 现象：canary 占比远超 5% → 诊断：stable Service selector 误含 `track: canary` Pod → 修复：收紧 selector 到 `track: stable`。
- 现象：canary 起不来 Pending → 诊断：required 反亲和无空节点 → 修复：确认节点池余量（64 vCPU=8 节点预算内）。

**坑**：
- 坑 1｜canary 与 stable 共享 ConfigMap 但版本不兼容。现象：新代码写新字段旧代码读崩。后果：灰度反噬全站。改进：灰度版本必须向后兼容一个发布周期（expand-contract）。
- 坑 2｜canary 1 副本且无 PDB。现象：节点维护时灰度样本消失、观测窗断裂；更糟"canary 全挂没人发现，因为流量只有 5%"。改进：canary 加 PDB + 独立绝对量告警。
- 坑 3｜权重热改不生效被误认为功能失效。改进：`get events` 查 ALB 调谐；权重推进写进任务 31 演练脚本。

### Day 3 · 任务 31｜灰度发布演练 5→20→50→100 与回滚（人员B，2 人时，16:00–18:00）

**前置/状态**：任务 27 完成且 V1–V3 通过；任务 32 告警可触达双人；候选 SHA 与 ConfigMap checksum 已登记。**必须双人**：一人操作，一人核对指标。
**依赖警示（探针降级口径）**：G1-b（P95 首字延迟）门依赖 G8 `/metrics`；未落地时该门降级为 ALB 访问日志近似判定，**证据链须注明缺口且 SLA 承诺应下调**。

**操作步骤（CLI-first）**：

状态机：`Built → W5 →（观测窗5min+GUARD1）→ W20 → W50 → W100 → Promote（stable 滚同 SHA）→ Zero（canary 权重归 0）`；任一门越线 → `Rollback = 权重归 0`。

- **GUARD1（每档必过）**：G1-a canary 5xx 率不高于 stable 1.2 倍且绝对值 <0.5%（ALB 日志 + Prometheus）；G1-b P95 首字延迟不高于 stable +15%；G1-c **额度扣减对账差异必须为 0**（主库 `logs` 与 `users.quota` 对账 SQL；注意 `BATCH_UPDATE_ENABLED=true` 的 ≤5s 批量窗口会造成正常延迟入账，对账须扣除此窗口口径）。
- **GUARD2（仅 Promote）**：含 DB 迁移必须处于 Expand 阶段（Contract 禁止与灰度同批）；`.down.sql` 在 staging 跑通 `up→down→up`；`SESSION_SECRET` 与镜像 SHA 不同时改。

```bash
REL=${GIT_SHA_CANDIDATE}
for W in 5 20 50 100; do
  kubectl --context mnl -n new-api annotate ingress new-api-canary \
    alb.ingress.kubernetes.io/canary-weight="${W}" --overwrite
  sleep 300                     # 每档观测窗 5 分钟
  echo "== weight ${W}% =="
  kubectl --context mnl -n new-api get pods -l track=canary
  # 第二人核对看板：canary 5xx、P95、额度对账、DB 慢查询；任一越线 → 立刻权重归 0
done
# 100% 后先滚 stable，再归零 canary（保持"始终有回滚目标"）
kubectl --context mnl -n new-api set image deploy/new-api-stable new-api=${ACR_MNL_PREFIX}:${REL}
kubectl --context mnl -n new-api rollout status deploy/new-api-stable --timeout=15m
kubectl --context mnl -n new-api annotate ingress new-api-canary alb.ingress.kubernetes.io/canary-weight="0" --overwrite
```

期望输出：

```
== weight 5% ==   # 每档看板四门全绿才进下一档
deployment "new-api-stable" successfully rolled out
```

**验证方法**：

```bash
# 各档通过线：5% canary 5xx ≤ 基线+0.05pp；20% P95 ≤ SLO(如800ms)；50% DB 连接数/CPU 无阶跃；100% 对账差异 0
# 回滚演练（本卡核心证据）：权重归 0 生效 ≤30s 且无残余错误
time (kubectl --context mnl -n new-api annotate ingress new-api-canary alb.ingress.kubernetes.io/canary-weight="0" --overwrite && \
      until [ "$(curl -s https://api.likha.com/api/status | jq -r .version)" = "$STABLE_VER" ]; do sleep 1; done)
```

**不通过时修复**：
- 现象：某档 5xx 越线 → 诊断：确认是 canary 独有问题还是全站抖动（对比 stable 同时段）→ 修复：canary 独有则**权重归 0 回滚**（秒级，只动 Ingress 注解，不重排 Pod），事后查 candidate 镜像。
- 现象：G1-c 对账差异非 0 → 诊断：先排除 `BATCH_UPDATE_ENABLED` ≤5s 窗口与对账 SQL 时区偏差；真实差异 → 修复：立即回滚并冻结发布，差异进 M4 证据。
- 现象：Promote 后发现配置不兼容 → 诊断：只回镜像没回 ConfigMap → 修复：**版本 = 镜像 SHA + ConfigMap checksum** 一起回，GitOps 回退一个 commit。

**坑**：
- 坑 1｜100% 后 stable 停在旧版、canary 长期当主跑。后果：1 副本扛全量、无从回滚。改进：SOP 强制"100% → 滚 stable → 归零 canary"三连，缺一步视为发布未完成；**永远不要为回滚删 canary Deployment**。
- 坑 2｜回滚只回镜像不回配置。后果：新旧参数交叉读崩。改进：SHA+checksum 绑定。
- 坑 3｜灰度期间发生 AutoMigrate，stable 旧码不认新列。改进：严格 expand-contract，灰度阶段迁移只能是 Expand。
- 坑 4｜观测窗没有基线对比，看不出变差。改进：每档记录前一天同时段基线数字，写进 §12 证据。

### Day 3 · 任务 50｜PITR 备份恢复演练，记录真实 RPO/RTO（人员B，2 人时，19:00–21:00 演练窗口）

**前置/状态**：RDS PostgreSQL 备份策略 `EnableBackupLog=1`、`PreferredBackupTime` 落在业务低谷（马尼拉本地凌晨 2–4 点 = `18:00Z-20:00Z`）；主库已开启删除保护；**双人复核窗口**方可执行。

```bash
aliyun rds DescribeBackupPolicy --DBInstanceId ${RDS_MNL_INSTANCE_ID}
# 期望："EnableBackupLog":"1"，备份时间落在低谷窗
aliyun rds DescribeDBInstanceAttribute --DBInstanceId ${RDS_MNL_INSTANCE_ID} | jq '.Items.DBInstanceAttribute[0].DeletionProtection'   # 期望 true
```

**操作步骤（CLI-first）**：

1. 主库写入可追踪哨兵并强制归档 WAL（缩短可恢复延迟）：

```bash
psql "host=${RDS_HOST} user=${DBA_USER} dbname=newapi" <<'SQL'
CREATE TABLE IF NOT EXISTS ops_drill_marker (id serial primary key, note text, ts timestamptz default now());
INSERT INTO ops_drill_marker(note) VALUES ('pitr-drill-before');
SELECT pg_switch_wal();
SQL
```

2. 【控制台】RDS →「备份恢复」→**「恢复到新实例」**，时间点选 `now()`；规格选**最小可用配**（只验数据正确性与耗时，不验性能；成本按小时计，验完立即释放）。**严禁点"覆盖原实例"**——这是全方案唯一直接造成生产数据丢失的按钮；恢复目标必须是新实例，差异数据再手工导回，禁止任何形式的原实例覆盖。
   `[图 D3-B-50a｜拍摄对象：RDS"恢复到新实例"对话框（时间点恢复选项）；打码：实例 ID、连接串、账号]`
   `[图 D3-B-50b｜拍摄对象：Runbook 中"覆盖原实例"按钮打红叉的截图条目；打码：无]`
3. 记录三个时间点：发起恢复 `T0`、新实例可连 `T1`、哨兵齐全 `T2`。**RTO = T1−T0**；数据损失 = 最后已归档 WAL 与故障点之差（本次理论 0）。

**验证方法**：

```bash
aliyun rds DescribeBackupTasks --DBInstanceId ${NEW_DRILL_INSTANCE_ID}   # 期望 Progress=100%，无 Failed
psql "host=${NEW_DRILL_HOST} user=${DBA_USER} dbname=newapi" <<'SQL'
SELECT count(*) FROM users;             -- 与主库对比一致
SELECT max(ts) FROM ops_drill_marker;   -- 应等于最后一条写入时间（差 ≤5min）
SELECT pg_is_in_recovery();             -- 期望 f（新实例可写）
SQL
```

**不通过时修复**：
- 现象：可恢复时间点不覆盖近 7 天 → 诊断：`EnableBackupLog=0` → 修复：开启后**历史不可回补**，只能重新起算，并把 RPO 口径按新起点写入 §12。
- 现象：`DescribeBackupTasks` 有 Failed → 诊断：看 `Engine`/`BackupMethod`；WAL 归档失败 → 修复：查 OSS 授权 `AliyunRDSBackupDefaultRole`。
- 现象：哨兵末条时间差 >5min → 诊断：`pg_switch_wal()` 未执行或归档延迟高 → 修复：记录**真实 RPO**，按 SLA 口径确认是否可接受，不可接受则加"WAL 归档延迟 >15min"告警（RDS 监控 `LogSize`/云监控事件）。
- 现象：恢复后业务表行数不一致 → 诊断：优先怀疑恢复了错误的库（多 DB 实例）→ 修复：核对 `RestoreTime` 与源库名单独重做。

**坑**：
- 坑 1｜把"恢复到新实例"点成"覆盖原实例"。后果：**生产数据直接丢失**。改进：演练窗口+双人复核；Runbook 截图打红叉（上图）；主库删除保护常开。
- 坑 2｜恢复实例照抄主库规格（16C64G）。后果：一次演练几十美元，且大实例常排队无库存导致超时失败。改进：最小规格。
- 坑 3｜没测"OSS 不可写"分支。后果：权限被改坏后 PITR 静默退化为每日全量，RPO 从分钟级变 24 小时。改进：WAL 归档延迟告警。
- 坑 4｜恢复耗时未计入 region 级故障场景。64GB 级实例 PITR 实测常在 **1.5–4 小时**。后果：SLA 的 RTO 在 region 故障下不成立（属排除项②）。改进：实测值写进 M5 证据与客户对齐；不接受则需第三 region 主库（超范围重新立项）。
- 收尾：`aliyun rds DeleteDBInstance --DBInstanceId ${NEW_DRILL_INSTANCE_ID}`（先关删除保护），导出备份任务耗时曲线截图存档。

### Day 3 · 任务 37｜主库故障切换演练：RDS HA + 应用重连 + 额度对账（人员A，2 人时，20:00–22:00 演练窗口）

**前置/状态**：任务 43/44 完成（PgBouncer 已上线，`query_wait_timeout=120` 大于漂移时间）；Redis fail-open 已在 §7.4 验证；冻结发布（§11.2）并通知窗口；**演练前临时降低 GTM 敏感度或摘掉备池**（备池本不该在 D7 前加入）。

**操作步骤（CLI-first）**：

1. 后台打流量并启动对账采样：

```bash
hey -z 900s -c 100 -m GET https://api.likha.com/api/status &
```

2. 【控制台】RDS → 实例详情 →「服务可用性」→「主备切换」（指定 5 分钟内），同时记录发起时刻 `T0`。
   `[图 D3-B-37a｜拍摄对象：RDS 服务可用性页的"主备切换"入口与切换任务进度；打码：实例 ID、内网地址]`
3. 观察四层时间线并回填：① 实例侧 VIP 漂移（高可用版地址不变，仅 VIP 漂移，通常 ≤30s，官方不承诺 SLA）；② 池侧回收坏连接（PgBouncer transaction 模式语句中断/session 模式只断连）；③ 应用侧首个成功请求时间与错误总数（`server closed the connection unexpectedly` / `FATAL: terminating connection`；GORM+`database/sql` 重建连接但**已有事务失败**）；④ 额度对账。
4. 三条铁律复核：连接池显式配 `RetryTimes` 与非零退避（否则 Pod 死持有死连接直到重启）；`query_wait_timeout=120` > 漂移时间（否则切换期堆积的等待一次性超时打爆应用）；Redis 不能 fail-close（若因 Redis 判定失败全站 429，会把 30 秒演练放大成整站不可用）。

**验证方法**：

```bash
psql "host=${RDS_HOST} user=${DBA_USER} dbname=newapi" -c "SELECT pg_is_in_recovery();"   # 新主期望 f（无脑裂双写）
psql "host=${RDS_HOST} user=${DBA_USER} dbname=newapi" -c "SELECT count(*) FROM pg_stat_activity;"   # 期望回到基线
# 用户侧：5xx 持续 ≤45s、占比 <0.1%、全部自愈无人工介入
# 额度对账（切换窗口 logs 与 users.quota 必须平账，差异≠0 则 M4 不通过）：
psql "host=${RDS_HOST} user=${DBA_USER} dbname=newapi" -c "SELECT ..."  # 对账 SQL 需扣除 BATCH_UPDATE_ENABLED=true 时 ≤5s 批量落库窗口（红线口径）；额度变更必须走 UPDATE ... SET quota = quota - $x WHERE quota >= $x 原子条件更新
```

通过判据：实例漂移 ≤30s；连接恢复（首错→首个成功查询）≤15s；用户可见 5xx ≤45s 且占比 <0.1%；**数据正确 = 对账差异必须为 0**。

**不通过时修复**：
- 现象：应用"看起来恢复"但偶发读写失败 → 诊断：部分连接仍持旧主 → 修复：验证应用侧 `SELECT pg_is_in_recovery()` 看到 false；必要时 `rollout restart`（非默认动作）。
- 现象：超时请求持续堆积不返回 → 诊断：应用未 fail-fast → 修复：perf 环境 `iptables` 模拟 DB 黑洞（AZ 整体故障分支），验证返回 503 而非 FD 打爆——直接决定 §13 预案可行性。
- 现象：对账出现重复扣费 → 诊断：额度"读后写"非原子 → 修复：改原子条件 UPDATE + master-only 对账 Job，重跑演练。
- 现象：演练期间流量被切到新加坡 → 诊断：GTM 判主站不健康自动切换 → 修复：确认为"人为制造窗口"，还原 GTM 配置，敏感度调低后重测。

**坑**：
- 坑 1｜死连接残留。现象：偶发只读/写失败。后果：难排查的"闪断"。改进：验证 + 重连配置显式化。
- 坑 2｜长事务/长连接跨切换，SSE 会话全断。改进：SSE 客户端必须有重连语义；§12 SLA 写明"主库切换影响进行中的流式请求"（排除项候选，需客户确认）。
- 坑 3｜额度扣减依赖读后写。后果：重试即重复扣费。改进：原子 UPDATE + 对账 Job；`BATCH_UPDATE_ENABLED` 的 ≤5s 丢失窗口是红线，对账口径必须写明。
- 坑 4｜GTM 误切双活假象。后果：跨区延迟突增。改进：演练前降敏感度/摘备池。
- 坑 5｜只测了 HA 切换没测完全不可用。改进：黑洞分支必测（见修复第 2 条）。

### Day 3 · 泳道 B 出口检查清单

```
[ ] 任务 26：SLS 两站 Project/Logstore 就绪，GetLogs 有真实 Pod 日志；Grafana（新加坡）跨区数据源出图；三重拨测独立产出结果
[ ] 任务 32：SLO/错误预算看板（21.6 分钟/月）可用；可控 P1 在 ≤3 分钟电话触达 2 值班 + 负责人；上游 5xx 单独曲线不计入自身 SLA
[ ] 任务 43：单实例容量 C 实测落表；HPA 4→16 阶梯扩容无 Pending、缩容不低于 4；I-1/I-2/I-3 三不变量通过（16 实例 PgBouncer 就位）
[ ] 任务 44：备站 min=2→24 全 Ready ≤6 分钟（>10 分钟须重谈 RTO）；24×C ≥ 1.5×主站峰值；warmup→切流顺序固化进 Runbook
[ ] 任务 27：x-canary 头强制路由 + 1000 采样占比 ≈5% + 权重归 0 秒级生效三项全过；canary 独立告警（5xx>3 兜底）已建
[ ] 任务 31：5→20→50→100 每档 GUARD1 全绿（对账差异=0）；回滚 ≤30s 无残余错误；stable 已滚同 SHA、canary 保留为回滚目标
[ ] 任务 50：RPO/RTO 实测记录（含哨兵时间差 ≤5min）；恢复仅到新实例且已释放；Runbook 红叉截图归档
[ ] 任务 37：漂移 ≤30s / 重连 ≤15s / 5xx ≤45s / 对账差异=0 四项达标；GTM 敏感度已还原；DB 黑洞 fail-fast 分支已测
[ ] 探针降级口径已在 §12 证据链声明：G8（/healthz、/readyz、/metrics）未完成，SLA 承诺相应下调；ARMS APM 未纳入证据链
```
