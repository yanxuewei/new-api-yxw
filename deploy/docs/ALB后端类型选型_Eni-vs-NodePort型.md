# ALB 后端类型选型：ENI/Pod-IP 型 vs ECS/NodePort 型

> 2026-10-06 · 触发问题：「没证书就只能走 NodePort=32656？不能走 ENI/Pod IP 型？为什么？」
> 全部数据为 `ap-southeast-6` / ALB `alb-1riqckb1h8ezm0y7s9` 实测。

---

## 一、先纠正一个前提：**证书与后端类型零关系**

| 议题 | 由谁决定 |
|---|---|
| 能否用 HTTP 80 明文 | 监听器协议（建了 HTTP 监听即可） |
| 能否用 ENI/Pod-IP 型后端 | 服务器组类型 + CNI 模式 |
| 能否上 443/TLS | **证书**（G5 缺口） |

⇒「没证书」只意味着**不能开 443**，**不构成**「不能用 ENI 型」的任何理由。
ENI 型现在就能挂 80 明文，技术上完全可用。

**所以答案是：不是不能，是当时被两个别的因素挡住了。**

---

## 二、真正挡住 IP 直连走 ENI 型的两件事（实测）

### 2.1 Ingress 把 Host 写死了

```yaml
# Ingress new-api-verify（唯一 Ingress）
spec:
  rules:
  - host: ph-verify.internal.likha.hk        # ← 写死
    http:
      paths:
      - backend: {service: {name: new-api-stable, port: {number: 80}}}
        path: /
        pathType: Prefix
```

Controller 据此只生成**一条**规则：

| RuleId | 优先级 | 条件 | 目标组 |
|---|---|---|---|
| `rule-0f7ru4csbcn41ygmb4`（`rule-80-1`） | 1 | **Host = `ph-verify.internal.likha.hk`** AND Path = `/*` | `sgp-tqgwt413t19mum8oa9`（ENI 型） |

用 IP 直访时 HTTP `Host:` 头 = `8.212.161.49`（或空）→ **不匹配** → 落到 `DefaultActions`。
⇒ ENI 组**根本没机会被命中**，与证书无关。

### 2.2 AlbConfig 声明的 80 默认动作是 Redirect 到不存在的域名

```yaml
# AlbConfig mnl-alb
spec:
  listeners:
  - port: 80
    protocol: HTTP
    httpDefaultActions:                        # ← 声明
    - type: Redirect
      redirectConfig: {host: www.likha.hk, https: true, port: "443"}
```

而**实际** default action 已被改为 ForwardGroup → `sgp-fm7kdwz99wtzbffkfx`（ECS/NodePort 型）。
即使不动它，Redirect 也走不通：`likha.hk` 的 NS **NXDOMAIN**、`www.likha.com` CNAME 指向 Shopify ⇒ 跳过去是死路。

**结论**：即使把 ENI 组设成 default action，也会被 AlbConfig 的 Redirect 声明覆盖（reconcile 回退）。这是我当时避开 ENI 主路径的直接原因。

---

## 三、为什么当时选了 NodePort（工程理由，非能力限制）

1. **绕过 Host 匹配**：NodePort/Ecs 组没有被规则"占住"，可自由挂到 default action，IP 直访即刻生效。
2. **不被 Controller 抢**：Ecs 组的后端是**节点 IP**，与 Pod 生命周期解耦；Controller reconcile 时不会因为 Pod 重建而抖动。
3. **路径短、可诊断**：节点 IP 固定、SG 规则可见（当前 4 条命脉规则），出问题能逐段 curl。
4. **不依赖 Terway ENI 语义**：ENI 型要求 Pod 有独立网卡，Pod IP 可回收复用，健康检查必须开且必须准 —— 调试面更大。

代价：多一跳（ALB → 节点 → kube-proxy → Pod）、需要 3 条 SG 规则同时成立（见 REFERENCE §任务19补）。

---

## 四、两型技术差异（实测 + 官方口径）

