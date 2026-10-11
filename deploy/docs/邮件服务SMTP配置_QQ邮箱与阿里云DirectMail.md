# new-api 邮件服务（SMTP）配置指南

> **两条路线**：A. QQ 个人邮箱（免费 / 5 分钟）· B. 阿里云邮件推送 DirectMail（生产推荐 / 自有域名）
> **适用站点**：new-api（likha.hk 菲律宾站点）后台 → 系统设置 → SMTP 邮箱
> **文档日期**：2026-10-10 ｜ 实测环境：WSL Ubuntu + aliyun CLI 3.5.1（国际站）

---

## 0. 结论先行

| 路线 | 成本 | 发件人地址 | 到位时间 | 定位 |
|---|---|---|---|---|
| **A. QQ 个人邮箱** | 免费 | `xxx@qq.com` | 约 5 分钟 | 先跑通功能、内测、低频通知 |
| **B. 阿里云 DirectMail** | 2000 封免费（每天 ≤200 封）；超出 0.29 USD/千封 | `noreply@dm.likha.hk` | 约 30 分钟（含 DNS 生效） | **生产上线** |

**推荐路径**：先用路线 A 把功能跑通，上线前切到路线 B（发件人用自有域名，到达率与合规性更好）。

### 当前账号实测状态（2026-10-10）

| 检查项 | 结果 | 说明 |
|---|---|---|
| `aliyun dm` 通道 | ✅ 可用 | 产品版本 `2015-11-23`，国际站端点；CLI 支持 |
| 发信域名列表 | ⚠️ **空**（`TotalCount=0`） | 尚未创建任何发信域名 ⇒ 从第 3 章第 1 步开始 |
| 首次探测异常 | ⚠️ `InvalidUser.NotFound` | 端点被解析到非国际站点所致，复测稳定成功；如再遇请加 `--region ap-southeast-1` |
| 云解析主域名 | ✅ `likha.hk` | `DomainId 3b4321ce86d3436aa46e3a8ba96a6133`，免费版 TTL 下限 600s |

---

## 1. 界面字段语义总览

后台「SMTP 邮箱」共 8 个可填项，对应关系与代码位置如下（`common/constants.go` / `common/email.go`）：

| 界面字段 | 配置键 | 语义 | 关键行为（代码位置） |
|---|---|---|---|
| SMTP 主机 | `SMTPServer` | 服务商域名 | 同时用作 TLS `ServerName`（`email.go:39`） |
| 端口 | `SMTPPort` | 25 / 465 / 587 | 填 **465** 且未选 STARTTLS 时**自动走隐式 TLS**（`email.go:45`） |
| SMTP 加密方式 | `SMTPSSLEnabled` / `SMTPStartTLSEnabled` | 三选一：无加密 / SSL/TLS / STARTTLS | 单选，前端互斥（`email-settings-section.tsx:75-84`） |
| 跳过 SMTP TLS 证书验证 | `SMTPInsecureSkipVerify` | 允许自签 / 主机名不匹配 | 生产环境**必须保持关闭**（`email.go:40`） |
| 用户名 | `SMTPAccount` | SMTP AUTH 账号 | 与 Token 同时非空才触发认证（`email.go:33-35`） |
| 密码 / 访问令牌 | `SMTPToken` | 凭据 | 留空 = 保留原值，不会清空 |
| 强制 AUTH LOGIN | `SMTPForceAuthLogin` | 强制用 AUTH LOGIN 而非 AUTH PLAIN | Outlook / 部分服务商需要；QQ、DirectMail 不需要 |
| 发件地址 | `SMTPFrom` | 用作 `MAIL FROM` | ⚠️ **只填纯邮箱**，见 §4 附录 B |

---

## 2. 路线 A：QQ 个人邮箱（免费）

QQ 邮箱免费提供 SMTP 服务，个人邮箱即可使用。但**必须先做两步一次性准备**（开启服务 + 生成授权码），直接填 QQ 登录密码一定失败。

