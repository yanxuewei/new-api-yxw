# SG 站 `sg.likha.hk` 502 Bad Gateway 修复记录

- **日期**：2026-10-12（11:44 报障 → 11:52 修复完成）
- **站点**：新加坡备站（ap-southeast-1）· ALB `alb-amdwm60xmznh7s1nae` · Ingress `new-api-ph-standby`
- **严重级别**：P1（对用户可见的 HTTPS 不可用）
- **处置结论**：✅ 已修复并验收通过（`https://sg.likha.hk` → 200）

---

## 1. 现象

浏览器访问 `https://sg.likha.hk` → **502 Bad Gateway**，错误页页脚为 `alb`（ALB 生成，非应用）。

- 同一域名 `http://sg.likha.hk`（80）**正常**。
- `www.likha.hk`（马尼拉主站，走 mnl ALB）**正常**。

## 2. 根因

**443 监听上不存在 `sg.likha.hk` 的 Host 规则**，请求不匹配任何规则 ⇒ 落**监听器默认动作** ⇒ 派生占位服务器组：

| 监听 | 规则（修复前） | 目标组 | 结果 |
|---|---|---|---|
| **443** | `rule-443-1` Host=`sg-standby.internal.likha.hk`（唯一） | `sgp-rlxs1mqishcxcfkx7u`（健康） | 仅内部域名可用 |
| 443 | **默认动作**（无匹配时） | **`sgp-l3cxrmoj1oq451l0fn` = `kube-system-fake-svc-443`**（后端为**节点 IP:3000**、健康检查 `off`） | **502** |
| 80 | `rule-80-1` Host=内部域名 | `sgp-rlxs1mqishcxcfkx7u` | ✅ |
| 80 | `rule-80-2`（无 Host，来自 `new-api-ph-standby-ip`） | `sgp-8m8eknlyw0z1busl6r` | ✅ 兜底 |

**为什么问题被掩盖**：80 端口有一个**无 Host 兜底 Ingress**（`new-api-ph-standby-ip`，`purpose: ip-direct-access`），
任何 Host 都能命中 → HTTP 一直正常；而该 Ingress **只监听 80**（`listen-ports: [{"HTTP":80}]`），
443 上没有任何兜底 ⇒ HTTPS 直接暴露 502。10-12 上线 443 时只给 `new-api-ph-standby` 开了 443，
这个缺口就此形成。

**证据（修复前实时 API）**：
- `aliyun alb ListRules --ListenerIds.1 lsn-iqn5i233mvv7eu4u6w` → `TotalCount=1`，Host 仅 `sg-standby.internal.likha.hk`
- `aliyun alb ListListeners` → 443 默认动作 `ForwardGroup ['sgp-l3cxrmoj1oq451l0fn']`
- `GetListenerHealthStatus --IncludeRule true` → `rule-443-1` 的 `NonNormalServers=[]`（后端 **健康**，排除后端故障）
- 集群内直测 `curl http://new-api-ph-standby/api/status` → **200**（应用层无问题）

## 3. 修复

**方式**：声明式（改 Ingress，不直调 ALB OpenAPI —— 托管 ALB 禁止直调）。

给 `Ingress/new-api-ph-standby` 追加一条 host（保留原内部 host），用 JSON patch 只动 `spec.rules`，**不触碰注解**：

```bash
kubectl -n new-api patch ingress new-api-ph-standby --type=json -p='[{"op":"add","path":"/spec/rules/-","value":
 {"host":"sg.likha.hk","http":{"paths":[{"path":"/","pathType":"Prefix","backend":
 {"service":{"name":"new-api-ph-standby","port":{"number":80}}}}]}}}]'
```

**同步的真源文件**（此前与集群漂移，本次对齐）：
- `deploy/manifests/ingress-sg-standby.yaml`（listen-ports 补 HTTPS:443 + 新增 `sg.likha.hk` host + 头部注释重写）
- `deploy/tasks/task25/bodies/08-apply-ingress.sh`（同上，执行器）