| 维度 | **ENI / Pod-IP 型** ``sgp-tqgwt413t19mum8oa9`` | **ECS / NodePort 型** ``sgp-fm7kdwz99wtzbffkfx`` |
|---|---|---|
| `ServerGroupType` | `Instance`（服务器类型组） | `Instance` |
| 后端 `ServerType` | **`Eni`** ×4 | **`Ecs`** ×4 |
| 后端实体 | Pod 的独立网卡 ENI | 节点 ECS 实例 |
| 后端端口 | **3000**（容器端口直连） | **32656**（NodePort） |
| 网络跳数 | ALB → Pod ENI（**一跳**，VPC 内直连） | ALB → 节点 → netfilter/kube-proxy → Pod（**多一跳**） |
| 跨节点转发 | 不需要 | `externalTrafficPolicy=Cluster` 下需要（跨节点 SG 放行） |
| 依赖的 CNI | **必须 Terway ENI 模式**（Pod 独立网卡 + 独立 SG）；HostNetwork Pod 不可用 | 任意 CNI |
| 后端生命周期 | Controller watch EndpointSlice **自动增删** | 节点集合变化才需改；**Pod 生灭无感** |
| 健康检查 | **必须开**（Pod IP 会被回收复用，旧 IP 可能已指向别的 Pod） | 可关（当前 **`HealthCheckEnabled=false`**，靠 kube-proxy 自己剔除） |
| 优雅摘除 | `ConnectionDrain enabled=true, 120s` | `false`（未配） |
| 谁管理 | **Controller 独家**（手工改会被 reconcile 覆盖） | 手工可控（但同名组仍可能被 reconcile） |
| 客户端 IP | HTTP 监听下由 **`X-Forwarded-For`** 传递（`XForwardedForEnabled` 默认开、不可关） | **同样是 XFF** —— 七层监听下两型在应用层看到的一致 |
| 创建时间 / 来源 | `2026-10-06T00:20:16Z`，Tags `ingress_name=new-api-verify`、`ServiceName=new-api-new-api-stable-80` | `2026-09-30T10:23:40Z`，Tags `ingress_name=mnl-alb-listener-80`、`ServiceName=kube-system-fake-svc-80` |
| 故障域 | Pod 重建即变（组内成员随 EndpointSlice 漂移） | 节点级稳定 |
| 附加配额消耗 | 无 | 占 NodePort 端口 + 节点 SG 规则 |

### ★ 关于「保留客户端源 IP」的常见误解

ALB 是**七层**负载均衡。**HTTP/HTTPS 监听下，两型后端的客户端真实 IP 都来自 `X-Forwarded-For` 头**（`xForwardedForConfig.XForwardedForEnabled` 默认开启且**不可关闭**）。
**不存在**「ENI 型才有真实源 IP、NodePort 型会丢失」这种情况 —— 那是**四层 TCP/UDP 监听 + CLB/NLB** 语境下的区别（CLB 经典网络/HTTP 监听反而**拿不到**源 IP）。

⇒ 选型时**不要**把「保留源 IP」当作 ENI 型的优势。两者等价。

---

## 五、最佳应用场景

### ENI / Pod-IP 型 —— 生产主路径

- 需要 **Ingress Controller + 域名**的正常业务入口（Host 规则天然匹配）。
- Pod 频繁扩缩（HPA min4/max15）→ 后端自动跟随，无需人工。
- 想省掉一跳、降低 P99 延迟。
- 要求按 Pod 粒度做灰度/权重/摘流（`ConnectionDrain 120s` 已就位）。
- **前提**：集群用 Terway ENI 模式（本集群满足）。

### ECS / NodePort 型 —— 兜底 / 应急 / 解耦

- **Controller 不可用或未装**时的应急入口（例如任务 19 期间 Controller 曾疑似缺位）。
- 需要**与集群声明解耦**的稳定入口（不随 Pod 重建抖动）。
- 后端**混合**：既有 k8s Pod 又有非 k8s 机器，NodePort 是统一接口。
- 网络诊断：节点 IP 固定，便于逐段定位。
- 跨集群共享同一个 ALB 时。

### 混合（当前架构）—— 规则分流

```
80 端口
├── 规则 rule-80-1（Host=ph-verify.internal.likha.hk）→ ENI 组     ← 业务路径（域名可达时）
└── DefaultActions                                     → ECS 组     ← 应急 IP 直连
```

ALB 规则**优先于** default action ⇒ **规则路径永远先命中**。这正是当前"域名走 ENI、IP 兜底走 NodePort"能并存的原因。

---

## 六、若要让 IP 直连走 ENI 型，正确做法

### 方案 A（推荐）：加一个不带 host 的 Ingress

k8s Ingress **不写 `spec.rules[].host`** 即表示匹配任意 Host。Controller 会生成**无 Host 条件**的 Path-only 规则，优先级排在 Host 规则之后、default action 之前。
⇒ IP 直访即命中 → 走 ENI 型新派生组。

**优点**：不动 AlbConfig，**不受 default action 被 reconcile 回 Redirect 的影响**（规则先于 default 匹配）。
**注意**：Path-only 规则会**吃掉所有未被 Host 规则命中的流量**，需确认这是预期。

### 方案 B（不推荐）：把 ENI 组设为 default action

