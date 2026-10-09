# HPA 扩缩容策略详解 · `hpa-new-api-stable`

> 对象：`HorizontalPodAutoscaler/hpa-new-api-stable`（namespace `new-api`，apiVersion `autoscaling/v2`）
> 目标：`Deployment/new-api-stable`
> 实况抓取：**2026-10-06 23:10 (GMT+8)**，经 `deploy/ack_remote.sh mnl` 从集群内直读
> 抓取脚本：`deploy/hpa_bodies/00-get-hpa.sh`（HPA spec + 实时用量）、`deploy/hpa_bodies/01-node-capacity.sh`（节点可分配量）

---

## 一、实况快照

### 1.1 HPA

| 项 | 值 |
|---|---|
| `minReplicas` | **4** |
| `maxReplicas` | **13** |
| `metrics` | **仅 cpu**，`target.averageUtilization = 70`（`type: Utilization`） |
| `currentReplicas` | 4 |
| `desiredReplicas` | 4 |
| 当前 CPU 指标 | `averageUtilization: 0`（`averageValue: 1m`） |
| `lastScaleTime` | `2026-10-06T00:13:22Z`（北京 08:13） |
| 创建时间 | `2026-10-05T15:20:44Z` |

### 1.2 目标 Deployment 的资源声明

```yaml
container new-api:
  requests: {cpu: "2",   memory: 4Gi}   # ← HPA 分母
  limits:   {cpu: "4",   memory: 8Gi}
```

> **`requests.cpu` 是 HPA 的除数。** 改 requests 等于改全部阈值，改 HPA 的 `target` 数值不如改它影响大。

### 1.3 集群节点（4 台）

| 项 | 值 |
|---|---|
| 规格 | `ecs.g9ae.2xlarge`（8 vCPU / 32 GiB） |
| 每节点 allocatable | cpu **7910m** · memory **30945144Ki (≈29.5 Gi)** · pods 48 |
| 集群总 allocatable | **31640m ≈ 31.64 核** |
| 当前各节点已分配 requests | 5310m / 3000m / 2900m / 3700m = **14910m ≈ 14.91 核** |

---

## 二、判定核心：HPA 不算"低于多少"，只算"要几个"

**不存在"CPU 低于 X% 就缩容"这种规则。** HPA 每次评估只做一件事——算**目标副本数**，然后：

- `desired > current` → 扩容分支
- `desired < current` → 缩容分支

公式（`type: Utilization` 场景）：

```
desiredReplicas = ceil[ currentReplicas × (当前平均利用率 / target利用率) ]
```

其中：

```
当前平均利用率 = (所有 Pod 的 CPU 实际用量之和 / 所有 Pod 的 requests.cpu 之和) × 100%
```

### 2.1 本集群的具体数字

```
requests.cpu          = 2 核
target                = 70%
单 Pod 阈值线          = 70% × 2 核 = 1.4 核
```

**缩容触发门槛**（含 tolerance，见 §四）：

```
1.4 核 × 0.9 = 1.26 核/Pod   ← 平均用量跌到这以下才走缩容
```

> **注意**：这是按 `requests` 算的**比例**，不是按 limits。所以"Pod 实际只用了 1m（0.05%）"完全正常——它在 requests 面前微不足道。

### 2.2 算例

| 场景 | 计算 | 结果 |
|---|---|---|
| 当前 13 个，均值 100m | `ceil[13 × (0.1/1.4)] = ceil[0.93]` | **1** → 想缩到 1，被 `minReplicas=4` 夹住 |
| 当前 13 个，均值 1300m | `ceil[13 × (1.3/1.4)] = ceil[12.07]` | **13** → 不动 |
| 当前 13 个，均值 2000m | `ceil[13 × (2.0/1.4)] = ceil[18.57]` | **19** → 想扩，被 `maxReplicas=13` 夹住 |
| 当前 4 个，均值 1m | `ceil[4 × (0.001/1.4)] = ceil[0.003]` | **1** → 夹到 4（**即当前真实状态**） |

---

## 三、缩容策略：三层闸门串联

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300      # 闸门 1：刹车
    selectPolicy: Max                    # 闸门 3：多策略取舍
    policies:
    - type: Pods
      value: 2
      periodSeconds: 120                 # 闸门 2：限速
