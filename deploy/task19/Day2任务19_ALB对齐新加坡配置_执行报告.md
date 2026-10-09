# Day 2 · 任务 19 收口｜马尼拉 ALB 对齐新加坡规范执行报告

- **日期**：2026-10-06（19:10–20:05 GMT+8）
- **触发**：用户指令「把菲律宾马尼拉的 alb 也类似配置」（对照 2026-10-06 完成的任务 25 新加坡 ALB）
- **集群**：`cd57e40ce9a634c1698c2f5c5e09bd93c`（ap-southeast-6 马尼拉）
- **结论**：**✅ 三项对齐全部完成并实测通过**；任务 19 的 **V1b（超时 60/600）由 ❌ 转 ✅**；顺带清除了自 2026-10-06 09:00 起存在的 **drift 与规则遮蔽**。

---

## 一、变更前 → 变更后

| 维度 | 变更前（实测） | 变更后（实测） |
|---|---|---|
| **0 监听器超时** | `IdleTimeout=15` / `RequestTimeout=60`（V1b ❌） | **`IdleTimeout=60` / `RequestTimeout=600`（V1b ✅）** |
| **无 Host 流量**（裸 IP） | `rule-80-2` → **FixedResponse 404**（`http://8.212.161.49` 返回 `Not Found`） | `rule-80-2` → **ForwardGroup → 主站**（200） |
| **catchall-404** | Prio 2，**生效**（遮蔽了 IP 直访） | Prio 3，被 noHost 遮蔽（保留为兜底） |
| **AlbConfig `httpDefaultActions`** | 三态漂移：last-applied=`Redirect→www.likha.hk`、live=`FixedResponse 404`、云端=`ForwardGroup` | **字段已删除**，声明与云端一致 |
| **占位组 `sgp-fm7kdwz99wtzbffkfx`** | 被手工塞 4 节点 `Ecs:32656`（drift，**域名未匹配即泄漏到主站**） | **成员 0**，回到"无后端"原义（与 SG default 一致） |
| **AlbConfig generation** | 2 | 3 |

### 三条规则终态（`lsn-ihrgkty2sjdy8s5p4h` :80）

| Prio | RuleId | 条件 | 动作 | 来源 |
|---|---|---|---|---|
| 1 | `rule-0f7ru4csbcn41ygmb4` | Host=`ph-verify.internal.likha.hk` **AND** Path `/*` | ForwardGroup → `sgp-tqgwt413t19mum8oa9` | `Ingress/new-api-verify`（order 1） |
| **2** | `rule-b1t5tod05rdsfdua8n` | Path `/*`（**无 Host**） | ForwardGroup → **`sgp-j4qrgy3f7bcv1r67na`** | **`Ingress/new-api-stable-ip`（order 50）← 本次新增** |
| 3 | `rule-rdd0uzut5mcuatuno8` | Path `/*`（**无 Host**） | FixedResponse 404 | `Ingress/new-api-catchall-404`（order 100） |
| — | default | — | ForwardGroup → `sgp-fm7kdwz99wtzbffkfx`（**现为空组**） | Controller 自管 |

> `order` 语义实测有效：1 < 50 < 100 ⇒ Prio 1 / 2 / 3 严格按序。

---

## 二、实测证据（2026-10-06 20:00）

