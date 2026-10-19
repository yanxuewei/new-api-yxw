# 任务 38 · 本地零云调用项取证（2026-10-19）

执行机：WSL Ubuntu（深圳侧），`aliyun/kubectl/jq/python3/openssl/go1.25.1/docker` 在位；
`gitleaks / govulncheck / trivy / nmap / testssl` **均缺失**（未安装，见「缺口」）。
本文件所有输出均已脱敏：只记录 token 的**长度、格式前缀、md5 前 12 位**，绝不记录明文值。

---

## #1 无硬编码密钥 —— 判定：**有条件通过（模式命中 3 类，但无一项是可用的凭据）**

### 命令
```bash
git log -p --all --no-color | python3 <hist_scanner>     # 扫描器（一次性，未入仓，见 /tmp/t38）
git ls-files | xargs <head_triage>                       # HEAD 工作树分诊
```
扫描器判据（4 类）：`LTAI[0-9A-Za-z]{6,}`、`(?i)accesskeysecret…=[A-Za-z0-9]{28,32}`、
PEM `BEGIN … PRIVATE KEY` 头 + 其后 **≥20 行连续 base64 体**、其他供应商 token（ghp_/AKIA/sk-/xoxb）。

### 结果（全历史 6613 commits，`git rev-list --all --count`）
| 判据 | 命中 | 说明 |
| --- | --- | --- |
| **AKSecret（28–32 位）** | **0** | 全历史无任何 AccessKeySecret 落仓 |
| **真实私钥体（PEM 头后 ≥20 行 base64）** | **0** | HEAD 与全历史均为 0 |
| PEM `PRIVATE KEY` 头 | 3 处（HEAD） | `deploy/…v2.0.md:L1971` 是核查命令自身的 grep 串；`relay/channel/vertex/service_account.go:L68/74` 是上游代码拼字符串 |
| `LTAI` 格式串 | 5 个去重值 | 见下 |

`LTAI` 去重值逐项判定（长度即证据，真实 AKID 为 24 位）：

| md5(前12) | len | 出现位置 | 判定 |
| --- | --- | --- | --- |
| `a5233ed0c4ab` | 20 | 用户设置指南.md(+2 bak)、`gen_guide_images.py:341`、`05-创建用户-步骤3-保存AK.svg`、`index.html:22`、`task17_rrsa.sh`、`ram_user_mgmt.sh` | **示例/占位**（行内含示例类指示词 `placeholder_indicator=YES`），len≠24 |
| `bc41e8ae4555` | 10 | 同上 + `standby-deployment.yaml` | 掩码残段 |
| `7e3c959fcf8c` / `561b63f3f3aa` | 14 | `deploy/docs/开发AK与权限边界_落地报告.md:L54,L55` | **真实 AKID 的前 14 位截断**，对应 `dev-zhangzijun`、`dev-xiangdong` 两个 RAM 用户（报告自称 Active） |
| `291fd9f95e…` | 26 | `go.sum`（上游 2024-08 commit b8664e71） | 误报：hash 片段撞 `LTAI` |

### 残余风险与待办
- ⚠ 两个 dev AKID 的**前缀**入仓（非完整凭据，不可单独鉴权），但指南判据字面是「0 命中」→ 需**豁免单**或改写为明显占位串（如 `LTAI5t************`）。
- ❓ 待云侧只读复核（需授权）：`aliyun ram ListAccessKeys --UserName dev-zhangzijun|dev-xiangdong` 确认这两个 AK 是否仍 Active、以及是否与在用的 AK 相同 → 决定是否轮换。
- ⚠ 结构性风险（与坑 4 同源）：仓内存在大量 `.bak*`/`.workbuddy/backup/` 与 `deploy/logs/` 证据文件且被 Git 跟踪，叠加 Obsidian vault **自动提交并推送**（见记忆 `project-vault-backup-autocommit`）⇒ 一旦私钥/完整 AK 落到这些目录即被静默推送。建议把 `deploy/logs/`、`.workbuddy/`、`*.bak*` 加 `.gitignore` 并从索引移除（写操作，需授权）。

---

## #6 SQL 注入面 —— 判定：**通过（0 处不可信拼接）**

命令：`grep` 全仓 `\.Raw(`/`\.Exec(`/`\.Where(`/`\.Order(`/`\.Group(`/`\.Having(`/`\.Select(`/`clause.Expr`/`gorm.Expr`/`fmt.Sprintf`+SQL 关键字，并对 ORDER BY/LIMIT/表名/列名逐个回溯到 handler。