### 2.1 获取 16 位授权码（一次性）

1. 登录 **mail.qq.com** → 右上角 **设置** → **账户**
2. 找到 **「POP3/IMAP/SMTP/Exchange/CardDAV/CalDAV 服务」**（页面底部）→ 点 **开启**
3. 按弹窗提示，用绑定手机**发送验证短信**到指定号码
4. 回到该处点 **「生成授权码」**
5. 复制得到的 **16 位字母数字串** —— 它就是 SMTP 密码，**只显示一次，务必保存**

> ⚠️ 授权码 ≠ QQ 登录密码。修改一次 QQ 密码，**所有已生成的授权码立即失效**，需重新生成。

### 2.2 填写参数

**组合 A（首选）**

| 界面字段 | 填写值 |
|---|---|
| SMTP 主机 | `smtp.qq.com` |
| 端口 | `465` |
| SMTP 加密方式 | **SSL/TLS** |
| 跳过 SMTP TLS 证书验证 | 关 |
| 用户名 | `你的QQ号@qq.com`（完整邮箱） |
| 密码 / 访问令牌 | **16 位授权码** |
| 强制 AUTH LOGIN | 关 |
| 发件地址 | `你的QQ号@qq.com` |

**组合 B（备选）**：端口 `587` + 加密方式 `STARTTLS`，其余同上。

**企业邮箱**：主机改为 `smtp.exmail.qq.com`，端口 `465`，其余同上。

### 2.3 两个必踩的坑

1. **「发件地址」不能填 `New API <xxx@qq.com>`**
   占位符只是格式示意。该控件有纯邮箱正则校验（`email-settings-section.tsx:57-61`，`^[^\s@]+@[^\s@]+\.[^\s@]+$`），带尖括号和空格**必然校验失败**。只填 `xxx@qq.com`。
2. **加密方式不要选「无加密」**
   Go 的 `net/smtp` 在明文连接上会**拒绝发送认证凭据**；且端口 25 基本已被 QQ 封停。要么 SSL/TLS（465），要么 STARTTLS（587）。

### 2.4 验证方法

后台没有独立的「发送测试邮件」按钮。走一次前端流程即可：
**登录页 → 注册 / 忘记密码 → 填邮箱 → 收到验证码邮件 = 配置成功。**

### 2.5 报错对照表

| 报错 | 原因 | 处置 |
|---|---|---|
| `535 Authentication failed` | 填了 QQ 密码而非授权码；或授权码已失效 | 重新生成授权码 |
| `550` / `553` | 发件地址与用户名不一致，或填了显示名格式 | 两处都改成同一个纯邮箱 |
| `connection refused` / 超时 | 端口与加密方式不匹配（如 587 却选 SSL/TLS） | 改成 465 + SSL/TLS |
| `unencrypted connection` | 选了「无加密」 | 改用 SSL/TLS |

### 2.6 QQ 的固有限制（详细）

> 标注口径：**【官方】** = 腾讯帮助中心明确说明；**【第三方】** = 第三方实测/转录，腾讯未公开承诺，仅供量级参考。

| 限制 | 影响 |
|---|---|
| **发信频率 / 日限量有硬顶，频繁发送触发临时封禁** | **只能用于验证码、通知等低频场景**，不能做营销群发 —— 详见下方 ①–⑧ |
| 服务器在国内 | 从马尼拉/新加坡访问有 100–300 ms 跨国延迟（不影响可用性） |
| 不支持自有域名 | 不能以 `likha.hk` 发件（会 550），发件人只能是 `@qq.com` |
| 改密码即全部失效 | 需重新生成授权码并更新配置 |

#### ① 三层阶梯式限流闸门【官方】

腾讯帮助中心（「550 Connection frequency limited」/「550 Domain frequency limited」）明确的**阶梯式动态保护**机制：

