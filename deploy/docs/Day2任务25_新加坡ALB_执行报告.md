# Day 2 · 任务 25｜新加坡 ALB + Service/Ingress（PH 备）执行报告

- 执行日期：**2026-10-06**
- 任务卡：`deploy/wf2/part2b.md:297`（人员A，1.5 人时，D2 B 窗）
- 集群：`ca75829e3492d491d9d434de087913798`（ap-southeast-1，2 节点 k8s v1.35.7-aliyun.1）
- 结论：**✅ 核心链路打通（HTTP 80，域名 + 公网 IP 双入口）；⏳ TLS 443 因证书缺失降级待补**

---

## 一、交付物

| 资源 | ID / 值 | 状态 |
|---|---|---|
| **AlbConfig** | `sg-alb`（cluster-scoped） | ✅ |
| **ALB 实例** | `alb-amdwm60xmznh7s1nae` / `alb-newapi-sg` | ✅ Active |
| ALB DNS | `alb-amdwm60xmznh7s1nae.ap-southeast-1.alb.aliyuncsslbintl.com` | ✅ |
| ALB 公网 IP（固定） | **`43.98.186.238`**（1a，`eip-t4np56ofc8jz8b4r67enz`）<br>**`47.237.68.142`**（1b，`eip-t4nepu7cfv1grgpw1hx6f`） | ✅ 双 AZ |
| **监听器** | `lsn-qmi1hpyr3j83tq3z8j` :80 HTTP（`ingress-auto-listener-80`） | ✅ Running |
| **IngressClass** | `alb` → AlbConfig `sg-alb` | ✅ |
| **Ingress** | `new-api` / `new-api-ph-standby`，host `sg-standby.internal.likha.hk` | ✅ |
| **Ingress（追加）** | `new-api` / `new-api-ph-standby-ip`，**无 host**（IP 直访入口，见 §八） | ✅ |
| **服务器组** | `sgp-rlxs1mqishcxcfkx7u`（`new-api-new-api-ph-standby-80`，**Eni 型**） | ✅ |
| 服务器组（追加） | `sgp-8m8eknlyw0z1busl6r`（同上名，无 Host Ingress 派生，成员相同） | ✅ |
| **监听规则** | `rule-80-1` Prio1（Host+Path）/ `rule-80-2` Prio2（仅 Path） | ✅ Available |
| 访问日志 | `sls-newapi-sg/alb_access`（**本次新建**） | ✅ |
| 删除保护 | `Enabled: true` | ✅ |

**新增仓库文件**

| 文件 | 用途 |
|---|---|
| `deploy/manifests/ingressclass-sg.yaml` | SG IngressClass 权威副本 |
| `deploy/manifests/albconfig-sg.yaml` | SG AlbConfig 权威副本（含全部坑注释） |
| `deploy/manifests/ingress-sg-standby.yaml` | 备站 Ingress 权威副本 |
| `deploy/manifests/ingress-sg-standby-noHost.yaml` | **IP 直访**用无 Host Ingress 权威副本（§八） |
| `deploy/manifests/hosts-sg-standby.sh` | 本机 `/etc/hosts` 一键加/删（`add\|del\|status`，§八） |
| `deploy/task25_bodies/00–10-*.sh` | 勘察 / 建类 / 建 AlbConfig / 超时探针 / defaultAction 探针 / 终态 / 备站核查 / 建 Ingress / 无 Host 建 / 组成员对比 |

---

## 二、最终链路

```
Internet
  │  Host: sg-standby.internal.likha.hk  → rule-80-1（域名入口）
  │  任意 Host（含直接输 IP）           → rule-80-2（IP 直访入口，§八新增）
  ▼
ALB alb-amdwm60xmznh7s1nae  (Internet / Standard / PostPay / 双 AZ 1a+1b)
  43.98.186.238 · 47.237.68.142
  │  lsn-qmi1hpyr3j83tq3z8j :80  HTTP
  │    idleTimeout=60 · requestTimeout=600   ← ✅ 实测生效
  │  rule-80-1 (Prio 1, Host=sg-standby.internal.likha.hk, Path=/*) → sgp-rlxs1mqishcxcfkx7u
  │  rule-80-2 (Prio 2, 无 Host, Path=/*)                          → sgp-8m8eknlyw0z1busl6r
  ▼
服务器组（两组成员相同）   (Eni 型 · 一跳直连 · Wrr · HTTP)
  ├─ eni-…uakh0  10.1.19.124:3000  Available   (节点 10.1.19.103 / ap-southeast-1a)
  └─ eni-…070pe  10.1.38.120:3000  Available   (节点 10.1.38.113 / ap-southeast-1b)
  健康检查 GET /api/status 6s/3s 2xx, healthy2/unhealthy3 · ConnectionDrain 120s
  ▼
Service new-api-ph-standby (ClusterIP 172.22.2.80:80)
  ▼
Deployment new-api-ph-standby 2/2 Running（任务 28 产出，本次未动）
```