与 AlbConfig 的 `httpDefaultActions: Redirect` 直接冲突，Controller reconcile 会改回。要稳定必须**先删除/修改 AlbConfig 的 `listeners` 段**。

### ⚠ 无论哪个方案，必须先解决这个隐患

`AlbConfig mnl-alb` 声明 80 = Redirect `www.likha.hk:443`，而域名不存在。
**当前 IP 直连通道之所以活着，是因为手工把 default action 改成了 ForwardGroup 并与声明相悖。**
⇒ 任何一次 Controller reconcile（重启、Ingress 变更、组件重装）都可能把 80 default 拉回 Redirect → **直连通道立即失效**。

**修复建议**：删掉 AlbConfig 的 `listeners` 段（让 Controller 只管 Ingress 派生的部分），或将其改为与现状一致的 ForwardGroup。

---

## 六之二、AlbConfig 修复方案对比（2026-10-06 12:56 补充调研）

### ★ 调研中新发现两个推翻前提的硬证据

**证据 1：字段名疑似写错 —— 官方是 `defaultActions`，集群里写的是 `httpDefaultActions`**

阿里云官方《ALB Ingress 配置词典》的「全量 AlbConfig YAML」中，ListenerSpec 的字段清单为：

```yaml
listeners:
  - port: 80
    protocol: HTTP
    gzipEnabled: null
    http2Enabled: null
    securityPolicyId: ""
    idleTimeout: 15
    requestTimeout: 60
    caEnabled: false
    quicConfig: {quicUpgradeEnabled: false, quicListenerId: ""}
    defaultActions: []            # ★ 官方字段名
    caCertificates: []
    certificates: []
    xForwardedForConfig: {...}
    logConfig: {...}
    aclConfig: {...}
```

而本集群 `AlbConfig mnl-alb` 里写的是：

```yaml
listeners:
  - httpDefaultActions:           # ★ 疑似错误字段名（ALB OpenAPI 风格）
    - redirectConfig: {host: www.likha.hk, https: true, port: "443"}
      type: Redirect
    port: 80
    protocol: HTTP
```

**证据 2：`AlbConfig` CRD 无 schema 校验**

```
kubectl get crd albconfigs.alibabacloud.com -o json
→ versions[0].schema.openAPIV3Schema = {"x-kubernetes-preserve-unknown-fields": true}
```

⇒ **任何字段名都会被接受，写错不会报错**，Controller 解析不到就直接忽略。

**推论**：`httpDefaultActions: Redirect` **极可能从未生效**。
⇒「声明的 Redirect 会被 reconcile 应用、冲掉当前 ForwardGroup」这个隐患，**前提本身可疑**；但它同时意味着**这个字段名是一颗定时炸弹** —— 谁"好心修正"成 `defaultActions`，Redirect 就会立刻生效并**打掉直连通道**。
⇒ **必须做一次触发式验证来定论**（见下）。

**证据 3：Controller v3.1.1 不自动创建监听器**

来源：`alibabacloud-aiops-skills` 的 ALB Ingress 参考 ——
> "ALB Ingress Controller ... **v2.11.0+ does not auto-create listeners, must explicitly define them in AlbConfig**"
> "listeners uses replace-style update, patch must pass the complete listeners array"

阿里云官方文档另明确：
> "删除监听之前必须移除监听下的全部 Ingress，否则无法成功移除监听，并会产生相关报错。"

本集群组件版本 **v3.1.1 ≥ v2.11.0** ⇒ 这条适用。

### 两方案对比

| | **方案 A：删 `listeners` 段** | **方案 B：改成 ForwardGroup** |
|---|---|---|
| 依据 | 「让 Controller 只管 Ingress 派生的部分」 | 「让声明与现状一致」 |
| 80 监听器归属 | v3.1.1 **不自动创建监听器** ⇒ 删声明 = 放弃该监听器，Controller 会**尝试删除**它 | 保留声明 ⇒ 监听器稳定受管 |
| Ingress 还在会怎样 | 官方明说：**必须先移除监听下全部 Ingress 才能删监听**，否则**报错** ⇒ 陷入 reconcile 报错循环 | 无影响 |
| 对 IP 直连通道 | **彻底断**（监听器没了，Ingress 路由也断）；即使监听器侥幸存活，default 也被重置 | 可保（若引用正确） |
| 对任务 19 待配项 | **`idleTimeout` / `requestTimeout` 无处可配**（这俩**只在 ListenerSpec 内**，见官方字段表）⇒ V1b 600s 目标永久卡死 | 保留配置能力 ✅ |
| 未来域名启用 | 还得把 `listeners` 加回来 | 80→443 跳转还得再改一次 |
| 可验证性 | 无（改完才发现） | **低**（`defaultActions` 里 ForwardGroup 的 server group 引用方式，官方全量 YAML 里是空数组 `[]`，**未给示例**） |
| 额外风险 | — | 引用 `sgp-fm7kdwz99wtzbffkfx` 有**悬空风险** —— 该组是 Controller 为 `mnl-alb-listener-80` 派生的（Tag `ingress_name=mnl-alb-listener-80`、`ServiceName=kube-system-fake-svc-80`、CreateTime `2026-09-30T10:23:40Z`），若 Controller 因 default 变更重建该组，硬编码 ID 即失效 |
| **判定** | **❌ 危险，不可取** | **⚠️ 可行但机制不透明，需实测** |