| 入口 | 站点数 | 全静态/占位符 | 常量插值 | **不可信拼接** | 待判 |
| --- | --- | --- | --- | --- | --- |
| `.Where(` | 473 | 433 | 40 | **0** | 0 |
| `.Order(` | 48 | 43 | 5 | **0** | 0 |
| `.Select(` | 72 | 66 | 6 | **0** | 0 |
| `.Raw(` | 19 | 18 | 1 | **0** | 0 |
| `.Exec(` | 24 | 18 | 6 | **0** | 0 |
| `.Group(` / `.Having(` | 4 / 1 | 全部字面量 | 0 | **0** | 0 |

关键安全机制（已定位到实现）：
- 排序白名单：`model/channel.go:80-123`、`model/user.go:22-67` 把请求 `sort_by/sort_order` 映射进 allowlist 后用 `clause.OrderByColumn`，未知键回落 `priority`/`id`；入口 `controller/channel.go:196`。
- 方言保留字用常量：`model/main.go:46-61` 的 `commonGroupCol/commonKeyCol/commonTrueVal/logGroupCol`（约 40 处消费）。
- ClickHouse 侧：`model/main.go:436-478` TTL 由 `%d` 注入**整型** env（`LOG_SQL_CLICKHOUSE_TTL_DAYS`，运维控制、非请求可控）；`model/log.go:106-108` 排序前缀全部为字面量。
- 迁移：`model/option_primary_key_migration.go:192,211` 有 `optionSafeIdent` 标识符白名单。

待判（2 项，均非注入）：
1. `model/user.go:472-483` `SearchUsers` 的 `keyword` 已绑定参数（无注入），但**未经 `sanitizeLikePattern`** ⇒ `%`/`_` 通配可致索引退化为全表扫（LIKE 型 DoS，非 SQLi）。入口 `controller/user.go` `GetUsers(c.Query("keyword"))`。
2. `migrations/*.sql`（6 个）无 Go 侧 runner，由运维工具执行 ⇒ 按设计不参数化，需线下确认执行通道。

测试覆盖：`model/clickhouse_log_test.go:70-125`、`model/task_plugin_test.go:146-166`、`model/locking_test.go:19`、`model/migration_dialector_test.go:154-157`。
⚠ 无任何测试断言"请求传入的 `sort_by` 无法越过 allowlist" —— 可补一条小回归测试（代码改动，另议）。

---

## #15 供应链 —— 判定：**通过（1 处例外）**

命令：`grep -nE "uses: |--frozen-lockfile|no-verify|skip" .github/workflows/*.yml` + `git ls-files`。

- 锁文件入仓 ✅：`go.mod/go.sum`、`relaykit/go.mod/go.sum`、`web/bun.lock`、`electron/package-lock.json`。
- 不跳过校验 ✅：`ci.yml:82`、`release.yml:41,95`、`electron-build.yml:50` 全部 `bun install --frozen-lockfile`；Go 侧未见 `GOFLAGS=-mod=mod`/`GONOSUMDB`/`GONOSUMCHECK`/`-no-verify`。
- 构建脚本来源固定 ✅（基本）：所有 `uses:` 均钉到**完整 commit SHA**（如 `actions/checkout@9c09b…# v7.0.0`）。
  ⚠ **例外 1 处**：`.github/workflows/docker-build.yml:140` = `uses: sigstore/cosign-installer@v3`（可变 tag，同文件 :93 已钉 SHA）。
- CI 含 `go vet` / `go build` / `make test` / `bun run typecheck` / `bun run test`；镜像侧有 cosign 签名步骤（`docker-build.yml:96`、`docker-image-branch.yml:117`）与 `sha256sum` 校验和（`release.yml:58,107`）。
- ⚠ **缺口**：CI **没有任何 SCA/密钥扫描步骤**（全仓 `.github/` grep `govulncheck|gitleaks|trivy|grype|snyk|npm audit|osv|dependabot` = 0 命中），也无 `dependabot.yml` ⇒ #2 依赖漏洞只能靠手工窗口跑，且 M4 之后无自动回归。
- ⚠ 外部 reusable workflow：`sync-release-to-gitcode.yml:240` 调 `nvdacn/sync_to_gitcode/...@18b7011…`（第三方仓、已钉 SHA）。

---

## #5 传输加密 —— 判定：**不通过（2 项硬缺口）** · 证据 `#5_#13_tls_cors_probe.log`