**与马尼拉的关键差异（本次更规范）**：走的是 **Eni（Pod IP）型**，而非马尼拉临时通道的 `Ecs:NodePort`。因此天然具备：Pod 重建自动同步、健康检查生效、ConnectionDrain 120s。**不需要 NodePort 通道**。

---

## 三、实测证据

| 项 | 命令 | 结果 |
|---|---|---|
| AlbConfig 状态 | `kubectl get albconfig sg-alb` | `ALBID=alb-amdwm60xmznh7s1nae`；事件 `SuccessfullyReconciled` |
| 监听器属性 | `aliyun alb GetListenerAttribute` | `ListenerPort=80` · **`IdleTimeout=60`** · **`RequestTimeout=600`** · `ListenerStatus=Running` |
| 核心验收 | `curl -H "Host: sg-standby.internal.likha.hk" http://43.98.186.238/api/status` | **200**，body 为真实 new-api 响应（`data.HeaderNavModules` …） |
| 无 Host（落 default） | 同上去掉 Host | **503**（占位组 `kube-system-fake-svc-80` 无后端，符合预期） |
| 路径覆盖 | `/` `/api/status` `/healthz` | `200 / 1047B` · `200 / 2579B` · `200 / 1047B`（`/` 的 1047B 与马尼拉一致） |
| 双 AZ 稳定性 | 两 IP × 6 次 | **12/12 = 200**，无失败 |
| 后端成员 | `aliyun alb ListServerGroupServers` | 2× **`ServerType=Eni`**，Port **3000**，Weight 100，**Available**，跨 1a/1b |
| 健康检查 | `ListServerGroups` | `HealthCheckEnabled=true` · `GET /api/status` · `6s/3s` · `http_2xx` · healthy2/unhealthy3 |
| 摘流保护 | 同上 | `ConnectionDrainEnabled=true, Timeout=120` |

---

## 四、★★ 本次四条新知识（已入 REFERENCE.md）

### 1. `logStore` 名必须以 `alb_` 开头 —— webhook 硬校验

首次 apply 被拒：

```
admission webhook "albconfig.alb.validate.k8s.io" denied the request:
webhook validate albconfig sg-alb: logstore name should start with alb_
```

⇒ ALB 访问日志的 logstore **必须下划线前缀 `alb_`**。`sls-newapi-sg` 原本只有一个连字符的 `alb-access`（**不合规**），已在本次补建 `alb_access`（ttl=30 / shardCount=2 / standard，与马尼拉 `sls-newapi-mnl/alb_access` 同参数）。
⇒ 这同时解释了马尼拉项目里为何 `alb-access` 与 `alb_access` 并存。

### 2. `idleTimeout` / `requestTimeout` **有效**；马尼拉 V1b 失败的根因是「根本没写」

SG 侧写入 `idleTimeout: 60 / requestTimeout: 600` 后云端回读一致（60/600）。
而马尼拉 `AlbConfig mnl-alb` 的 `listeners` 段只有 `port / protocol / httpDefaultActions` —— **从未写过超时参数**，因此拿到的是 Controller 默认值 `15/60`。
⇒ **任务 19 的 V1b（60/600）不是"ALB 不支持"，只是漏配**；补齐一条 apply 即可（马尼拉侧按用户 13:15 裁定暂不动）。

### 3. ★★ `defaultActions` / `httpDefaultActions` **均不生效** —— Controller 一律覆盖

零风险探针（SG 侧无流量）：

```
写入  defaultActions: [{ type: FixedResponse, fixedResponseConfig: { httpCode: "404" } }]
k8s 侧 spec 保留该字段  ✅
云端 GetListenerAttribute 回读 DefaultActions =
  ForwardGroup → sgp-p1qg1z0rqgbovj3yqd   ← 仍是 Controller 派生的占位组
```

