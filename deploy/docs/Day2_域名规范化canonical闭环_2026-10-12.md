# Day2 · 域名规范化 / Host 收敛 canonical 闭环（马尼拉 ALB）

> 执行：2026-10-12 15:32–15:38 HKT（mnl）· 放行：用户「执行」
> 方案真源：`deploy/docs/域名规范化与Host收敛_最佳实践方案_2026-10-12.md`
> 结论：**✅ 四个入口全部达标；308 方法保留已实证；无回归、无残留**

---

## 1. 结论（TL;DR）

canonical 主域名定为 **`www.likha.hk`**，根域 `likha.hk` 在 **80 + 443 双侧**收敛到 www：

| 入口 | 目标 | 码 | 状态 |
|---|---|---|---|
| `http://likha.hk` | `https://www.likha.hk` | 301 | ✅ **一跳到位** |
| `http://www.likha.hk` | `https://www.likha.hk` | 301 | ✅ |
| `https://likha.hk` | `https://www.likha.hk` | **308** | ✅ |
| `https://www.likha.hk` | —（业务） | 200 | ✅ 不跳 |

**最关键的一条**：443 那一跳用 **308 而非 301** —— 实测 `curl -L -d ''` → `code=404 redirects=1`，证明 **POST 未被降级为 GET**（若用 301 会降级成 GET 并得 200）。`likha.hk` 很可能被客户填作 API `base_url`，用 301 会导致 `POST /v1/...` 静默失败。

---

## 2. 交付物与变更清单

| # | 对象 | 变更 | 时间 |
|---|---|---|---|
| 1 | `Ingress/new-api-http-redirect`（mnl, :80） | `actions.redirect` 的 `RedirectConfig.host`：`${host}` → **字面量 `www.likha.hk`**（**唯一改动**，其余注解/labels/rules 零变化） | 15:33 apply |
| 2 | `Ingress/new-api-https-canonical`（mnl, :443） | **新建**：`host: likha.hk` → `httpCode: "308"`；`listen-ports=[{"HTTPS":443}]`；`order:"1"` | 15:38 apply |
| 3 | `deploy/manifests/ingress-mnl-http-redirect.yaml` | 同步真源 + 头注（未 apply → 已 apply） | — |
| 4 | `deploy/manifests/ingress-mnl-https-canonical.yaml` | 新增落地件（头注：已 apply + 实测） | — |
| 5 | 探针 `Ingress/canon-probe`（临时） | 试跑 308 → **验后立即删除**（无残留） | 15:32 建 / 15:34 删 |

**未改动**：`AlbConfig/mnl-alb`（443 监听与证书沿用，证书来自 listener，Ingress 无需 `certificate-id`）、`new-api-stable-ip`、canary、catchall-404、DNS、SG 侧一切资源。

---

## 3. 执行序列（4 步，含上线前探针）

| 步 | 动作 | 证据 |
|---|---|---|
| 0 | **只读基线**：mnl 443 监听 `lsn-hjl2cz2g9oqvee4eix` 仅 2 条规则（`ph-verify` prio=1 / 兜底 prio=2）；80 监听 `lsn-ihrgkty2sjdy8s5p4h` 6 条 | `canon_before_rules_*.json` |
| 1 | **探针试跑**：建 `canon-probe.likha.hk`（443 / order=1 / 308）→ 查云侧规则确认 `Type=Redirect`+`HttpCode=308` → curl 实测 `HTTP/2 308` → **删除**（规则还原为 2 条） | `t_canon_10..14` |
| 2 | **80 侧 apply**：`host` 字面量化 | `t_canon_20/21` |
| 3 | **443 侧 apply**：新建 canonical Ingress | `t_canon_30/31` |

**为什么必须做第 1 步**：本轮已两次亲历「字段名/取值错误 ⇒ **静默失效**」（`redirectConfig`/`statusCode` 写错时 Controller 忽略且 HTTP 仍 200）。`308` 是否被 Controller 放行**不能靠文档假设**，必须用探针 + 云侧 `RuleActions` 证伪。成本约 2 分钟，收益是避免把「假通过」当成上线。

---

## 4. 验收实测（2026-10-12 15:38 HKT）

### 4.1 四入口全链路（`t_canon_40_final.sh`）

```
http://likha.hk          HTTP=301 -> https://www.likha.hk/api/status
http://www.likha.hk      HTTP=301 -> https://www.likha.hk/api/status
https://likha.hk         HTTP=308 -> https://www.likha.hk/api/status
https://www.likha.hk     HTTP=200 redirects=0
```

端到端跟随链（`-L`）：三条收敛入口 **全部 `final=https://www.likha.hk/api/status` · `code=200` · `redirects=1`** ⇒ **全部一跳到位，无链式跳转**。

### 4.2 ★ P0：308 方法保留（本题最关键证据）

```
POST https://likha.hk/api/status   code=404 redirects=1 final=https://www.likha.hk/api/status
```
`/api/status` 只注册 GET。POST 能穿透到后端并得到 **404**，说明 **方法被保留**；若 308 被降级，客户端会以 GET 重发 ⇒ 得 **200**。⇒ **308 语义成立**。

### 4.3 云侧规则终态（`aliyun alb ListRules --ListenerIds.1 lsn-hjl2cz2g9oqvee4eix`）

