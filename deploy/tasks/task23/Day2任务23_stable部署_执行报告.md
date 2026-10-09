# Day 2 · 任务 23｜stable Deployment（4 副本 + PDB + HPA + 反亲和）—— 执行报告

- **卡片**：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` §Day2 任务 23（第 3419–3553 行，单人 2 人时，D2 上午 09:00–11:00）
- **执行日期**：2026-10-05 23:10–23:31（UTC+8；集群侧 UTC 15:2x）**＋ 2026-10-06 07:42–08:40 补测 V3/V4/ALB 与成本复核 ＋ 08:51–08:54 只读复核（托管组件存活 / 切流现状 / 弹性组件实名）**
- **执行通道**：`deploy/lib/ack_remote.sh mnl`（云助手 `ecs RunCommand` → VPC worker 节点内 kubectl，admin 私网 kubeconfig；10-05 用 `ACKCTL_DIR=/tmp/ackctl-mnl-t23` 固定目录，**10-06 起执行期文件与节点侧目录一律按 `RUN_ID` 唯一**，原因见 §十一-⑦）
- **产物**：`deploy/aliyun/ph/stable-deployment.yaml`（清单，含差异说明）、`deploy/tasks/task23/stable.sh`（`--precheck/--dryrun/--apply/--verify/--status/--wire-alb/--cleanup`）、`deploy/tasks/task23/bodies/03b~04c-*.sh`（V3/V4 补测 body）、`deploy/tasks/task23/bodies/05-albctrl-lease.sh`/`06-goatscaler-lease.sh`/`07-ingress-backend.sh`（10-06 08:5x 托管组件存活与切流复核，全只读）、`deploy/tasks/task23/price_matrix.py`（单价复核）、`deploy/logs/task23_*_2026100{5,6}-*/`（body.sh + remote.out + 实际下发清单全量留存）
- **结论**：✅ **清单已落地，V1–V4 与 ALB 切流全部有实测证据**（10-06 补测后）。马尼拉 `new-api-stable` 4/4 Running、跨 AZ 2/2、0 重启、Service 转发通（ClusterIP 3×200 + 集群 DNS 4×ok）、真实滚动一次（revision 1→2）且事件序列证明「先建后杀」；stable Pod 对 PG **零 DDL**（schema 指纹 FP0==FP1 逐字相同）、DB 账号 `newapi`（非迁移账号）、`GOMAXPROCS=4` 对 `nproc=8`；**V3 drain 真驱逐通过**（仅 1 个 stable Pod 被驱逐、容量未减、替补可调度、uncordon 已恢复）；**V4 分三段**：指标链路（canary 200%/65% → 1→3）通过、真实 stable 容量通路（4→6→4、AZ 3/3、配额 25/64）通过，**但"CPU 65% 由业务流量触发"未证**（详见 §七 的结论口径）；**ALB 已切 `svc/new-api-stable` 并 200 取证**，同步销掉任务 19 的 V2 健康检查。
  **裁定已落地**：`maxReplicas` **16 → 15**（不抬配额），现网 + 清单 + 卡片三处同步，算术见 §九。**卡片方法缺陷**：卡片 V4 的"独立 stress Pod"判据在本 workload 上必然假阴性，已连正文改为三段式（§八-6/7）。
  **08:5x 复核收回了 3 条既有判定**（详见 §十三-③/⑤、§十四-2/2b）：① 任务 19 的"集群内无 alb workload ⇒ ALB Ingress Controller 未运行"**判据无效**（组件在 ACK 托管控制面；lease `renewTime` 与节点侧 `date -u` 同秒 + `SuccessfullyReconciled` 才是证据），已连任务 19 正文与步骤 1 命令一起改正；② 本卡上一版"用户面没有 cluster-autoscaler"⇒ 实况是弹性组件实名 **`ack-goatscaler`** 且活着（`cm/autoscaler-meta` 全参数已取），**组件存在性已证、开节点动作未实测**；③ 由 ②带出的**双层缩容风险**（`scale_down_enabled=true` + `unneeded_duration 10m` + 本服务 CPU 常年 0%）已列入残留。
- **授权留痕**：本卡写操作（`--apply`、`ROLL=1 --verify`）在任务 18 已取得的「一次核准，apply+verify 连着跑」同一变更窗口授权范围内执行；10-06 的 **V3 drain / V4 压测与临时改 HPA / `--wire-alb`** 由项目负责人逐项核准（原话见 §七开头），临时改过的 `maxReplicas`/`target`/`minReplicas` **均已还原**，压测与 canary Pod 已删（残留 0）。

---

## 一、清单与卡片的差异（只有两处，都有实测依据）

| # | 卡片口径 | 实装口径 | 依据 |
| --- | --- | --- | --- |
| ① | PDB `minAvailable: 3`；V3 期望「ALLOWED DISRUPTIONS = 0（4 副本时）」 | 沿用现网 `pdb-new-api-stable` 的 **`minAvailable: "70%"`**；4 副本下 `disruptionsAllowed = 1` | 现网该 PDB 早在 **2026-09-30 08:54:10** 就按 `70%` 建好，selector 与卡片逐字相同（`app=new-api`+`track=stable`），apply 为 `configured`→无实际变化。4 副本下 `ceil(0.7×4)=3` ⇒ 与 `minAvailable: 3` **完全等价**；而写成固定 3 在 HPA 扩到 16 时反而把健康下限降到 3（70% 口径是 12），所以选一个**不放松且随规模自动收紧**的值。⚠ 卡片 V3 的期望值本身算错：`minAvailable 3` + 4 副本 ⇒ allowed = 4−3 = **1**，不是 0（已连正文一起改）。 |
| ② | 步骤 3：GitOps 里**不要写** `spec.replicas` | 清单**保留** `replicas: 4` | 本仓无 ArgoCD/Flux，apply 由 `deploy/tasks/task23/stable.sh` 直发，不存在 sync 打回 4 的事故路径；`--verify` 会把 `Deployment.spec.replicas` 与 HPA 期望做对照。**接 GitOps 时必须按卡片加** `ignoreDifferences: [/spec/replicas]`。 |

其余按卡片逐条实装，另有 **7 处卡片正文本身的问题**（含判据/manifest/验收方法写错）已连正文修正，见 §八。`env` 里补了 `GOMAXPROCS: "4"`——卡片步骤 1 的 manifest 没写，但坑 2 的改进项要求显式钉住，实测对照见 §六-④。

`checksum/config` 不在清单里写死值，由脚本在**节点侧**渲染：`sha256(sorted-json(new-api-config.data))[:12]` = **`c35088fad4a1`**（ConfigMap 一改，下次 apply 自动触发滚动）。

---

## 二、前置核实（`--precheck`，全只读）

证据：`deploy/logs/task23_precheck_20261005-232004/remote.out`（首轮 `…-231923` 的 P5 有一段 Python `NameError`，修脚本后重跑，见 §十一-③）

| 项 | 结果 | 说明 |
| --- | --- | --- |
| 节点机型 | ⚠ 实际开出 **`ecs.g9ae.2xlarge`** ×4 | 卡片/任务 11 口径写 `g9i.2xlarge`。复核 `aliyun cs DescribeClusterNodePools`：节点池 `np-mnl-app` 的多机型列表 = `['ecs.g9i.2xlarge','ecs.g8ine.2xlarge','ecs.g9ae.2xlarge']`（min 4 / max 8，state `active`）⇒ **`g9i` 只是列表首项，实况按库存落到 `g9ae`**。同为 8C/32G 档（allocatable `7910m`/30.2 Gi 印证），本卡容量算术不受影响；但故障域/性能基线判断**须以节点实况为准**（已连卡片正文改正）。 |
| AZ 分布 | ✅ 6a×2 + 6b×2 | 无节点被 cordon（`UNSCHED=<none>`） |
| 单节点 allocatable | `7910m` CPU / `30945140Ki`≈30.2 Gi | 本卡每 Pod requests 2C/4Gi ⇒ 空闲 5.70/6.81/6.61/6.31 核，**每节点还能放 6 个** |
| HPA 依赖 | ✅ `autoscaling/v2`=1、`policy/v1`=1、`metrics-server` deploy `1/1` | `kubectl top nodes` 有输出 = 指标通路可用 |
| 既有 stable 资源 | ✅ 无 `deploy/svc/hpa new-api-stable`（新建）；PDB 已存在 | 既有 PDB 明细：`minAvailable=70%`、created `2026-09-30T08:54:10Z`、当时 `allowedDisruptions=0`（因无匹配 Pod，`NoPods` 事件同源） |
| ConfigMap | ✅ 7 键，`NODE_TYPE=slave` | 其余：`SQL_MAX_OPEN_CONNS=100`、`SQL_MAX_IDLE_CONNS=50`、`LOG_SQL_CLICKHOUSE_TTL_DAYS=90`、`MEMORY_CACHE_ENABLED=false`、`SYNC_FREQUENCY=30`、`TZ=Asia/Manila` |
| Secret | ✅ 6 键 | `LOG_SQL_DSN / REDIS_CONN_STRING / SESSION_SECRET / SESSION_SECRET_OLD / SQL_DSN / SQL_DSN_MIGRATE`；stable 走 `envFrom` 取 `SQL_DSN` ⇒ 解析出账号 **`newapi`**（DML），非 `newapi_migrate` |
| 配额算术 | ✅ 已裁定 `maxReplicas=15` | 10-05 判"16 顶不到（天花板 15）"⇒ 10-06 项目负责人裁定「降到 15」，现网/清单/卡片已同步，算术见 §九 |
| 镜像可拉性 | ✅ `preflight phase=Succeeded`（1 轮） | 用清单里同一个 `-vpc` image + 同一个 SA `new-api-app`，容器内 `/new-api` 138,404,002 B |
| 探针路径 | ✅ `/api/status` **200** + JSON | 复用已在跑的 master Pod；卡片坑 5（该接口不查 DB）仍在，处置见 §六-⑤ |

---

## 三、清单合法性（`--dryrun`，server-side）

证据：`deploy/logs/task23_dryrun_20261005-232428/remote.out`

服务端校验覆盖 HPA `autoscaling/v2` 字段、PDB 百分比口径、探针**端口名**（`port: http` 而非 3000）、`topologySpreadConstraints` 结构：

```
deployment.apps/new-api-stable        unchanged (server dry run)
poddisruptionbudget…/pdb-new-api-stable configured  (server dry run)
horizontalpodautoscaler…              unchanged (server dry run)
service/new-api-stable                unchanged (server dry run)
```

D2 段回读现状与改写前一致 ⇒ dry-run 未持久化。

---

## 四、落地（`--apply`）

证据：`deploy/logs/task23_apply_20261005-232040/remote.out`

1. **A1 红线断言**：显式非 `slave` 的容器只有既有的 `new-api-master-*`（期望如此）；stable 容器 env 显式 `NODE_TYPE=slave` + ConfigMap `slave` ⇒ 本卡 4 副本**不会变成第二个 master 去跑迁移**（`common/init.go:89` 是 `!= "slave"` 字符串判断，留空即 master）。
2. **A3 apply**：`deployment created` / `pdb configured`（70% 无变化）/ `hpa created` / `service created`，checksum 渲染 `c35088fad4a1`。
3. **A4 rollout**：4 副本 150 s 上限内 `[OK] rollout 完成`。
4. 体积：raw 24,858 B → gzip+b64 15,384 B → 外层命令 20,868 B（**24 KB 上限内**；首发超限的教训见 §十一-①）。

---

## 五、V1 副本与分布（验收 ✅）

```
spec.replicas=4  ready=4  updated=4  unavailable=(空)
AZ ap-southeast-6a Running pods = 2
AZ ap-southeast-6b Running pods = 2
（首轮落点）10.0.22.194 / 10.0.22.195 / 10.0.43.200 / 10.0.43.201 各 1 个
```

- 4 个 Pod 全 `Running`、`RESTARTS=0`（探针与 OOM 无恙）。
- `service/new-api-stable` ClusterIP `172.21.15.220` 80/TCP；`endpoints` **ready=4 / notReady=0** ⇒ 未就绪 Pod 不会进 ALB 后端。
- **反亲和双向核对**：AZ 硬约束（`DoNotSchedule`）满足 2/2；无 Pending Pod；四节点均可调度。
- ⚠ **滚动后的观察**（`--status` 23:30:22）：6a 的 2 个 Pod 都落在 `10.0.22.195`，`10.0.22.194` 上 0 个。**不是缺陷**——hostname 维度是 `ScheduleAnyway` 软约束，调度器不强制再平衡；AZ 硬约束仍满足。若要求跨节点也硬隔离，需把 hostname 那条改成 `DoNotSchedule`（4 节点×2 AZ 下 16 副本会立刻摆不平），属另一轮裁定。

---

## 六、V2 零停机滚动（验收 ✅，已真跑一次）

证据：`deploy/logs/task23_verify_20261005-232501/remote.out`（`ROLL=1` 的那次）+ `…-232713/remote.out`（只读取证）

① `ROLL=1 bash deploy/tasks/task23/stable.sh --verify` 下发 `rollout restart`，`maxUnavailable: 0 / maxSurge: 1`，`[OK] 滚动完成`，revision **1 → 2**，旧 RS `7df66777c` desired 归 0、新 RS `7f96d6ff48` `desired=4 current=4 ready=4 available=4`。

② **容量不减的机械证据**（事件时间戳，23:27:13 只读轮）：

```
15:25:32Z ScalingReplicaSet  Scaled up   new-api-stable-7f96d6ff48 from 2 to 3
15:25:32Z ScalingReplicaSet  Scaled down new-api-stable-7df66777c  from 3 to 2
15:25:32Z Killing            …7df66777c-9kj9q Stopping container new-api
15:25:42Z ScalingReplicaSet  Scaled up   …7f96d6ff48 from 3 to 4
15:25:42Z ScalingReplicaSet  Scaled down …7df66777c  from 2 to 1
15:25:57Z ScalingReplicaSet  Scaled down …7df66777c  from 1 to 0
```

每一步 **先 scale up 再 scale down**（同一秒内配对），4→3→2→1 的过程中健康数始终 ≥4 ⇒ 「全程未缩容量」这条由事件序列支撑，不是凭 rollout 成功推定。

③ **Service 真转发**（借同 ns 的 master Pod 走 svc DNS）：`GET #1/#2/#3 -> 200`（ClusterIP），`via-cluster-dns #1..#4 ok`。