| 触发层级 | 超限后果 | 恢复时间 |
|---|---|---|
| 超过**每分钟**发信量 | 该 **IP / 发件人域名**禁止发信，持续**若干分钟** | 数分钟 |
| 超过**每小时**发信量 | 禁止发信，持续**若干小时** | 数小时 |
| 超过**每日**发信量 | **本日剩余时间禁止再发信** | 次日 0 点（UTC+8）重置 |

- **阈值属腾讯保密数据，官方明确不予公开**；且按 **IP** 与 **发件人域名** 两个维度分别管控。
- 阈值**随历史发信信誉动态调整** —— 长期合规发信的对象额度更宽松。
- ⚠️ 该规则的原文场景是「**向 QQ 邮箱投递**」（对方是 QQ 邮箱时），但同一风控体系也约束 `smtp.qq.com` 账号自身的发信行为。

#### ② 账号日发信量上限【第三方，口径不一】

腾讯**从未官方公布**个人邮箱的日发信量，以下均为第三方来源，且互相冲突：

| 账号类型 | 日发信量 | 来源性质 |
|---|---|---|
| 普通个人 QQ 邮箱（2G 容量档） | 约 **100 封/天** | 腾讯帮助中心历史口径的第三方转录 |
| 3G/4G 会员、移动 QQ、QQ 行 | 约 **500 封/天** | 同上 |
| 部分资料给出的普通账号口径 | 200 封/天 | 第三方实测，与上行冲突 |

> **规划取值：按 100 封/天 保守估算**。腾讯不承诺、不公开、可随时动态下调。

#### ③ 速率与连接级限制【第三方】

| 项 | 值 |
|---|---|
| 发信速率 | ≤ 约 **30 封/分钟** |
| 单个 SMTP 连接 | ≤ 约 **50 封** |
| 单封邮件附件 | ≤ 50 MB（实际不建议 >10 MB） |
| 失败邮件 | 同样**计入日配额** |

> 本项目影响面：new-api 每封邮件都**新建连接**（`common/email.go` 无连接池），所以「单连接 50 封」不构成约束；真正制约我们的是**每分钟速率**与**每日总量**。

#### ④ 会加速触发封禁的高危行为【官方 + 第三方】

- 短时间大批量发信，或失败后**密集重试**
- 连续投递到**不存在的收件地址**（硬退信率过高）
- 邮件正文含**外链、营销话术、敏感词**
- 收件人点击**「举报垃圾邮件」**
- 未启用 SSL/TLS 的**明文连接**反复尝试认证
- 账号或发信服务器**疑似被盗用**（异地登录 + 群发）

#### ⑤ 封禁分级与恢复时间

| 级别 | 典型触发 | 恢复时间 |
|---|---|---|
| **频率限流**（临时） | 短时间内高频发信 | **10 分钟 – 1 小时**自动解除；⚠️ **期间不要重试**，重试会延长封禁 |
| 群发 / 异地登录风控 | 大批量群发、异常登录 | **24 – 72 小时**自动解除 |
| 被举报垃圾邮件 | 收件人举报 | 最长 **7 天** |
| 多次违规 / 违法内容 | 反复违规 | **永久封禁**，只能换邮箱 |

#### ⑥ 新账号 14 天门槛【官方】

**新激活的 QQ 邮箱需满 14 天**才允许开启 POP3 / IMAP / SMTP 服务（第三方客户端登录同理，部分资料写作 15 天）。
⇒ **上线前请提前激活并验证**，不要等上线当天才开通。

#### ⑦ 对本站的实际影响测算

| 场景 | QQ 邮箱可行性 |
|---|---|
| 内测 / 个人项目（< 100 注册/天） | ✅ 可用 |
| 站点公开后 100 – 500 注册/天 | ⚠️ **必然触顶** —— 按 100 封/天计，**第 101 个用户开始收不到验证邮件**，且失败邮件同样计入配额 |
| > 500 注册/天 | ❌ 不可用 |

#### ⑧ new-api 侧已有防护与缺口（**已于 2026-10-10 正式立案为 `G8-EV-1`**）