不写任何 default action 时（首批 apply）回读**同样是** `ForwardGroup → 占位组`。
⇒ **Controller 用自己的 `ForwardGroup → {ns}-fake-svc-{port}` 覆盖 AlbConfig 的 default action**，与字段名对错无关。

**推论（推翻先前结论）**：马尼拉那颗「谁把 `httpDefaultActions` 改成官方名 `defaultActions` 就会激活 Redirect、当场打断直连 IP 通道」的**定时炸弹不存在** —— 正确字段名同样不生效。
⇒ 马尼拉 80 = ForwardGroup 是**稳定态**。风险仅剩「有人直接在 ALB 控制台手改」。

### 4. Controller 自动创建监听器（命名 `ingress-auto-listener-{port}`）

`AlbConfig` 仅声明 `listeners: [{port: 80, protocol: HTTP}]` → 云端自动出现监听器 `ingress-auto-listener-80`。
另：AlbConfig **零 Ingress** 时会创建占位服务器组 `kube-system-fake-svc-80` 并置于 default action，事件 `AlbconfigZeroIngress`（属预期，非故障）。
⇒ 先前记的「v2.11.0+ 不自动创建监听器」**证据不足、结论存疑**，本条以实测为准。

---

## 五、与任务卡的偏差（必须记录）

| 项 | 任务卡 | 实际 | 原因 |
|---|---|---|---|
| 监听端口 | `listen-ports: '[{"HTTPS":443}]'` | **`[{"HTTP":80}]`** | CAS 证书缺失（`ListUserCertificateOrder --region ap-southeast-1` ⇒ **TotalCount=0**，G5 未闭环）⇒ 443 无从创建 |
| 验收命令 | `curl --resolve …:443:${VIP} https://…` | `curl -H "Host: …" http://<IP>/api/status` | 同上 |
| 超时验收 | `IdleTimeout=60 / RequestTimeout=600` | **✅ 已达成**（80 监听器上实测生效） | 无偏差 |

**证书到位后待做（单步）**：① AlbConfig 加 443 listeners + `certificates[].CertIdentifier`；② Ingress 注解改回 `'[{"HTTPS":443}]'`；③ 复测 443。

---

## 六、未完成 / 后续

| 项 | 状态 | 前置 |
|---|---|---|
| 443 + TLS 监听器 | ⏳ | G5 证书（CAS 账号内证书数为 0） |
| 主站 token 打备站业务接口（SESSION_SECRET 一致性复验，任务卡 §7.4 V4） | ⏳ **未执行** | 需 RMNL token（`MNL_TOKEN_PLACEHOLDER`），本次未取 |
| SG ALB 接 WAF（任务卡坑 2） | ⏳ | D6；规则从主站导出模板保持一致 |
| GTM 备池 `pool-sg` 入池 | ⛔ **硬门禁** | M4 接管演练通过前**不得入池**（任务卡 + `gtm-address-pool.md` 坑 3） |

**成本**：ALB 按量 `PostPay / PayByTraffic`，Internet 型自动分配 2 个 EIP（按流量计费）。**备站常态零流量** ⇒ 仅实例小时费。

---

## 七、附带发现（非本任务范围）

1. **任务 28 已由并行会话完成**：`Deployment/new-api-ph-standby` 2/2 Running（双节点跨 AZ），`Service` 2 个 ready endpoint，镜像 `acr-newapi-mnl-registry.ap-southeast-6.…:20260928-26ac63233`（**跨区拉取成功**，建 Pod 33 分钟前）。本次执行开始时的勘察（13:47）该资源尚不存在，属并发写入 —— `ack_remote.sh` 已有的 RUN_ID 隔离机制未见异常。
2. 集群内存在任务 28 的临时依赖 Pod `t28-pg`（`postgres:17`，反复重启，29m 前最后一次 Started）——**非任务 25 产物，未处理**，建议任务 28 收口时清理。
3. `ns new-api` 有 `ResourceQuota new-api-quota`，**强制要求**临时 Pod 声明 `limits.cpu/memory` + `requests.*`（本次 `kubectl run` 调试被拦，改用节点直连 curl）。

---

## 八、追加：ALB 公网 IP 直访（无 Host Ingress）—— ✅ 已通（15:15–15:35）

### 背景

