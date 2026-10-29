# jkt dev 集群 SLS 容器日志开通 · 执行报告（2026-10-16）

> 目标：为 `ack-newapi-jkt-dev`（ap-southeast-5）开通 SLS 集群日志采集，**口径参照马尼拉**。
> 结论：**已开通并验证**（stdout 路纳秒级实时入库；file 路秒级入库，毫秒缺口为两站既有问题）。
> 过程中触发一次**容量事故**（dev 集群调度饱和 → `dev.likha.hk` 503），已定位并零成本修复。

## 一、与马尼拉的机制差异（先看这张表）

| 维度 | 马尼拉 mnl | 雅加达 jkt dev |
|---|---|---|
| 采集组件 | `logtail-ds` v3.3.3.1-aliyun（DaemonSet 4/4） | **`loongcollector` v3.3.10.0**（DS 3/3）+ `loongcollector-operator` 1/1 |
| CRD | `clusteraliyunpipelineconfigs.telemetry.alibabacloud.com` | **同名同 API 组**（loongcollector 附加组件自带） |
| CR 翻译器 | `alibaba-log-controller`（logtail 附加组件内置） | **`loongcollector-operator`**（Deployment，需能调度！） |
| 落点 project | `k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c` | `k8s-log-cb0abf5bc06034f7bbdb991752f6f3e62`（建集群时已由 log controller 创建，RG=`rg-nonprod`=集群同组） |
| 输入过滤 | `io.kubernetes.container.name: new-api` | **`io.kubernetes.pod.namespace: newapi-dev`**（见下） |
| 结果配置名 | 被 webhook 钉死为 CR 名 | 同（`new-api-app-{stdout,file}-ns`） |

**过滤口径为何必须改**（实测）：mnl 的生产 ns 里三个 Deployment 的容器**都叫 `new-api`**；jkt 的容器名**各不相同**——
`new-api`（new-api-dev）/ `new-api-dev-slave` / `new-api-channel-task-dev`。沿用容器名过滤会**漏掉 dev.likha.hk 背后的
`new-api-dev-slave`**，故改为按命名空间过滤（该 ns 内应用容器全纳入，且对将来新增负载天然覆盖）。

## 二、落地清单（三步，均已执行）

### 1) logstore + 索引（`deploy/sls/jkt_provision.sh`）

jkt 的 `k8s-log-<cid>` 原本只有 `audit-<cid>` / `k8s-event` / `policyadmit-<cid>` 三个系统库，缺业务库。
按**马尼拉实测参数**补齐（索引 body 直接从 mnl `GetIndex` 取回裁剪，避免手抄漂移）：

| logstore | ttl | shard | maxSplitShard | appendMeta | 索引 |
|---|---|---|---|---|---|
| `app-stdout` | **180** | 2 | 32 | true | index_mode=v2，**17 字段键** + 全文 |
| `app-file` | **30** | 2 | 64 | false | 纯全文（keys={}） |

回读：`app-stdout index: ttl=180 keys=17` · `app-file index: ttl=30 keys=0` ✅（与 mnl 逐项一致）

### 2) 两份 ClusterAliyunPipelineConfig

- `deploy/sls/clusterpipelineconfig-app-stdout-jkt.yaml`
- `deploy/sls/clusterpipelineconfig-app-file-jkt.yaml`

除 project/endpoint/Region 与输入过滤外，与 mnl 逐字同构：`service_docker_stdout`（旧版 Go 插件，保住
`_pod_name_` 等**普通字段**）+ `global.EnableTimestampNanosecond/UsingOldContentTag` + `processor_gotime(_time_, SetTime)`；
file 侧 `input_file` + `processor_regex`（抓 ms → `log_ts`，`FullMatch: false`）+ `processor_gotime(SetTime)`。

CLI 复核（SLS 侧已翻译成功）：`global={EnableTimestampNanosecond:true,UsingOldContentTag:true}` + processors 齐 ✅
CR 状态：`status.message=success` ✅

### 3) 执行器扩展（一站入口管三站）

`deploy/sls/apply_pipeline_ns.sh` 增加 jkt：`site_cid/site_reg`、`target_manifest`、`site_remote`（jkt 走
`deploy/lib/ack_remote_jkt_dev.sh` 私网临时 kubeconfig 通道）、`site_ns`（jkt 的 ns 是 `newapi-dev`，
且**跳过**老式 `AliyunLogConfig` 清理步骤——jkt 无历史 CR）。

```bash
bash deploy/sls/jkt_provision.sh check|plan|apply     # logstore + 索引（EXEC_MODE=apply 才写）
bash deploy/sls/apply_pipeline_ns.sh apply  all jkt   # 两份 CR
bash deploy/sls/apply_pipeline_ns.sh verify all jkt   # 数据校验
```

## 三、验收（实测）

| 项 | 期望 | 实测 |
|---|---|---|
| `app-stdout` 实时性 | 近 30 分钟有数据 | ✅ 100 行，含 `ns=611725234` 纳秒 |
| `app-stdout` 覆盖 | 三个负载容器 | ✅ `new-api-dev`(x46) + `new-api-dev-slave`(x54)（channel-task 该时段无输出） |
| `app-file` 实时性 | 近 30 分钟有数据 | ✅ 100 行（`[GIN]`/`[SYS]` 均在） |
| `app-file` 毫秒 | `log_ts` 有值 | ❌ **`log_ts=None`（见 §五，非 jkt 独有）** |
| 服务侧影响 | 无（dev.likha.hk 200） | ✅ 3/3 200 |

## 四、事故与修复：加装采集组件把 dev 集群压垮（已闭环）