```

### 闸门 1 — `stabilizationWindowSeconds: 300`（主力）

HPA 每 15s 算一次理想副本数，但**缩容时不采信当前建议值**，而是回看**过去 300s（5min）内所有建议值的最大值**，用它当本轮目标。

⇒ 只要 5 分钟内出现过一次高建议，就不缩。作用 = 滤掉负载毛刺、瞬时低谷。

**这是缩容的主要延迟来源，不是限速。**

### 闸门 2 — `policies`：滑动窗口限速

`type: Pods` + `value: 2` + `periodSeconds: 120` = **任意 120s 窗口内净缩减 ≤ 2 个 Pod**（≈ 1 Pod/min）。

这是**天花板**不是步长——刹车比它狠时按刹车走。

### 闸门 3 — `selectPolicy: Max`

多条 policy 时选**动作幅度最大**的那条。缩容语境下 = 选"缩得最多"的策略。

**本 HPA 的 `scaleDown` 只有一条 policy ⇒ 此字段无实际作用**（默认值就是 `Max`）。

### 3.1 组合时序（13 → 4）

```
t=0      负载暴跌，理想值 13 → 1
t=0..5m  窗口内仍有 13 的建议 → 实际保持 13，一个不动
t=5m     窗口内最大值降下来 → 开始缩，但受限速
t=5m     13 → 11
t=7m     11 → 9
t=9m      9 → 7
t=11m     7 → 5
t=13m     5 → 4    ← 触底（minReplicas）
```

**13 缩到 4：≈ 5min 稳定窗 + 9/2×2min ≈ 14 min，全程约 15 分钟。**

---

## 四、不可忽视的 10% 死区（tolerance）

HPA 有全局容差 `--horizontal-pod-autoscaler-tolerance`，**默认 0.1**：

```
若 |1 − (当前利用率 / target) | ≤ 0.1  →  完全不动作（不缩也不扩）
```

⇒ 真正的缩容门槛是 **平均利用率 < 0.9 × target**：

```
target = 70%  ⇒  低于 63%（= 1.26 核/Pod）才缩
70% ± 10% 区间内（63% ~ 77%）按兵不动
```

这一层**不在 YAML 里**，容易漏算。

---

## 五、扩容策略（对比理解设计意图）

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 30       # 只看 30s
    selectPolicy: Max
    policies:
    - {type: Percent, value: 100, periodSeconds: 60}   # 每 60s 翻倍
    - {type: Pods,    value: 8,   periodSeconds: 60}   # 每 60s 最多 +8
```

| | 扩容 | 缩容 |
|---|---|---|
| 稳定窗 | **30s** | **300s**（10×） |
| 限速 | 60s 内 **翻倍(100%)** 或 **+8**，取大 | 120s 内 **−2** |
| 手感 | 激进（保可用性） | 保守（防抖） |

**不对称是刻意的**：涨得快、跌得慢。宁可多花钱，也不让容量抖动。

扩容时序（4 → 13）：

```
t=0   4 → 8   (Percent 100% = +4；Pods 8；Max 取 8 → 但只能到 8)
t=60s 8 → 13  (Percent 100% = +8；Pods = +8；Max 取 8 → 16，被 max 夹到 13)
```

**≈ 1 分钟就能从 4 顶到 13。**

---

## 六、内存为什么没参与

`spec.metrics` **只有 cpu 一项**——这是对的，不是漏配。

内存是**不可压缩**资源：

- Go/Java/C 的 GC 后不保证归还 OS，RSS 高位横盘
- 进程常驻缓存只增不减
- 利用率长期贴着阈值 ⇒ **永不缩，甚至一直扩**

官方明确不建议把 memory 当唯一扩缩指标。`new-api` 是 Go，尤其明显。

若要加内存，正确做法是**和 CPU 并列**并理解"多指标取 Max"的语义：

> HPA 对每个指标独立算 `desiredReplicas`，然后**取最大值** ⇒ **想缩必须先让所有指标都低**。加一个指标 = 加一道锁。

---

## 七、当前状态解读

```
ScalingLimited / TooFewReplicas
  message: "the desired replica count is less than the minimum replica count"
```

**含义**：HPA 已经算出"副本数应该比 4 更少"，但被 `minReplicas: 4` 拦住了。

配合 `currentMetrics.cpu.averageUtilization: 0`（`averageValue: 1m`）：

> 当前每个 Pod 只用 **1m CPU**，requests 是 **2 核** ⇒ 利用率 **0.05%**，距 63% 的缩容门槛有 1260 倍的差距。

**这不是故障，是"低压保护"正常生效。** HPA 长期停在 `minReplicas` 是低流量期的预期形态。

---

## 八、⚠️ 两个必须处理的问题

### 8.1 DRIFT：live 值与 last-applied 不一致

| 来源 | `averageUtilization` |
|---|---|
| `spec.metrics[0].resource.target`（**实际生效**） | **70** |
| `metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]`（**上次 apply 的声明**） | **65** |

⇒ **有人在声明之外直接改了 HPA**（`kubectl edit` / `patch` / 控制台），未回写 Git 源。