④ **坑 2 对照实测**：容器内 `GOMAXPROCS = 4`，而 `nproc = 8`（按宿主机算）⇒ 不显式钉就会按 8 核起 worker、被 4C limit throttle。Go 1.25 container-aware 在本镜像上不自动生效，**必须写死**。

⑤ **坑 5 仍在**：`/api/status` 不查 DB/Redis ⇒ 冷 Pod 可能"过早 ready"。本轮用 `startupProbe`（5 s × 30 = 150 s 上限）兜住启动段 + `maxUnavailable: 0` 保证容量不减；`/readyz`（查 DB+Redis）属 **G8 代码项**，落地后替换三个探针路径。滚动期事件里可见 `Startup probe failed: … connection refused`（4 m 前，1 次）——进程监听前的正常拒绝，未影响就绪。

---

## 七、V3 / V4 / ALB —— 已实测（2026-10-06 核准后补测，三项全部执行）

核准留痕（项目负责人 IM，2026-10-06）：「1. 可以继续」（V3 drain + V4 HPA）、「2. 确认」（`--wire-alb`）、「3. 降到 15」（`maxReplicas` 裁定）。

### V3 —— drain 真驱逐（`deploy/logs/task23_drain*_20261006-075*/remote.out`）

| 判据（卡片原文） | 实测 |
| --- | --- |
| drain 成功 | `task23_drain_20261006-075210` 在节点上落的 `/tmp/drain.log`（由 `task23_drain_post_20261006-075714` 回读全文，13 行）：`node/ap-southeast-6.10.0.43.200 cordoned` → 5 条 `evicting pod` → 5 条 `evicted` → **`node/ap-southeast-6.10.0.43.200 drained`** |
| **仅 1 个 stable Pod 被驱逐** | ✅ 只有 `new-api-stable-…-xrw42`（该节点仅此 1 个 stable Pod）。另 4 个是 `kube-system` 的 Deployment Pod（gatekeeper / coredns / policy-template-controller / ack-cost-exporter），`--ignore-daemonsets` 只跳过 DS、不跳过它们 ⇒ **drain 的爆炸半径不止本 ns**，这是本轮才拿到的实况 |
| 其余 3 个保持 Running | ✅ 全程 `deploy ready=4/4`：`SuccessfulCreate …-qggpc` 与 `Killing …-xrw42` **同一秒**（事件同带 `5m3s` 前缀），替补 Pod 20 s 内 `Started`；唯一告警是 `Startup probe failed: … connection refused`（进程监听前的正常拒绝） |
| 驱逐后新 Pod 能被调度 | ✅ **但没落到空节点 `.22.194`，而是落到 `.43.201`**。原因不是容量而是 `topologySpreadConstraints`：驱逐后 6a=2 / 6b=1，补到 6a 会变 3:1 违反 `maxSkew: 1` ⇒ 只能放 6b。**AZ 硬约束在真实故障下确实生效**（也正因此短时内 6b 两台机器各承载 2 副本，见 §十三-②） |
| PDB | 驱逐前后 `allowed=1` 不变（`minAvailable 70%` ⇒ 健康下限 3，4 副本时恰好允许 1 个）；被驱逐的正是这 1 个名额 |
| 善后 | 目标节点 `非 DS Pod 数=0`；`kubectl uncordon` 成功、四台 `Ready`。**uncordon 不会重排 Pod**，终态仍是 2×`.22.195` + 2×`.43.201`（之后被 V4 的 6→4 缩容打散成每节点 1 个） |