## 4. 验收（修复后）

| 项 | 结果 |
|---|---|
| `https://sg.likha.hk/api/status` | **200**（`47.237.68.142` / `43.98.186.238` 逐 IP + 走 DNS，均 200） |
| `http://sg.likha.hk/api/status` | **200** |
| `curl -L https://sg.likha.hk/` | **200** |
| TLS / SNI | `subject=CN=*.likha.hk` · `issuer=Aliyun RSA TLS DV G1` · `TLSv1.3 / TLS_AES_128_GCM_SHA256` · **Verify return code: 0 (ok)** |
| 弱版本反例 | `-tls1_1` → 服务端回 **`tlsv1 alert protocol version`(70)** ✔ |
| 内部域名回归 | `sg-standby.internal.likha.hk` :443 → 200（`-k`）、:80 → 200 ✔ |
| 主站回归 | `www.likha.hk` → 200 ✔ · mnl 裸 IP `http://8.212.161.49/api/status` → 200 ✔ |

**ALB 规则（修复后）**：

| 监听 | 规则 | Host | 目标服务器组 |
|---|---|---|---|
| 443 | `rule-443-1` (prio 1) | `sg-standby.internal.likha.hk` | `sgp-rlxs1mqishcxcfkx7u` |
| 443 | **`rule-443-2` (prio 2)** | **`sg.likha.hk`** | `sgp-rlxs1mqishcxcfkx7u` |
| 80 | `rule-80-1` (prio 1) | `sg-standby.internal.likha.hk` | `sgp-rlxs1mqishcxcfkx7u` |
| 80 | **`rule-80-2` (prio 2)** | **`sg.likha.hk`** | `sgp-rlxs1mqishcxcfkx7u` |
| 80 | `rule-80-3` (prio 3) | （无 Host，兜底） | `sgp-8m8eknlyw0z1busl6r` |

## 5. 经验教训

1. **★ ACK 托管 ALB 的「默认动作」= Controller 派生的占位组**（`kube-system-fake-svc-<port>`，后端写的是**节点 IP:3000**、健康检查 `off`）⇒ **任何未匹配的 Host/Path 一律 502**。它不是「转发到业务后端」，别当成兜底。
2. **HTTPS 比 HTTP 更容易暴露路由缺口**：HTTP 侧常被历史遗留的「无 Host 兜底 Ingress」掩盖，HTTPS 侧若只开了具名 Host，缺口就现形。**验收必须 HTTP/HTTPS 各测一遍**。
3. **`RuleName`（`rule-80-2` 等）会随规则增删重新编号**（本次 nohost 兜底从 `rule-80-2` 变成 `rule-80-3`）⇒ **判路由只信实时 API 的 `Host`/`Priority`/`ServerGroupId`，勿引用历史 RuleName**。
4. **只 annotate 集群、不回写仓库真源**会造成漂移（本次 `ingress-sg-standby.yaml` 仍写着 `[{"HTTP":80}]`）⇒ 改配置必须同步真源文件。
5. **别用 `curl -I`（HEAD）验可用性**：`/api/status` 只注册 GET，HEAD 会得到**应用层 404**，与 ALB 层 404/502 混淆。

## 6. 遗留

- **443 仍无「无 Host 兜底」**（`new-api-ph-standby-ip` 只监听 80）。当前策略：SG 侧**仅显式 Host 才可达**（`sg.likha.hk` / `sg-standby.internal.likha.hk`），其余 Host 走 443 会 502 —— 这符合「收敛 Host」方向（任务 47）。若后续需要与 mnl 对称的全兜底，再给该 Ingress 加 443。
- `sg-standby.internal.likha.hk` 走 443 时证书 SAN 不匹配（通配符只覆盖 `*.likha.hk`）⇒ 内部域名**应继续用 80**，或后续为内部域名另签证书。