三条对外发信路径的守卫矩阵（逐行取证，`router/api-router.go:44/45/49/50`）：

| 路由 | 现有守卫 | 按 IP | 按邮箱 |
|---|---|---|---|
| `GET /api/verification` | `EV`（2 次/30 秒）+ Turnstile | ✅ | ❌ |
| `GET /api/reset_password` | 仅 `CT`（**20 次/20 分钟**）+ Turnstile | ✅（宽松 300 倍） | ❌ |
| `POST /oauth/email/bind/{start,resend}` | `CT` + `UC:account-security` + `EV` | ✅ | ❌ |

- **已确认存在的两条硬事实**：
  1. `EV` 限流（`middleware/email-verification-rate-limit.go:14-15`，2 次/30 秒）**只按 `ClientIP` 取键**（`:21` `redisIPRateLimitKey`；内存降级 `:47` 同样只带 IP）—— **换 IP 即绕过**。
  2. **`/api/reset_password` 根本没挂 `EV`**，只挂 `CT`（`common/constants.go:222-223`：20 次/20 分钟）⇒ 忘记密码接口比注册验证码接口**宽松 300 倍**，而它同样真实发信。
  3. `TurnstileCheck` 是**软开关**（`middleware/turnstile-check.go:17`）：未配置 `TURNSTILE_SECRET_KEY` 时整个中间件是 no-op。
- ⚠️ **结论**：三条路径**都没有**"按目标邮箱"与"全局出信总量"闸门 ⇒ 用 **IP 池 × 邮箱列表**分布式刷，可在几分钟内烧光当日额度，**全站真实用户随即收不到验证码与找回密码邮件**（HTTP 面完全正常，无任何告警）。
- ✅ **处置**：已立案为门禁扩围项 **`G8-EV-1`**，设计为三层闸门（L1 按邮箱 3/10min + 5/day · L2 按 IP 现状 · **L3 全局出信熔断**，含日配额 80% 软熔断与连续失败熔断）、14 条验收清单与 5 条残余风险。
  → **立案文档**：`deploy/docs/G8增补_邮件发信闸门_立案_2026-10-10.md`
- **建议**：QQ 只作**内测/兜底**通道；生产切 DirectMail（每天 200 封免费，账号级额度且随信誉调整），并在 Grafana 对**发信失败率**与 `newapi_email_send_suppressed_total{reason="quota"}` 做告警。

---

## 3. 路线 B：阿里云邮件推送 DirectMail（生产推荐）

### 3.1 前置条件

| 项 | 要求 |
|---|---|
| 服务开通 | 控制台 → 产品「邮件推送 DirectMail」→ 开通（需实名认证） |
| 发信域名规划 | 建议用**子域名** `dm.likha.hk`，隔离主域信誉（文档明确建议：邮件推送勿与主域企业邮箱混用） |
| 云解析 | `likha.hk` 已在阿里云云解析（`DomainId 3b4321ce86d3436aa46e3a8ba96a6133`） |
| RAM 权限 | 执行账号需 `dm:*`（或最小集：`CreateDomain` / `DescDomain` / `QueryDomainByParam` / `CreateMailAddress` / `ModifyPWByDomain` / `CheckDomain`）；用主账号 AK 则无需配置 |
| 地域端点 | `dm.ap-southeast-1.aliyuncs.com`（国际站）。CLI 未指定 `--region` 时用 profile 默认地域亦可正常工作 |

> 阿里云云解析的「自动配置解析」**仅华东地域支持**，国际站不适用 ⇒ 必须手动/脚本写入 DNS 记录。

### 3.2 需要配置的 6 条 DNS 记录

以发信域名 `dm.likha.hk`、云解析主域名 `likha.hk` 为例。
**主机记录（RR）一律以控制台「发信域名 → 配置」页或 `DescDomain` 返回值为准，不要手抄本文档。**