### 更优方案（第三选项）

**方案 C：不碰 AlbConfig，新增一个不带 `spec.rules[].host` 的 Ingress**

- ALB **规则优先于 default action** ⇒ 即使 default 某天被 reconcile 变成 Redirect，IP 直连仍走规则，**天然与 reconcile 兼容**。
- 不动 `listeners` ⇒ 保留 `idleTimeout` / `requestTimeout` 配置能力。
- 生成的是 **Path-only 规则**，由 ALB Ingress Controller 派生 **ENI 型**服务器组 ⇒ 顺带拿到 HPA 自动同步、健康检查、`ConnectionDrain 120s`。
- 副作用：Path-only 规则会**吃掉所有未被 Host 规则命中的流量**（当前只有 1 条 Host 规则，无冲突）。
- 代价：`sgp-fm7kdwz99wtzbffkfx`（Ecs 型）与 `newapi-np`（NodePort）随之成为冗余，可在验证后退役。

**推荐序：C ≫ B > A**

### 定论所需的验证步骤（低风险，需用户批准）

当前所有推断都卡在同一处：**`httpDefaultActions` 到底有没有被 Controller 读进去？**

**触发式验证**：改一个无害字段把 reconcile 引出来，然后读 80 监听器的 `DefaultActions`。

```bash
# 1. 记下当前 default action
python3 lib/aliyun_rpc.py alb GetListenerAttribute --region ap-southeast-6 \
  --version 2020-06-16 ListenerId=lsn-ihrgkty2sjdy8s5p4h

# 2. 触发 reconcile（无害变更）
kubectl annotate albconfig mnl-alb probe=20261006 --overwrite
#   或改 Ingress 上一个无关注解

# 3. 等 1–2 分钟后重读
python3 lib/aliyun_rpc.py alb GetListenerAttribute ...   # 同样命令
```

| 结果 | 含义 | 后续 |
|---|---|---|
| default **变成 Redirect** | 声明**有效**，隐患为真 | **必须**先修（走方案 C，最稳） |
| default **保持 ForwardGroup** | 声明**无效**（字段名错） | 隐患是假的，但字段名是定时炸弹；仍建议走 C，并顺手修字段名 |

> ⚠️ 若结果是"变成 Redirect"，IP 直连会**当场失联**。回滚只需一条 `UpdateListenerAttribute` 把 default 改回 ForwardGroup（命令模式见 `task_alb_url/bodies/`）。**建议在低峰执行，并预先备好回滚命令。**

---

## 七、一句话结论

> **不是「没证书只能走 NodePort」。**
> 证书只管 443。ENI 型与 NodePort 型在 80 明文下**都能用**。
> 当时走 NodePort 是因为 ① Ingress 把 Host 写死，IP 直访匹配不上 ENI 组；② AlbConfig 声明 80 跳转到不存在的域名，挡住了把 ENI 组设为默认后端的做法。
> 只是**工程上绕了个更稳的路**，不是 ALB 的能力限制。

---

## 附：本文涉及的实测命令

```bash
# 服务器组类型与属性
python3 lib/aliyun_rpc.py alb ListServerGroups --region ap-southeast-6 --version 2020-06-16 \
  ServerGroupIds.1=sgp-tqgwt413t19mum8oa9

# 后端成员（看 ServerType = Eni / Ecs）
python3 lib/aliyun_rpc.py alb ListServerGroupServers --region ap-southeast-6 --version 2020-06-16 \
  ServerGroupId=sgp-tqgwt413t19mum8oa9

# 监听器规则（看 Host 条件）
python3 lib/aliyun_rpc.py alb ListRules --region ap-southeast-6 --version 2020-06-16 \
  ListenerIds.1=lsn-ihrgkty2sjdy8s5p4h

# AlbConfig / Ingress 声明
bash ack_remote.sh mnl task_alb_url/bodies/27-albconfig-inspect.sh
```
