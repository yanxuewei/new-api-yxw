# Day 3 · 任务 47｜ALB 安全组源收敛 + SNI 域名校验 —— 执行报告（2026-10-06）

- **卡片**：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` Day 3 任务 47
- **结论**：**部分交付** —— ① 源收敛**分支判定 + 书面定稿**完成；② **未匹配 Host 兜底加固完成（本次最大发现与修复）**；③ SNI/443 域名校验**待 G5 证书**；④ WAF/CC 两条缓解**待任务 20**。
- **证据目录**：`deploy/logs/task47_20261006-141650/`
- **IaC 产物**：`deploy/aliyun/ph/catchall-404-ingress.yaml`

---

## 一、源收敛分支判定（书面定稿）

**采用分支：WAF 3.0 云原生接入（不收敛）** —— `sg-mnl-alb` 入向**保持** `0.0.0.0/0:80,443`。

- 依据 P0-6：WAF 3.0 云原生接入为透明代理，**不产生回源网段**；按旧方案收敛为"WAF 回源段"会让真实流量全被挡（坑 1）。
- DCDN 分支未采用（DCDN 未开通；若后续启用，须 `DescribeDcdnL2Ips` 取段 + **每日差异比对告警**，不得一次性抄录）。
- **V3 复核（与任务 22 同一条 jq，双卡互证）**：`sg-mnl-alb` 入向实测仅 2 条，`0.0.0.0/0` 仅落在 80/443：
  ```
  TCP 80/80   0.0.0.0/0  http-301-only
  TCP 443/443 0.0.0.0/0  pub-https-ingress
  ```

**三条缓解的状态**：

| 缓解 | 状态 |
| --- | --- |
| ① WAF 防护策略 | ⏸ 待任务 20（WAF 未接入） |
| ② CC 阈值对齐 `GLOBAL_API_RATE_LIMIT` | ⏸ 待任务 20 |
| ③ `alb-access` SLS 访问日志审计 | ✅ **已生效**（实测 `AccessLogConfig = sls-newapi-mnl/alb_access`；SLS `ap-southeast-6` 项目内 22 个 Logstore 含 `alb_access`） |

## 二、未匹配 Host 兜底（本次实锤漏洞 + 修复）

### 2.1 加固前实测（坑 2 的真实暴露面）

| 请求 | 结果 |
| --- | --- |
| `Host: ph-verify.internal.likha.hk` → `/api/status` | **200** |
| `Host: www.likha.hk` / `ops.likha.hk` / `evil.example.com` → `/api/status` | **200（❌ 直落业务）** |
| 直连 VIP（Host=IP）→ `/` | **200**（返回 new-api 登录页, `X-Oneapi-Request-Id` 头） |

链路成因：:80 监听**默认动作 = ForwardGroup → `sgp-fm7kdwz99wtzbffkfx`（kube-system/fake-svc）** → 4 台节点 `NodePort 32656`（`svc/newapi-np`）→ 业务 Pod。⇒ 任何人拿 ALB VIP 伪造任意 Host 即可绕过域名体系直达业务。

> ⚠ **测试口径坑（本次踩到）**：macOS 宿主 `http_proxy=127.0.0.1:7890` 会让 `curl` 经本地代理，产生"合法 Host 502 / IP Host 200"的**假象**。判据必须 `curl --noproxy '*'` 或从**跳板机/节点侧**取（本报告全部结论以跳板机侧为准）。

### 2.2 修复尝试与结论

1. **AlbConfig 路子（未生效，记录行为）**：patch `spec.listeners[0].httpDefaultActions = FixedResponse 404`（generation 1→2，控制器 `SuccessfullyReconciled`）→ **监听默认动作 75s 后仍是 ForwardGroup**；此前 spec 里的 `Redirect`（gen=1）同样从未落。⇒ **本集群 ACK ALB 控制器不消费 AlbConfig 的默认动作声明**（spec 与运行时默认动作不一致是已知行为，spec 现留 FixedResponse 404 作声明口径，待任务 19 全量重放时再收敛）。
2. **兜底 Ingress 路子（已生效）**：新建 `Ingress/new-api-catchall-404`（无 host → `alb.ingress.kubernetes.io/actions.reject` = `FixedResponse 404`）。
   - 首版被控制器分到 **priority 1**，把合法 Host 规则挤到 priority 2 ⇒ `ph-verify → 404`（打坏任务 23 的 ALB→stable 链路）。
   - 修正：`alb.ingress.kubernetes.io/order`（**数值越小优先级越高，范围 1–1000，默认 10**）→ 合法 Host 规则 `order=1`、兜底 `order=100`。
   - **最终规则表**：
     ```
     rule-80-1  pri=1  Host: ph-verify.internal.likha.hk  →  ForwardGroup sgp-tqgwt413t19mum8oa9
     rule-80-2  pri=2  （无 host 条件，兜底）              →  FixedResponse 404
     ```

### 2.3 加固后实测（跳板机侧）

| 请求 | 结果 |
| --- | --- |
| `Host: ph-verify.internal.likha.hk` → `/api/status` | **200** ✅ |
| `Host: www.likha.hk` / `ops.likha.hk` / `evil.example.com` / IP Host | **404 + body "Not Found"** ✅ |

## 三、V 项判定

| 项 | 结果 | 说明 |
| --- | --- | --- |
| V1 伪造 Host 不命中 stable | ✅ | 四个伪造 Host 全 404（加固前 200） |
| V2 合法 Host 正常 | ✅（HTTP:80） | `ph-verify.internal.likha.hk → 200`；**HTTPS 200 待 G5** |
| V3 ALB 入向复核 | ✅ | 仅 80/443 ← `0.0.0.0/0`（与任务 22 互证） |
| SNI/443 域名校验 | ⏸ 挂账 | 无 443（G5 证书）；证书到后由任务 19 全量重放（80 Redirect + 443 + TLS 策略），届时补 SNI 反例（`openssl s_client -servername`） |

## 四、遗留与后续

1. **WAF/CC（任务 20）**：云原生接入未落地前，"不收敛"分支的两条缓解缺失，属**已登记的口径缺口**（任务 20 完成即补齐）。
2. **443 + SNI（G5）**：证书签发后按任务 19 全量重放；届时 `:80` 期望默认动作=Redirect、`:443` 期望默认动作=受控/兜底，且需复验"伪造 Host 在 443 上同样非 200"。
3. **ALB 默认动作**：现仍指向 `fake-svc`（已被兜底规则遮蔽，属哑动作）；任务 19 全量重放时一并处理。`sg-mnl-alb` 业务组未绑定到 ALB（`SecurityGroupIds=null`，ALB 用系统 SG）——与任务 22 记录一致。
4. **catch-all 规则的生命周期**：任务 23 后续新增 `www.likha.hk`/`ops.likha.hk` 正式 Ingress 时必须保持各自 `order` 高于兜底（兜底固定 100）；GitOps 纳管 `deploy/aliyun/ph/catchall-404-ingress.yaml`。