### V4 —— HPA 触发实测（三段式；卡片原方法不成立，见 §八-6）

**① 卡片原方法（独立压测 Pod 打流量）——已实跑，结论是「不可判」**（`task23_v4_trigger_20261006-075922`）：`t23-cpu-load` 起 8 路 × 500 次 `wget /api/status`，负载 Pod 全程 `Running`，同时把 stable 的 HPA 临时降到 `max=6 / target=1%`，轮询 14×15 s ⇒ **一次都没扩**。四个 Pod 的 `kubectl top` 压测前后都是 `cpu=1m mem≈24Mi`（1m / 2000m = **0.05%**，连 1% 门槛都不到）。⇒ 「未扩容」在这里**不能**判 HPA 故障。

**② 指标链路（canary 证明）——通过**（`task23_v4_canary_20261006-080453`）：同 ns 建 1 副本 canary（容器内 `while :; do :; done`，`requests.cpu=100m` / `limits.cpu=200m`）+ 独立 HPA `min1/max3/target 65%`。
- `kubectl top` 实测单 Pod `cpu=201m` ⇒ 利用率 **200%**；
- 约 20 s 内 `New size: 3; reason: cpu resource utilization (percentage of request) above target` + `Scaled up … from 1 to 3`，HPA 读数 `cpu: 200%/65%`、`REPLICAS 1→3`。

⇒ metrics-server → HPA → Deployment 这条**通路是好的**；上一轮卡片担心的「FailedGetResourceMetric 需修复」在本 workload 上不是必修项。

**③ 真实 stable 的容量与缩容通路（有界 4→6→4）**（`task23_v4_capacity_20261006-081017`）：只改 `minReplicas 4→6`（不碰 max/target），触发一次真实扩容再还原。
- 扩容：`Scaled up replica set new-api-stable-7f96d6ff48 from 4 to 6`、`New size: 6; reason: Current number of replicas below Spec.MinReplicas`，**第 2 个轮询点（约 20 s）即 6/6**；无 Pending、无 `forbidden: exceeded quota`。
- 6 副本分布：AZ **6a=3 / 6b=3**（恰好满足 `maxSkew 1`），四台节点各 1–2 个；单节点 `requests.cpu` 最高 `5310m / allocatable 7910m`；endpoints 6 个 `:3000`。
- 配额：`limits.cpu 25/64`、`limits.memory 50Gi/128Gi`、`requests.cpu 12500m/48`、`requests.memory 25Gi/96Gi` ⇒ 6 副本余量充足。
- 缩容：`minReplicas 6→4` 后 **第 2 个轮询点（约 25 s）就回到 4/4**，事件为 `SuccessfulDelete` + `Scaled down … from 6 to 4`，**没有任何 Eviction 记录** ⇒ **HPA 缩容走 ReplicaSet 直接删 Pod，不经 Eviction API，PDB 拦不住它**。这条推翻"有 PDB 就能挡住任意减容"的直觉：PDB 只保护 drain/主动驱逐路径。同时说明 300 s down-stabilization window 不适用于 min-floor 抬高后的回落（那是 spec 变更，立即执行）。
- 善后：`minReplicas`/`maxReplicas`/`target` 全部还原，压测 Pod 与 canary（Deployment+HPA）已删，`残留 Pod 0 个`，配额回到 `17/64`。

**关于「CPU 维度 HPA 对本服务实际失效」**：`/api/status` 极轻（4000 次请求仍 `1m`），指标分母是 **container requests（2C）** 且只对 `scaleTargetRef` 的 Pod 取平均 ⇒ 要打满 65% 需要真实 relay 流量（tokenizer / 序列化 / 加解密）。本轮未做（需可控的真实推理流量），已列残留项。**结论口径**：HPA 的**机制**已验证可用，**阈值可达性**未验证 ⇒ 不能声称「扩容演练通过」，只能说「指标链路与容量通路通过，CPU 触发点未被业务流量证明可达」。 ⚠ **2026-10-06 裁定 F14「HPA 指标优先 CPU」**（原话）⇒ `cpu/65`（分母 request 2C）为定案口径，**现网本就如此，本卡与任务 43 都不需为指标动 HPA、不需为此滚一次发布**；该裁定**接受而不消除**上面的失效面：任务 43 卡原主张的"过渡期内存 HPA"作废留痕，补偿三件套（G8 自定义指标 `new_api_active_sse_connections` / `Pending>0 持续 3min` P1 告警 / `快速扩容（HPA 失灵时）` Runbook 改 `minReplicas` 而非 `kubectl scale`）转为**任务 43 验收前置**。指标复核取证：`deploy/logs/task23_hpa_metric_20261006-092453/remote.out`（`spec.metrics[0]=Resource/cpu target=65`；空闲 4 Pod `CPU=1m`、`MEMORY=26~28Mi`）。

### `--wire-alb` —— 已执行（`task23_wire-alb_20261006-082013`）