**现象**：`loongcollector` 附加组件安装（11:47 HKT）后，`new-api-dev-slave` 与 `loongcollector-operator`
**双双 Pending** ⇒ `dev.likha.hk` **503**（该域名后端正是 slave）。

**根因（容量三重约束，实测）**：

| 节点 | allocatable CPU | 已请求 | Pod 数 | 备注 |
|---|---|---|---|---|
| `.174` | 1930m | 1670m (86%) | 16/15 | 有空余 CPU、**无 Pod 槽** |
| `.199` | 1930m | 1890m (97%) | 16/15 | 同样无槽 |
| `.153` | 1930m | 1900m (98%) | 10/15 | **有 5 槽但 CPU 仅剩 30m**（ARMS Prometheus 单 pod 占了 **1000m**） |

采集组件新增 3×`loongcollector-ds`（各 100m + 1 槽）+ 1×operator（100m + 1 槽），正好吃掉最后的余量：
`2 Insufficient cpu, 2 Too many pods`。**dev 集群本就贴近上限，附加组件是最后一根稻草。**

**修复（零成本，单点最小改动）**：`arms-prom/arms-prometheus-ack-arms-prometheus` 的
`requests.cpu` **1000m → 300m**（memory 保持 1Gi），并重建该 Pod 使新请求计入。
⇒ `.153` 由 98% → **77%**，slave 与 operator 双双调度成功。

**验收**：slave `1/1 Running`、operator `1/1 Running`、`dev.likha.hk` 3/3 **200**、待调度仅剩三条
`node-exporter`（另一既有问题，见 §六）。

**复现命令（干跑已验证）**：

```bash
# 1) 降请求（新 RS 生效）
kubectl -n arms-prom patch deploy arms-prometheus-ack-arms-prometheus --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests","value":{"cpu":"300m","memory":"1Gi"}}]'
# 2) 重建该 Pod（★ 关键：节点核算看 Pod 字段，patch Deployment 不改运行中 Pod 的 requests）
kubectl -n arms-prom delete pod -l app.kubernetes.io/name=arms-prometheus-ack-arms-prometheus --wait=false
# 3) 复核
kubectl get pod -A --field-selector status.phase=Pending -o wide
```

> ⚠️ 该 patch 属**手工变更**（非附加组件参数）；若后续附加组件重装/升级回滚此请求，按 §六-1 评估加节点。

## 五、真相纠正：`app-file` 毫秒在两站**都没生效**

任务 26 报告（2026-10-09）曾记「app-file 已能出毫秒」。本次逐条对账，**该结论不成立**：

| 站点 | 在跑镜像 | file 行内容 | `log_ts` |
|---|---|---|---|
| mnl | `newapi-master:20260928-26ac63233` | `[GIN] 2026/10/16 - 12:04:43 \| api \| …` | **None** |
| jkt | `newapi-master:20261015-c62445555` | `[GIN] 2026/10/16 - 11:04:42 \| api \| …` | **None** |

**根因**：毫秒补丁（`middleware/logger.go:38`、`common/sys_log.go:20/27/34`、`logger/logger.go:113`）
落在提交 `9fff2aa47`（`UPSTREAM_CHANGES.md` 条目 1–5），**位于 `feature/log-ms-precision` 分支、PR 未开、未进 main**
⇒ CI 产出的镜像**都不含**这两处格式改动 ⇒ 行内无 `.000` ⇒ 正则不命中 ⇒ 无 `log_ts`、无 `__time_ns_part__`。
stdout 路不受影响（纳秒来自容器 runtime 字段 `_time_`，与镜像无关）。

**处置**：属既有挂账（G8 代码补项），**本次不改码/不重建镜像**；jkt 与两生产站保持**同一现状**（口径一致优先）。

## 六、遗留（未动，需裁定）

1. **dev 集群容量**：3×2C 节点已 86/97/77%，Pod 上限 15/节点已贴顶；节点池 `np-jkt-dev-app`
   `desired=3 max=3` 且**未开自动伸缩**。本次是"借"ARMS 的 1000m 腾出来的，**下次再来一个附加组件或一次滚动
   仍可能卡住**。三个选项：① 加 1 台节点（≈$80/月，最干净）；② 常态下调 ARMS Prometheus 请求（本次已做，
   但附加组件重装/升级可能回滚）；③ 改 dev 负载 requests（治标）。
2. **`arms-prom/node-exporter-*` 三个 Pod 长期 `ImagePullBackOff`（1/2，已 3 天）**——与本次无关，但同样占
   槽位与 20m 请求，建议单独排查（镜像地址在 jkt 地域可能不可达）。
3. **ARMS Prometheus 的 requests 可能被附加组件回滚**：若回滚，`Running` 的 Pod 不受影响（仅影响下次调度），
   但届时应改走选项 ①。
4. `app-file` 毫秒需等 ms 补丁进 main + 重建镜像（G8），届时两站同时受益。

## 七、取证脚本

`deploy/logs/t_jkt_sls_recon{,_2}.sh`（组件/CRD/project/logstore/索引）· `t_jkt_sls_k8s.sh`（集群内 DS/CRD/容器名）·
`t_jkt_operator_diag.sh` / `t_jkt_pending_diag.sh` / `t_jkt_capacity.sh`（容量与 Pending 归因）·
`t_jkt_capacity_fix.sh`（干跑）+ `t_jkt_capacity_apply.sh`（执行）· `t_jkt_final_verify.sh`（终验）·
`t_ms_compare.sh`（毫秒对账）· `t_jkt_sls_pods.sh`（容器覆盖核对）。