| # | 类型 | 主机记录 (RR) | 记录值 | 作用 | 新域名必配 |
|---|---|---|---|---|---|
| 1 | TXT | `aliyundm.dm`（字段 `HostRecord`） | `DnsTxt` | **所有权验证** | ✅ |
| 2 | TXT | `dm` | `v=spf1 include:spf1.dm.aliyun.com -all`（`DnsSpf`） | **SPF** — 声明授权发信 IP | ✅ |
| 3 | TXT | `aliyun-<selector>._domainkey.dm`（`DkimRR`） | `DkimPublicKey` | **DKIM** — 签名防篡改 | ✅ |
| 4 | TXT | `_dmarc.dm`（`DmarcHostRecord`） | `v=DMARC1; p=quarantine; rua=mailto:dmarc@likha.hk; pct=100` | **DMARC** — 未通过时的处置策略 | ✅ |
| 5 | MX | `dm` | `mx01.dm.aliyun.com`（`MxRecord`），优先级 `5` | **回信路由** | ✅ |
| 6 | CNAME | `dmtrace.dm`（`CnameRecord`） | `tracedm.aliyuncs.com`（`TracefRecord`） | 点击/打开跟踪（可选） | ➖ |

**验证规则**：**新域名**需 SPF / DKIM / DMARC / MX **四项全部通过**才算验证通过；老域名仅需所有权 + SPF + MX。

**SPF 注意**：一个域名只能有**一条** SPF TXT。本次只加到子域 `dm.likha.hk`，**不影响主站 `likha.hk`**。

**DMARC 建议**：先用 `p=quarantine` 观察 1–2 周，确认无异常后再收紧为 `p=reject`。

### 3.3 可执行配置清单

> 全部命令已封装为脚本：`deploy/ops/directmail_setup.sh`（见 §3.5）。
> 下列为手动执行的分步清单，便于逐步核对。

**Step 0 — 开通服务（控制台，一次性）**
控制台 → 搜索「邮件推送」→ 开通 → 选择国际站。确认账号已完成实名认证。

**Step 1 — 创建发信域名**

```bash
aliyun dm CreateDomain --DomainName dm.likha.hk --method POST
# 返回 DomainId，记下来（也可用 QueryDomainByParam 反查）
```

**Step 2 — 拉取权威 DNS 记录值（不要手抄）**

```bash
aliyun dm QueryDomainByParam --KeyWord dm.likha.hk --PageSize 50
# 从 data.domain[] 取 DomainId

aliyun dm DescDomain --DomainId <上一步的 DomainId> --RequireRealTimeDnsRecords false
# 关键返回字段：
#   HostRecord / DnsTxt        → 所有权验证 TXT
#   DnsSpf                     → SPF TXT 值
#   DkimRR / DkimPublicKey     → DKIM TXT 主机记录与公钥
#   DmarcHostRecord / DnsDmarc → DMARC TXT 主机记录与值
#   MxRecord                   → MX 值
#   CnameRecord / TracefRecord → CNAME 跟踪记录
```

**Step 3 — 写入云解析（`likha.hk` 区域）**

以最高频的两条为例，其余同构：

```bash
# 所有权验证 TXT
aliyun alidns AddDomainRecord --DomainName likha.hk \
  --RR "aliyundm.dm" --Type TXT --Value "<DnsTxt>" \
  --TTL 600 --Line default --method POST

# SPF TXT
aliyun alidns AddDomainRecord --DomainName likha.hk \
  --RR "dm" --Type TXT --Value "v=spf1 include:spf1.dm.aliyun.com -all" \
  --TTL 600 --Line default --method POST

# MX（必须带 --Priority）
aliyun alidns AddDomainRecord --DomainName likha.hk \
  --RR "dm" --Type MX --Value "mx01.dm.aliyun.com" \
  --Priority 5 --TTL 600 --Line default --method POST
```

> 幂等性：写入前先用 `aliyun alidns DescribeDomainRecords --DomainName likha.hk --RRKeyWord <RR>` 查是否已存在。
> 可复用既有脚本 `deploy/manifests/dns-likha-hk.sh` 的写法风格（`RR` / `IPS` / `TTL` / `LINE` 全可覆盖）。