- 改写前：`ingress/new-api-verify rules=1`，`host=ph-verify.internal.likha.hk path=/ -> svc/new-api-master:80`（任务 19 原状）。
- 断言通过后 JSON-Patch → `svc/new-api-stable`（当时 `readyReplicas=4`）；改写后 ingress 后端为 `new-api-stable`，控制器事件 `Scheduled for sync` → `SuccessfullyReconciled`。
- 数据面（节点内直连 `alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com`，`Host: ph-verify.internal.likha.hk`）：**`GET /api/status -> 200`、`GET / -> 200`**。
- **顺带销掉任务 19 的 V2 健康检查验收**（10-06 08:4x 由 ALB OpenAPI 只读复核，见 `sgp-*` 三行）：监听 `lsn-ihrgkty2sjdy8s5p4h`（HTTP:80）的 `rule-0f7ru4csbcn41ygmb4`（`Host=ph-verify.internal.likha.hk`、`Path=/*`、`Priority=1`）后端 = **`sgp-tqgwt413t19mum8oa9` / `new-api-new-api-stable-80`**（控制器自动建，`HealthCheckEnabled=true`），成员 4 条 ENI `10.0.22.205 / 10.0.22.218 / 10.0.43.202 / 10.0.43.215 :3000` 全部 `Available`，与当时 `endpoints/new-api-stable` 的 4 个 IP **逐一对应** ⇒ ALB 侧确认拿到健康 Pod。
- 残留：手动建的 `sgp-1zdipho1kpupp43v4m` / **`newapi-direct-ip-3000`**（`ServerGroupType=Ip`）里固化了 4 个**当时的 Pod IP**（`10.0.22.218/219`、`10.0.43.215/218`，全 `Available`）。当前监听默认动作是 `sgp-fm7kdwz99wtzbffkfx`（`kube-system-fake-svc-80`）、唯一转发规则指 stable ⇒ **该组未被任何监听/规则引用**，是惰性资源；但它的 IP 是"快照式"写死的，Pod 重建后必然变陈 ⇒ 见 §十四-3。

---

## 八、本卡发现的**卡片正文问题**（7 处，已连正文一起修正，不是追加备注）

| # | 卡片原文 | 问题 | 已改为 |
| --- | --- | --- | --- |
| 1 | V3 期望「`kubectl get pdb` … ALLOWED DISRUPTIONS = **0**（4 副本时）」 | **算错**：4 副本 + `minAvailable 3`（或等价的 `70%`，`ceil(2.8)=3`）⇒ allowed = 4−3 = **1**；实测就是 1。照原文判会把正常状态当不通过 | 期望改 **1**，并补前置提醒：stable Pod 不存在时显示的 0 是 `NoPods` 造成的（现网 PDB 自 2026-09-30 起长期如此） |
| 2 | 前置「任务 18 节点池（**g9i.2xlarge**）就绪」 | 与实况不符：实际开出的 4 台是 **`ecs.g9ae.2xlarge`**。复核节点池 = 多机型列表 `[g9i, g8ine, g9ae]` ⇒ `g9i` 只是首项，按库存落 `g9ae` | 前置改成实测机型 + 节点池多机型口径 + allocatable 数字；同档位故算术不变，但故障域判断以节点实况为准 |
| 3 | 前置「`SESSION_SECRET` 等明文只在 **KMS**/保管目录」 | 与 2026-10-05 裁定「全线不使用 KMS/凭据管家」冲突（RRSA/KMS/ExternalSecret 永久不实施） | 改为「明文只进堡垒机保管目录 `/root/.deploy_secrets/<KEY>`」 |
| 4 | 步骤 1 manifest `envFrom: [{configMapRef: …}]`（**没有 `secretRef`**） | 漏挂 Secret。缺它**不是起不来**：`SESSION_SECRET` 为空时 `common/init.go:50-58` 直接跳过赋值，`common/constants.go` 里 `SessionSecret = uuid.New().String()` ⇒ **每个 Pod 各自随机** ⇒ 4 副本之间 session 互不认账、随机掉线，且每次重启全员登出。只有值等于字面量 `random_string` 才 `log.Fatal` | manifest 补 `- secretRef: {name: new-api-secrets}` 并写明真实后果（原写法会让人以为"没配也能跑"） |
| 5 | 步骤 1 manifest `env` 只有 `NODE_TYPE`，但坑 2 要求显式 `GOMAXPROCS` | 正文自相矛盾；且实测容器内 `nproc = 8`（= 宿主核数）而 `limits.cpu = 4`，不能假设运行时自动收敛 | env 补 `{name: GOMAXPROCS, value: "4"}`，坑 2 的"Go 1.25 container-aware 默认可用"改成实测口径 |
| 6 | V4 步骤「`kubectl run cpu-burn --image=polinux/stress -- stress --cpu 8`」后判「HPA 应在 3–5 min 内把副本数从 4 抬到 8」 | **方法有两处硬伤**：(a) `stress` 跑在**另一个 Deployment 之外的一次性 Pod** 里，HPA 的指标只对 `scaleTargetRef`（= `Deployment/new-api-stable`）的 Pod 取平均 ⇒ 无论压多狠，stable 的读数都不变；(b) 即便换成"对 stable 打真实 HTTP"，`/api/status` 不查 DB/Redis，4000 次请求后 Pod 仍是 `cpu=1m` = requests 的 **0.05%**，65% 门槛数学上不可达。照原文执行会得出"HPA 坏了"的**假阴性**（本轮实跑 14×15 s 一次未扩，正是这个假阴性） | 卡片 V4 改成三段：**①指标链路**用带 `while :; do :; done` 的 canary Deployment + 独立 HPA（`requests.cpu=100m` ⇒ `limits 200m` 即 200%）证明 metrics-server→HPA→RS 通；**②容量通路**对真实 stable 只抬 `minReplicas 4→6→4`（有界、不撞配额）验证调度与 AZ；**③阈值可达性**明确标为"需真实 relay 流量，本卡未证"，不把①②当成通过 |
| 7 | V4 的压测镜像写 `polinux/stress`（清理清单里还有 `busybox`） | 本集群**唯一实测过的拉取路径**是自建 ACR 的 VPC 端点（任务 5/6 冷节点验证），Docker Hub 可达性从未验证过 ⇒ 直接照原文起 Pod 有 `ImagePullBackOff` 风险，把"验证 HPA"变成"排查拉镜像" | 卡片补一句：压测/烧 CPU 的 Pod 复用已在节点上的业务镜像 `acr-newapi-mnl-registry-vpc…/newapi-prod/newapi-master:20260928-26ac63233` + `sh -c` 死循环或 `wget` 循环（本轮 canary 与 load Pod 都这么起，事件为 `already present on machine and can be accessed by the pod`，零拉取）。**注**：这是"避免未验证路径"，不是"Docker Hub 已被证伪" |


---

## 九、配额与容量：`maxReplicas` 已裁定为 **15**（2026-10-06）

**裁定原话**：「3. 降到 15」⇒ 采取"降 `maxReplicas`"而非"抬 ResourceQuota"。已同步三处：现网 HPA `patch`（`kubectl -n new-api patch hpa hpa-new-api-stable --type json -p '[{"op":"replace","path":"/spec/maxReplicas","value":15}]'`）、清单 `deploy/aliyun/ph/stable-deployment.yaml`（`maxReplicas: 15`）、指南任务 23 卡（见下）。

实测 `ResourceQuota new-api-quota`（`deploy/logs/task23_verify_20261005-232713/remote.out` V6；10-06 复核数值不变）：