命令：`openssl s_client -tls1|-tls1_1|-tls1_2|-tls1_3`、逐弱套件 `-cipher` 尝试、`curl -D -` 头抽样（4 个入口 × 全量）。
⚠ 卡内指定工具 `nmap --script ssl-enum-ciphers` **本机不可用**（nmap 未装）⇒ 未产出 ssllabs 口径的 grade。

| 判据 | www.likha.hk | sg.likha.hk | likha.hk | img.likha.hk(OSS) |
| --- | --- | --- | --- | --- |
| TLS1.0 / 1.1 拒绝 | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| TLS1.2 | ✅ `ECDHE-RSA-AES128-GCM-SHA256` | ✅ 同 | ✅ 同 | ✅ 同 |
| TLS1.3 | ✅ | ✅ | ✅ | ❌ **REJECT（alert protocol version）** |
| 弱套件（NULL/EXP-RC4/RC4/3DES/AES*-SHA CBC） | 全拒 ✅ | 全拒 ✅ | 全拒 ✅ | ❌ **`AES128-SHA`、`AES256-SHA` 可用**（CBC 无前向保密） |
| 证书链 / 校验 | 3 块、`Verify return code: 0 (ok)`、`CN=*.likha.hk`、`issuer=Aliyun RSA TLS DV G1` | 同 | 同 | 同 |
| **HSTS** | ❌ **无 `Strict-Transport-Security`** | ❌ 无 | ❌ 无 | — |
| HTTP 强转 HTTPS | ✅ `301 → https` | ❌ **明文 200 OK，不跳转** | （见日志） | — |

根因（代码级）：
- HSTS：全仓 `grep -rni strict-transport` = **0 命中** ⇒ 应用不发；ALB 侧也没有该项。修复点待定（应用中间件 vs ALB/Ingress 注解），**不得凭印象先改**。
- sg 监听 80 未开强转（www 开了）⇒ 两地监听配置不一致，可在任务 24/40 的监听回读里核。

---

## #13 CORS —— 判定：**不通过（实测正是卡内禁止的组合）**

```
OPTIONS /api/status        → 204 + ACAO:* + ACAC:true + Allow-Headers:* + Allow-Methods:GET,POST,PUT,DELETE,OPTIONS + Max-Age:43200
OPTIONS /v1/models|/v1/chat/completions → 204 + 同上
GET /v1/models（带 Origin） → 401 + ACAO:* + ACAC:true        ← 实际响应也回了通配符
GET /api/status（带 Origin） → 200 + 无任何 ACAO
```

根因（代码级，已定位）：
- `middleware/cors.go:11-12`：`AllowAllOrigins = true` **且** `AllowCredentials = true` —— 卡内判据「禁 `*` + credentials」被字面违反；`cors.go:14` `AllowHeaders = ["*"]`。
- 挂载位置异常：`router/relay-router.go:16` 在 **engine 级** `router.Use(middleware.CORS())`，且 `router/main.go:16-18` 先 `SetApiRouter` 后 `SetRelayRouter` ⇒ `/api/*` 的业务路由注册时未含 CORS（所以带 Origin 的 GET 不回 ACAO），而 `/v1/*` 与 gin 重建的 no-method(OPTIONS) 链含 CORS。这是**行为与配置不一致**的隐患，不只是"通配符太宽"。
- 严重性评估（不夸大）：浏览器在 `ACAO:*` + `ACAC:true` 组合下**不会**携带 Cookie，故凭会话的跨站读取实际被浏览器挡住；真实暴露面是"任意站点可用持有者提供的 Key 读 `/v1/*` 响应"，属产品形态所需（浏览器端 SDK 直连）。但判据仍是字面不通过，且 `Allow-Headers:*` + 全方法放行放大了预检覆盖面。
- ⚠ 该文件是上游 new-api 代码，改动属 fork 级决策 ⇒ 需你裁定「改白名单回显」还是「出豁免单+风险接受人+复审日」。

---

## 本轮未做（缺工具，需另行授权安装或换通道）
- `gitleaks`（本轮用卡内允许的 `git log -p --all` 兜底，已覆盖同等判据）
- `govulncheck`、`bun install`/`npm audit`（WSL 无 node/bun）→ **#2 完全未取证**
- `nmap ssl-enum-ciphers` / `testssl.sh` → **#5 无 grade 结论**
- ACR 企业版镜像扫描结果 → 需云侧只读 API（`cr GetScanStatus` 等）