**Step 4 — 验证域名**

```bash
aliyun dm CheckDomain --DomainId <DomainId>          # 主动触发校验
aliyun dm DescDomain --DomainId <DomainId> --RequireRealTimeDnsRecords true
# 关注 4 个状态位：0 = 通过，1 = 未通过
#   DkimAuthStatus / SpfAuthStatus / MxAuthStatus / DmarcAuthStatus
# DomainStatus：0 表示已验证可用
```

DNS 生效一般 4 小时内（最迟 48 小时）。未通过时**手动再点一次验证**主动触发。

**Step 5 — 创建发信地址**

```bash
aliyun dm CreateMailAddress \
  --AccountName "noreply@dm.likha.hk" \
  --AddressType INTERNAL \
  --Sendtype trigger \
  --ReplyAddress "<一个能收信并完成验证的真实邮箱>" \
  --method POST
```

- `AddressType`：域名已在本系统创建填 `INTERNAL`
- `Sendtype`：验证码/通知类选 `trigger`；营销群发选 `batch`
- 回信地址需**单独验证**（控制台 → 验证回信地址 → 收邮件填验证码，15 分钟内有效）
- 新建发信地址建议**等待 10 分钟**再试发信

**Step 6 — 设置 SMTP 密码**

控制台：发信地址列表 → 「设置 SMTP 密码」。
或 CLI（域名级口令，同样可用于 SMTP AUTH）：

```bash
aliyun dm ModifyPWByDomain --DomainName dm.likha.hk --Password '<你的密码>' --method POST
```

密码复杂度（服务端强校验）：**长度 10–20 位；≥2 位数字 + ≥2 位大写 + ≥2 位小写；不能与上次相同。**

**Step 7 — 在 new-api 后台填写 SMTP 参数**

| 界面字段 | 填写值 |
|---|---|
| SMTP 主机 | `smtpdm.aliyun.com` |
| 端口 | `465` |
| SMTP 加密方式 | **SSL/TLS** |
| 跳过 SMTP TLS 证书验证 | 关 |
| 用户名 | `noreply@dm.likha.hk`（= 发信地址） |
| 密码 / 访问令牌 | 上一步设置的 SMTP 密码 |
| 强制 AUTH LOGIN | 关 |
| 发件地址 | `noreply@dm.likha.hk` |

> ⚠️ **DirectMail 的 SMTP 只提供 25（明文，ECS 默认封）/ 80（明文）/ 465（SSL）三个端口，没有 587/STARTTLS** ⇒ 加密方式**必须选 SSL/TLS**，端口填 465。

**Step 8 — 端到端验证**

后台 → 登录页 → 「忘记密码」→ 填一个真实邮箱 → 确认收到邮件且发件人显示为 `noreply@dm.likha.hk`。
若未收到：先看 `aliyun dm DescDomain --DomainId <id> --RequireRealTimeDnsRecords true` 的四个状态位，再看 SPF/DKIM 是否被收件方 DNS 正确解析：

```bash
dig +short TXT dm.likha.hk @8.8.8.8
dig +short TXT <DkimRR>.likha.hk @8.8.8.8
dig +short MX dm.likha.hk @8.8.8.8
```

### 3.4 计费与额度

| 项 | 国际站口径 |
|---|---|
| 免费额度 | 每个阿里云**主账户共 2000 封**，**每天最多免费 200 封** |
| 超出后 | 按量 **0.29 USD / 1000 封**（不足 1000 封按比例，最低计费 0.01 USD） |
| 日/月额度 | 每日初始 2000 封（随信誉等级调整）；月额度 = 日额度 × 30 |
| SMTP 发信频率 | 12000 次 / 180 秒 |
| 附件 | 总大小 ≤15 MB（base64 膨胀约 1.5×，建议按 8 MB 准备） |
| 数据保留 | 统计数据保留 1 个月 |

### 3.5 一键脚本