| 探针 | 结果 |
|---|---|
| `GetListenerAttribute` | `ListenerStatus=Running` · **`IdleTimeout=60`** · **`RequestTimeout=600`** |
| IP 直访 `http://8.212.161.49/api/status` ×6 | **200 ×6** |
| IP 直访 `http://8.212.183.7/api/status` ×6 | **200 ×6** |
| 带 Host（回归）两 IP ×6 | **24/24 全 200**（含无 Host 组） |
| 域名路径 `curl --resolve ph-verify.internal.likha.hk:80:<IP>` | A → **200 / 2579B**，B → **200 / 2579B** |
| 路径覆盖（无 Host） | `/` 200·1047B · `/api/status` 200·2579B · `/healthz` 200·1047B · `/v1/models` **401** · **与新加坡逐项一致** |
| body 校验 | 真 new-api JSON（`{"data":{"HeaderNavModules":…`） |
| 新服务器组 `sgp-j4qrgy3f7bcv1r67na` | `new-api-new-api-stable-80` · **Instance 型 · HealthCheck=True** · Available |
| 占位组 `sgp-fm7kdwz99wtzbffkfx` 成员 | **0**（4 个 `Ecs:32656` 已摘，Job `c9d0c1c3-…`） |
| 超时改动期间断流 | **无**（改 AlbConfig 前后各测，全 200） |
| **★ Eni 组随滚动更新自动同步（意外取证）** | 变更窗口内 `new-api-stable` 恰好发生滚动更新（ReplicaSet `7f96d6ff48` → `86d6ff48d7`），两个 Eni 组的成员**自动换成新 Pod IP**（`10.0.43.214` / `10.0.43.217` / `10.0.22.219` / `10.0.43.206`），过程 **24/24 全 200 零中断** ⇒ REFERENCE 中「Pod 变→组变」由推断升为**实测** |

---

## 三、本次四条新知识（已入 REFERENCE.md）

1. **★ `aliyun alb ListRules` 的参数是 `--ListenerIds.N`（复数）**
   用 `--ListenerId`（单数）会回 `"--ListenerId" is not a valid parameter or flag`，且 **CLI 会建议 `--ListenerIds`** —— 与 `RuleConditions`/`RuleActions` 复数坑同源。**遇 CLI 说参数名非法，先信 CLI。**

2. **★ catchall-404 曾把 IP 直访彻底遮蔽（19:20 实测 `404 / 9B "Not Found"`）**
   `Ingress/new-api-catchall-404`（order 100，Path `/*` 无 Host）会把**所有**非 `ph-verify` Host 的流量（含裸 IP）变成 404 ⇒ 任务 19 报告 §七记的「`http://8.212.161.49` 可用」**当时已失效**。
   ⇒ 结论：**同一 listener 上"无 Host 的 Path `/*`"规则只能有一条语义** —— 要嘛兜底 404，要嘛转发业务，靠 `order` 决定。马尼拉现取"业务优先 + 404 沉底"。

3. **`httpDefaultActions` 的三态漂移（本次清除）**
   同一字段在 `last-applied` / `live spec` / 云端三处各不相同（Redirect / FixedResponse 404 / ForwardGroup），而**云端那一份才是真实生效值**。⇒ 该字段既无效又制造"声明≠现实"的审计噪音。**已从 `mnl-alb` 删除**（新加坡侧零风险探针已证：Controller 一律覆盖）。

4. **`--DryRun true` 是 ALB 写操作的低成本校验器**
   `RemoveServersFromServerGroup --DryRun true` 回 `DryRunOperation` = 参数与资源校验全过，**不产生任何变更**。建组/加删成员前先干跑，可避免"参数写错却看起来成功"。

---

## 四、⚠️ 风险与边界（须知晓）

| # | 项 | 说明 |
|---|---|---|
| **1** | **任意 Host 都能打到主站** | `rule-80-2` 无 Host 条件 ⇒ 除 `ph-verify.internal.likha.hk` 外的**任何 Host**（含他人把自有域名解析到 `8.212.161.49`）都命中主站（实测陌生域 → **200**）。这是"与新加坡完全同构"的必然代价（SG 侧同样存在，只是备站无流量）。**主站场景下建议后续收紧。** |
| 2 | 收紧路径 A（推荐） | 给 `new-api-stable-ip` 加源 IP 白名单：`alb.ingress.kubernetes.io/conditions.<svc>` + `SourceIp` 条件（需你提供出口 IP 段）。收紧后裸 IP 仅白名单可访问。 |
| 3 | 收紧路径 B | 直接删除 `Ingress/new-api-stable-ip` → 规则回到 Prio 3 的 404 兜底（IP 直访关闭，域名入口不受影响）。**一条命令即可回滚**。 |
| 4 | 服务器组重名 | `sgp-j4qrgy3f7bcv1r67na` 与 `sgp-tqgwt413t19mum8oa9` 同名 `new-api-new-api-stable-80`（两个 Ingress 指同一 Service，Controller 按 `<ns>-<svc>-<port>` 命名）。冗余，非错误，**与 SG 侧现象一致**。 |
| 5 | 仍无 TLS | 仅 HTTP 80；443 待 G5 证书。 |
| 6 | `newapi-np`（NodePort 32656） | **未动**。清 drift 后它已无 ALB 侧引用（default 组为空），按任务卡保留至证书到位再退役。 |