| 维度 | hard | 现用（stable 4 副本 + 其他） | 扩到 16 副本合计 | 配额天花板 |
| --- | --- | --- | --- | --- |
| `requests.cpu` | 48 核 | 8.50（stable 8.00 + 其他 0.50） | 32.50 ✅ | 23 副本 |
| `requests.memory` | 96 Gi（98304 Mi） | 17408 Mi | 66560 ✅ | 23 副本 |
| **`limits.cpu`** | 64 核 | 17.00（stable 16.00 + master 1.00） | **65.00 ❌** | **15 副本** |
| **`limits.memory`** | 128 Gi（131072 Mi） | 34816 Mi | **133120 ❌** | **15 副本** |

- 算术：16×4C + master 1C = **65 > 64**；16×8Gi + master 1Gi = 133120 Mi > 131072 Mi ⇒ **第 16 个副本会被配额直接拒（`forbidden: exceeded quota`）**；15×4C + 1C = **61 ≤ 64**、15×8Gi + 1Gi = **121 Gi ≤ 128 Gi** 才成立 ⇒ 两个 limits 维度的天花板都是 **15**，`maxReplicas` 取 15。
- 现量对照（本轮真实扩到 6 副本，`task23_v4_capacity_20261006-081017`）：`limits.cpu 25/64`、`limits.memory 50Gi/128Gi`、`requests.cpu 12500m/48`、`requests.memory 25Gi/96Gi` ⇒ 6 副本一路无 Pending、无配额拒绝，是这条算式的实测锚点。
- **但节点侧的约束没有因为改成 15 而消失**：15×2C = 30C requests，4 台节点 allocatable 合计 **31.64C**，看似够；AZ 硬约束（`maxSkew 1` + `DoNotSchedule`）要求两 AZ 副本数差 ≤1 ⇒ 15 副本 = 8/7，单 AZ 8 Pod × 2C = **16C > 单 AZ 现有 15.82C** ⇒ **仍需扩到 6 台（每 AZ 3 台 = 23.73C）**。即 15 这个数字消除了"配额直接拒"，没消除"扩节点"，后者属任务 42。
- 连接数口径：`SQL_MAX_OPEN_CONNS=100`/Pod ⇒ 15 副本对 RDS PgBouncer（6432）的潜在开连接 **1500**（含 master 与备站另算），这是副本数除配额外、节点外的第三道约束（呼应 §6.4 与任务 30 的 4 万连接预算讨论）。
- **未采纳的备选**（留痕）：把 `limits.cpu`/`limits.memory` 抬到 ≥68 核 / ≥136 Gi 可保留 16，但那样配额天花板 16 仍低于 `requests` 维度的 23，且要同步扩节点池 ⇒ 收益只有 1 个副本，裁定选择降 `maxReplicas`。
- **代价**：`maxReplicas` 由 16 变 15 ⇒ 卡片「stable 接管 24 副本」的容量口径（xlsx `说明与总览!B29`、`落地计划!C46,C47`、`G10!B79`）**在本 ns 配额下不可能达成**，已进 §7 xlsx 回改清单（只列不改）。

---

## 十、权限边界（与任务 13/18 的 schema 最小化不冲突）

| 证据 | 值 |
| --- | --- |
| apply 前基线 FP0 | `37\|77f5c248d32cecb7c7e28a9b655deede\|1174c9028cc094295a7b6bb066f51c14` |
| apply 后 FP1 | **同上，逐字相同** |
| stable Pod 启动日志 DDL（PG 口径） | **0 行**；`ERROR/FATAL` **0 行** |
| 实际数据库账号 | `newapi`（DML 经 6432 PgBouncer），**不是** `newapi_migrate` |

代码依据：slave 启动在 `model/main.go:215-217`（主库）与 `:262-264`（日志库）两处 `if !common.IsMasterNode { return nil }` 提前返回 ⇒ stable Pod 对 PG/CK **一条 DDL 都不发**。

---

## 十一、失误与修正（脚本侧，均已落进 `deploy/tasks/task23/stable.sh` / `task23/bodies/*`）

| # | 症状 | 根因 | 修正 |
| --- | --- | --- | --- |
| ① | `CmdContent.ExceedLimit`（403） | 首个 precheck body 23.6 KB → 外层 b64 26.6 KB > ECS **24 KB** 上限 | 下发前剥掉整行 YAML 注释（9,364 B → **3,733 B**）；把带清单的 server-side dry-run 单独拆成 `--dryrun`；本地加体积自检（估算 `0.85×(body+6.4 KB)`，≥24 KB 直接 `die` 并提示拆分，**不再硬发**） |
| ② | 配额算术把运行中的 stable 副本**双算**（输出"实际最多 11 副本"） | `used` 里已含 stable，又整份加上 `replicas×per_pod` | 改成读现值 `CUR`，`other = used − per_pod×CUR`，再算 `other + per_pod×maxr` 与天花板 `int((hard−other)//per_pod)`；先用 fixture 验算再实跑，两者都得 15 |
| ③ | `NameError: name 'sys' is not defined`（P5 Secret 段） | heredoc 里 `import` 漏 `sys` | 补齐；重跑得 6 键与 DSN 账号 |
| ④ | `CFG_SUM: unbound variable`（本地就展开） | `printf` 里写成 `\\$CFG_SUM` | 改回 `\$CFG_SUM`，落到节点侧由双引号展开为现值 |
| ⑤ | `ROLL=1` 下发后远端读不到 | 远端 body 是独立进程，不继承本地 env | 由脚本把 `ROLL='1'` 字面写进 body 第 3 行 |
| ⑥ | 「全程未缩容量」当时只是推定 | rollout 成功 ≠ 容量未减 | 补 RS desired/current/ready/available + 事件序列取证（§六-②），并把这段固化进 `--verify` |
| ⑦ | **drain 被中途顶掉**：`/tmp/ackctl/remote.sh: line 55: syntax error near unexpected token ')'`，`kubectl drain` 已生效但后续取证与 `uncordon` 全丢，节点停在 `SchedulingDisabled` | `deploy/lib/ack_remote.sh` 的执行期文件（`remote_body.sh` / `remote_cmd.sh`）与节点侧目录 `/tmp/ackctl/` 都是**固定路径**，另一个并发会话在同一时间下发自己的 body，把我正在跑的脚本覆盖成它的内容（错误位置 `line 55` 正是它的行） | `deploy/lib/ack_remote.sh` 改为按 `RUN_ID` 唯一：本地 `remote_body.<run>.sh` / `remote_cmd.<run>.sh`、节点侧 `/tmp/ackctl-<run>/remote.sh` + `trap rm -rf` 自清 + 本地 `trap` 清理；`bash -n` 通过后重跑，并写 `03-drain.sh`（drain 输出落 `/tmp/drain.log`）+ `03c-drain-post.sh` 分段补救，V3 证据因此未丢失。**教训**：破坏性命令必须先把输出重定向到节点侧文件，否则一次覆盖就永久失去取证 |
| ⑧ | 长 body 本地轮询提前打印「超时未完成」 | 默认 `LOOPS=24`（×5 s = 120 s）小于 body 实际耗时（drain/V4 各 3–8 min） | 对已知长 body 显式传 loops（90/110/130），本轮 4 个 body 分别在第 2/44/38/93 轮 Success |
| ⑨ | V4 第一版 body 轮询完仍 `des=4` 却无结论 | 只观察"有没有扩"，未同时观察**指标读数本身**⇒ 无法区分"HPA 坏"与"压不到" | 每轮同时输出 `kubectl top pods` + HPA `jsonpath` 的 `cur/des/cond/reason`；并在 body 里临时把 target 降到 **1%**（数学上排除门槛因素）后仍不扩 ⇒ 才能断定"指标未被抬起"，而非"HPA 故障" |
| ⑩ | `deploy/lib/ack_remote.sh` 冷缓存时必然失败（本轮一直命中缓存所以没暴露） | 拉 kubeconfig 的分支把响应写到 `kc.${RUN_ID}.json`，紧接着的解析却读死的 `kc.json` | 改成同一个 `kc.${RUN_ID}.json`；**冷路径已实跑验证**：`ACKCTL_DIR=$(mktemp -d)` + 只读 body ⇒ `[i] kubeconfig -> …/kubeconfig (server=https://10.0.22.182:6443)` → `COLD-PATH-OK` → `BODY END (第 1 轮 · Success)`，临时目录只剩 `kubeconfig`（带 `RUN_ID` 的中间文件被 EXIT trap 清掉） |
| ⑪ | 05 body 第 6 段"Ingress 后端"与 endpoints **打印为空**，看起来像"没查到对象" | 两个独立小错：`ingest.networking.k8s.io` 短名在本集群不存在（`the server doesn't have a resource type "ingest"`，06 body 暴露）；endpoints 用 `--no-headers \| awk '{print $3}'` 取到的是 NOTREADY 列（输出只剩 `+`） | 07 body 改用全名 `ingresses.networking.k8s.io` + `endpoints -o jsonpath='{range .subsets[*]}{.addresses[*].ip}…'` ⇒ 拿到 `ph-verify.internal.likha.hk / -> new-api-stable:80` 与 4 个 `:3000` 后端 IP（§十二 收口复核）。**教训**：判"查不到"之前先确认命令本身有效——`2>/dev/null` 会把这类 API 层错误静默成空输出 |
| ⑫ | 上一版把「用户面 `get deploy,sts` 无 cluster-autoscaler」当成组件缺失的证据（§十三-③ 的原口径） | ACK 托管组件跑在控制面，用户面本就不可见；ALB 同错（任务 19 ③ 曾据此判定控制器未运行） | 改为 **lease holder + `renewTime` 与节点侧 `date -u` 同秒 → EndpointSlice IP/AGE → 调谐产物** 三级取证（05/06 body 即此法），据此把结论收回并更正为"弹性组件实名 `ack-goatscaler`、活着、开节点动作未测"；任务 19 正文（③ 与步骤 1 命令）同步改正 |