```bash
# 只读：服务与域名现状
bash deploy/ops/directmail_setup.sh status

# 干跑：拉取权威记录值并打印将要写入的 DNS 计划（不产生任何写操作）
bash deploy/ops/directmail_setup.sh plan

# 执行：创建发信域名 + 幂等写入 6 条 DNS 记录（已存在则跳过）
bash deploy/ops/directmail_setup.sh apply

# 校验：拉取实时 DNS 解析结果与四个验证状态位
bash deploy/ops/directmail_setup.sh verify
```

可覆盖的环境变量：`DOMAIN`（默认 `dm.likha.hk`）、`ZONE`（默认 `likha.hk`）、`TTL`（600）、`LINE`（default）、`SENDER`（noreply）。

---

## 4. 附录

### 附录 A — CLI 命令速查

| 用途 | 命令 |
|---|---|
| 列出发信域名 | `aliyun dm QueryDomainByParam --PageSize 50` |
| 新建发信域名 | `aliyun dm CreateDomain --DomainName <域名>` |
| 查域名配置与 DNS 值 | `aliyun dm DescDomain --DomainId <id>` |
| 实时校验域名 | `aliyun dm CheckDomain --DomainId <id>` |
| 新建发信地址 | `aliyun dm CreateMailAddress --AccountName <邮箱> --AddressType INTERNAL --Sendtype trigger` |
| 设置 SMTP 密码 | `aliyun dm ModifyPWByDomain --DomainName <域名> --Password <密码>` |
| 删除发信域名 | `aliyun dm DeleteDomain --DomainId <id>` |
| 查/加/删解析记录 | `aliyun alidns DescribeDomainRecords / AddDomainRecord / DeleteDomainRecord` |

排查提示：接口的参数名以 CLI 内建元数据为准，例如 `DescDomain` **只接受 `--DomainId`（不接受域名）**，`AddDomainRecord` 的 MX 记录**必须带 `--Priority`**。遇到 CLI 报参数非法时，先信 CLI，用 `aliyun dm <Action> --help` 核对。

### 附录 B — 为什么「发件地址」只能填纯邮箱

前端 schema 对 `SMTPFrom` 的校验是纯邮箱正则：

```
/^[^\s@]+@[^\s@]+\.[^\s@]+$/
```

而它会被直接用作 SMTP 的 `MAIL FROM`（`common/email.go:111`）。因此：
- 填 `New API <noreply@example.com>` → **前端直接判非法**；
- 填一个与自己认证账号**不同的**邮箱 → 服务端回 `550`（发件人与认证用户不一致）。

显示名由系统名（`SystemName`）自动拼接：`From: <SystemName> <SMTPFrom>`（`email.go:96`），无需也不应在该字段手写显示名。

### 附录 C — 两条路线切换成本

| 维度 | QQ → DirectMail |
|---|---|
| 改动范围 | 仅后台 8 个字段，无代码改动、无重启 |
| 回滚 | 改回 QQ 参数即可，两条线路配置互不冲突 |
| 用户感知 | 发件人域名从 `@qq.com` 变为 `@dm.likha.hk`，已发出的邮件不受影响 |

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-10 | 首版：QQ 邮箱参数 + DirectMail 域名验证与 SMTP 配置清单；新增 `deploy/ops/directmail_setup.sh` |
| 2026-10-10 | §2.6 扩写：补三层阶梯限流闸门 / 日发信量口径 / 速率与连接限制 / 高危行为 / 封禁分级与恢复时间 / 14 天门槛 / 本站影响测算 / new-api 侧防护（含 `email-verification-rate-limit.go` 实测参数） |
| 2026-10-10 | §2.6 ⑧ 升级：三条发信路径守卫矩阵 + `/api/reset_password` 未挂 EV（仅 CT 20/20min）+ Turnstile 软开关 三处取证；缺口正式立案为 **`G8-EV-1`** → `deploy/docs/G8增补_邮件发信闸门_立案_2026-10-10.md` |