§三 实测为「带 Host → 200，**无 Host → 503**」：`Ingress new-api-ph-standby` 把 host 写死 `sg-standby.internal.likha.hk`，浏览器直接输 IP 时 `Host:` = IP，**不匹配任何规则** ⇒ 落 `DefaultActions` ⇒ 503。
（马尼拉侧无 Host 能 200，是因**手工往 Controller 占位组塞了 4 个节点后端**，属 drift；SG 侧改用**声明式**做法。）

### 做法：新增规则级入口，而非改 default

按 §4.3 结论 —— **AlbConfig 的 `defaultActions` / `httpDefaultActions` 写入均被 Controller 覆盖** ⇒ 想让 IP 直访可用，**只能靠 Ingress 规则**。

新增 `Ingress/new-api-ph-standby-ip`（**`spec.rules[0]` 不写 host**）：

```
ALB :80  监听器 lsn-qmi1hpyr3j83tq3z8j
 ├─ rule-80-1  Prio 1  Host=sg-standby.internal.likha.hk AND Path=/*  → sgp-rlxs1mqishcxcfkx7u
 ├─ rule-80-2  Prio 2  Path=/*（无 Host 条件）                        → sgp-8m8eknlyw0z1busl6r   ← 本次新增
 └─ defaultActions                                                     → sgp-p1qg1z0rqgbovj3yqd（占位组，已不可达）
```

**有 Host 的规则优先于无 Host 规则**（Priority 数字小者优先）⇒ 两条天然共存，域名访问不受影响。

### 实测证据

| 项 | 结果 |
|---|---|
| 无 Host `43.98.186.238` ×6 | **200 200 200 200 200 200** |
| 无 Host `47.237.68.142` ×6 | **200 200 200 200 200 200** |
| 带 Host（回归）两 IP ×6 | **12/12 200** |
| body（无 Host） | 真 new-api：`{"data":{"HeaderNavModules":…` |
| `/` | 200 size=1047（与马尼拉一致） |
| `/api/status` | 200 size=2579 |
| `/v1/models` | **401** size=124（鉴权正常） |
| 新派生组 `sgp-8m8eknlyw0z1busl6r` | Eni 型，2 成员 `10.1.19.124` / `10.1.38.120`:3000 |
| 规则回读 | `rule-80-1` Prio1 Host+Path；`rule-80-2` Prio2 仅 Path |

### 可用入口

```
http://43.98.186.238          ← 直接访问，无需 Host / hosts
http://47.237.68.142
```

（`/v1/models` 401 属正常 —— 需 API key。）

### 副作用与边界

| 项 | 说明 |
|---|---|
| **流量吞噬** | `rule-80-2` 会吃掉**所有未被 Host 规则命中的流量**。当前该 ALB 仅一个域名 ⇒ 无冲突；**将来加第二个域名须重新评估** |
| **服务器组冗余** | 两个 Ingress 指向同一 Service ⇒ Controller 派生**两个内容相同的组**（各挂同样 2 个 Pod）。冗余，非错误 |
| **仍无 TLS** | 仅 HTTP 80；443 待 G5 证书 |
| **退役** | 证书 + 公网 DNS/GTM 就绪后可删本件（届时走域名） |

### 附带交付

- `deploy/manifests/ingress-sg-standby-noHost.yaml` —— 权威副本（含原理、副作用、退役条件注释）
- `deploy/manifests/hosts-sg-standby.sh` —— 本机 `/etc/hosts` 一键加/删（`add` / `del` / `status`）
  - 标记段 `# >>> sg-standby (task25) >>>` … `<<<`，`del` 只删自己那段，**不动系统其他行**
  - 幂等（重复 add/del 为 no-op）；macOS 自动 flush DNS 缓存；`HOSTS_FILE` 可覆盖便于自测
  - **本地已用临时文件跑通全流程**（add→幂等→status→del→幂等，系统行未被触碰）
  - 有了本节的 noHost Ingress 后，hosts 脚本主要用途变为：**按 AZ 分别验证**（`sg-standby` / `sg-standby-b`）与**证书到位后的域名访问**

### 容器/工具坑

- `aliyun alb GetRuleAttribute` **不是有效 API**（CLI 回 `"is not a valid api"`）
- `ListRules` 传 `RuleIds.N` 过滤 ⇒ `TotalCount: 0`（参数不生效）⇒ 只能全量取后本地筛
- `ListRules` 条件/动作字段是 **`RuleConditions` / `RuleActions`（复数）**；用单数恒空 `{}` 且**静默无报错**