---

## 十二、收口状态与交接

- **集群现状（2026-10-06 08:20 补测终态，`task23_wire-alb_20261006-082013` + `task23_v4_capacity_20261006-081017`）**：`new-api-stable` **4/4**，四台节点**各 1 个副本**（`.22.194` / `.22.195` / `.43.200` / `.43.201`，6a=2 / 6b=2）；`hpa-new-api-stable` `min=4 / max=15 / target cpu 65%`、读数 `cpu: 0%/65%`；`pdb-new-api-stable` `70%` allowed=1；`ResourceQuota` 回到 `limits.cpu 17/64`、`limits.memory 34Gi/128Gi`；四台节点全 `Ready`（`.43.200` 已 uncordon）；canary 与压测 Pod 已删（残留 0）。
- **ALB 出口已切**：`Ingress/new-api-verify`（`host=ph-verify.internal.likha.hk`）后端由任务 19 的 `svc/new-api-master` 改为 **`svc/new-api-stable`**，经 ALB 域名 `GET /api/status -> 200`、`GET / -> 200` ⇒ **任务 19 的 V2 健康检查验收同时销项**。`new-api-master` 仍 `1/1` 在跑（不再承接该域名流量）。
- **待办（本轮已清掉 ①②③，改列新残留）**：
  - ✅ ~~V3 drain 需核准后补测~~ → 已实测通过（§七-V3）。
  - ✅ ~~V4 stress~~ → 已实测，并修正卡片方法（§七-V4、§八-6）；**残留**：CPU 65% 触发点的"业务流量可达性"仍未证 ⇒ 需要真实 relay 压测才能声称完整通过。
  - ✅ ~~`--wire-alb` 待确认~~ → 已切并取证（§七）。
  - ✅ ~~`maxReplicas` 15 vs 抬配额~~ → 裁定 15，现网 + 清单 + 卡片三处同步（§九）。
  - ✅ ~~HPA 指标 cpu vs memory~~ → 裁定 **「HPA 指标优先 CPU」（F14，10-06）**；现网本就 `cpu/65` ⇒ **本卡零改动**，任务 43 卡的内存口径作废。残留不撤销：上面那条"业务流量可达性未证"仍是开放项，且补偿三件套转为任务 43 验收前置（§七-V4 末段）。
  - ⏳ ④ G8 `/readyz` 落地后替换三个探针（`/api/status` 不查 DB/Redis 的"过早 ready"风险仍靠 `startupProbe` 兜）。
  - ⏳ ⑤ 接 GitOps 时给 Deployment 加 `ignoreDifferences: [/spec/replicas]` 并按卡片去掉 `replicas`；同时把 `maxReplicas: 15` 一并纳入 Git 真源（本轮现网 patch 与清单已一致，但现网值仍可能被下次 `kubectl apply` 覆盖回旧清单，故必须同步）。
  - ⏳ ⑥ 机型与成本回填：**本条已在 10-06 完成单价核实与月费重算**（详见 §十四），卡片与指南成本表同步。
  - ⏳ ⑦ 见 §十三、§十四新增事实与残留。
  - ⏳ ⑧ **任务 42 前置（10-06 08:52 新列）**：`ack-goatscaler` 已证活着（§十三-③），但**从没开过第 5 台节点** ⇒ 需一次受控 `Pending` 实测扩节点；同时确认节点回收（`unneeded_duration 10m` / `scale_down_enabled=true`）是否尊重 PDB。两步都涉及真金白银/驱逐，**须核准**。

- **10-06 08:52 收口复核**（`logs/task23_albctrl_20261006-085148/`、`logs/task23_goatscaler_20261006-085256/`、`logs/task23_ingress_be_20261006-085337/`，全只读）：`Ingress/new-api-verify` = `ph-verify.internal.likha.hk / -> **new-api-stable:80**`（`ingressClassName=alb`，address = `alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com`）；`endpoints/new-api-stable` = `10.0.22.205 / 10.0.22.218 / 10.0.43.202 / 10.0.43.215 :3000` ⇒ **与 ALB ServerGroup 的 4 条 ENI 逐字一致**（V2 判定的第二条独立证据）；`endpoints/new-api-master` 仍空（预期，见任务 18 差异 ②）；HPA `min=4 max=15 target=65 cur=4 des=4`；PDB `minAvailable=70%`、`currentHealthy=4 desiredHealthy=3 disruptionsAllowed=1 expectedPods=4`、条件 `DisruptionAllowed=True/SufficientPods`。托管组件存活铁证：`lease/alb`、`lease/alb-gateway`、`lease/ack-goatscaler` 三者 `renewTime` 与节点侧 `date -u` **同秒**。

---

## 十三、本轮新增的**架构级事实**（影响后续卡片的判据）