### 回滚命令

```bash
# 回滚 1：关闭 IP 直访（恢复 Prio3 的 404 兜底）
kubectl -n new-api delete ingress new-api-stable-ip

# 回滚 2：恢复 drift 组 4 成员（如需临时用 default 兜底）
aliyun alb AddServersToServerGroup --region ap-southeast-6 --ServerGroupId sgp-fm7kdwz99wtzbffkfx \
  --Servers.1.ServerType Ecs --Servers.1.ServerId i-5ts9wk588cliiweawind --Servers.1.Port 32656 \
  --Servers.2.ServerType Ecs --Servers.2.ServerId i-5tsaatp5w68w13n4z1w8 --Servers.2.Port 32656 \
  --Servers.3.ServerType Ecs --Servers.3.ServerId i-5tsawhljdqzwqhmadqv0 --Servers.3.Port 32656 \
  --Servers.4.ServerType Ecs --Servers.4.ServerId i-5tsfiz0wh6r2kymp6jwh --Servers.4.Port 32656
```

---

## 五、交付文件

| 文件 | 说明 |
|---|---|
| `deploy/manifests/albconfig-mnl.yaml` | 马尼拉 AlbConfig **权威副本**（收敛后形态 + 三态漂移注释） |
| `deploy/manifests/ingress-mnl-stable-ip.yaml` | **无 Host Ingress** 权威副本（IP 直访，order 50） |
| `deploy/manifests/hosts-mnl.sh` | 本机 `/etc/hosts` 一键加/删（`add\|del\|status`，标记段 `mnl-verify`） |
| `deploy/task19/bodies/00-recon.sh` | 勘察（AlbConfig/Ingress/Svc/规则/事件/webhook 判活） |
| `deploy/task19/bodies/01-albconfig-timeout.sh` | AlbConfig 收敛 |
| `deploy/task19/bodies/02-nohost-ingress.sh` | 无 Host Ingress |

**可直接使用的入口**

```
http://8.212.161.49        ← 无需 Host
http://8.212.183.7
http://ph-verify.internal.likha.hk   ← 需 hosts 脚本或 --resolve
```

---

## 六、与新加坡（任务 25）的对齐度

| 项 | 新加坡 | 马尼拉 | 对齐 |
|---|---|---|---|
| AlbConfig 最小形态 + 超时 60/600 | ✅ | ✅（本次） | ✅ |
| 有 Host Ingress → 业务 | ✅ | ✅（既有 `new-api-verify`） | ✅ |
| **无 Host Ingress → 业务** | ✅ `new-api-ph-standby-ip` | ✅ **`new-api-stable-ip`（本次）** | ✅ |
| catchall / default 兜底 | 占位组（503） | catchall 404（Prio 3，沉底） | ≈（兜底形态略异，均可接受） |
| 后端类型 | Eni（Pod IP，自动同步） | Eni（`sgp-tqgwt413t19mum8oa9` / `sgp-j4qrgy3f7bcv1r67na`） | ✅ |
| hosts 脚本 | `hosts-sg-standby.sh` | **`hosts-mnl.sh`（本次）** | ✅ |
| 443 + TLS | ⏳ G5 | ⏳ G5 | 同步阻塞 |

> **一处刻意差异**：新加坡额外保留 `sgp-fm7kdwz99wtzbffkfx` 式占位组为空；马尼拉**同样**已清空，故两站 default 语义一致（无后端 ⇒ 503）。马尼拉多一层 catchall 404 规则作 Prio 3，属更保守的实现，**保留**。