**风险**：下次任何人用 `kubectl apply -f <旧 manifest>` 落地，会把 70 **静默改回 65** —— 阈值变了，行为也变，但没人在 diff 里看到。

**处理**：确认 70 是否是有意为之；是则回写 manifest 并重新 apply 对齐，否则 revert。

### 8.2 ⚠️ `maxReplicas: 13` 装不下 —— 会 Pending

**算账**（CPU requests，调度只看 requests）：

```
集群总 allocatable cpu                = 4 × 7910m        = 31.64 核
扣除 new-api-stable 以外的已分配       = 14910m − 8000m   =  6.91 核
                                       （含 new-api-master 2 核 + 系统组件 ≈4.9 核）
留给 new-api-stable 的上限            = 31.64 − 6.91     = 24.73 核

24.73 核 ÷ 2 核/Pod  =  12.36  ⇒  最多只放得下 12 个 Pod
```

**`maxReplicas = 13` 比实际容量多 1** ⇒ 顶到 13 时，**第 13 个 Pod 会因 `Insufficient cpu` 永久 Pending**。

内存不是瓶颈（13 × 4Gi = 52 Gi，总 allocatable 118 Gi，当前仅用 26.5 Gi）。

**三种解法**：

| 方案 | 动作 | 代价 |
|---|---|---|
| ① 降 max | `maxReplicas: 13 → 12` | 最省事；但丢了 1 个副本的弹性 |
| ② 开节点自动伸缩 | 节点池挂 cluster-autoscaler，Pod Pending 时自动加节点 | 最优；⚠ 需确认 ACK 节点池是否已启用 CA |
| ③ 降 requests | `requests.cpu: 2 → 1.5` | 立竿见影，但**同时把阈值线从 1.4 核降到 1.05 核**，HPA 变敏感（连 ① 一起调更稳） |

> ⚠ 注意方案 ③ 的连锁反应：requests 是 HPA 的除数，改它等于改所有阈值。

---

## 九、诊断命令

```bash
# 阈值定义在哪
kubectl -n new-api get hpa hpa-new-api-stable -o jsonpath='{.spec.metrics}' | python3 -m json.tool

# 当前 / 目标（左 = 当前平均利用率）
kubectl -n new-api get hpa hpa-new-api-stable
# → NAME  ... TARGETS      MINPODS MAXPODS REPLICAS AGE
#    hpa-…     cpu: 0%/70%  4       13      4        23h

# 实际用量
kubectl -n new-api top pods

# 看 HPA 算出的原始建议值 + 被谁夹住
kubectl -n new-api describe hpa hpa-new-api-stable   # 底部 Events + Conditions

# 容量核算
kubectl describe nodes | grep -A6 "Allocated resources"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{" "}{.status.allocatable.cpu}{"\n"}{end}'
```

---

## 十、调参速查

| 想要的效果 | 改哪里 |
|---|---|
| 更快缩容（省按量节点费） | `scaleDown.stabilizationWindowSeconds: 300 → 120~180` |
| 缩得更快（一次多减） | `scaleDown.policies[].value: 2 → 3` 或 `periodSeconds: 120 → 60` |
| 更早触发缩容 | 降 `target.averageUtilization`（70 → 60）**或**降 `requests.cpu` |
| 更难点到缩容 | 升 `target` 或升 `requests.cpu` |
| 不改 YAML 也能扩得更多 | 升 `maxReplicas`（**须先解决 §8.2 容量**） |
| 保底副本更多 | 升 `minReplicas` |

> **联动提醒**：本节点池是**按量付费**，缩容慢 = 多占节点时长实付。若负载是尖峰型（快涨快落），把稳定窗降到 120–180s 值得；稳态型则无需动。

---

## 附：完整 spec（集群实读，2026-10-06）

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-new-api-stable
  namespace: new-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: new-api-stable
  minReplicas: 4
  maxReplicas: 13
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70        # ⚠ last-applied 记的是 65，见 §8.1
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Max
      policies:
      - type: Pods
        value: 2
        periodSeconds: 120
    scaleUp:
      stabilizationWindowSeconds: 30
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
      - type: Pods
        value: 8
        periodSeconds: 60
```

---

## 附：相关文件

| 文件 | 用途 |
|---|---|
| `deploy/hpa_bodies/00-get-hpa.sh` | 直读 HPA 全量 spec + 用量 + 事件 |
| `deploy/hpa_bodies/01-node-capacity.sh` | 节点 allocatable / allocated 核算 |
| `deploy/ack_remote.sh <mnl\|sg> <body.sh>` | 执行通道（云助手 + 节点内 kubectl） |