| # | 事实 | 证据 | 影响 |
| --- | --- | --- | --- |
| ① | **HPA 缩容不经 Eviction API** | `minReplicas 6→4` 的事件只有 `SuccessfulDelete` + `Scaled down from 6 to 4`，无 `Eviction` ⇒ PDB `disruptionsAllowed` 对 HPA 缩容**没有约束力** | 「有 PDB 就不会掉容量」这条直觉只对 drain / 主动驱逐成立。若要让缩容也受 PDB 保护，只能靠 `behavior.scaleDown.selectPolicy=Disabled` 关掉自动缩容，或走外部驱逐编排 ⇒ 卡片与任务 46 故障演练需按此口径 |
| ② | **`topologySpreadConstraints` 会否决"落到空节点"** | drain 后 `.22.194` 完全空闲，替补 Pod 却被调度到已有 2 副本的 `.43.201`；6 副本时分布恰好 6a=3 / 6b=3 | AZ 硬约束在真实故障下生效（好事），但短时会出现"某 AZ 4 副本挤在 2 台机器"⇒ 单机故障域概率上升。若要每节点均摊需加 `whenUnsatisfiable` 之外的拓扑或换 `podAntiAffinity`，属任务 42/47 议题 |
| ③ | **弹性组件确实存在且在运行，但实名是 `ack-goatscaler`（不是 cluster-autoscaler）** —— 本行由"未证"改为"已证存在，扩节点动作仍未实测" | 10-06 08:52（UTC 00:52）只读三步（`deploy/tasks/task23/bodies/06-goatscaler-lease.sh`、`07-ingress-backend.sh`；证据 `logs/task23_goatscaler_20261006-085256/`、`logs/task23_ingress_be_20261006-085337/`）：`lease/kube-system/ack-goatscaler` holder **`ack-goatscaler-65889bc864-qdqdd`**、`renewTime=2026-10-06T00:52:57Z`（节点侧当时 `00:52:58Z`，**同秒续约**）；用户面 `pods -A`/`deploy,ds,sts -A` 含 goat **计数 0**（与 alb 同构，见 ⑤）；`cm/kube-system/autoscaler-meta` = `{"scaler-type":"goatscaler", "unneeded_duration":"10m","cool_down_duration":"10m","utilization_threshold":"0.5","scale_down_enabled":true,"scan_interval":"60s","expander":"least-waste","scale_up_from_zero":true,"max_graceful_termination_sec":14400,"skip_nodes_with_system_pods":true,"min_replica_count":0,"cpu":"500m","memory":"500Mi","nodepool_backoff_sec":600,"daemonset_eviction_for_nodes":false,"scaling_configurations":null}`；集群侧节点池 `DescribeClusterNodePools`：`np-mnl-app` `enable=true min=4 max=8 charge=PostPaid`、`np-sg-ph-standby` `enable=true min=2 max=12 charge=PostPaid`（原文 10-05 记的 `max=8` 一致）。`cm/cluster-autoscaler-status` **NotFound** ⇒ 它不用那个 CM，**当时按该名字查是查法错误** | 任务 42 的前提从"找不找得到 autoscaler"变成两件事：**(a) 扩容动作从未被实测**——节点数自始等于 `min=4`，goatscaler 只有一次真实 `Pending` 才会证明它能否开出第 5/6 台（§九 的 15 副本需 6 台仍悬着）；**(b) 缩容侧是活的**（`scale_down_enabled=true` + `unneeded_duration 10m` + `utilization_threshold 0.5`），叠加 ④（本服务 CPU 常年 ~0%）⇒ 一旦扩到 5~8 台再回落，节点会在 ~10 min 后被回收，与 HPA 缩容形成**双层缩容**。以上参数含义按 cluster-autoscaler 同名项推断，**任务 42 须实测确认**，别当已证 |
| ④ | **CPU 维度的 HPA 对本服务在当前流量模型下等于不工作** | 8 路 × 500 次 `/api/status`（实测脚本 `deploy/tasks/task23/bodies/04-hpa-trigger.sh:44`）⇒ `cpu=1m`（0.05% of requests 2C）；`/api/status` 是极轻端点，真实开销在 relay 的序列化/加解密 | `target 65%`（= 1.3C/Pod）只有真实 relay 流量能达到 ⇒ 监控与告警不能把"HPA 从没扩过"当异常；反过来，一旦 relay QPS 上来，扩容会成台阶式跳变，` stabilizationWindowSeconds 300` 是唯一的抖动保护 |
| ⑤ | **托管组件跑在 ACK 控制面，用户面不可见**（10-06 由 ALB + goatscaler 双证） | `get pods -A` 计 alb = **0**、`get deploy/ds/sts -A` 计 alb = 0，但 lease `alb`/`alb-gateway` holder = **`controlplane-alb-84bb75d758-l8q7g_…`**、**`renewTime=2026-10-06T00:52:57Z` 而节点侧 `date -u` 同时刻 00:52:58Z ⇒ 同秒续约 = 正在运行**；headless `Service/alb-ingress-controller` + `EndpointSlice alb-ingress-controller-4dprp`（`7.8.229.211`/`7.8.72.26`，两条 `ready=true`，AGE 10h = 10-05 22:08 重装时刻）；`ingress/new-api-verify` `Scheduled for sync` + `SuccessfullyReconciled`（31m 前）、`albconfig/mnl-alb SuccessfullyReconciled`（同批）。goatscaler 同构（③） | **修正了任务 19 的既有结论**：该卡曾以"集群内无任何 alb workload"为据判定控制器未运行 ⇒ 那条**判据无效**（10-05 的病征实际是"无调谐产物"，重装后恢复）。今后核查托管组件（ALB / cluster-autoscaler / 其他 addon）按 **lease holder + renewTime 与当前 UTC 同秒 → EndpointSlice IP/AGE → 调谐产物（events + 云侧对象变化）** 三级取证，`get pods` 为 0 **不是**缺失证据。已连任务 19 正文（③ 判定方法纠偏、步骤 1 命令）一起改正。另：本集群 `kubectl get ingest` 短名**不可用**（`the server doesn't have a resource type "ingest"`），必须写 `ingresses.networking.k8s.io` |

---

## 十四、残留与风险（按可操作性排序）

1. **CPU 触发点未用业务流量验证**（§七-V4 结论口径）：需要可控 relay 压测（真实 token 生成/序列化负载）才能声称 V4 完整通过。**未做**，本卡不声称。
2. **自动扩节点的动作仍未实测**（§十三-③ 已把"组件不存在"的猜测收回：`ack-goatscaler` 活着、`np-mnl-app enable=true min=4 max=8`）：`maxReplicas=15` 需要 ≥6 台节点（§九），而节点数从建池起就等于 `min=4`，**goatscaler 从没机会开第 5 台** ⇒ "HPA 扩不出来时能自动补节点"这条**通路存在性已证、有效性未证**。**行动（任务 42 前置，需核准，因为有真金白银）**：在受控窗口把 `minReplicas` 抬到超过 4 台可承载量（>12 个 2C 副本即必 `Pending`）观察 5~10 min 内是否自动出节点、落到哪个 AZ、`least-waste` 选的机型是否为三机型里最贵的 `g8ine`；测完立即还原。**PostPaid ⇒ 每多一台按 §十五 单价计费（g9ae 0.51848 USD/h 起）**，属可观测成本，须提前打招呼。
2b. **新增的双层缩容风险（同一批证据带出的）**：`scale_down_enabled=true` + `unneeded_duration 10m` + `utilization_threshold 0.5`，而 §十三-④ 实测本服务 CPU 常年 `1m`（≈0%）⇒ 只要节点数 > `min`，空闲节点会在 ~10 min 后被回收；叠加 HPA 自身缩容（且 §十三-① 已证 HPA 缩容不经 PDB），**"流量高峰后容量自动回落"是两层同时发生的**，压测与故障演练（任务 46）必须把节点回收一起算进去。缓解手段：`min=4` 已是地板（4 台恰好容 4 副本 + system Pod），高峰后的回收是**期望行为**（省钱），但需要确认 goatscaler 驱逐时是否尊重 `pdb-new-api-stable`（`daemonset_eviction_for_nodes=false`、`skip_nodes_with_system_pods=true` 的实际语义待测）。
3. **`newapi-direct-ip-3000`（`sgp-1zdipho1kpupp43v4m`，`Ip` 型服务器组）是快照式手写资源**：固化 4 个当时的 Pod IP（`10.0.22.218/219`、`10.0.43.215/218`）。本轮 ALB OpenAPI 复核：监听默认动作 = `kube-system-fake-svc-80`，唯一规则 = stable 组 ⇒ **它当前不在转发路径上**（惰性，无错路由风险，先前"会打到错误 Pod"的判断已按实况收回）。**风险在别处**：Pod 重建后这些 IP 必然失效/被复用，若日后有人误把规则指向它，就是一组陈旧的假后端。**行动**：删除该服务器组（任务 19 排障遗留；ALB 写操作需核准），或在指南任务 19 明确标注"仅排障用、禁止接流量"。
4. **`SessionSecret` 每次重启全员登出**（§八-4 的连带）：manifest 已补 `secretRef`，但 `SESSION_SECRET` 轮换仍未做（在待核准清单里）。轮换 = 全员登出，需窗口。
5. **`Ingress` 只有 HTTP:80**：ALB 监听 `lsn-ihrgkty2sjdy8s5p4h` 是唯一监听（HTTP:80），443 与证书属 G5 阻塞项 ⇒ 本次 200 取证走明文 80，**不代表** HTTPS 路径可用；`SESSION_COOKIE_SECURE` / `TRUSTED_URL` 仍要等 443。
6. **成本口径已核实并已裁定**（见下条与 `核心更新总结`）：节点池实况是 **PostPaid（按量）**，与指南 2026-09-28 裁定「ECS/Tair/RDS = 包年包月 PrePaid」冲突 ⇒ **2026-10-06 用户裁定：维持按量付费（`PostPaid`）**。成本表以**按量**口径为准（`g9ae` 0.51848 USD/h × 4 台 × 730 h ≈ **1513.96 USD/月**），指南 v2.0 已全量回改（F13 + 任务 11/24/42/52 卡 + 附录）。
7. **账户余额未能复核**：`QueryAccountBalance` 在本账号返回 `AuthSiteFail`（换 `--region cn-hangzhou` 同样失败）⇒ 「余额 0.00 USD（2026-09-30）」仍是旧证据，本轮**无法**确认，PostPaid 下的欠费停机风险需人工在控制台看。