| 规则 | prio | 条件 | 动作 |
|---|---|---|---|
| `rule-5eb1lqucee6bjp6wtn` | **1** | `Host=likha.hk` + `Path=/*` | **Redirect 308 → HTTPS://www.likha.hk${path}** |
| `rule-x7xtulp78h1kb67zcc` | 2 | `Host=ph-verify.internal.likha.hk` | ForwardGroup(`sgp-j4qrgy3f7bcv1r67na`) |
| `rule-1367p70ubvq2wrh6z0` | 3 | `Path=/*`（兜底） | ForwardGroup(`sgp-j4qrgy3f7bcv1r67na`) |

⇒ canonical **prio=1 成功压过兜底 prio=3**（这是方案里的硬约束①，已达成）。

### 4.4 回归（全绿）

| 项 | 结果 |
|---|---|
| 裸 IP `http://8.212.161.49/api/status` / `.183.7` | **200 · redirects=0**（不跳转，10-06 裁定 A 保留） |
| 裸 IP `https://8.212.161.49/api/status` (`-k`) | **200 · redirects=0** |
| `ph-verify.internal.likha.hk` :80 | **200**（canary/内部验收不受影响） |
| `sg.likha.hk` HTTPS（跨地域） | **200**（新加坡未受影响） |
| `https://www.likha.hk` 证书链 | `subject=CN=*.likha.hk` ← `Aliyun RSA TLS DV G1`，**Verify 0 (ok)** |
| `Host: bogus.example.com` → HTTPS | **200**（任务 47 未做，与预期一致，**非回归**） |

---

## 5. 关键技术结论（可复用）

1. **★ 承载 API 的域名做收敛，一律 `308`（不用 301）** —— 301/302/303 下客户端普遍把 POST 降级为 GET 并丢 body。本次已实测坐实（4.2）。ALB `RedirectConfig.HttpCode` 合法取值 = `301/302/303/307/308`；HTTPS 监听**只能跳 HTTPS**。
2. **★ Controller 对「错字段名 / 不支持的取值」一律静默失败**（不报错、HTTP 仍可能 200）⇒ 上线前必须用**临时 host 探针 + 云侧 `RuleActions`** 复核，不能只看 curl 状态码。
3. **★ RuleId 会复用/漂移**（本次实测）：探针规则拿到的是**基线里 `ph-verify` 那条的 RuleId**；canonical 上线后同一 ID 又归属 `Host=likha.hk`。⇒ **判路由一律实时查 API，RuleId 无稳定性、勿落库引用**。
4. **`order` 决定能否压过兜底**：canonical 必须 `order="1"` < `new-api-stable-ip` 的 `50`，否则 443 兜底规则会先匹配。
5. **443 的 canonical Ingress 只能放根域** `likha.hk` —— 放 `www.likha.hk` 就是 canonical 跳自己 ⇒ 无限 308。

---

## 6. 已知非阻塞项

`likha.hk` / `www.likha.hk` 均有 **TTFB 长尾**（连续 10 次采样：**0 失败**；`https://likha.hk` 峰值 `7.68s`、`www` 峰值 `7.07s`，常态 0.7–2.4s）。

- **与 Host 收敛无关**：两域名均出现；且本次唯一一次 `A 组超时` 在 B 组同 URL 上立即复现为 200。
- 指向**跨境链路 或 后端 P99**。建议另立排查：ARMS/SLS 核对 mnl `new-api` Pod P99 与 ALB `UpstreamResponseTime`。
- 现有站点监控（`likha-hk-newapi-status`，5 min）覆盖不到该量级抖动。

---

## 7. 遗留与回退

| 项 | 说明 |
|---|---|
| **任务 47（Host 收敛）** | 仍**未做**：删 nohost 兜底 Ingress + 伪造 Host 复测 404。现状伪造 Host 经 443 兜底仍 **200** |
| SG 侧无 301/308 | `sg.likha.hk` 80/443 均直连业务，**两地口径不一致**，建议一并定 |
| **回退** | 80 侧：`host` 改回 `${host}` 并 apply；443 侧：`kubectl -n new-api delete ingress new-api-https-canonical`。⚠ **301/308 已被客户端长期缓存 ⇒ 回退仅对新客户端生效** |

---

## 8. 复现脚本与产出（`deploy/logs/`，gitignored）

| 文件 | 用途 |
|---|---|
| `t_canon_00_recon.sh` | 只读基线（监听 + 规则） |
| `t_canon_10_probe_body.sh` / `t_canon_11_check.sh` / `t_canon_12_probe_curl.sh` / `t_canon_13_probe_del_body.sh` / `t_canon_14_after_del_check.sh` | 探针建/查/测/删/还原 |
| `t_canon_20_apply80_body.sh` / `t_canon_21_verify80.sh` | 80 侧 apply + 验收 |
| `t_canon_30_apply443_body.sh` / `t_canon_31_verify443.sh` | 443 侧 apply + 验收 |
| `t_canon_40_final.sh` / `t_canon_41_stability.sh` | 最终总验收 + 稳定性抽样 |
| `t_canon_rule_parse.py` | ALB 规则解析器（`HostConfig.Values` / `PathConfig.Values`） |
| `canon_*.json` | 各阶段云侧规则快照 |