---

## 十五、机型单价核实与月费重算（裁定 4「单价不一样，月费要重算」）

只读取证：`aliyun ecs DescribePrice`（`Amount=1`，含系统盘 ESSD 100 GB + 数据盘 ESSD PL1 300 GB），脚本 `deploy/tasks/task23/price_matrix.py`，输出 `deploy/logs/task23_price_20261006-082504/matrix.out`；新加坡侧 `deploy/logs/task23_cost_20261006-082618/`。

### 马尼拉 `ap-southeast-6` / `ap-southeast-6a`（节点池 `np-mnl-app`）

| 机型 | 包月 USD/台 | 按量 USD/台·h | 包年 USD/台 | 备注 |
| --- | --- | --- | --- | --- |
| **`ecs.g9ae.2xlarge`（实况）** | **288.82** | **0.51848** | 2575.66（原 3465.82，折 890.16） | 4 台节点全部是该机型 |
| `ecs.g9i.2xlarge`（指南原报价） | 277.97 | 0.47048 | — | 仅在机型列表首项，库存未落到 |
| `ecs.g8ine.2xlarge` | 332.28 | — | — | 列表第三项 |

- **原成本表错在三处**：① 单价用 `g9i` 且是 **217.17 USD/台**（不含盘），实况机型含盘 **288.82**；② 4 台合计写 1111.88，按 `g9ae` 含盘应为 **288.82 × 4 = 1155.28 USD/月**，差 **+43.40**；③ 按量行写「1.57808 USD/h ⇒ 月约 1136」，按 `g9ae` 应为 **0.51848 × 4 = 2.07392 USD/h ⇒ ×730 h ≈ 1513.96 USD/月**。
- **付费方式实况 = 按量（2026-10-06 用户裁定采纳，F13 已闭合）**：`DescribeClusterNodePools` + `DescribeInstances` 回读 `np-mnl-app` 与其 4 台 ECS 全是 **`PostPaid`（按量）** ⇒ **月费口径即按量的 ≈1514 USD/月**（不是包月 1155.28）；「扩容即预付 12 个月」的坑 7 推论**不成立**（已按裁定作废）。⚠ 代价是**按量配额余量为 0**（`postpay_c` 64 = `max_size` 8×8），扩节点前须提额。
- **可省的金额（⚠ 2026-10-06 已裁定不转包月/包年，以下仅作参考、不再执行）**：按量 1513.96 → 包月 1155.28 省 **358.68 USD/月（约 24%）**；包年 10302.64 ⇒ 折 **858.55 USD/月**，较按量省 **655.41 USD/月（约 43%）**。`g9i` 若可售则包月 277.97/台 = 1111.88，比 `g9ae` 包月便宜 43.40/月，但**可售性不可控**（本轮 4 台全落 `g9ae` 即库存证据）。

### 新加坡 `ap-southeast-1` / `ap-southeast-1a`（节点池 `np-sg-ph-standby`）

| 机型 | 包月 USD/台 | 按量 USD/台·h |
| --- | --- | --- |
| `ecs.g9i.2xlarge` | 302.10 | 0.51168 |
| **`ecs.g9ae.2xlarge`** | **332.32** | 0.57328 |
| `ecs.g8ine.2xlarge` | 362.44 | 0.61428 |

- 该池 2 台节点是 **混合机型**：`ecs.g8ine.2xlarge`（10.1.38.113）+ `ecs.g9ae.2xlarge`（10.1.19.103），**都不是任务 24 卡头写的 `g9i.2xlarge`** ⇒ 卡头机型表述错误，已按实况更正。
- 备站按量月费 = (0.61428 + 0.57328) × 730 ≈ **867.5 USD/月**；若按卡头的 `g9i` 报价（302.10 × 2 = 604.20 包月）**低估约 260 USD/月**。

### 已回写的文档位置

`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`：成本量化表（4478 行区）、任务 11 卡「前置」付费方式（2508 行）与坑 7（2623 行）、任务 24 卡头机型（3557 行）、验收清单机型判据（3252 行）；`deploy/docs/核心更新总结_2026-10-05.md` 相应段落。**xlsx 侧只列回改清单，不编辑。**

---

## 十六、原始口径（留档，勿据此执行）

- **集群现状**（`deploy/logs/task23_status_20261005-233022/remote.out`，10-05 23:30 只读复核）：`new-api-stable` **4/4**（revision 2）、`service/new-api-stable` ClusterIP `172.21.15.220`、`endpoints` 4 个 `:3000`、`hpa-new-api-stable` `cpu: 0%/65%` min 4/max 16/replicas 4、`pdb-new-api-stable` `70%` allowed=1；master 仍 `1/1` 未受影响；`Ingress/new-api-verify` 后端仍指任务 19 的 `new-api-master`（未切）。
- **机型表述回填（本卡已改的部分）**：节点池本就是三机型列表 `[g9i, g8ine, g9ae]`（任务 11 卡步骤 2 的 `instance_types` 设计，顺序即优先级），实际开出 4 台 `g9ae` ⇒ 指南里**已连正文更正** 6 处：F1 裁定行、§2.1 参数基线"节点机型"行、全局基线参数表"节点池机型（实测修订）"行、泳道 B（任务 10–23 组）与泳道 D 前置基线行、任务 11 卡「前置/状态」（补建池实况 + allocatable）、任务 23 卡「前置/状态」。**xlsx 侧更旧**：`说明与总览!B28`、`资源清单-马尼拉!D15`、`资源清单-新加坡!D11`、`落地计划!C14`、`里程碑与验收!D6` 仍写 **`g8i.2xlarge`**，而 `g8i` 全系 2026-09-25 实测**未在马尼拉上架**（指南 F1 已作废该口径）⇒ 已进 §7 xlsx 回改清单（只列不改）。
- **未提交**：本卡脚本/清单/日志与报告均未 commit（未收到要求）。
