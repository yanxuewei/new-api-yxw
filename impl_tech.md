# new-api 技术设计文档（impl_tech.md）

| 项目 | 内容 |
| --- | --- |
| 文档版本 | v1.0 |
| 编写日期 | 2026-09-19 |
| 适用代码基线 | 分支 `main`，commit `972aed197`（`fix(log): derive response model mismatch from names instead of a stored flag (#7464)`） |
| 目标读者 | 架构 / 后端 / 前端 / SRE / 运维 |
| 部署目标 | 阿里云（主：马尼拉 `ap-southeast-6`；次：曼谷 `ap-southeast-7`），主要服务菲律宾与泰国客户 |
| 可用性目标 | 系统整体 SLA ≥ **99.95%** |

> 说明：本文档所有事实均来自当前仓库代码的实际阅读，并在需要处标注 `文件:行号`。凡标注 **[现状]** 的是仓库中已经实现的能力；凡标注 **[需补建]** 的是当前工程缺失、需要在落地部署时补齐的能力。本章之外的"第九章 系统不足与改进措施"对二者做了完整清单化梳理，请勿混读。

---

## 目录

1. [系统概述与设计目标](#一系统概述与设计目标)
2. [整体分层架构设计](#二整体分层架构设计)
3. [代码目录结构设计](#三代码目录结构设计)
4. [数据存储结构设计](#四数据存储结构设计)
5. [核心业务逻辑时序图](#五核心业务逻辑时序图)
6. [日志 / 监控 / 限流 / 灰度 / 回滚能力设计](#六日志--监控--限流--灰度--回滚能力设计)
7. [阿里云部署方案（菲律宾 + 泰国）](#七阿里云部署方案菲律宾--泰国)
8. [SLA 99.95% 达成方案](#八sla-9995-达成方案)
9. [系统不足与改进措施](#九系统不足与改进措施)
10. [附录](#十附录)
11. [附录A：阿里云负载均衡选型与使用指南（ALB / NLB / CLB）](#附录a阿里云负载均衡选型与使用指南alb--nlb--clb)
12. [附录B：主节点故障容灾设计](#附录b主节点故障容灾设计)

---

## 一、系统概述与设计目标

### 1.1 系统定位

new-api 是一个 **AI 模型 API 网关 / 代理**（Go + React 单体可执行程序），核心职责：

- **协议聚合**：将 40+ 上游 AI 供应商（OpenAI、Anthropic Claude、Google Gemini、Azure OpenAI、AWS Bedrock、阿里通义、字节豆包、Kling、Vidu、Sora 等）统一为 OpenAI / Claude / Gemini 三套兼容协议对外提供。
- **流量治理**：多渠道路由（优先级 + 权重 + 标签 + 约束）、会话亲和、自动失败重试、故障渠道自动禁用与恢复。
- **账号与计费**：用户 / 令牌（API Key）体系、按 token / 按次 / 表达式分档计费、钱包额度与订阅额度双资金源、充值与退款、消耗明细。
- **控制台**：渠道管理、模型定价、用量看板、性能指标、日志与审计、系统设置热更新。
- **异步任务**：视频 / 图片 / 音乐等长任务的提交、轮询、结算与产物下载；JS 插件（Sobek 沙箱）扩展任务协议。

### 1.2 关键工程特征（决定架构设计的事实）

| 特征 | 事实依据 | 架构含义 |
| --- | --- | --- |
| 前后端合并为单一二进制 | `main.go:44` `//go:embed web/dist`；`router/web-router.go:22` 由 `common.EmbedFolder` 提供静态资源 | 灰度 / 回滚粒度是"整个应用版本"，无法独立发布前端；镜像即应用 |
| 无独立注册中心、无服务发现 | 全仓库无 Nacos/Consul/etcd 依赖 | 多实例之间靠 **数据库轮询 + Redis** 达成一致，水平扩容即可线性扩展 |
| 配置热更新靠轮询 | `main.go:115` `go model.SyncOptions(common.SyncFrequency)`；`model/option.go:222`；默认 `SYNC_FREQUENCY=60` | 配置变更最大 **60 秒** 收敛窗口；灰度开关可用，但不是秒级 |
| 缓存一致性靠轮询，唯一 pub/sub 是 WebSocket 关闭广播 | `model/channel_cache.go:109`、`pkg/wsmanager/wsmanager.go:113-155` | 渠道禁用可在秒级踢掉长连接，但路由表变更最长滞后 60 秒 |
| 定时任务用数据库租约去重 | `model/system_task.go:28-51`、`service/system_task.go:263`，锁 TTL 60s、心跳 TTL/3 | 多实例安全，滚动发布不会重复扣费/重复轮询 |
| 迁移只在 master 节点执行 | `model/main.go:262-267`，`common.IsMasterNode = NODE_TYPE != "slave"`（`common/init.go:89`） | 滚动发布时必须保证 master 先起，否则 schema 落后 |
| 无 `/health`、`/metrics` 端点 | 全仓库唯一 prometheus import 是探测上游能力（`controller/channel_inference.go:20`） | K8s 探针只能用 `GET /api/status`；Prometheus 抓取需自建 exporter |
| 上游无熔断器、无并发信号量 | 无 `breaker` 符号；仅优先级轮转 + `RetryTimes` | 单渠道故障时表现为"重试放大"，需要自建熔断（见第九章） |
| JSON 统一走 `common.Marshal/Unmarshal` | `common/json.go`，AGENTS.md 强制 | 编解码行为可控（数字精度、`GetJsonType`） |
| 三数据库同时支持（SQLite/MySQL/PG）+ ClickHouse 仅日志库 | `common/database.go:3-10`、`model/main.go:120-149` | 生产可选 MySQL 或 PG；日志可下沉 ClickHouse |

### 1.3 设计目标与量化指标

| 维度 | 目标值 | 校验方式 |
| --- | --- | --- |
| 可用性 SLA | ≥ 99.95%（月度不可用预算 ≤ 21.9 分钟） | SLO 燃尽图 + `/api/status` 外部拨测 |
| 网关自身延迟开销 | P99 网关内耗时（不含上游）≤ 80 ms | `perf_metrics` 的 `latency` 减去上游耗时 |
| 首 token 延迟（TTFT）增量 | 网关新增 ≤ 20 ms（流式） | `perf_metrics` 的 `ttft` 指标 |
| 单实例容量 | ≥ 1,500 并发 SSE 长连接、≥ 800 QPS 管理面请求 | 压测基线（见 3.9） |
| 数据一致性 | 计费误差 = 0（额度不超扣、不重复扣） | `subscription_pre_consume_records.request_id` 唯一索引 + 对账任务 |
| 配置收敛时间 | ≤ 60 s（现网默认），关键开关目标 ≤ 10 s | 灰度开关演练 |
| 故障恢复 RTO / RPO | RTO ≤ 5 min（回滚）/ RPO ≤ 0（RDS 主备 + binlog/WAL 归档） | 演练 |
| 区域延迟 | 菲律宾用户 RTT ≤ 15 ms，泰国用户 RTT ≤ 45 ms | 阿里云地域选择 + GA |

---

## 二、整体分层架构设计

### 2.1 分层架构图

```mermaid
flowchart TB
  subgraph CL["客户端"]
    CUST["业务客户 SDK<br/>OpenAI/Claude/Gemini 客户端"]
    ADMIN["管理员与用户浏览器<br/>React 19 SPA"]
  end

  subgraph L1["L1 接入层 阿里云托管"]
    DNS["云解析 DNS + 全局加速 GA"]
    CDN["CDN/DCDN 静态加速"]
    WAF["WAF 3.0"]
    ALB["ALB 七层负载均衡<br/>TLS 卸载 / 多可用区 / 灰度权重"]
  end

  subgraph L2["L2 传输与会话层 Gin Engine"]
    MW0["RequestId / Version / I18n / Recovery<br/>ConfigureTrustedProxies / SetUpLogger / StatsMiddleware"]
  end

  subgraph L3["L3 认证与流量治理层"]
    AUTH["TokenAuth 令牌鉴权<br/>UserAuth / AdminAuth / RootAuth"]
    RBAC["Casbin authz 权限策略"]
    RL["全局限流 / 模型维度限流 / 关键接口限流"]
    SHED["系统负载保护 PerformanceCheck 503"]
    AUDIT["管理面审计中间件"]
  end

  subgraph L4["L4 路由分发层"]
    DIST["Distribute 中间件<br/>模型解析 / 令牌白名单 / 分组校验"]
    SELECT["渠道选择<br/>优先级分层 + 权重随机 + 会话亲和 + 约束过滤"]
  end

  subgraph L5["L5 协议转换与中继层"]
    HANDLER["relay handlers<br/>chat/claude/gemini/responses/image/audio/rerank"]
    KIT["relaykit 独立模块<br/>DTO + 双向协议转换"]
    STREAM["StreamScanner / SSE 写出"]
    WSM["wsmanager 上游 WebSocket 复用"]
    PLUGIN["jsplugin Sobek 沙箱<br/>异步任务协议插件"]
  end

  subgraph L6["L6 计费与结算层"]
    PRICE["价格计算 price / ratio / tiered"]
    EXPR["billingexpr 表达式引擎"]
    SESSION["BillingSession 预扣 / 结算 / 退款"]
  end

  subgraph L7["L7 业务服务层"]
    CTRL["controller 约 100+ 文件"]
    SVC["service 约 60+ 文件"]
  end

  subgraph L8["L8 领域模型与数据访问层"]
    MODEL["model GORM 实体与仓储"]
    CACHE["内存缓存 + cachex 混合缓存"]
  end

  subgraph L9["L9 存储与中间件层"]
    RDS["RDS PostgreSQL 或 MySQL 高可用版"]
    TAIR["Tair / Redis 集群"]
    CK["云数据库 ClickHouse 日志库"]
    OSS["OSS 对象存储 产物与缓存"]
  end

  subgraph L10["L10 后台任务层"]
    RUNNER["system_task runner<br/>DB 租约 + 运行历史"]
    JOBS["渠道自动测试 / 上游模型同步<br/>异步任务轮询 / 日志清理"]
  end

  subgraph L11["L11 可观测层"]
    LOG["分级日志 + 请求 ID + 审计"]
    PERFM["perf_metrics 指标<br/>模型 x 分组 x 时间桶"]
    PROM["Prometheus + Grafana + ARMS/SLS 需补建"]
  end

  CUST --> DNS --> ALB
  ADMIN --> DNS
  DNS --> CDN --> OSS
  WAF --> ALB
  ALB -->|"L7 转发"| MW0
  MW0 --> AUTH --> RBAC --> RL --> SHED
  SHED --> DIST
  DIST --> SELECT
  SELECT --> HANDLER
  HANDLER --> KIT
  HANDLER --> PLUGIN
  HANDLER --> STREAM
  HANDLER --> WSM
  HANDLER --> PRICE
  PRICE --> EXPR
  PRICE --> SESSION
  MW0 --> CTRL --> SVC --> MODEL
  SESSION --> MODEL
  MODEL --> CACHE
  MODEL --> RDS
  CACHE --> TAIR
  MODEL --> CK
  STREAM -->|"SSE 回吐"| CUST
  RUNNER --> JOBS
  JOBS --> MODEL
  RUNNER --> TAIR
  SESSION --> OSS
  LOG --> MW0
  PERFM --> HANDLER
  PROM --> LOG
  PROM --> PERFM
  PROM --> ALB
```

### 2.2 每一层的职责说明

#### L1 接入层（阿里云托管服务，非代码层）

| 组件 | 职责 | 关键设计 |
| --- | --- | --- |
| 云解析 DNS + 全球加速 GA | 菲律宾 / 泰国用户就近接入 | 菲律宾用户解析到马尼拉 `ap-southeast-6`，泰国用户解析到曼谷 `ap-southeast-7`；GA 用于跨境回源加速 |
| CDN / DCDN | `web/dist` 静态资源加速 | 注意 **[现状]** `middleware/cache.go:14` 使用硬编码 `Cache-Version` SHA 做缓存失效，每次发布必须手工 bump，否则 SPA 白屏 |
| WAF 3.0 | CC 防护、SQLi/XSS、IP 黑名单 | 必须放行 `POST /api/user/epay/notify`、`/api/stripe/webhook` 等回调路径（无鉴权、带签名校验） |
| ALB | 七层负载均衡、TLS 卸载、按权重灰度 | SSE 不断流**不靠**调大超时：ALB listener `idleTimeout` 上限仅 60 s、`requestTimeout` 上限 180 s，且只能在 `AlbConfig` CRD 配置，无对应 Ingress 注解；必须开启网关心跳 ping（默认关闭，间隔须设 15–20 s）并保证首包延迟远小于 180 s，详见附录A |
| KMS / Secrets Manager | `SQL_DSN`、`SESSION_SECRET`、上游 key 的密文托管 | **[现状]** 渠道 key 明文存 `channels.key`，改进见第九章 R-13 |

**协议约束**：网关自身只做 HTTP/1.1 + SSE 与 WebSocket。ALB 的 HTTP/HTTPS 监听对 WS/WSS 透明，但长连接仍受 listener 60 s idle 上限约束，保活依赖应用层心跳；Realtime 若引入 UDP 流量，ALB 无 UDP 监听，必须走 NLB。网关优雅停机需与 ALB 连接优雅摘除（connection drain）时间窗对齐，参考 `SHUTDOWN_TIMEOUT_SECONDS`（默认 120 s，`main.go:236`）。详见附录A。

#### L2 传输与会话层（`main.go` + `middleware/`）

启动期装配顺序（`main.go:181-204`）：

```
gin.New()
  -> ConfigureTrustedProxies        信任代理白名单，防 IP 伪造
  -> gin.CustomRecovery             panic 转 500，返回 type=new_api_panic
  -> middleware.RequestId()         生成并回写 X-Oneapi-Request-Id
  -> middleware.Version()           版本信息注入上下文
  -> middleware.I18n()              按 Accept-Language / 用户偏好解析语言
  -> middleware.SetUpLogger(server) gin.LoggerWithFormatter 访问日志
  -> (可选) Umami / GA 脚本注入 indexPage
```

该层职责：连接计数（`middleware/stats.go` 的 `activeConnections` 是唯一实时连接指标）、请求体落盘与清理（`middleware/body_cleanup.go:11` 的 `BodyStorageCleanup`，配合 `common.GetBodyStorage` 支持重试重放）、解压请求（`DecompressRequestMiddleware`）、全局响应体上限（`MAX_REQUEST_BODY_MB` 默认 128）。

**重要陷阱**：`router/main.go:16-22` 先注册 `/api/*` 再注册 `/v1/*`，而 `router/relay-router.go:16-19` 用 **engine 级 `router.Use`** 挂 CORS/解压/BodyCleanup/Stats。Gin 在注册路由时快照中间件链，因此这四个中间件 **只作用于其后注册的 relay/task/video 路由**，`/api/*` 需要在 `router/api-router.go:20` 自行挂 `BodyStorageCleanup`。新增路由组时必须显式确认中间件链。

#### L3 认证与流量治理层

| 子能力 | 实现 | 说明 |
| --- | --- | --- |
| 令牌鉴权 | `middleware/auth.go:361 TokenAuth()` | 支持 `Authorization: Bearer`、`sk-` 前缀、Anthropic `x-api-key`、Gemini `?key=`、OpenAI Realtime 子协议 `openai-insecure-api-key.<key>` |
| 令牌缓存与围栏 | `model/token_cache.go:94`，Redis `token:<HMAC(key)>`，写操作前先抬 `token:fence:<HMAC>`（TTL 10 s） | 防止读到"变更前的旧快照又被回写" |
| 控制台会话 | `service/auth_session.go` + `model/user_session.go`（`sid varchar(64)` 主键、refresh token 哈希、`status active/revoking/revoked`） | Cookie Refresh + Bearer Access，`auth_version` 做全局失效 |
| 渠道 pin | `middleware/auth.go:543`，token 第二段 `parts[1]` 作为管理员 pin 渠道 | 便于压测与故障定位，也是灰度定点验证手段 |
| RBAC | `service/authz/`（Casbin `SyncedEnforcer`）+ `casbin_rule` 表 + `authz_roles`；策略 60 s 重载（`main.go:119`） | 管理面细粒度权限 |
| 限流 | 见 6.4 | 固定窗口（Redis Lua）+ 令牌桶 + 内存滑动窗口三级 |
| 过载保护 | `middleware/performance.go:41` | CPU/内存/磁盘超阈值直接 503，错误类型 `system_cpu_overloaded` 等 |
| 管理面审计 | `middleware/audit.go:101` | 挂在 `authHelper` 内，AdminAuth/RootAuth 的写路由自动审计，响应体最多缓冲 64 KiB |

#### L4 路由分发层（`middleware/distributor.go` + `service/channel_select.go`）

职责链：`GetChannelConstraints` → `getModelRequest`（gjson 从请求体读 `model`/`group`，然后 `Seek(0)` 重置 body）→ 令牌模型白名单 `TokenModelLimitAllows` → `SelectChannelForRequest`（pin → 亲和 → `CacheGetRandomSatisfiedChannel`）→ `SetupContextForSelectedChannel`（注入渠道 key / baseURL / param_override，多 key 轮询 `GetNextEnabledKey`）。

选择算法（`model/ability.go:108-158`，内存版在 `model/channel_cache.go:117`）：

1. 按 `group + model + enabled` 过滤（`abilities` 复合主键 `(group, model, channel_id)`）。
2. 约束过滤（`filterAbilitiesByConstraints:169`，任务插件身份不匹配时 **fail-closed**）。
3. 优先级分层：distinct priority 降序，第 N 次重试取第 N 层；重试耗尽后钳制到最低层。
4. 层内加权随机：槽位 = `weight + 10`，`weight=0` 仍有基线流量。

#### L5 协议转换与中继层

- `relay/` 是宿主侧中继核心：各格式 handler（`compatible_handler.go`、`claude_handler.go`、`gemini_handler.go`、`responses_handler.go`、`image_handler.go`、`audio_handler.go`、`rerank_handler.go`、`relay_task.go`）+ `channel/`（各供应商适配器）+ `helper/`（校验、价格、流扫描）。
- `relaykit/` 是 **独立 Go module**（`relaykit/go.mod`，root 通过 `replace` 引用），只放 DTO 与协议转换，禁止依赖宿主模块（AGENTS.md 强制，验证命令 `cd relaykit && GOWORK=off go build ./...`）。日志钩子由宿主在 `main.go` 用 `kitutil.SetLogging` 注入，保持解耦。
- `pkg/wsmanager/` 管理上游 WebSocket 复用与广播关闭；`pkg/jsplugin/` 用 Sobek 运行任务协议插件（`plugins/tasks/<vendor>/plugin.js`，共 10 个插件、约 5,217 行），沙箱只注入 `utils`（`jwtSignHS256`/`hmacSHA256`/`volcSignV4`/`uuid`/`json.clone`/`unixNow` 等），**不注入 fetch**，HTTP 由宿主发起（`pkg/jsplugin/request.go` 有 SSRF 校验 `ValidateRequestURL`）。

#### L6 计费与结算层

`service/billing.go` + `service/billing_session.go` + `service/quota.go` + `service/text_quota.go` + `pkg/billingexpr/`。三种资金源顺序由 `subscription_first` / `wallet_first` 策略决定；预扣 → 结算 → 退款全部以 `request_id` 幂等（`subscription_pre_consume_records.request_id` 唯一索引）。表达式分档计费由 `billingexpr`（expr-lang）编译并缓存哈希（`ExprHashString`），黄金样例在 `pkg/billingexpr/testdata/`。

#### L7 业务服务层 / L8 领域模型层

`controller/` 只做参数与响应编排，业务规则在 `service/`，数据访问与缓存在 `model/`。`model/` 同时承担仓储、缓存、状态机（渠道状态 1 启用 / 2 手动禁用 / 3 自动禁用）与迁移职责，是本项目最厚的一层。

#### L9 存储与中间件层

见第四章。核心是"主库（业务+配置+计费）+ 日志库（可分离，支持 ClickHouse）+ Redis（缓存/限流/指标）+ OSS（产物）"四块。

#### L10 后台任务层

`controller.RegisterScheduledSystemTasks()` + `service.StartSystemTaskRunner()`（`main.go:158-159`）。任务类型含渠道自动测试、上游模型同步、异步任务轮询、日志清理。并发安全靠 `system_task_locks`（**主键 = 任务类型**）的条件更新租约：抢占只允许 `locked_until < now`，心跳每 `TTL/3` 续租，续租失败返回 `ErrSystemTaskLockLost` 取消处理器。调度节拍：空闲轮询 15 s、锁 TTL 60 s、scheduler 15 s、过期锁清扫 30 s。

#### L11 可观测层

见第六章。**[现状]** 该层只有"内部自研指标 + 文件日志 + 数据库日志"，没有对外指标暴露，是达成 99.95% SLA 的主要短板之一。

---

## 三、代码目录结构设计

### 3.1 仓库总体结构

```
new-api-yxw/
├── main.go                     进程入口：初始化 + 中间件装配 + 优雅关闭
├── go.mod / go.sum             根模块 Go 1.25.1（镜像用 1.26.1）
├── go.work*                    workspace（relaykit 以 replace 接入）
├── makefile                    build-web / start-api / dev / test / reset-setup
├── Dockerfile                  三阶段构建（bun 前端 -> go 编译 -> debian-slim 运行）
├── Dockerfile.dev              开发镜像
├── docker-compose.yml          生产参考编排（new-api + redis + postgres，可选 mysql/clickhouse）
├── docker-compose.dev.yml      本地开发编排（含挂载源码热重建）
├── new-api.service             systemd 单元（裸机部署）
├── VERSION                     版本文件（当前为空，见第九章 R-02）
├── AGENTS.md / CLAUDE.md       工程规约（含计费、认证 OWASP、三数据库强制要求）
├── README.{md,en,fr,ja,zh_CN,zh_TW}.md
├── LICENSE / NOTICE / THIRD-PARTY-LICENSES.md
│
├── router/                     路由层：URL -> 中间件链 -> controller
├── middleware/                 横切层：认证/限流/审计/压缩/过载/请求 ID/i18n
├── controller/                 接口编排层（约 100+ 文件）
├── service/                    业务服务层（约 60+ 文件），含 service/authz/
├── model/                      领域模型 + GORM 仓储 + 内存缓存 + 迁移
├── relay/                      中继核心（handler + channel 适配器 + helper）
├── relaykit/                   独立子模块：DTO + 协议转换
├── dto/                        请求/响应数据传输对象（供应商专有协议）
├── types/                      跨层公共类型（PriceData、task_artifact、set、rw_map）
├── common/                     基础设施：环境、日志、JSON、Redis、DB、限流、加密、缓存文件
├── constant/                   常量：API 类型、渠道类型、缓存 key、上下文 key、任务
├── setting/                    可热更新配置域（billing/ratio/model/operation/perf/performance/task_pricing…）
├── logger/                     日志器实现（级别、文件轮转）
├── i18n/                       后端多语言（en/zh）
├── oauth/                      OAuth/OIDC 供应商抽象与自定义 provider 加载
├── pkg/                        可复用库：billingexpr / cachex / jsplugin / perf_metrics / wsmanager / ionet
├── plugins/                    JS 任务插件（embed.go + tasks/<vendor>/plugin.js）
├── e2e/                        Go 端到端测试（文档解析插件全链路）
├── web/                        React 19 前端（Rsbuild）
├── electron/                   桌面端封装
├── docs/                       设计与接口文档
├── bin/                        历史 SQL 迁移脚本 + time_test.sh
└── .github/workflows/          CI/CD：ci / docker-build / release / electron-build 等
```

### 3.2 后端逻辑分层（Go 模块内）

| 层 | 目录 | 依赖方向 | 代表文件 | 说明 |
| --- | --- | --- | --- | --- |
| 入口 | 根 | -> router/service/model/pkg | `main.go` | `InitResources()` 依次加载<br>`.env`<br>`common.InitEnv`<br>logger<br>ratio_setting<br>HTTP client<br>token encoder<br>`model.InitDB`<br>`authz.Init`<br>`CheckSetup`<br>`InitOptionMap`<br>`InitLogDB`<br>`common.InitRedisClient`<br>`perfmetrics.Init`<br>`StartSystemMonitor`<br>i18n<br>oauth 自定义 provider<br>`StartAuthArtifactCleanup` |
| 路由 | `router/` | -> middleware, controller | `api-router.go`<br>`relay-router.go`<br>`video-router.go`<br>`task-router.go`<br>`plugin-router.go`<br>`task-plugin-protocol-router.go`<br>`dashboard.go`<br>`web-router.go`<br>`channel-router.go`<br>`authz-router.go` | 每个 router 均有同名 `*_test.go` 断言中间件链与权限（如 `relay_router_test.go`、`task_router_test.go`） |
| 中间件 | `middleware/` | -> model, service | `auth.go`(约 600 行)<br>`distributor.go`<br>`rate-limit.go`<br>`model-rate-limit.go`<br>`audit.go`<br>`performance.go`<br>`secure_verification.go`<br>`task_artifact_access.go`<br>`trusted_proxies.go` | 每个安全/限流中间件都配 `*_test.go` |
| 控制器 | `controller/` | -> service, model | `relay.go`(重试主循环)<br>`channel*.go`<br>`topup*.go`<br>`option.go`<br>`perf_metrics.go`<br>`system_task*.go`<br>`user.go`<br>`twofa.go` | 只做编排；管理端点约 250+ 条路由 |
| 服务 | `service/` | -> model, pkg, relaykit | `channel_select.go`<br>`relay_error.go`(重试决策)<br>`billing_session.go`<br>`quota.go`<br>`text_quota.go`<br>`task_billing.go`<br>`tiered_settle.go`<br>`channel_affinity.go`<br>`system_task.go`<br>`http_client.go` | 业务规则集中地；`authz/` 子包封装 Casbin |
| 模型 | `model/` | -> common, constant | `user.go`<br>`token.go`<br>`channel.go`<br>`ability.go`<br>`log.go`<br>`audit_log.go`<br>`task.go`<br>`topup.go`<br>`subscription.go`<br>`option.go`<br>`main.go`(连接与迁移)<br>`system_task.go`<br>`locking.go` | 含 `lockForUpdate` 方言封装（SQLite 跳过 `FOR UPDATE`） |
| 中继 | `relay/` | -> relaykit, setting, common | `relay_adaptor.go`(供应商工厂)<br>`helper/price.go`<br>`helper/valid_request.go`<br>`helper/stream_scanner.go`<br>`request_billing.go`<br>`channel/`(40+ 子目录) | `streamSupportedChannels` 决定 `StreamOptions` 是否透传 |
| 转换 | `relaykit/` | 独立模块 | `dto/`(35 文件)<br>`types/`(8)<br>`relayconvert/`(注册表 + internal/{oai_chat,oai_responses,claude_messages,gemini_chat,toolconv,media})<br>`reasonmap/`<br>`kitutil/` | 有 `testdata/golden` 黄金转换用例 |
| 基础设施 | `common/` | 无业务依赖 | `json.go`<br>`database.go`<br>`redis.go`<br>`sys_log.go`<br>`rate-limit.go`<br>`body_storage.go`<br>`disk_cache.go`<br>`node_identity.go`<br>`system_monitor.go`<br>`pprof.go`<br>`password_crypto.go`<br>`crypto.go`<br>`embed-file-system.go`<br>`gin.go`<br>`page_info.go` | 全项目 JSON 必须走 `common.Marshal/Unmarshal/DecodeJson/GetJsonType` |
| 配置 | `setting/` + `constant/` + `types/` | -> common | `setting/rate_limit.go`<br>`setting/operation_setting/`<br>`setting/billing_setting/`<br>`setting/ratio_setting/`<br>`setting/perf_metrics_setting/`<br>`setting/performance_setting/`<br>`setting/task_pricing_setting/` | `setting.*` 结构体由 `model.handleConfigUpdate` 从 `options` 反序列化，支持热更新 |
| 可观测 | `logger/` + `pkg/perf_metrics/` | -> common | `logger/logger.go`<br>`pkg/perf_metrics/{metrics,flush,outcome,types}.go` | 见第六章 |
| 插件运行时 | `pkg/jsplugin/` + `plugins/` | -> common | `engine.go`(池化 Sobek runtime + watchdog + 信号量)<br>`registry.go`<br>`routing.go`<br>`utils.go`(注入全局 `utils`)<br>`cli.go`(`./new-api plugin …`)<br>`request.go`(SSRF 校验) | 契约文档 `docs/plugin-api/v1.md` + `v1.schema.json` + `v1.d.ts` |

### 3.3 前端目录结构（`web/`，共 1,346 个源文件）

```
web/
├── rsbuild.config.ts        Rsbuild 2 构建；dev proxy /api,/v1,/mj,/pg -> VITE_REACT_APP_SERVER_URL
├── vitest.config.ts         jsdom 环境，testTimeout 20s
├── components.json          shadcn 配置
├── .oxlintrc.json           oxlint 规则，含自定义 project/intl-locale 规则
├── oxfmt / cz.yaml / knip.config.ts / netlify.toml / .node-version
├── scripts/                 oxlint 自定义规则实现与用例、版权头脚本、i18n 同步
├── index.html               内含 <!--umami--> / <!--Google Analytics--> 占位符，由 Go 注入
├── public/
└── src/
    ├── main.tsx             createRouter(routeTree, context:{queryClient}, defaultPreload:'intent')
    ├── routeTree.gen.ts     自动生成的路由树（62 KB）
    ├── routes/    (64)      TanStack Router 文件式路由：(auth)/ (errors)/ _authenticated/ + 顶层公开页
    ├── features/  (910)     业务模块（见 3.4）
    ├── components/(235)     共享组件：ui/ layout/ data-table/ ai-elements/ floating-window/
    │                        json-code-editor/ model-group-selector/ multi-select/ + confirm-dialog 等业务封装
    ├── lib/       (50)      http-client.ts(axios 单例 + GET 去重 + 401 刷新) api.ts auth-session.ts
    │                        query-client.ts handle-server-error.ts currency.ts format.ts roles.ts nav-modules.ts
    ├── stores/    (4)       auth-store / system-config-store / notification-store / pricing-preferences-store
    ├── hooks/     (22)      use-admin / use-system-config / use-sidebar-* / use-table-url-state / __tests__/
    ├── i18n/      (10)      config.ts languages.ts(toIntlLocale) static-keys.ts locales/{en,zh,zh-TW,fr,ru,ja,vi}.json
    ├── context/   (6)       theme/font/direction/layout/search/theme-customization provider
    ├── config/    (1)       fonts.ts
    ├── styles/    (3)       Tailwind 4 主题与 CSS 变量
    └── assets/    (36)
```

**前端分层约定**（`web/AGENTS.md`）：routes（页面装配与鉴权守卫）→ features（业务模块）→ components（共享 UI）→ lib（技术设施/HTTP/i18n/格式化）→ stores（跨页状态）。每个 feature 目录固定为 `api.ts / types.ts / constants.ts / components/ / lib/ / hooks/ / index.tsx / __tests__/`。

### 3.4 前端业务模块清单（`web/src/features/`，按文件数）

| 模块 | 文件数 | 职责 |
| --- | --- | --- |
| `system-settings` | 167 | 全站设置中心（计费、限流、认证、性能、模型、支付、任务插件等 option 面板） |
| `channels` | 99 | 渠道 CRUD、多 key、模型测试、上游模型同步、健康与自动禁用状态 |
| `usage-logs` | 76 | 消耗/错误/登录/审计日志查询与导出 |
| `pricing` | 62 | 模型价格与分组倍率展示 |
| `models` | 54 | 模型元数据、供应商、端点、命名规则 |
| `auth` | 53 | 登录/注册/OAuth/OTP/找回密码 |
| `task-plugins` | 51 | JS 任务插件管理、协议声明、路由绑定 |
| `playground` | 49 | 在线调试台（SSE） |
| `dashboard` | 38 | 用量看板与 VChart 图表 |
| `security` | 31 | MFA、Passkey、会话管理、账号安全 |
| `keys` | 30 | API 令牌 CRUD |
| `wallet` | 30 | 充值、兑换码、订阅、账单 |
| `home` / `redemption-codes` / `users` | 21 / 21 / 21 | 首页、兑换码、用户管理 |
| `subscriptions` / `profile` / `rankings` | 18 / 16 / 14 | 订阅、个人主页、排行 |
| `model-pricing` / `setup` / `system-info` / `system-update` | 11 / 9 / 9 / 8 | 定价配置、初始化向导、实例列表、系统更新 |
| `legal` / `errors` / `chat` / `performance-metrics` / `about` | 6 / 5 / 4 / 4 / 3 | 法务页、错误页、聊天、性能指标面板、关于 |

### 3.5 测试设计

| 层级 | 位置 | 规模 | 技术 | 运行方式 |
| --- | --- | --- | --- | --- |
| Go 单元/集成测试 | 各后端包内 `*_test.go` | **278 个文件** | `testify/require` + `assert`、`httptest`、内存 SQLite（`glebarez/sqlite`）、GORM | `make test`（分根模块与 `relaykit` 两次 `GOWORK=off go test`） |
| 路由与中间件契约测试 | `router/*_test.go`、`middleware/*_test.go` | 覆盖 relay/task/plugin/channel/auth/rate-limit | 断言中间件顺序与权限门槛 | 同上 |
| 计费黄金用例 | `pkg/billingexpr/testdata/`、`service/tiered_settle_test.go` | 表达式编译与分档结算 | 精确期望值表驱动 | 同上 |
| 协议转换黄金用例 | `relaykit/relayconvert/testdata/golden` | 三协议双向转换 | 快照比对 | `cd relaykit && GOWORK=off go test ./...` |
| E2E | `e2e/doc_parse_test.go` | **仅 1 个文件 / 1 个用例** | Go + 真实 gin 中间件栈 + 内联 JS 插件，跑通"提交→批量查询→产物→内容代理" | `go test ./e2e/...` |
| 前端单测 | `web/src/**/*.test.ts(x)` | **153 个文件**，统一放模块内 `__tests__/` | Vitest + React Testing Library + jsdom | `cd web && bun run test` |
| 前端行为契约 | 组件交互、可访问性、i18n、locale 格式化 | `web/scripts/oxlint/__tests__/` | 自定义 lint 规则 `project/intl-locale`（禁止把 `zhCN` 传入 `Intl.*`） | `bun run lint` |
| 三数据库矩阵 | **[需补建]** | AGENTS.md 要求任何 DB 行为变更必须在真实 SQLite/MySQL/PG 上跑，且记录版本与结果 | 建议 CI job 矩阵 + 日志库 ClickHouse | 见 7.9 |

**测试原则（AGENTS.md 强制）**：不写"只为提升覆盖率"的测试；不写依赖随机输入/固定 sleep/仅打印日志的假压测与假 fuzz；表驱动 + 显式 fixture + 精确期望输出；小改动禁止在 `controller/`、`service/`、`setting/` 各层散落新测试文件。

### 3.6 文档设计

| 路径 | 内容 |
| --- | --- |
| `AGENTS.md` / `CLAUDE.md`（26 KB） | 工程规约总纲：现代 Go 惯用法、relaykit 独立性、JSON 封装、三数据库兼容、OWASP 认证强制要求、计费读取门禁、前后端规则、Issue/PR 流程 |
| `.agents/rules/billing.md` | 计费表达式、内置定价、安全不变量、上游响应派生可计费量（改动计费相关代码前必须完整阅读） |
| `.agents/github/ISSUE.md`、`.agents/github/PR.md` | Issue / PR 模板与拒答范围 |
| `.agents/skills/` | i18n-translate、shadcn-ui（含 vendor 规则 base-vs-radix/composition/forms/icons/styling）、vercel-react-best-practices |
| `docs/authentication.md`（18 KB） | 认证与会话设计 |
| `docs/plugin-api/v1.md` + `v1.schema.json` + `v1.d.ts` + `README.md` | 任务插件契约 v1：`meta` / `buildSubmitRequest` / `parseSubmitResponse` / `buildQueryRequest` 或 `buildBatchQueryRequest` / `parseTaskResult` / `listArtifacts` / `buildContentRequest` / `meta.routes` / `meta.protocols`、能力协商、SSE 轮询契约 |
| `docs/openapi/api.json`、`docs/openapi/relay.json` | 管理面与中继面 OpenAPI |
| `docs/channel/other_setting.md` | 渠道 `other_info` 字段说明 |
| `docs/installation/BT.md` | 宝塔部署 |
| `docs/ionet-client.md`、`docs/translation-glossary*.md` | IoNet 客户端、翻译术语表（en/zh/fr/ru） |
| `web/AGENTS.md`（23 KB） | 前端规范：i18n、组件复用强制检索、测试细则、构建部署 |
| `relaykit/README.md` | relaykit 能力矩阵、安装、快速开始、转换上下文、多模态内容、版本兼容性 |
| `README.{md,zh_CN,zh_TW,en,fr,ja}` | 面向用户的多语言说明（**受保护的品牌与组织署名信息，禁止修改**） |

### 3.7 工具链

| 类别 | 工具 | 命令 |
| --- | --- | --- |
| 前端包管理 | **Bun 1.4.0**（优先于 npm/yarn/pnpm） | `bun install` / `bun run dev` / `bun run build` |
| 前端类型检查 | `@typescript/native-preview`（`tsgo`） | `cd web && bun run typecheck` / `bun run build:check` |
| 前端 Lint / 格式 | oxlint（含自定义规则）+ oxfmt + knip（死代码） | `bun run lint` / `bun run format` / `bun run knip` |
| 前端 i18n | `i18n:sync` 脚本，扁平 JSON，英文原句作 key | `cd web && bun run i18n:sync` |
| 提交规范 | commitizen（`cz.yaml`） | `git cz` |
| Go 构建 | Go 1.25.1（镜像 1.26.1，`GOEXPERIMENT=greenteagc`，`CGO_ENABLED=0`） | `go build -ldflags "-s -w -X common.Version=$(cat VERSION)"` |
| 插件 CLI | Sobek + 自研 CLI | `./new-api plugin <子命令>`（`main.go:50` -> `jsplugin.RunCLI`） |
| 性能剖析 | pprof（`ENABLE_PPROF=true` -> `0.0.0.0:8005`）+ Pyroscope（`StartPyroScope`，`PYROSCOPE_*`） | 见 6.2 |
| 开发编排 | `docker-compose.dev.yml`、`make dev-api` / `dev-api-rebuild` / `dev-web` / `dev` / `reset-setup` | 端口：API 3000、Web 5173、PG 5432 |
| 桌面端 | Electron 39.8.10 + electron-builder 26 | `electron/build.sh`（bun 构建前端 -> `CGO_ENABLED=1 go build` -> 打包 dmg/zip、nsis/portable、AppImage/deb） |
| CI/CD | GitHub Actions：`ci.yml`（双模块 vet+build、`make test`、bun typecheck + test）、`docker-build.yml`（多架构 + cosign 签名 + manifest 合并）、`release.yml`（三平台二进制 + sha256）、`electron-build.yml`、`docker-image-branch.yml`、`sync-release-to-gitcode.yml` | `.github/workflows/` |

### 3.8 辅助与遗留目录

- `bin/`：仅历史遗留 `migration_v0.2-v0.3.sql`、`migration_v0.3-v0.4.sql`、`time_test.sh`。**[需补建]** 无当前迁移脚本，schema 全部依赖 AutoMigrate（见 4.8）。
- 根目录 **无 `scripts/`**，可执行脚本集中在 `web/scripts/` 与 `makefile`。
- `plugins/embed.go`：`//go:embed tasks` 将 10 个插件源码编译进二进制，并提供 `Source()`/`Icon()`/`IconDataURI()`；`plugins/*_responses_test.go`（13 个文件）针对 alibaba/kling/vidu/sora/veo/sunoapi/google/hailuo/jimeng/doubao/vertex_ai 等的响应解析做回归。

### 3.9 压测设计 **[需补建为主]**

**现状**：仓库仅有 Go 微基准，**没有任何面向 HTTP 网关的黑盒压测方案**。

| 已有基准 | 位置 | 度量对象 |
| --- | --- | --- |
| `BenchmarkTaskPluginRuntime` / `AfterGC` / `Submit` / `SSE` | `relay/channel/task/jsplugin/performance_test.go` | JS 插件 runtime 池化、GC 影响、提交与 SSE 解析耗时 |
| 4 个分档/倍率计费基准（其中 2 个 `b.RunParallel`） | `service/tiered_settle_test.go` | 表达式结算 CPU |
| `BenchmarkExprCompile` / `BenchmarkExprRunCached` | `pkg/billingexpr/billingexpr_test.go` | 表达式编译 vs 缓存命中执行 |
| `BenchmarkRequestDeepCopy` | `relay/request_clone_test.go` | 重试重放所需深拷贝开销 |
| `bin/time_test.sh` | 历史脚本 | 无断言，不作为压测基线 |

**目标方案**（落地要求，禁止用"随机输入 + sleep + 只打日志"的伪压测代替）：

1. **工具**：`vegeta`（常量 QPS 稳态）+ `k6`（场景编排）+ `hey`（冒烟）；配置放入新建 `perf/` 目录（`perf/k6/relay-chat.js`、`perf/vegeta/targets`、`perf/baseline/README.md`）。
2. **场景矩阵**：
   - S1 非流式 chat（mock 上游固定 128 token，`stream=false`）→ 目标 ≥ 800 QPS/实例，P99 ≤ 80 ms（网关内）。
   - S2 流式 chat（mock 上游 1,000 chunk，2 s 完成）→ 目标 ≥ 1,500 并发 SSE/实例，内存 ≤ 1.5 GiB。
   - S3 管理面列表（日志分页、渠道列表，PageSize=100）→ ≥ 800 QPS。
   - S4 上游故障注入（mock 上游 5% 5xx + 2% 超时）→ 验证 `RetryTimes` 放大效应与端到端成功率，输出"重试放大比"。
   - S5 限流命中 → 验证 429 + `Retry-After` 与 Redis Lua 原子性边界突发。
   - S6 长任务提交 + 轮询（10k 未完成任务）→ 验证 `system_task_locks` 租约不被多实例抢占。
3. **验收口径**：以 `perf_metrics` 的 `success_rate`、`avg_latency`、`avg_ttft`、`avg_tps` 与 Prometheus `process_resident_memory_bytes` / `go_goroutines` / GC 停顿共同判定，指标必须与 1.3 的目标值逐项比对；每次结果作为 `perf/baseline/<date>-<commit>.md` 归档并作为回归门禁（相对劣化 > 10% 阻断发布）。
4. **环境要求**：压测客户端与被测系统跨可用区部署（同 VPC 内 `i2`/`g8i` 实例），mock 上游用 `docker-compose.perf.yml` 拉起，禁用真实上游以隔离计费噪声，但必须开启 `BATCH_UPDATE_ENABLED` 与 `MEMORY_CACHE_ENABLED` 以贴近现网。

---

## 四、数据存储结构设计

### 4.1 存储拓扑

```mermaid
flowchart LR
  subgraph APP["new-api 实例 N 个"]
    G["Gin + GORM + 内存缓存"]
  end
  subgraph PRIMARY["主库 业务与配置"]
    P1["RDS PostgreSQL 15 高可用版 或 MySQL 8.2"]
  end
  subgraph LOGDB["日志库 可分离"]
    L1["同主库 默认 LOG_SQL_DSN 未配置"]
    L2["云数据库 ClickHouse logs 与 audit_logs 按月分区"]
  end
  subgraph REDIS["Tair 或 Redis 7"]
    R1["用户与令牌缓存 限流计数 指标聚合 亲和映射"]
  end
  subgraph OBJ["OSS"]
    O1["任务产物 磁盘缓存 导出文件"]
  end
  G -->|读写事务| P1
  G -->|日志写入| L1
  G -->|日志写入| L2
  G -->|HINCRBY Lua EVAL| R1
  G -->|签名 URL 上传下载| O1
```

- 主库连接池：`SQL_MAX_IDLE_CONNS=100`、`SQL_MAX_OPEN_CONNS=1000`、`SQL_MAX_LIFETIME=60`（`model/main.go:258-260`）。
- 日志库由 `LOG_SQL_DSN` 决定；未配置时 `LOG_DB = DB`（`model/main.go:230-238`）。**ClickHouse 只允许作为日志库**，用作主库时启动报错并提示改用 `LOG_SQL_DSN`（`model/main.go:143-146`）。
- 默认主库为 SQLite：`one-api.db?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_txlock=immediate`（`common/database.go:64`）——仅适合单机/开发。
- 慢查询阈值 `SQL_SLOW_THRESHOLD_MS` 默认 **200 ms**（`model/gorm_logger.go:20-47`），非 DEBUG 模式关闭参数打印，驱动错误做脱敏。

### 4.2 核心实体关系图

```mermaid
erDiagram
  USERS ||--o{ TOKENS : "签发 API 令牌"
  USERS ||--o{ USER_SESSIONS : "登录会话"
  USERS ||--o| TWO_FAS : "MFA"
  USERS ||--o| PASSKEY_CREDENTIALS : "通行密钥"
  USERS ||--o{ USER_OAUTH_BINDINGS : "第三方绑定"
  CUSTOM_OAUTH_PROVIDERS ||--o{ USER_OAUTH_BINDINGS : "提供身份"
  USERS ||--o{ EXTERNAL_IDENTITY_CLAIMS : "身份占用声明"
  USERS ||--o{ TOP_UPS : "充值订单"
  USERS ||--o{ USER_SUBSCRIPTIONS : "订阅实例"
  SUBSCRIPTION_PLANS ||--o{ USER_SUBSCRIPTIONS : "套餐定义"
  USERS ||--o{ LOGS : "产生用量"
  USERS ||--o{ AUDIT_LOGS : "产生审计"
  USERS ||--o{ CHECKINS : "签到"
  USERS }o--o{ GROUPS : "分组归属"
  CHANNELS ||--o{ ABILITIES : "按分组与模型暴露"
  MODELS ||--o{ ABILITIES : "被渠道支持"
  VENDORS ||--o{ MODELS : "供应商"
  CHANNELS ||--o{ TASKS : "执行异步任务"
  CHANNELS ||--o{ MIDJOURNEYS : "执行绘图任务"
  TASK_PLUGINS ||--o{ CHANNELS : "协议绑定"
  REDEMPTIONS ||--o{ TOP_UPS : "兑换"
  OPTIONS ||--o{ SYSTEM_SETTINGS : "键值配置源"
  SYSTEM_TASKS ||--|| SYSTEM_TASK_LOCKS : "租约互斥"
  MODELS ||--o{ PERF_METRICS : "按模型统计"
```

> `GROUPS` / `SYSTEM_SETTINGS` 是逻辑概念：分组不是表，而是 `users.group`、`tokens.group`、`channels.group`、`abilities.group` 与 `setting/user_usable_group.go`、`setting/auto_group.go` 的组合；`SYSTEM_SETTINGS` 实际物理落地为 `options` 表的行。

### 4.3 表清单（注册于 `model/main.go:337-373` 的 `DB.AutoMigrate` 与 `:395-403` 的 `migrateLOGDB`）

#### (a) 身份与访问

| 表 | 定义位置 | 关键字段与约束 |
| --- | --- | --- |
| `users` | `model/user.go:79-115` | `Id int` PK；`username` unique+index；`password` not null；`email`/`display_name` index；`github_id`/`discord_id`/`oidc_id`/`wechat_id`/`telegram_id`/`linux_do_id` 各带 index；`access_token char(32)` **uniqueIndex**；`aff_code varchar(32)` uniqueIndex；`quota`/`used_quota`/`aff_quota`/`aff_history` **int64**（32 位平台启动硬校验，见 4.9）；`group varchar(64) default 'default'`；`auth_version bigint not null default 1`；`deleted_at` 软删除 |
| `tokens` | `model/token.go:14-33` | `user_id` index；`key varchar(128)` **uniqueIndex**；`expired_time bigint default -1`；`model_limits text`；`auto_groups text`；`allow_ips`；`cross_group_retry`；软删除 |
| `user_sessions` | `model/user_session.go:42-63` | **String PK** `sid varchar(64)`；`refresh_hash char(64)` + `previous_refresh_hash`（轮换宽限）；`login_method`；`status active/revoking/revoked`；unix bigint 的 `created_at/last_active_at/expires_at/revoked_at`；`user_auth_version` |
| `auth_flows` | `model/auth_flow.go:45-60` | `token_hash char(64)` uniqueIndex（只存 HMAC，绝不存 token 明文）；`purpose varchar(32)`/`provider`/`intent`/`payload text`；**`time.Time`** 的 `created_at/expires_at/consumed_at` |
| `external_identity_claims` | `model/external_identity_claim.go:21-27` | unique `(provider, subject)`、unique `(provider, user_id)`，防止 IdP 账号被重复绑定抢占 |
| `passkey_credentials` | `model/passkey.go:23-43` | `user_id` **uniqueIndex（每人一个通行密钥）**；`credential_id varchar(512)` uniqueIndex；`public_key text`/`sign_count`/`aaguid`/`transports`/`rp_id` |
| `two_fas` / `two_fa_backup_codes` | `model/twofa.go:14-36` | `user_id` unique；`secret varchar(255)`、`failed_attempts`、`locked_until`；备份码 `code_hash` + `is_used` |
| `custom_oauth_providers` | `model/custom_oauth_provider.go:40-67` | `slug varchar(64)` uniqueIndex；各端点 + gjson 字段映射列 + `access_policy text`；`client_secret` 标 `json:"-"` |
| `user_oauth_bindings` | `model/user_oauth_binding.go:11-20` | unique `(user_id, provider_id)`、unique `(provider_id, provider_user_id)` |
| `casbin_rule` | `model/casbin_rule.go:3-14` | `ptype` + `v0..v5`（size 100）；复合 index `idx_casbin_rule` 与 unique `idx_casbin_rule_unique`（7 列） |
| `authz_roles` | `model/authz_role.go:3-16` | `key` uniqueIndex；`built_in`/`enabled`/`sort`；int64 autoCreateTime/autoUpdateTime |
| `login_encryption_keys` | `model/password_crypto.go:17-21` | `slot varchar(32)` uniqueIndex + `private_key_pem text`（登录密码传输 RSA 密钥槽，可轮换） |

#### (b) 路由与供应商

| 表 | 定义位置 | 关键字段 |
| --- | --- | --- |
| `channels` | `model/channel.go:20-60` | `key`（保留字，需 `commonKeyCol` 转义）、`open_ai_api_key`、`type`、`status default 1`、`name` index、`tag` index、`models`、`group varchar(64)`、`model_mapping text`、`param_override`/`header_override`/`setting text`、`status_code_mapping varchar(1024)`、`weight *uint`、`priority *int64`、`balance float64`、`used_quota bigint`、`response_time`、`channel_info **json**`（多 key 状态 `ChannelInfo`）、`other_info` |
| `abilities` | `model/ability.go:18-26` | 见 4.4 |
| 渠道约束 | `model/channel_constraint.go`、`model/channel_satisfy.go` | **无表**，纯内存过滤逻辑，作用于 `channel_cache.go` 的快照 |

#### (c) 计费与财务

| 表 | 定义位置 | 关键字段 |
| --- | --- | --- |
| `top_ups` | `model/topup.go:15-26` | `amount int64`（额度）、`money float64`、`trade_no` **unique+index**、`payment_method`、`payment_provider`、`status`、`create_time`/`complete_time` |
| `redemptions` | `model/redemption.go:14-27` | `key char(32)` uniqueIndex、`quota default 100`、`expired_time`（0 表示永久）、`used_user_id`、软删除 |
| `subscription_plans` | `model/subscription.go:146-190` | `price_amount **decimal(10,6)**`、`currency`、`duration_unit`/`duration_value`/`custom_seconds`、`stripe_price_id`/`creem_product_id`/`waffo_pancake_product_id`、`upgrade_group`/`downgrade_group`、`total_amount bigint`、`quota_reset_period`。**SQLite 走独立建表 + 逐列 ALTER**（`model/main.go:499-576`） |
| `subscription_orders` | `:214-228` | `trade_no` unique、`provider_payload text` |
| `user_subscriptions` | `:253-281` | `amount_total`/`amount_used bigint`、`status`、`next_reset_time` index、`source order/admin`、复合 `idx_user_sub_active(user_id,status,end_time)` |
| `subscription_pre_consume_records` | `:1238-1247` | `request_id varchar(64)` **uniqueIndex** —— 预扣/退款幂等账本，计费误差为 0 的关键 |
| `quota_data` | `model/usedata.go:13-26` | 按 **小时** 聚合的看板数据，`idx_qdt_model_user_name(model_name,username)`、`idx_qdt_created_at` |
| `options` | `model/option.go:21-23` | **String PK** `key` + `value text`；数百个键在 `InitOptionMap`（`:33-...`）播种；全部热更新配置的物理载体 |
| 模型定价 | `model/pricing.go:28`、`model/model_pricing_config.go`、`model/request_policy.go:24` | **无独立表**，由 `options` + `models` + `abilities` 在内存派生；`RequestPolicySnapshot` 为运行时结构 |

#### (d) 异步任务与产物

| 表 | 定义位置 | 关键字段 |
| --- | --- | --- |
| `tasks` | `model/task.go:50-72` | `task_id varchar(191)` index、`platform`/`user_id`/`channel_id`/`action`/`status`/`progress`/`submit_time`/`start_time`/`finish_time`/`created_at` 均 index；`properties **json**`、`data json`、`private_data **json**`（`TaskPrivateData`：上游 key、上游任务 ID、结果 URL、`TaskBillingContext`、插件状态、轮询失败次数，`task.go:111-134`） |
| `midjourneys` | `model/midjourney.go:3-29` | `mj_id`、`action`、`image_url`/`video_url`/`video_urls`/`buttons`/`progress`/`billing_channel_id`，时间字段 index |
| `task_plugins` | `model/task_plugin.go:37-56` | unique `(key, version)` = `uk_task_plugin_key_version`；`source text`、`source_hash`、`icon size:524288`（MySQL 映射 mediumtext）、`active` index |

> **无 `artifacts`/`files` 表**：产物以 URL 与 JSON 形式存于 `tasks.private_data` / `midjourneys`，下载走签名访问（`middleware/task_artifact_access.go:174`）+ `service/task_artifact_store.go`。改进见第九章 R-08。

#### (e) 日志、审计与运行态

| 表 | 定义位置 | 关键字段 |
| --- | --- | --- |
| `logs` | `model/log.go:59-81` | `user_id`、`created_at bigint`(unix 秒)、`type`、`content`、`username`、`token_name`、`model_name`、`quota`、`prompt_tokens`、`completion_tokens`、`use_time`(秒)、`is_stream`、`channel_id`、`token_id`、`group`、`ip`、`request_id varchar(64)`、`upstream_request_id varchar(128)`、`other JSON text`；`channel_name` 只读（`gorm:"->"`） |
| `audit_logs` | `model/audit_log.go:26-46` | `event_id varchar(64)` uniqueIndex、`category`(login/security/operation/access_token)、`action`、`token_ref`（PAT 的 SHA-256 指纹，**绝不存明文 bearer**）、`auth_method`、`ip`、`user_agent(512)`、`method`、`route`、`status`、`success`、`request_id`、`content text`、`other JSON` |
| `perf_metrics` | `model/perf_metric.go:11-23` | `idx_perf_model_group_bucket(model_name, group, bucket_ts)` unique（upsert 冲突目标） |
| `system_instances` | `model/system_instance.go:17-24` | **String PK** `node_name varchar(128)`；`started_at`/`last_seen_at`/`created_at`/`updated_at` index |
| `system_tasks` | `model/system_task.go:28-41` | `task_id` uniqueIndex、可空 `active_key` **uniqueIndex**（保证同类型只有一个活跃任务）、`type`/`status`/`locked_by`/时间 index |
| `system_task_locks` | `model/system_task.go:43-49` | **String PK** `type`；`task_id`/`locked_by`/`locked_until` index |
| `setups` | `model/setup.go:3-7` | 单行 `version` + `initialized_at`（初始化向导状态） |

#### (f) 其他

| 表 | 定义位置 | 关键约束 |
| --- | --- | --- |
| `models` | `model/model_meta.go:35-61` | unique `uk_model_name_delete_at(model_name, deleted_at)`、`vendor_id` index、`endpoints text`、`name_rule`（exact/prefix/suffix/contains，`:64-75`） |
| `vendors` | `model/vendor_meta.go:15-26` | 同款软删除唯一名 |
| `prefill_groups` | `:78-87` | `uniqueIndex:uk_prefill_name, where:deleted_at IS NULL`（**部分唯一索引**，跨方言需特判） |
| `checkins` | `model/checkin.go:14-20` | unique `(user_id, checkin_date varchar(10))` |

### 4.4 `abilities`：路由选路的物理基础

```mermaid
flowchart TD
  A["渠道保存或更新"] --> B["AddAbilities 或 UpdateAbilities"]
  B --> C["按 channel.Models x channel.Group 生成笛卡尔积"]
  C --> D["去重 key 为 group 竖线 model"]
  D --> E["每 50 行批量插入 ON CONFLICT DO NOTHING"]
  E --> F["abilities 表"]
  F --> G["GetRandomSatisfiedChannel 按 group+model+enabled 查询"]
  G --> H["priority 降序分层"]
  H --> I["层内按 weight+10 加权随机"]
  F --> J["每 SYNC_FREQUENCY 秒重建内存快照 group2model2channels"]
```

- 列定义（`model/ability.go:18-26`）：`group varchar(64)` **PK**、`model varchar(255)` **PK**、`channel_id int` **PK + index**、`enabled bool`、`priority *int64 default 0 index`、`weight uint default 0 index`、`tag *string index`。
- **无 `uniqueIndex` 标签**：唯一性由三列复合主键保证（该表显式关闭自增）。
- 语义：`AddAbilities`（`:216-255`）、`UpdateAbilities`（`:263-...`，事务内先删后插）、`DeleteAbilities`（`:257`，按 `channel_id`）、状态/标签变更走 `UpdateAbilityStatus`（`:333-352`）。
- `weight=0` 仍获得基线流量（槽位 `weight+10`），这是"新渠道灰度从 0 权重起步仍会被少量命中"的原因，灰度设计必须考虑（见 6.5）。

### 4.5 索引设计要点

| 索引 | 列 | 服务的查询 | 位置 |
| --- | --- | --- | --- |
| `idx_created_at_id` | `(created_at, id)` | 日志按时间 keyset 分页 | `model/log.go:60-62` |
| `idx_user_id_id` | `(user_id, id)` | 个人日志列表 | `model/log.go:60-61` |
| `idx_created_at_type` | `(created_at, type)` | 按类型 + 时间范围筛选 | `model/log.go:62-63` |
| `index_username_model_name` | `(model_name, username)` | 日志检索过滤 | `model/log.go:65-67` |
| `idx_logs_request_id` / `idx_logs_upstream_request_id` | 单列 | 请求链路关联排障 | `model/log.go:78-79` |
| `idx_audit_user_time` / `idx_audit_token_time` | `(user_id, created_at)` / `(token_ref, created_at)` | 审计视图与 PAT 维度筛查 | `model/audit_log.go:29-35` |
| `idx_user_sessions_user_status_expiry` | `(user_id, status, expires_at)` | 活跃会话上限校验（`USER_SESSION_ACTIVE_LIMIT`） | `model/user_session.go:44-57` |
| `idx_user_sessions_status_revoked` | `(status, revoked_at)` | 批量吊销扫描 | 同上 |
| `idx_auth_flow_purpose_expiry` | `(purpose, expires_at)` | 按用途取流程 + 过期回收 | `model/auth_flow.go:48-55` |
| `idx_user_sub_active` | `(user_id, status, end_time)` | 有效订阅查找 | `model/subscription.go:255-263` |
| `idx_perf_model_group_bucket` | `(model_name, group, bucket_ts)` | 指标增量 upsert | `model/perf_metric.go:13-15` |
| `idx_casbin_rule` / `idx_casbin_rule_unique` | 7 列 | 策略查找 + 幂等添加 | `model/casbin_rule.go` |
| `uk_model_name_delete_at` / `uk_vendor_name_delete_at` / `uk_prefill_name`(部分) / `uk_task_plugin_key_version` | — | 软删除语义下的名字唯一 | 对应 model 文件 |

> **保留字与方言**：`group`、`key` 是保留字，所有原生 SQL 必须使用 `commonGroupCol` / `commonKeyCol`（`model/main.go:43-63` 按方言在 `` `group` `` 与 `"group"` 之间切换）；布尔值使用 `commonTrueVal`/`commonFalseVal`；分支判断使用 `common.UsingMainDatabase()` / `common.UsingLogDatabase()`。

### 4.6 主键 / 时间戳 / 软删除策略

- **主键**：默认 GORM 自增整型 `id`；String PK 仅 4 处（`options.key`、`user_sessions.sid`、`system_instances.node_name`、`system_task_locks.type`）+ 复合 String PK `abilities`。不使用数据库序列（不使用 `AUTO_INCREMENT`/`SERIAL` 显式建主键，交给 GORM，AGENTS.md 强制）。
- **时间戳两种风格并存**（有意为之，改动时必须保持）：
  - 传统宽表用 `int64`/`bigint` unix 秒 + 显式 `autoCreateTime`（`user.go:111`、`user_session.go:54`、`authz_role.go:11`）——便于分区/范围扫描与时区无关统计。
  - 新认证类表用 `time.Time` 由 GORM 管理 DATETIME（`auth_flow.go:54`、`passkey.go:40`、`custom_oauth_provider.go:65`、`twofa.go:22`）。`model/db_time.go` 提供数据库时钟归一化。
- **软删除**：仅 9 个模型带 `gorm.DeletedAt`（users、tokens、redemptions、passkeys、two_fas、two_fa_backup_codes、prefill_groups、models、vendors），均额外建 `deleted_at` index；需要绕过时用 `Unscoped()`（`user.go:309`、`passkey.go:212`、`token.go:492`）。
- **行锁**：`lockForUpdate(tx)`（`model/locking.go:17-23`）对 MySQL/PG 发 `FOR UPDATE`，SQLite 自动跳过。**禁止**在调用点复制 `clause.Locking{Strength:"UPDATE"}`，也禁止使用 GORM v1 的 `gorm:query_option`（v2 会静默忽略，导致无锁）。
- **瞬时字段**：`gorm:"-:all"` 标记永不落库（`user.go:83-94`、`model_meta.go:50-60`）。

### 4.7 日志库与 ClickHouse 设计

| 维度 | SQL 引擎（MySQL/PG/SQLite） | ClickHouse |
| --- | --- | --- |
| 建表 | `LOG_DB.AutoMigrate(&Log{}, &AuditLog{})` | 启动时执行 **raw `CREATE TABLE IF NOT EXISTS`**（`model/main.go:436-463`、`model/audit_log.go:247-255`） |
| 引擎与分区 | 无 | `MergeTree()`，`PARTITION BY toYYYYMM(toDateTime(created_at))` |
| 排序 | 主键自增 | logs：`ORDER BY (created_at, request_id)`；audit_logs：`ORDER BY (created_at, event_id)` |
| TTL | 由 `log_cleanup` 系统任务分批删除，`logCleanupBatchSize = 100`（`service/system_task.go:76-102`，`model/log.go:705-738`） | `LOG_SQL_CLICKHOUSE_TTL_DAYS`（**默认 0 = 不自动删除**），启动时 `SHOW CREATE TABLE` 探测后 `MODIFY TTL` 或 `REMOVE TTL`（`model/main.go:465-492`）；清理改为单条 `ALTER TABLE logs DELETE ... SETTINGS mutations_sync = 1`（分批 mutation 会反复重写 part） |
| ID 语义 | 自增 ID 可展示 | CH 的 `id` 无意义，展示 ID 在 Go 侧重新赋值（`model/log.go:110-121`），排序改用 `clickHouseLogOrder`（`:106`） |
| `audit_logs` 保留 | 有意 **不接入 TTL / 不接入清理任务**（`model/audit_log.go:24-25`） | 同样无 TTL，审计长期保留 |
| DDL 演进 | AutoMigrate 自动加列 | **必须手工同步修改 Go 侧 DDL 字符串**，否则新字段在 CH 中不存在（风险 R-17） |

`logs.other` 为 JSON 文本，按角色投影（`formatLogOtherJSON` + `logOtherVisibility{User,Admin,Root}`，`model/log.go:116-138`）：低权限角色看不到 `admin_info` / `audit_info` / `root_info`。日志类型是固定整数而非 iota（`model/log.go:84-93`）：0 unknown、1 topup、2 consume、3 manage、4 system、5 error、6 refund、7 login——**跨版本兼容性要求，禁止改动编号**。

### 4.8 迁移与版本化策略

**现状：无版本化迁移文件、无 down 迁移**，只有 AutoMigrate + 手工编写的幂等修复步骤。

启动迁移序列（`model/main.go`，全部 **仅 master 节点执行**，`main.go:262-267`）：

```
1 前置修复（AutoMigrate 之前）
  ├─ migrateTokenKeyUniqueness        token_migration.go:117-197  把历史非唯一索引换成独立唯一索引
  ├─ migratePrefillGroupUniqueness    prefill_group_migration.go:97-172  重建部分唯一索引
  ├─ migrateSubscriptionPlanPriceAmount  main.go:644-680  float -> decimal(10,6)
  ├─ migrateTokenModelLimitsToText    main.go:580-620  varchar(1024) -> text（SQLite affinity 特判跳过）
  └─ migrateOptionPrimaryKey          option_primary_key_migration.go:20-140  临时表 + CreateInBatches(100) + advisory lock 重建
2 DB.AutoMigrate(约 30 个实体)         main.go:337-373
3 后置修复
  ├─ InitializeUserAuthVersions       main.go:377（必须在加列之后）
  ├─ InitializeExternalIdentityClaims
  └─ subscription_plans：SQLite 走 ensureSubscriptionPlanTableSQLite，其他方言走 AutoMigrate
4 自定义 Dialector                    migration_dialector.go:16-112
     屏蔽 MySQL decimal 默认值补零 与 PG char(N)/唯一性复检导致的"每次重启重复 ALTER"误报
5 CheckSetup / MigrateRetiredFrontendOptions / InitOptionMap / InitLogDB
```

**风险清单**（详见第九章 R-03、R-04）：AutoMigrate 只加不删（废弃列/索引永久泄漏）；SQLite 与 PG/MySQL 的部分索引和唯一性语义差异需要逐个 bespoke 检查器；无 schema 版本号可供回滚判定；`&Log{}` 出现在 **主库** AutoMigrate 列表（`main.go:349`），日志库分离时会留下一张空的 `logs` 孤儿表；非 master 节点从不迁移，混版本集群可能在 schema 就绪前就开始服务请求。

### 4.9 容量、写入放大与分页

| 机制 | 实现 | 参数 |
| --- | --- | --- |
| 额度批量合并写 | `model/utils.go:16-41` 五个内存合并器（`UserQuota`、`TokenQuota`、`UsedQuota`、`ChannelUsedQuota`、`RequestCount`），按行 ID 聚合后定时落库；int 溢出钳制（`:49-60`） | `BATCH_UPDATE_ENABLED=true` 开启，`common.BatchUpdateInterval` 秒 |
| 看板小时聚合 | `quota_data`：`created_at` 截断到小时（`usedata.go:80`），`CacheQuotaData` 以 NUL 连接复合键累加（`:51-76`），进程退出前 `SaveQuotaDataCache()` 落库避免丢数（`main.go:241-244`，issue #5679） | `DataExportEnabled`、`DataExportInterval` 分钟 |
| 分批尺寸 | 会话吊销 500 / 清理 500 / 扫描 1000（`user_session.go:22-25`）；abilities 插入 50；上游模型同步 100；订阅重置 300；Codex 凭证刷新 200；日志清理 100 | 硬编码 |
| 分页上限 | `PageInfo` 强制 `PageSize ≤ 100`，默认 `ItemsPerPage=10`（`common/page_info.go:70-81`）；最近日志上限 `MaxRecentItems=1000`（`log.go:145`）；会话列表 100 | 防大结果集打爆 |
| 排序注入防护 | 排序列走白名单 map（`channel.go:80-123`、`user.go:30-68`） | — |
| 无分库分表 | 全库无 sharding、无 SQL 层分区（仅 ClickHouse 月分区） | 单库垂直扩展为主 |

**容量估算（菲律宾 + 泰国 1,000 DAU、日均 300 万次中继请求）**：

- `logs`：300 万行/日 ≈ 1.2 GB/日（含 `other` JSON），月增 ~36 GB；**必须**开 `LOG_SQL_DSN` 走 ClickHouse 并设 `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`。
- `perf_metrics`：模型数 200 × 分组 10 × 每小时 1 桶 ≈ 48 万行/月；默认 `RetentionDays=0` 永不清理（`setting/perf_metrics_setting/config.go:12-16`），**必须显式设为 30**。
- `quota_data`：小时粒度，约 200 模型 × 10 分组 × 24 = 4.8 万行/日。
- Redis：约 6,000 活跃用户 × 3 类 key + 限流计数，峰值 < 2 GB，Tair 主备 4 GB 足够。

### 4.10 Redis Key 清单

基础 TTL 由 `common.RedisKeyCacheSeconds()` = `SYNC_FREQUENCY`（默认 60 s）统一驱动；Redis 仅在设置 `REDIS_CONN_STRING` 时启用，`REDIS_POOL_SIZE` 默认 10，启动 5 s ping 失败即 fatal（`common/redis.go:16-54`）。**go-redis/v8 单节点客户端，无 Cluster/Sentinel universal client**（风险 R-05）。

| Key 模式 | 类型 / 字段 | TTL | 用途 | 位置 |
| --- | --- | --- | --- | --- |
| `user:<id>` | hash（`UserBase`），schema 版本常量 `userCacheSchemaVersion = 2` 拒绝旧结构 | `max(SYNC_FREQUENCY, 60)` | 用户与额度热路径；额度差用 `RedisHIncrBy` 应用 | `model/user_cache.go:50-61,127,143` |
| `token:<HMAC(key)>` | hash | 同上 | 令牌鉴权 | `model/token_cache.go:12-26` |
| `token:fence:<HMAC>` | 围栏标记 | **10 s** | 变更前排栏，禁止读侧回写旧快照 | `model/token_cache.go:17,33,43` |
| `auth:user:version:<uid>` / `auth:user:fence:<uid>` | 计数器 / 围栏 | cacheTTL / cacheTTL+max(cacheTTL,60) | 认证版本全局失效 | `model/user_auth_cache.go:26-42` |
| `auth:session:<digest(HMAC(SessionSecret, sid))>` | hash | `min(sessionTTL, SYNC_FREQUENCY)`，≥1 s | 会话校验 | `model/user_session.go:124-126,289-346` |
| `rateLimit:v2:ip:<mark>:<ip>`、`rateLimit:v2:user:<mark>:<uid>` | 计数 + TTL | 窗口时长 | 固定窗口限流；mark 见 6.4 | `middleware/rate-limit.go:15,44-50` |
| `rateLimit:MRRLS:<uid>` | LIST（`LPUSH`+`LTRIM 0,max-1`+`EXPIRE`） | 窗口 | 模型维度"成功请求"滑动窗口 | `middleware/model-rate-limit.go:28-65` |
| 令牌桶 key（`common/limiter/lua/rate_limit.lua`） | 桶状态 | — | 模型维度总请求配额 | `common/limiter/limiter.go:26-69` |
| `perf:<model>:<group>:<bucketTs>` | hash，字段 `req/ok/lat/ttft/ttft_n/out/gen_ms`，TxPipeline `HINCRBY`，1 s 超时 | **1 h** | 跨实例指标聚合 | `pkg/perf_metrics/metrics.go:452-500` |
| `new-api:channel_affinity:v1:<suffix>` | channel id | `rule.TTLSeconds` 否则 3600 | 会话亲和 | `service/channel_affinity.go:31,596,747-755` |
| `new-api:channel_affinity_usage_cache_stats:v1:<rule:group:keyFp>` | 命中/未命中计数 | 统计窗口 | 亲和效果评估 | `service/channel_affinity.go:853-920` |
| `notify_limit:<uid>:<scope>:<yyyymmddHH>` | 计数 | 小时桶 | 通知频率限制 | `service/notify-limit.go:58-93` |
| 订阅套餐缓存 key（按 plan id） | hash | cacheTTL | 套餐读取 | `model/subscription.go:128` |
| `user_group:%d` / `user_quota:%d` / `user_enabled:%d` / `user_name:%d` | 字符串 | cacheTTL | 旧版兼容 key 格式 | `constant/cache_key.go:5-9` |

> 定时任务互斥 **不走 Redis**，走 `system_task_locks` 表租约（`model/system_task.go:313-452`）。Redis 中唯一的 pub/sub 通道是渠道关闭广播 `channelCloseTopic`（`pkg/wsmanager/wsmanager.go:113-155`）。

---

## 五、核心业务逻辑时序图

### 5.1 `/v1` 路由的中间件链（精确顺序，`router/relay-router.go`）

`CORS:16` → `DecompressRequestMiddleware:17` → `BodyStorageCleanup:18` → `StatsMiddleware:19` → 路由组内 `RouteTag("relay"):72` → `SystemPerformanceCheck:73` → `TokenAuth:74` → （`GET /v1/responses:78` 在此注册，**因此跳过模型限流**）→ `ModelRequestRateLimit:80` → `Distribute:92` → handler。

已注册的中继入口：`GET /v1/models`、`GET /v1/models/:model`、`/v1beta/models`、`/v1beta/openai/models`、`POST /pg/chat/completions`、`GET /v1/responses`、`GET /v1/realtime`、`POST /v1/messages`、`POST /v1/completions`、`POST /v1/chat/completions`、`POST /v1/responses/compact`、`POST /v1/alpha/search`、`POST /v1/edits`、`POST /v1/images/generations`、`POST /v1/images/edits`、`POST /v1/embeddings`、`POST /v1/audio/transcriptions|translations|speech`、`POST /v1/rerank`、`POST /v1/engines/:model/embeddings`、`GET /v1/models/*path`、`POST /v1/moderations`、`/mj/*` 与 `/:mode/mj/*`；未实现协议由 `RelayNotImplemented` 兜底（`:165-176`）。

### 5.2 时序图：非流式对话中继（`POST /v1/chat/completions`）

```mermaid
sequenceDiagram
  autonumber
  participant CLI as 客户端
  participant ALB as 接入层 ALB
  participant MW as Gin 中间件链
  participant TAUTH as TokenAuth
  participant MRL as ModelRequestRateLimit
  participant DIST as Distribute
  participant SEL as 渠道选择
  participant CTRL as controller.Relay
  participant BIL as 计费 BillingSession
  participant ADP as 上游适配器
  participant UP as 上游供应商
  participant DB as 主库与 Redis

  CLI->>ALB: POST 携带 Bearer sk 与 JSON body
  ALB->>MW: 转发并注入 X-Forwarded-For
  MW->>TAUTH: RequestId 版本 i18n 访问日志
  TAUTH->>TAUTH: 解析多种协议鉴权头并取 parts
  TAUTH->>DB: 查 token HMAC 缓存 命中即跳过 DB
  TAUTH->>DB: 查 user 缓存 校验 auth_version 与状态
  TAUTH->>TAUTH: 令牌模型白名单 IP 白名单 可用分组与 auto 分组
  TAUTH->>MRL: 注入 token_id group 等上下文
  MRL->>DB: 读取分组配额 令牌桶加成功滑动窗口
  MRL->>DIST: 通过
  DIST->>DIST: gjson 读 model 与 group 后 Seek 0 复位 body
  DIST->>SEL: SelectChannelForRequest
  SEL->>DB: 内存快照 group2model2channels 优先 未命中回落 abilities 表
  SEL->>DIST: 返回 channel 及多 key 轮询选中的 key
  DIST->>CTRL: SetupContextForSelectedChannel 后进入 Relay
  CTRL->>CTRL: GetAndValidateRequest 与 GenRelayInfo
  CTRL->>BIL: PrepareRequestBilling 敏感词 估算 token 算价 分组倍率
  BIL->>DB: PreConsumeBilling 钱包或订阅预扣 TryReserveTokenQuota 原子 Lua
  CTRL->>ADP: 重试循环 从 RetryTimes 归零开始
  ADP->>DB: 从 body storage 重放请求体
  ADP->>UP: DoRequest 经代理与 HTTP 客户端池
  UP-->>ADP: 200 JSON usage
  ADP->>ADP: DoResponse 转换并统计 token 缺失时按估算兜底
  ADP->>BIL: PostTextConsumeQuota 分档或倍率结算
  BIL->>DB: SettleBilling 差额扣减 更新令牌与用户额度 批量合并器
  BIL->>DB: RecordConsumeLog 类型 2 含 request_id 与 upstream_request_id
  BIL-->>CTRL: 结算完成
  CTRL->>CTRL: defer 记录 perf_metrics 采样
  CTRL-->>CLI: 200 JSON 响应 附 X-Oneapi-Request-Id
```

### 5.3 时序图：流式 SSE 中继（含首 token 与异常退款）

```mermaid
sequenceDiagram
  autonumber
  participant CLI as 客户端
  participant CTRL as controller.Relay
  participant ADP as 上游适配器
  participant HTTPC as relay HTTP 客户端
  participant UP as 上游供应商
  participant SCAN as StreamScannerHandler
  participant KIT as relaykit 转换
  participant BIL as 计费结算
  participant DB as 日志库

  CLI->>CTRL: POST 携带 stream true
  CTRL->>BIL: 预扣按 max_tokens 家族估算
  CTRL->>ADP: 建立上游请求
  ADP->>HTTPC: GetHttpClientWithProxySettings
  HTTPC->>UP: ResponseHeaderTimeout 默认 1800 秒
  UP-->>ADP: Content-Type 为 text/event-stream
  ADP->>SCAN: 进入流处理并设置写缓冲
  loop 每个 chunk
    SCAN->>SCAN: 读取一行 无事件超过 STREAMING_TIMEOUT 则中断
    SCAN->>KIT: 按目标协议转换 chunk
    KIT-->>CLI: sendStreamData 加 FlushWriter 立即下推
    SCAN->>SCAN: 首个有效 delta 记录 TTFT
  end
  Note over SCAN: 周期性 ping 事件保活并 ExtendWriteDeadline
  SCAN->>SCAN: StreamStatus.RequireTerminal 校验终止事件
  SCAN->>BIL: handleLastResponse 汇总 usage 缺失则 ResponseText2Usage 估算
  alt 正常结束
    BIL->>DB: SettleBilling 差额结算并 RecordConsumeLog
    BIL-->>CLI: data done 与关闭流
  else 客户端断连或上游错误
    SCAN->>CTRL: 返回错误与已消耗量
    CTRL->>BIL: RefundFailedRequestBilling 异步退款并可计违约费
    CTRL->>DB: RecordErrorLog 类型 5 仅当 ERROR_LOG_ENABLED
    CTRL->>CTRL: DecideRelayRetry 决定是否换渠道重试
  end
```

### 5.4 时序图：令牌鉴权与缓存围栏

```mermaid
sequenceDiagram
  autonumber
  participant REQ as 中继请求
  participant AUTH as middleware.TokenAuth
  participant TC as model.ValidateUserToken
  participant RD as Redis
  participant DB as 主库

  REQ->>AUTH: Authorization Bearer sk 或 x-api-key 或 goog 参数或 ws 子协议
  AUTH->>AUTH: 归一化去前缀 切分 parts 取可选 pin 段
  AUTH->>TC: ValidateUserToken
  TC->>RD: HGETALL token 冒号 HMAC
  alt 缓存命中
    RD-->>TC: 令牌哈希
  else 缓存未命中
    TC->>DB: 按 key 查询 tokens 行
    TC->>RD: Lua 脚本 先读 token fence 围栏
    alt 围栏存在
      RD-->>TC: 拒绝回写 避免旧快照覆盖新状态
    else 已有哈希
      RD-->>TC: 仅续期 TTL 不覆盖内容
    else 无缓存
      TC->>RD: 写入哈希并设置 TTL
    end
  end
  TC->>TC: 校验 status 与 enabled 与 expired_time 与 remain_quota
  TC-->>AUTH: 令牌对象
  AUTH->>AUTH: IP 白名单匹配 CIDR
  AUTH->>RD: GetUserCache 用户哈希
  AUTH->>DB: 未命中则查库并按 auth_version 兜底校验
  AUTH->>AUTH: 校验 using_group 属于可用分组
  AUTH->>REQ: SetupContextForToken 注入令牌额度 分组 模型限制 跨组重试标记
  Note over AUTH,REQ: 额度是否充足不在鉴权层判定 交由 BillingSession 预扣阶段
```

### 5.5 时序图：登录（密码 + TOTP 二次因子）

```mermaid
sequenceDiagram
  autonumber
  participant BRW as 浏览器
  participant RL as CriticalRateLimit
  participant TS as TurnstileCheck
  participant CTRL as controller.Login
  participant CR as 密码解密与校验
  participant LV as 登录验证服务
  participant SES as 会话服务
  participant AUD as 审计与日志

  BRW->>RL: POST 登录接口 携带用户名密码
  RL->>TS: 每 IP 与每用户固定窗口限流
  TS->>CTRL: 校验人机验证 失败时返回 200 且 success false
  CTRL->>CTRL: 检查 PasswordLoginEnabled
  CTRL->>CR: DecryptPassword 使用服务端公钥加密的传输密文
  CR->>CR: ValidateAndFill 按用户名或邮箱查用户 argon2id 优先回落 bcrypt
  CR->>CTRL: 校验账号状态与密码
  alt 需要二次验证
    CTRL->>LV: StartLoginVerification 计算验证策略
    LV->>AUD: 创建 auth_flow 记录 仅存 token HMAC
    LV-->>BRW: 返回 LoginChallenge 并终止本次登录
    BRW->>LV: POST 登录 2FA 接口 携带 TOTP 或备份码
    LV->>LV: VerifyTwoFactorCode 含失败计数与锁定
    LV->>SES: CompleteLoginVerification
  else 无需二次验证
    CTRL->>SES: setupLoginAtAuthVersion 创建会话
  end
  SES->>SES: 校验活跃会话上限与签发窗口上限
  SES->>AUD: IssueAccessToken 签发 access token 与 refresh 哈希
  SES->>BRW: 写 Refresh Cookie 并设置 no-store
  AUD->>AUD: recordLoginAudit 不记录任何凭据
  AUD->>AUD: RecordLoginLog 类型 7
```

### 5.6 时序图：充值与回调入账

```mermaid
sequenceDiagram
  autonumber
  participant USR as 用户
  participant API as 支付下单接口
  participant TP as model.TopUp
  participant PSP as 支付渠道 epay 或 stripe
  participant CB as 回调接口
  participant RECH as 入账事务
  participant RD as Redis 额度
  participant LOG as 日志

  USR->>API: POST 自助支付 关键接口限流
  API->>API: getPayMoney 计算分组充值倍率与额度
  API->>PSP: 创建远端订单
  API->>TP: 插入待支付订单 trade_no 唯一
  API-->>USR: 返回支付跳转地址
  PSP->>CB: 异步通知 无鉴权但有体积限制
  CB->>CB: isEpayWebhookEnabled 开关校验
  CB->>PSP: Verify 验签 epay 为 MD5 签名 stripe 为 webhook 签名
  CB->>CB: LockOrder 进程内互斥 真正幂等靠数据库
  CB->>RECH: RechargeEpay 事务开始
  RECH->>RECH: lockForUpdate 按 trade_no 行锁
  RECH->>RECH: 已 success 则判定 alreadyDone 直接返回
  RECH->>RECH: 金额换算额度并做溢出严格校验
  RECH->>RECH: 更新订单状态为 success 并给用户额度累加
  RECH->>RD: 事务提交后 Redis HINCRBY 同步用户额度缓存
  RECH->>LOG: RecordTopupLog 类型 1
  LOG-->>PSP: 返回 success 文本
```

### 5.7 时序图：异步任务（视频生成）全生命周期

```mermaid
sequenceDiagram
  autonumber
  participant CLI as 客户端
  participant VR as video 与 task 路由
  participant TR as controller.RelayTask
  participant ADP as 任务适配器或 JS 插件
  participant BIL as 任务计费
  participant DB as tasks 表
  participant UP as 上游
  participant RUN as system_task runner
  participant POLL as 轮询服务
  participant ART as 产物下载

  CLI->>VR: POST 生成请求 经 TokenAuth 与插件端点守卫
  VR->>TR: Distribute 选定渠道
  TR->>TR: GenRelayInfo 任务格式 解析 origin task 并套用亲和
  TR->>ADP: ValidateRequestAndSetAction 与算价 表达式或按次
  TR->>BIL: 预扣 ForcePreConsume 关闭信任旁路
  loop RetryTimes 重试
    TR->>ADP: buildSubmitRequest 或适配器提交
    ADP->>UP: 上游创建任务
    UP-->>ADP: 返回上游 task id
  end
  TR->>DB: Billing.Reserve 上调差额 并 InitTask 写入 private_data 计费上下文
  TR->>BIL: SettleBilling 与 LogTaskConsumption 落库后置为 durable
  TR-->>CLI: 返回自有 task_id
  RUN->>RUN: 抢 system_task_locks 租约 心跳每 TTL 三分之一续租
  RUN->>POLL: RunTaskPollingOnce 每 15 秒节拍
  POLL->>POLL: sweepTimedOutTasks 按 TASK_TIMEOUT_MINUTES 判超时
  POLL->>DB: GetAllUnFinishSyncTasks 按平台分组
  POLL->>ADP: 按渠道 FetchTask 每渠道间隔 1 秒避免打爆上游
  ADP->>UP: 查询任务状态或批量查询
  alt 任务成功
    POLL->>DB: CAS 更新状态 fromStatus 保护
    POLL->>BIL: 评估实际用量并重算额度差额
  else 任务失败
    POLL->>BIL: RefundTaskQuota 全额或部分退款
    POLL->>DB: 标记失败
  end
  CLI->>ART: GET 产物内容 携带访问令牌或签名
  ART->>ART: VerifyTaskArtifactAccess 加匿名尝试限流
  ART->>DB: 读取 private_data 中的结果地址
  ART-->>CLI: 代理回吐内容
```

### 5.8 时序图：渠道自动禁用与恢复闭环

```mermaid
sequenceDiagram
  autonumber
  participant RL as 中继重试循环
  participant DEC as DecideRelayRetry
  participant PCE as ProcessChannelError
  participant SCH as 禁用判定
  participant CH as 模型层状态更新
  participant WS as wsmanager
  participant TEST as 渠道自动测试任务
  participant UP as 上游

  RL->>DEC: 上游返回错误或渠道异常
  DEC->>DEC: 按状态码区间与错误类型判定是否重试
  DEC->>PCE: 判定不再重试 或 需要拉黑
  PCE->>PCE: 记录脱敏后的错误日志
  PCE->>SCH: ShouldDisableChannel
  SCH->>SCH: 检查自动禁用开关 渠道错误 状态码区间默认 401 关键词 Aho-Corasick
  SCH->>CH: 异步 DisableChannel 且渠道自身 AutoBan 为真
  CH->>CH: 写 status 为 3 自动禁用 并更新 ability 状态
  CH->>CH: 内存缓存立即短路 下一次同步刷新路由表
  CH->>WS: CloseChannelsAndBroadcast 本地关闭并 Redis 发布
  WS-->>RL: 其他实例订阅后关闭该渠道活跃 WebSocket
  CH->>CH: NotifyRootUser 通知管理员
  loop 每 auto_test_channel_minutes 默认 10 分钟
    TEST->>TEST: 抢租约并选择测试模式 全量 或仅自动禁用 或被动恢复
    TEST->>UP: 以 IsChannelTest 为真发起真实中继
    alt 响应健康
      TEST->>CH: ShouldEnableChannel 仅从自动禁用态恢复 并 EnableChannel
    else 仍失败或响应过慢
      TEST->>PCE: 再次 processChannelError 保持禁用
    end
    TEST->>CH: 更新 response_time 供观测
  end
```

### 5.9 时序图：配置热更新跨节点收敛

```mermaid
sequenceDiagram
  autonumber
  participant ADM as 管理员
  participant API as PUT option 接口
  participant CTL as controller.UpdateOption
  participant DB as options 表
  participant LOC as 本节点内存配置
  participant OTH as 其他节点
  participant RD as Redis

  ADM->>API: 修改一个配置键
  API->>CTL: RootAuth 或权限校验通过后进入
  CTL->>CTL: 类型归一化 键级守卫 支付合规 计费表达式校验
  CTL->>DB: FirstOrCreate 后 Save 落库
  CTL->>LOC: updateOptionMap 立即写内存并 handleConfigUpdate 分发到 setting 结构体
  CTL->>ADM: 返回成功
  CTL->>CTL: recordManageAudit 仅记 key 不记 value
  loop 每 SYNC_FREQUENCY 默认 60 秒
    OTH->>DB: 全量读取 options
    OTH->>OTH: 逐行更新内存并刷新请求策略快照
  end
  Note over OTH: 渠道类变更另有 SyncChannelCache 同频重建路由快照
  OTH->>RD: 唯一秒级传播是渠道关闭广播
```

---

## 六、日志 / 监控 / 限流 / 灰度 / 回滚能力设计

### 6.1 能力矩阵总览

| 能力 | 现状 | 缺口 | 落地要求 |
| --- | --- | --- | --- |
| 分级日志 | **[现状]** 文件日志（级别 + 请求 ID + 轮转）+ 访问日志 + SQL 慢查询日志 | 无结构化 JSON、无集中采集 | 采集到 SLS，改 JSON 格式（R-06） |
| 业务日志落库 | **[现状]** `logs` 表 8 种类型，角色投影脱敏 | 无采样、无 trace id 贯通 | 与 OpenTelemetry trace 关联（R-07） |
| 审计日志 | **[现状]** `audit_logs` 独立表，管理面写路由自动审计，长期保留不接清理 | 无外发到 SIEM | 投递 SLS + 冷备 OSS |
| 指标监控 | **[现状]** `perf_metrics`（模型 × 分组 × 时间桶）+ 活跃连接数 + 系统资源采样 | **无 Prometheus /metrics、无 /health** | 自建 exporter + 探针端点（R-01） |
| 链路追踪 | **[缺口]** 仅 `request_id` / `upstream_request_id` 两跳关联 | 无 span | 接入 OpenTelemetry（R-07） |
| 限流 | **[现状]** 三级：全局固定窗口 / 关键接口 / 模型维度令牌桶 + 成功滑窗 | 无按令牌维度、无自适应并发 | 补令牌级 RPM/TPM（R-09） |
| 过载保护 | **[现状]** CPU/内存/磁盘阈值 503 摘流 | 阈值两处不一致、无连接数上限 | 统一配置 + 增加并发上限（R-10） |
| 灰度发布 | **[部分]** 业务灰度可用（分组 / 渠道权重 / tag / model_mapping / pin / 请求策略）；**代码灰度无机制** | 无金丝雀、无按用户维度分流 | ALB 权重双版本 + 业务分组双轨（6.5、7.7） |
| 回滚 | **[部分]** 镜像回滚 + `options` 配置回滚 + 渠道禁用即止血；**无 schema 回滚** | 无 down migration | 双轨发布 + 前向兼容迁移（6.6、R-03） |
| 熔断 | **[缺口]** 无 circuit breaker、无并发信号量 | 故障渠道靠重试放大 | 引入 per-channel 熔断（R-11） |

### 6.2 日志能力

#### 6.2.1 四类日志

| 类别 | 实现 | 关键事实 |
| --- | --- | --- |
| 系统日志 | `logger/logger.go:100-123`，格式 `[LEVEL] 时间 | request_id 或 SYSTEM | 消息` | 级别 `INFO/WARN/ERR/DEBUG`（`:20-25`）；`DEBUG` 由 `DEBUG=true` 开（`common/init.go:87`）；`FatalLog` 直接 `os.Exit(1)` |
| 文件与轮转 | `logger.SetupLogger()`（`logger.go:42-74`） | **按行数轮转，非按时间**：`maxLogCount = 1000000` 行后重开 `oneapi-<yyyyMMddHHmmss>.log`；目录由 **CLI 参数 `-log-dir`（默认 `./logs`）** 指定，**没有对应环境变量**；写句柄在 `common.LogWriterMu` 下热切换，输出为 `io.MultiWriter(stdout, file)` |
| 访问日志 | `middleware/logger.go:20-48` | `[GIN] 时间 | routeTag | requestID | status | latency | clientIP | METHOD path`；`/api/oauth/*`、`/oauth/*` 会剥掉 query 防泄漏 code；routeTag 默认 `web`，relay 组设 `relay` |
| SQL 日志 | `model/gorm_logger.go:20-47` | 慢查询阈值 `SQL_SLOW_THRESHOLD_MS` 默认 **200 ms**，Warn 级；非 DEBUG 关闭参数打印；驱动错误脱敏 |

#### 6.2.2 关联与脱敏

- 请求关联：`X-Oneapi-Request-Id`（`middleware/request-id.go:10-18`）+ `X-Upstream-Request-Id`，两者同时写入 `logs.request_id` / `logs.upstream_request_id`，构成"客户端 → 网关 → 上游"的最小可追溯链。
- 强制脱敏（AGENTS.md 认证安全条款）：审计事件 **必须排除** 密码、验证码、恢复码、私钥与可用会话令牌。已落地的体现：`auth_flows.token_hash` 只存 HMAC；`audit_logs.token_ref` 只存 PAT 的 SHA-256 指纹（`model/audit_log.go:61-70`）；`logs.other` 按角色投影；`options` 变更审计只记 key 不记 value；`middleware/audit.go` 响应体缓冲上限 64 KiB（`:190-204`）。

#### 6.2.3 日志采集时序（含 SLS 落地）

```mermaid
sequenceDiagram
  autonumber
  participant REQ as 请求处理
  participant LG as logger 文件写入
  participant FS as 容器日志目录
  participant COL as Logtail 采集器
  participant SLS as 阿里云 SLS
  participant DB as 日志库 logs 或 audit_logs
  participant GR as Grafana 或 SLS 看板
  participant AL as 告警通道

  REQ->>LG: 按级别写系统或访问日志
  LG->>FS: stdout 与文件双写 超 100 万行轮转新文件
  REQ->>DB: 业务写 logs 类型 2 或 5 或 7
  REQ->>DB: 管理面写路由自动写 audit_logs
  COL->>FS: 采集容器标准输出与文件 打标签 node_name 与 version
  COL->>SLS: 批量投递 按 project 与 logstore 分层
  SLS->>SLS: 建立 request_id 索引 保留 30 天 冷数据投递 OSS
  GR->>SLS: 按 request_id 聚合错误率与慢请求
  SLS->>AL: 关键字告警 panic 与 quota 异常 与上游 401 突增
  DB->>DB: log_cleanup 系统任务分批清理 logs 每批 100
  Note over DB: audit_logs 有意不接清理 长期保留
```

**生产落地要求**：
1. 容器启动参数必须带 `--log-dir /app/logs`（`docker-compose.yml` 已示范），并用 `logging: driver: json-file, max-size: 100m, max-file: 5` 兜底，防止文件轮转按"行数"导致单文件过大。
2. **禁止** `DEBUG=true` 进入生产（会打开 SQL 参数打印与冗余日志）。
3. SLS logstore 划分：`new-api-sys`（系统/访问）、`new-api-audit`（审计，保留 ≥ 180 天）、`new-api-relay-error`（`logs` 中 type=5 的同步副本）。

### 6.3 监控能力

#### 6.3.1 现有内部指标

`pkg/perf_metrics` 以 **模型 × 分组 × 时间桶** 为主键聚合原子计数器（`types.go:101-109`）：

| 原始量 | 派生指标 | 计算式（`metrics.go:445-450`） |
| --- | --- | --- |
| `requestCount` / `successCount` | 成功率 % | `success/request*100` |
| `totalLatencyMs` | 平均时延 | `total/count` |
| `ttftSumMs` / `ttftCount` | 平均 TTFT（仅统计已发出首包的流） | `sum/n` |
| `outputTokens` / `generationMs` | 平均 TPS | `outputTokens/(generationMs/1000)` |

- 采样点：`controller/relay.go:134` 的 defer → `perfmetrics.RecordRelayResult`（`metrics.go:32-64`），一次请求一条样本。
- 结果分类（`outcome.go:23-121`）：客户端取消、业务拒止、内容审查、ping 失败 → `OutcomeIgnored`；HTTP 400/405/409/413/415/422 忽略；上游鉴权失败/配额耗尽/5xx 记为失败。**这套语义保证指标不被客户端行为污染**，是 SLO 计算的基础。
- 桶宽 `BucketTime`：`minute|5min|hour`，默认 **hour / 3600 s**；`flushLoop` 每 `FlushInterval`（默认 5 分钟，最小 1）把"已完结"的桶 `UpsertPerfMetric` 增量写 `perf_metrics`；DB 失败则把计数回灌内存重试；内存中超过 24 h 的桶丢弃（`flush.go:64-68`）。
- 跨实例聚合：每个样本同时 `HINCRBY` 进 Redis `perf:<model>:<group>:<bucketTs>`（TTL 1 h，1 s 超时），因此控制台看到的是全局值。
- 查询窗口：默认 24 h，上限 30 天（`metrics.go:92-98`）。
- 暴露方式：`GET /api/perf-metrics`、`GET /api/perf-metrics/summary`（`router/api-router.go:37-42`），权限为 `HeaderNavModulePublicOrUserAuth("pricing")`。

#### 6.3.2 系统与运行时监控

| 能力 | 实现 | 参数 |
| --- | --- | --- |
| 资源采样 | `common.StartSystemMonitor()`（`common/system_monitor.go:37-76`）每 5 s 采 CPU/内存/磁盘（关闭时 30 s） | 阈值来自 `setting/performance_setting/config.go:30-40`：`MonitorEnabled=true`、`CPU=90`、`Mem=90`、`Disk=95`；**注意 `common/performance_config.go:17-22` 的初始化默认 Disk=90，两处不一致（R-10）** |
| 过载摘流 | `middleware/performance.go:41-70` 返回 **503**，错误类型 `system_cpu_overloaded` / `system_memory_overloaded` / `system_disk_overloaded`（`/v1/messages` 返回 Claude 形态错误体） | 见 6.4.4 |
| 连接数 | `middleware/stats.go` 的 `activeConnections`（**唯一**的实时并发指标） | — |
| 管理端点 | `/api/performance/{stats,disk_cache,reset_stats,gc,logs}`（root only，`router/api-router.go:237-245`） | 支持手工触发 GC、清磁盘缓存、清日志 |
| CPU 剖析 | `ENABLE_PPROF=true` → pprof 监听 `0.0.0.0:8005` + CPU 触发 dump 到 `./pprof/cpu-*.pprof`（`common/pprof.go`）+ `common.Monitor()` | **必须仅内网可达，严禁暴露公网** |
| 持续剖析 | `common.StartPyroScope()`（`main.go:175`），`PYROSCOPE_*` 环境变量 | 建议接 ARMS 持续剖析或自建 Pyroscope |
| 节点存活 | `service.StartSystemInstanceReporter()` 上报 `system_instances`，控制台 `/api/system-info/{instances,stale-instances}` 可查看与清理 | 多实例部署的可观测基础 |

#### 6.3.3 需补建：Prometheus 指标面与探针

**[需补建]** 当前**没有任何 Prometheus exporter**（全仓库唯一的 prometheus import 是 `controller/channel_inference.go:20`，用于探测**上游**的 `/health`、`/version`、`/v1/models`、`/metrics` 能力，与网关自身无关）；也没有 `/health`、`/ready` 路由。落地方案：

1. 新增 `GET /healthz`（liveness，无依赖检查）、`GET /readyz`（readiness，检查主库 `DB.Ping()` + 日志库 + Redis + 渠道缓存已初始化），公开免鉴权、不写访问日志。
2. 新增 `GET /metrics`（root 或内网 ACL），导出：`newapi_http_requests_total{route,code}`、`newapi_http_request_duration_seconds`（histogram）、`newapi_active_connections`、`newapi_relay_upstream_duration_seconds{channel,model,outcome}`、`newapi_relay_retries_total{reason}`（reason 取 `service/relay_error.go:21-58` 的决策原因）、`newapi_channel_status{channel_id}`、`newapi_quota_preconsume_total`、`newapi_quota_refund_total`、`newapi_rate_limit_rejections_total{mark}`、`newapi_perf_{requests,success,latency_ms,ttft_ms,output_tokens,generation_ms}`（直接由 `perf_metrics` 内存桶导出，避免二次统计）、`newapi_system_{cpu,mem,disk}`、`newapi_system_task_lock_renew_failures_total`、`go_*`、`process_*`。
3. 用 ServiceMonitor / PodMonitor 抓取，或 `prometheus-pushgateway`（长驻 scrape 更稳）。

#### 6.3.4 监控指标采集与告警时序

```mermaid
sequenceDiagram
  autonumber
  participant RL as 中继请求
  participant MEM as perf_metrics 内存桶
  participant RD as Redis perf 哈希
  participant FL as flushLoop 每 5 分钟
  participant PM as perf_metrics 表
  participant API as 查询接口
  participant WEB as 控制台性能面板
  participant PROM as Prometheus 需补建
  participant GRF as Grafana 与 ARMS
  participant ALR as 告警 钉钉或短信或电话

  RL->>MEM: 请求结束按 outcome 记一次样本
  RL->>RD: HINCRBY 跨实例聚合 TTL 1 小时
  FL->>PM: 已完结桶增量 upsert 冲突键为模型分组桶时间
  FL->>PM: 写库失败则计数回灌内存下次重试
  FL->>PM: RetentionDays 大于 0 时清理过期桶 默认 0 永不清理
  API->>PM: 按窗口查询 默认 24 小时上限 30 天
  API->>WEB: 渲染成功率 时延 TTFT TPS
  PROM->>MEM: 抓取导出器 需补建
  PROM->>GRF: 保存两年降采样
  GRF->>ALR: 成功率低于 99.5 持续 2 分钟 触发 P1
  GRF->>ALR: 5xx 比例超阈值或 p95 时延劣化 触发 P2
  GRF->>ALR: 错误预算 30 天窗口燃尽 触发发布冻结
```

**告警规则基线**（阈值需在压测后校准）：

| 告警 | 表达式（Prometheus 语义） | 窗口 | 级别 | 处置 SOP |
| --- | --- | --- | --- | --- |
| 网关 5xx 比例 | `rate(newapi_http_requests_total{code=~"5.."}[2m]) / rate(...[2m]) > 0.1%` | 2 min | P1 | 检查实例健康 → 回滚灰度版本（6.6） |
| 中继成功率跌破 SLO | `min by (model) (newapi_perf_success_rate) < 99.0` | 5 min | P1 | 看渠道状态 → 手工禁用故障渠道 |
| TTFT 劣化 | `p95(newapi_relay_upstream_duration_seconds) > 8s` | 5 min | P2 | 检查上游与超时配置 |
| 渠道批量自动禁用 | `increase(newapi_channel_status_changes{to="3"}[10m]) > 3` | 10 min | P1 | 判定上游区域性故障 → 切换备用区域渠道 |
| 限流拒绝突增 | `rate(newapi_rate_limit_rejections_total[5m]) > 5/s` | 5 min | P3 | 判定是否为攻击或误配 → 调 `GLOBAL_API_RATE_LIMIT` |
| 过载摘流生效 | `rate(newapi_http_requests_total{code="503"}[2m]) > 0` | 2 min | P2 | 扩容或调低 `MaxConcurrentStreams` |
| Redis 不可用 | `newapi_redis_up == 0` | 1 min | P0 | 限流会 **fail-closed 返回 500**，必须立即处理（6.4.3） |
| 任务租约续期失败 | `increase(newapi_system_task_lock_renew_failures_total[5m]) > 0` | 5 min | P2 | 检查数据库慢查询与实例 GC |
| 磁盘缓存水位 | `newapi_system_disk_used_percent > 85` | 10 min | P3 | 调 `DiskCache` 清理接口或扩容 |
| 额度对账不平 | 每日对账任务：`sum(logs.quota) != delta(users.used_quota)` | 24 h | P1 | 计费不变量告警（第九章 R-12） |

### 6.4 限流能力

#### 6.4.1 三套算法并存（精确区分）

| 中间件 | 算法 | 存储 | 失败语义 |
| --- | --- | --- | --- |
| `middleware/rate-limit.go`（全局/网页/关键/搜索/上传下载） | **固定窗口**：Redis Lua 原子 `INCR → EXPIRE → TTL`，返回 `{allowed,count,ttl}`（`:22-36`）。代码注释明确保留"窗口边界最多 2 倍突发"的语义、**禁止改成滑动 ZSET**（`:17-21`） | Redis；无 Redis 时回落 `common.InMemoryRateLimiter` | Redis 出错 **fail-closed 返回 500**（`:117-120,236-240`）；内存回落是**滑动窗口**（per-key FIFO + LRU 空闲淘汰，`RateLimitKeyExpirationDuration=20min`） |
| `middleware/model-rate-limit.go`（模型维度） | 总请求：**令牌桶**（`common/limiter`，Lua 服务端时间桶，容量 = `count*duration`，速率 = `count`）；成功请求：**Redis LIST 滑动窗口**（`LPUSH`+`LTRIM 0,max-1`+`EXPIRE`，key `rateLimit:MRRLS:<uid>`，`:28-65`） | Redis 或内存 | 仅当"HTTP <400 且流未失败"才计入成功窗口（`:169-172`）；Redis 路径返回 429 + OpenAI 错误体，内存路径返回裸 429 |
| `middleware/email-verification-rate-limit.go` | 固定窗口，mark `EV`，**硬编码 2 次 / 30 秒**（`:12-16`） | Redis | Redis 出错 **降级到内存**（`:25-28`），与全局策略相反 |
| `middleware/request_body_limit.go` | 体积上限（非速率）：匿名接口 `constant.AnonymousRequestBodyLimitKB`，为负时兜底 **512 KB**；全局解压后上限 `MAX_REQUEST_BODY_MB` 默认 128 | 内存 | 413 |
| `middleware/turnstile-check.go` | 人机验证，**不是限流**：所有拒绝返回 **HTTP 200 + `success:false`**（`:20-59`） | — | 对上层监控不可见，需在 SLS 侧按 `success:false` 单独统计（R-15） |

#### 6.4.2 默认参数（`common/init.go:123-137`，声明在 `common/constants.go:210-231`）

| 中间件 | 环境变量（开关 / 次数 / 窗口秒） | 默认值 | mark |
| --- | --- | --- | --- |
| `GlobalAPIRateLimit` | `GLOBAL_API_RATE_LIMIT_ENABLE` / `GLOBAL_API_RATE_LIMIT` / `_DURATION` | **true / 360 / 180** | `GA` |
| `GlobalWebRateLimit` | `GLOBAL_WEB_RATE_LIMIT*` | **true / 120 / 180** | `GW` |
| `CriticalRateLimit`、`UserCriticalRateLimit(scope)` | `CRITICAL_RATE_LIMIT*` | **true / 20 / 1200** | `CT` / `UC:<scope>` |
| `SearchRateLimit`（按用户） | `SEARCH_RATE_LIMIT*` | **true / 10 / 60** | `SR` |
| `Upload` / `Download` | 无开关，始终启用 | **10 / 60** | `UP` / `DW` |
| 模型维度 | option 键 `ModelRequestRateLimitEnabled` / `Count` / `DurationMinutes` / `SuccessCount` / `Group`（`model/option.go:148-151,179,441,612-619`） | `false / 0（不限）/ 1 / 1000`，分组覆盖走 `GetGroupRateLimit`（`setting/rate_limit.go:47-59`），校验上限 `MaxInt64/86400` | `MRRLS` |

> 限流参数是 **option（数据库热更新）** 而非环境变量，因此**可以在不发版的情况下调整模型维度限流**，这是最重要的应用层止血手段；而全局/关键接口限流是环境变量，改动需要滚动重启。

#### 6.4.3 限流执行时序

```mermaid
sequenceDiagram
  autonumber
  participant CLI as 客户端
  participant MW as 全局限流中间件
  participant RD as Redis
  participant MEM as 内存限流器
  participant MRL as 模型维度限流
  participant HOTCFG as 热更新配置
  participant BIZ as 业务处理

  CLI->>MW: 命中受保护路由
  MW->>MW: 生成 key 为 rateLimit v2 ip 或 user 加 mark
  alt Redis 可用
    MW->>RD: EVAL Lua 原子 INCR 首次 EXPIRE 返回 TTL
    RD-->>MW: allowed count ttl
  else Redis 故障
    MW-->>CLI: 500 且 fail-closed 拒绝
  end
  alt 被限
    MW-->>CLI: 429 附带 Retry-After 秒数
  else 放行
    MW->>MRL: 进入模型维度限流
    MRL->>HOTCFG: 按分组读取 Count Duration SuccessCount
    MRL->>RD: 令牌桶扣减总量 与 LIST 滑动窗口查成功数
    alt 超限
      MRL-->>CLI: 429 并返回 OpenAI 形态错误体
    else 通过
      MRL->>BIZ: 继续 Distribute 与中继
      BIZ-->>MRL: 响应完成
      MRL->>RD: 仅当 status 小于 400 且流未失败才记成功样本
    end
  end
```

**关键提示**：全仓库 **没有任何 `X-RateLimit-*` 响应头**，只有 `Retry-After`（`writeRateLimited:139-145`）。客户 SDK 无法自适应退避，改进见 R-09。

### 6.5 灰度发布能力

灰度必须 **双轨并行**，因为单一二进制把前端、中继、计费打包在一起（1.2），代码灰度与业务灰度的爆炸半径完全不同。

#### 6.5.1 轨道 A：业务灰度（ **[现状]** 已具备，分钟级、无需发版）

| 手段 | 载体 | 粒度 | 收敛时延 | 适用 |
| --- | --- | --- | --- | --- |
| 分组倍率与模型倍率 | `setting/ratio_setting/` + `options` | 按用户分组 | ≤ 60 s | 新模型只对内部分组开放 |
| 渠道 `tag` + 约束 | `channels.tag`、`model/channel_constraint.go` | 按渠道集合 | ≤ 60 s | 新供应商只服务特定分组 |
| 渠道 `priority` | `abilities.priority` | 优先级分层（第 N 次重试用第 N 层） | ≤ 60 s | 新渠道放最低层做影子流量 |
| 渠道 `weight` | `abilities.weight`（槽位 `weight+10`） | 加权随机 | ≤ 60 s | 百分比放量；注意 0 权重仍有基线命中 |
| `model_mapping` | `channels.model_mapping` | 客户端模型名 → 上游模型名 | ≤ 60 s | 换上游实现而客户端无感 |
| 请求策略 | `model/request_policy.go` + `service/request_policy.go`（决策事件写入 `logs.other`） | 每请求 | ≤ 60 s | 重试/pin/严格会话策略灰度 |
| 管理端 pin | token 第二段 → `ContextKeyAdminChannelPin` | 指定令牌 | 即时 | 内部账号定点验证 |
| 会话亲和 | `service/channel_affinity.go`（Redis，默认 TTL 3600 s） | 按会话 | 即时 | 保证灰度期同一会话稳定 |
| 前端模块开关 | `header_nav` 配置 + `MigrateRetiredFrontendOptions` | 按模块/角色 | ≤ 60 s | 控制台新功能可见性 |

```mermaid
sequenceDiagram
  autonumber
  participant OPS as 运维或产品
  participant ADM as 控制台设置页
  participant API as PUT option 接口
  participant DB as options 表
  participant N0 as 本节点内存
  participant POLL as 其他节点 SyncOptions
  participant RD as Redis 路由快照
  participant GW as 网关请求路径

  OPS->>ADM: 把新渠道权重设为 10 并限定分组
  ADM->>API: 提交配置
  API->>DB: 落库
  API->>N0: 立即生效
  POLL->>DB: 60 秒内轮询拉取
  POLL->>POLL: SyncChannelCache 重建 group2model2channels
  GW->>RD: 按优先级与权重选择 新渠道获得基线流量
  GW->>DB: 决策事件写入 logs.other 便于对比
  OPS->>ADM: 观察 perf_metrics 新渠道成功率与 TTFT
  alt 指标劣化
    OPS->>ADM: 权重归零或禁用渠道 60 秒内止血
  else 指标达标
    OPS->>ADM: 阶梯提升权重到目标比例
  end
```

#### 6.5.2 轨道 B：代码灰度（ **[需补建]**）

利用"单二进制 + 无状态实例"的特性，用 **ALB 服务器组权重 / ACK 双 Deployment** 做版本双轨：

1. `new-api-stable`（N 副本，标签 `track=stable`）与 `new-api-canary`（1 副本，标签 `track=canary`）指向同一 Service 选择器的两个服务器组。
2. ALB 按权重 100/0 → 95/5 → 80/20 → 50/50 → 0/100 逐级放量，每级观察 ≥ 15 min（3 个 `FlushInterval` 周期，确保 `perf_metrics` 桶已落库）。
3. 会话一致性：**中继 API 是无会话的（token 在 Redis/DB）**，因此 canary/stable 混跑不会破坏请求；但控制台登录与 refresh cookie 依赖 `SESSION_SECRET` 一致（多机部署必须显式设置，见 `docker-compose.yml` 注释），否则 canary 会造成随机登出。
4. 数据库前向兼容：canary 与 stable 必须能读写同一 schema（禁止在本次发布做破坏性迁移，见 6.6、R-03）。
5. 灰度准入判定（自动门禁）：canary 的 `success_rate ≥ stable - 0.2pp`、`p95_latency ≤ stable * 1.15`、`5xx_rate < 0.1%`、无新增 panic 关键字，任一不满足自动把权重打回 0。
6. 前端灰度：静态资源版本号来自 `VITE_REACT_APP_VERSION`（= `VERSION` 文件内容）+ `middleware/cache.go:14` 的硬编码 `Cache-Version`。**必须**把 `Cache-Version` 改为构建期注入（R-02），否则 canary 与 stable 会共享同一份 CDN index.html，导致 SPA chunk 404。

```mermaid
sequenceDiagram
  autonumber
  participant CI as CI 流水线
  participant ACR as 阿里云容器镜像服务
  participant K8S as ACK 集群
  participant ALB as ALB  ingress
  participant ST as stable 副本组
  participant CN as canary 副本组
  participant PR as Prometheus 与 Grafana
  participant GATE as 灰度门禁 Job
  participant OPS as 值班

  CI->>CI: 跑 make test 与 relaykit 独立构建 与 bun typecheck 与 lint
  CI->>ACR: 推送镜像 tag 为 git sha 与多架构 manifest 与 cosign 签名
  CI->>K8S: 只更新 canary Deployment 镜像
  K8S->>CN: 滚动起 1 副本 就绪探针 readyz 通过后接流
  ALB->>CN: 权重 5 到 20
  CN->>CN: 与 stable 共用主库 Redis 与日志库
  PR->>CN: 抓取 canary 指标
  GATE->>PR: 比对 canary 与 stable 的成功率 时延 5xx panic
  alt 门禁通过
    GATE->>ALB: 提升权重 50 后 100
    ALB->>ST: stable 滚动升级到新版本 成为新的 stable
    GATE->>ALB: 删除或保留 0 权重 canary
  else 门禁失败
    GATE->>ALB: 权重立即打回 0
    GATE->>OPS: 触发 P1 告警 附 canary 日志与指标快照
    OPS->>K8S: 回滚 canary 镜像或整体回滚
  end
```

### 6.6 回滚能力

| 回滚层级 | 手段 | 时延 | 数据影响 | 现状 |
| --- | --- | --- | --- | --- |
| 流量回滚（业务止血） | 渠道禁用 / 权重归零 / 分组收回 / `AutomaticRetryStatusCodes` 收紧 | ≤ 60 s（轮询） | 无 | **[现状]** |
| 配置回滚 | `PUT /api/option` 改回旧值；`logs`/`audit_logs` 记录 key 级变更历史 | ≤ 60 s | 无 | **[现状]**，但 `options` 无值级历史，需靠审计日志人工回溯（R-15） |
| 灰度回滚 | ALB 权重打回 0 / `kubectl rollout undo` | ≤ 2 min | 无 | **[需补建]** |
| 整体版本回滚 | 镜像 tag 回退（ACR 保留近 20 个 tag + cosign 校验） | ≤ 5 min | 需前向兼容 | **[需补建]** |
| 架构回滚 | **无 down migration**，只能"恢复备份"或"前向修复" | 10 min ~ 数小时 | RPO 取决于备份点 | **[缺口] R-03** |
| 数据回滚 | RDS 自动备份 + binlog/WAL 归档 + 按时间点恢复（PITR） | RTO ≤ 30 min | 期间写入丢失窗口需对账 | **[需补建]** |
| 计费一致性回滚 | `RefundFailedRequestBilling` + `subscription_pre_consume_records.request_id` 幂等 + 对账补偿任务 | 实时 / 小时级 | 无重复扣费 | **[现状]** 部分 |

**回滚决策树（必须写进值班 SOP）**：

```mermaid
flowchart TD
  A["告警触发 或 用户反馈"] --> B{"错误是否只影响<br/>某个模型或分组"}
  B -->|是| C["业务止血<br/>禁用渠道 或 权重归零 60 秒生效"]
  C --> D{"恢复"}
  D -->|否| E["回退相关 option 配置"]
  D -->|是| F["结束 记录事件"]
  B -->|否| G{"是否与某个版本相关"}
  G -->|是| H{"canary 是否独立"}
  H -->|是| I["ALB 权重打回 0<br/>1 分钟内止血"]
  H -->|否| J["rollout undo 回 stable 镜像<br/>保留新 schema"]
  G -->|否| K{"是否数据库相关"}
  K -->|是| L{"是否破坏性迁移"}
  L -->|否| M["前向修复 不回滚 schema"]
  L -->|是| N["PITR 恢复从库 校验后切换<br/>同时冻结发布"]
  K -->|否| O["检查上游区域性故障<br/>切备用区域渠道"]
  E --> F
  I --> F
  J --> F
  M --> F
  N --> F
  O --> F
```

**硬性约束（回滚可行性的前提）**：
1. 发布顺序必须 **master 节点先升级并跑完迁移**，slave 后升级（`model/main.go:262-267`），否则 slave 可能在 schema 就绪前接流。
2. 迁移必须"只加不减"：新列可空或有默认值，禁止在同一发布窗口内删列/改类型/收紧约束（这是 AutoMigrate 的天然限制，必须靠流程约束）。
3. `VERSION` 文件必须有值，否则回滚时无法从 `/api/status` 判断线上实际版本（R-02）。
4. 每次发布必须记录 `image tag → git sha → 变更的 option key 列表`，作为回滚点元数据。

---

## 七、阿里云部署方案（菲律宾 + 泰国）

### 7.1 地域选择与网络拓扑

**延迟事实（公网 RTT 量级，用于决策，实际以拨测为准）**：

| 用户所在地 | 到马尼拉 `ap-southeast-6` | 到曼谷 `ap-southeast-7` | 到新加坡 `ap-southeast-1` |
| --- | --- | --- | --- |
| 菲律宾（马尼拉/宿务） | **5–15 ms** | 60–90 ms | 30–45 ms |
| 泰国（曼谷） | 55–80 ms | **5–20 ms** | 25–40 ms |

结论：**双区域主备（Active-Active）**，马尼拉承载菲律宾，曼谷承载泰国，新加坡作为灾备第三区域与上游出口汇聚点。AI 网关是长连接流式场景，RTT 直接叠加到 TTFT 体感，不能只放一个区域。

```mermaid
flowchart TB
  subgraph USERS["终端用户"]
    PH["菲律宾客户"]
    TH["泰国客户"]
    OTHER["其他地区客户"]
  end

  subgraph EDGE["阿里云全球接入"]
    GTM["云解析 DNS 全局流量管理 GTM<br/>按 Latency 就近解析 + 健康探测切换"]
    GA["全球加速 GA<br/>跨境回源与上游出口"]
    CDN["DCDN 静态加速<br/>web/dist 资源"]
    WAF1["WAF 3.0 实例 马尼拉"]
    WAF2["WAF 3.0 实例 曼谷"]
  end

  subgraph MNL["区域一 ap-southeast-6 马尼拉 主站点"]
    ALB1["ALB 多可用区<br/>idleTimeout 60s + SSE 心跳保活"]
    ACK1["ACK Pro 集群<br/>可用区 A + B"]
    RDS1["RDS PostgreSQL 高可用版<br/>主 A 备 B + 只读实例"]
    TAIR1["Tair 主备版"]
    CK1["云数据库 ClickHouse<br/>日志"]
    OSS1["OSS 同城冗余"]
  end

  subgraph BKKT["区域二 ap-southeast-7 曼谷 主站点"]
    ALB2["ALB 多可用区"]
    ACK2["ACK Pro 集群 可用区 A + B"]
    RDS2["RDS PostgreSQL 高可用版"]
    TAIR2["Tair 主备版"]
    CK2["ClickHouse"]
    OSS2["OSS"]
  end

  subgraph SG["区域三 ap-southeast-1 新加坡 灾备与出口"]
    DR["DTS 双向同步只读副本<br/>冷备 ACK 集群"]
    EGR["统一上游出口 NAT 与固定 EIP 池"]
  end

  MON["可观测中心<br/>SLS + ARMS + Prometheus + Grafana + 拨测"]

  PH --> GTM
  TH --> GTM
  OTHER --> GTM
  GTM -->|"PH 用户"| WAF1
  GTM -->|"TH 用户"| WAF2
  CDN --> OSS1
  WAF1 --> ALB1 --> ACK1
  WAF2 --> ALB2 --> ACK2
  ACK1 --> RDS1
  ACK1 --> TAIR1
  ACK1 --> CK1
  ACK1 --> OSS1
  ACK2 --> RDS2
  ACK2 --> TAIR2
  ACK2 --> CK2
  RDS1 -.->|"DTS 增量同步"| RDS2
  RDS2 -.->|"DTS 增量同步"| RDS1
  RDS1 -.->|"每日全量 + 归档"| DR
  ACK1 -->|上游调用| EGR
  ACK2 -->|上游调用| EGR
  EGR --> GA
  GA --> UPSTREAM["OpenAI / Anthropic / Google / Azure / AWS 等"]
  ACK1 --> MON
  ACK2 --> MON
```

### 7.2 云资源清单（生产最小高可用配置）

| 层 | 产品 | 规格建议 | 数量 | 关键配置 | 可用性贡献 |
| --- | --- | --- | --- | --- | --- |
| 接入 | 云解析 DNS + GTM | 旗舰版 | 1 | 按延迟解析，HTTP 健康探测 15 s，故障切换 ≤ 60 s | 单区域故障自动切走 |
| 接入 | DCDN | 按量 | 1 | `index.html` 强制 `no-cache`，带指纹的 chunk 缓存 7 天 | — |
| 接入 | WAF 3.0 | 企业版 | 2（每区域） | 放行支付回调路径；CC 防护阈值对齐 `GLOBAL_API_RATE_LIMIT` | 抗 L7 |
| 接入 | ALB | 标准版 II | 2（每区域多 AZ） | `AlbConfig` listeners：`idleTimeout=60`、`requestTimeout=180`（均为产品上限，SSE 靠网关 ping 保活）、HTTPS TLS1.2+1.3、`canary-weight` 灰度 | 99.99% |
| 计算 | ACK Pro 托管版 | 控制面 SLA 99.95% | 2 集群 | Kubernetes 1.31+，CNI Terway，多 AZ | 99.95% |
| 计算 | ECS 节点池 | `g8i.2xlarge`(8C32G) | 每区域 ≥ 4（跨 2 AZ） | 系统盘 100 G ESSD PL1 + 数据盘 200 G ESSD（`/data` 与 `/app/logs`） | — |
| 数据 | RDS PostgreSQL 高可用版 | pg 15，`rds.pg.c2.4xlarge` 或 16C64G | 2（每区域）+ 每区域 1 只读 | 主备跨 AZ、`SQL_MAX_OPEN_CONNS` 对齐连接上限、PITR 保留 7 天、每日全量 + WAL 归档到 OSS | 99.99% |
| 缓存 | Tair（Redis 兼容）| 主备版 4 GB（生产建议集群版） | 2 | 跨 AZ、密码 + 内网 ACL、`maxmemory-policy allkeys-lru` | 99.99% |
| 日志 | 云数据库 ClickHouse | 24.8 社区版 2 节点 | 2 | 仅 `LOG_SQL_DSN`、`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` | — |
| 存储 | OSS | 标准 + 低频生命周期 | 2 bucket | 同城冗余 ZRS、版本开启、生命周期 90 天转归档、防盗链 + 签名 URL | 99.995% |
| 同步 | DTS | 小型 | 2 链路 | 双向增量、冲突检测、延迟告警 > 5 s | 跨区 DR |
| 观测 | SLS + ARMS + Prometheus（ARMS Prometheus 版）+ Grafana 服务 | 按量 | 1 套 | 见 7.8 | — |
| 观测 | 云监控拨测（站点监控） | 菲律宾 + 泰国 + 新加坡探测点 | 3+ | 探测 `GET /api/status` 与 `GET /healthz`，1 min 间隔 | 真实用户视角 |
| 安全 | KMS 凭据管家 | 软件密钥 | 1 | 托管 `SQL_DSN`、`REDIS_CONN_STRING`、`SESSION_SECRET`、支付密钥 | — |
| 网络 | VPC + vSwitch + NAT + EIP | /16 与 3 个 /20 | 每区域 1 套 | 私有子网跑 Pod 与 DB，仅 ALB 在公网子网；NAT 出口固定 EIP 池用于上游白名单 | — |

### 7.3 应用部署形态选择

| 方案 | 适用 | 说明 |
| --- | --- | --- |
| **推荐：ACK + ALB Ingress + 双 Deployment（stable/canary）** | 生产 | 满足 99.95%、支持自动扩缩与灰度门禁；见 7.4 |
| 备选：ECS + Docker Compose（多机） | 成本敏感、单区域起步 | 见 7.5，需自建 Nginx/ALB 后端挂载与 keepalived |
| 不推荐：SAE / 函数计算 | — | SSE 长连接与 120 s 优雅停机、60 s 配置轮询、后台租约任务与 Serverless 冷启动/请求超时模型不匹配 |
| 不推荐：单实例 ECS | — | 无法达到 99.95%（任何滚动发布都算停机） |

### 7.4 ACK 部署清单（YAML）

#### 7.4.1 命名空间、配置与密钥

```yaml
# deploy/aliyun/00-namespace-config.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: new-api
  labels: { "app.kubernetes.io/name": "new-api" }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: new-api-env, namespace: new-api }
data:
  # ---- 运行时 ----
  GIN_MODE: "release"
  TZ: "Asia/Manila"                 # 曼谷站点改 Asia/Bangkok；统计按小时分桶建议统一 UTC 并单列展示时区
  PORT: "3000"
  ERROR_LOG_ENABLED: "true"         # 记录 type=5 错误日志
  BATCH_UPDATE_ENABLED: "true"      # 额度批量合并写，降低主库写放大
  MEMORY_CACHE_ENABLED: "true"
  SYNC_FREQUENCY: "30"              # 由 60 收紧到 30，缩小配置与路由收敛窗口
  SESSION_COOKIE_SECURE: "true"
  SESSION_COOKIE_TRUSTED_URL: "https://api.example-ph.com,https://api.example-th.com"
  TRUSTED_PROXIES: "10.0.0.0/8"     # 必须显式声明 VPC 段，否则默认信任 RFC1918 并告警
  MAX_REQUEST_BODY_MB: "64"
  USER_SESSION_ACTIVE_LIMIT: "50"
  USER_SESSION_ISSUANCE_LIMIT: "100"
  USER_SESSION_REVOKED_RETENTION_DAYS: "7"
  SHUTDOWN_TIMEOUT_SECONDS: "150"   # SIGTERM 后收尾在途请求的窗口，> 最长 SSE 预期并与 ALB connection-drain(120s) 对齐；与 idle 60s 上限无关（后者只掐无心跳的静默连接）
  RELAY_RESPONSE_HEADER_TIMEOUT: "600"
  RELAY_MAX_IDLE_CONNS: "2000"
  RELAY_MAX_IDLE_CONNS_PER_HOST: "400"
  RELAY_IDLE_CONN_TIMEOUT: "90"
  STREAMING_TIMEOUT: "300"
  SQL_SLOW_THRESHOLD_MS: "200"
  SQL_MAX_OPEN_CONNS: "300"         # 需 < RDS 最大连接数 / 实例数
  SQL_MAX_IDLE_CONNS: "60"
  SQL_MAX_LIFETIME: "60"
  REDIS_POOL_SIZE: "40"
  ENABLE_PPROF: "false"             # 仅排障时按节点临时开启，且 8005 严禁出网
  NODE_TYPE: "slave"                # 仅 master Deployment 置为 master
  LOG_SQL_CLICKHOUSE_TTL_DAYS: "90"
---
apiVersion: v1
kind: Secret
metadata: { name: new-api-secret, namespace: new-api }
type: Opaque
stringData:
  # 下列值由 KMS 凭据管家通过 ExternalSecret / RRSA 注入，禁止写进 Git
  SQL_DSN: "postgresql://newapi:REPLACE_ME@pg-mnl-rw.pg.rds.aliyuncs.com:5432/newapi?sslmode=require"
  LOG_SQL_DSN: "clickhouse://default:REPLACE_ME@clickhouse-mnl.clickhouse.rds.aliyuncs.com:9000/newapi_logs"
  REDIS_CONN_STRING: "redis://:REPLACE_ME@tair-mnl.redis.rds.aliyuncs.com:6379"
  SESSION_SECRET: "REPLACE_ME_32B_RANDOM_SAME_ACROSS_ALL_NODES_AND_REGIONS"
```

> **`SESSION_SECRET` 必须全区域全实例一致**（多机部署强制项，见 `docker-compose.yml` 注释）。若跨区使用不同值，GTM 切换区域的瞬间所有控制台会话失效。

#### 7.4.2 stable / canary 双 Deployment

```yaml
# deploy/aliyun/10-deployment-stable.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: new-api-stable
  namespace: new-api
  labels: { app: new-api, track: stable }
spec:
  replicas: 4                       # 跨 2 AZ，单 AZ 故障仍有 2 副本
  revisionHistoryLimit: 10
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }   # 0 不可用是 99.95% 的前提
  selector:
    matchLabels: { app: new-api, track: stable }
  template:
    metadata:
      labels: { app: new-api, track: stable }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "3000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: new-api                   # RRSA 绑定，访问 OSS/KMS/SLS
      terminationGracePeriodSeconds: 180            # 必须 > SHUTDOWN_TIMEOUT_SECONDS(150)
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { app: new-api } }
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { app: new-api } }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: new-api
          image: registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api:STABLE_SHA
          imagePullPolicy: IfNotPresent
          args: ["--log-dir", "/app/logs"]
          ports:
            - { containerPort: 3000, name: http }
          envFrom:
            - configMapRef: { name: new-api-env }
            - secretRef: { name: new-api-secret }
          env:
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }   # 用于审计与实例页识别
            - name: NODE_TYPE
              value: "slave"
          readinessProbe:
            httpGet: { path: /readyz, port: 3000 }        # 需补建；未实现前临时用 /api/status
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2                            # 快速摘流
          livenessProbe:
            httpGet: { path: /healthz, port: 3000 }        # 需补建；未实现前用 TCP 探针
            initialDelaySeconds: 20
            periodSeconds: 10
            failureThreshold: 3
          startupProbe:
            httpGet: { path: /api/status, port: 3000 }     # 覆盖 AutoMigrate 与缓存预热耗时
            failureThreshold: 60
            periodSeconds: 5
          resources:
            requests: { cpu: "2", memory: 2Gi, ephemeral-storage: 20Gi }
            limits:   { cpu: "4", memory: 4Gi }            # 内存 limit 必须设，配合 GC 与过载保护
          lifecycle:
            preStop:
              exec: { command: ["/bin/sh", "-c", "sleep 15"] }  # 等 ALB 摘除后端再收 SIGTERM
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: logs, mountPath: /app/logs }
      volumes:
        - { name: data, persistentVolumeClaim: { claimName: new-api-data } }
        - { name: logs, emptyDir: { sizeLimit: 10Gi } }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: new-api-stable, namespace: new-api }
spec:
  minAvailable: 3                   # 4 副本时允许 1 个维护性驱逐
  selector: { matchLabels: { app: new-api, track: stable } }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: new-api-stable, namespace: new-api }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: new-api-stable }
  minReplicas: 4
  maxReplicas: 16
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 55 } }
    - type: Pods
      pods: { metric: { name: newapi_active_connections }, target: { type: AverageValue, averageValue: "1200" } }
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600
      policies: [ { type: Pods, value: 1, periodSeconds: 120 } ]   # 缩容要慢，SSE 长连接迁移代价高
---
# canary 与上面唯一差异：labels/track=canary、replicas=1、minAvailable=1、
# PDB 独立、镜像为 CANDIDATE_SHA、ALB 服务器组独立、不打 HPA
```

> **master 节点单独处理**：必须存在一个 `NODE_TYPE=master` 的 Deployment（`replicas: 1`、`strategy: Recreate`、独立 PVC `ReadWriteOnce`）来跑 AutoMigrate 与 master-only 迁移；它**不接 ALB 流量**（不在 Service 选择器内），只跑后台任务与迁移。滚动发布顺序：先升级 master → schema 就绪 → 再滚动 stable slave → 最后升级 canary。这是解决 1.2 中"非 master 从不迁移"风险（R-04）的部署侧手段；master 故障后的接管时序、租约去重与 RTO 预算见附录B。

#### 7.4.3 AlbConfig、Service 与 ALB Ingress（含灰度）

> **官方核实后的关键事实**：ALB listener `idleTimeout` 取值 1–60 s（默认 15）、`requestTimeout` 取值 1–180 s（默认 60，超时由 ALB 直接返回 504），二者**只能在 `AlbConfig` CRD 的 `spec.listeners` 配置，不存在对应 Ingress 注解**；早期草案里 `idle-timeout: "900"` / `request-timeout: "0"` 均为无效写法。SSE 长流不被切断的前提是网关持续产生心跳事件（ping 默认关闭，须开启并设 15–20 s），完整论证见附录A.6。

```yaml
# deploy/aliyun/20-alb-ingress.yaml
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata:
  name: new-api-alb
  namespace: new-api
spec:
  config:
    name: new-api-alb
    addressType: Internet
    # zoneMappings: 至少 2 个可用区的 vSwitch（多 AZ 高可用前提）
    #   - vSwitchId: vsw-xxxx-mnl-a
    #   - vSwitchId: vsw-xxxx-mnl-b
  listeners:
    - port: 80
      protocol: HTTP            # 仅用于 301 跳转 HTTPS（ssl-redirect）
      requestTimeout: 30
    - port: 443
      protocol: HTTPS
      idleTimeout: 60           # 产品上限；SSE 保活靠网关 ping（15–20s 间隔）
      requestTimeout: 180       # 产品上限；只计"等待后端响应头"，不约束流时长
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: ingress.k8s.alibabacloud/alb
  parameters:
    apiGroup: alibabacloud.com
    kind: AlbConfig
    name: new-api-alb
---
apiVersion: v1
kind: Service
metadata: { name: new-api, namespace: new-api }
spec:
  type: ClusterIP
  selector: { app: new-api, track: stable }   # 只选 stable；灰度靠独立 canary Service
  ports: [ { name: http, port: 80, targetPort: 3000 } ]
---
apiVersion: v1
kind: Service
metadata: { name: new-api-canary, namespace: new-api }
spec:
  type: ClusterIP
  selector: { app: new-api, track: canary }
  ports: [ { name: http, port: 80, targetPort: 3000 } ]
---
# 主 Ingress：全部流量 → stable（不带 canary 注解）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api
  namespace: new-api
  annotations:
    alb.ingress.kubernetes.io/backend-protocol: "http"
    alb.ingress.kubernetes.io/ssl-redirect: "true"
    alb.ingress.kubernetes.io/healthcheck-enabled: "true"
    alb.ingress.kubernetes.io/healthcheck-path: "/api/status"      # 补建 readyz 后切换
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "10"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "2"
    alb.ingress.kubernetes.io/connection-drain-enabled: "true"
    alb.ingress.kubernetes.io/connection-drain-timeout: "120"      # 对齐 SHUTDOWN_TIMEOUT_SECONDS
spec:
  ingressClassName: alb
  tls:
    - hosts: [ "api.example-ph.com" ]
      secretName: api-example-ph-com-tls
  rules:
    - host: api.example-ph.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: new-api, port: { number: 80 } } }
---
# 灰度 Ingress：canary 注解必须在这条独立 Ingress 上，后端指向 canary Service；
# 权重由 GitOps 逐步改 5 -> 20 -> 50 -> 100（100 后合并回主 Ingress 并下线 canary）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api-canary
  namespace: new-api
  annotations:
    alb.ingress.kubernetes.io/canary: "true"
    alb.ingress.kubernetes.io/canary-weight: "5"
    # 内部账号白名单命中可叠加：alb.ingress.kubernetes.io/canary-by-header: "x-newapi-canary"
    alb.ingress.kubernetes.io/backend-protocol: "http"
spec:
  ingressClassName: alb
  rules:
    - host: api.example-ph.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: new-api-canary, port: { number: 80 } } }
```

> 注意两点与旧草案的差异：其一，Service 不再"一个 selector 同时匹配 stable 与 canary"——权重分流由 ALB 规则完成，两个轨道必须是两个 Service；其二，超时参数从注解移到 `AlbConfig.listeners`。

### 7.5 生产 Docker Compose 配置

两种用法：**(a)** 无 K8s 时的单机/多机快速生产部署；**(b)** 作为 ACK 之外的灾备冷站。相较仓库自带 `docker-compose.yml`（参考版，默认弱口令），下面这份是**生产加固版**：3 个网关实例做滚动发布单元、显式网络隔离、只读根文件系统、日志与指标 sidecar。

```yaml
# deploy/aliyun/docker-compose.prod.yml
# 用法：
#   单区域起步：docker compose -f docker-compose.prod.yml up -d --scale new-api=3
#   滚动发布：  docker compose -f docker-compose.prod.yml up -d --no-deps --no-build \
#                 --no-recreate new-api-canary && 切 ALB 权重 && 再逐个 replace new-api-stable-*
name: new-api-prod

x-newapi-common: &newapi-common
  image: registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api:${NEWAPI_VERSION:?set NEWAPI_VERSION}
  command: ["--log-dir", "/app/logs"]
  restart: unless-stopped
  read_only: true
  tmpfs:
    - /tmp:size=2g,mode=1777
  security_opt:
    - no-new-privileges:true
    - seccomp:unconfined
  cap_drop: [ALL]
  pids_limit: 4096
  mem_limit: 3g
  cpus: "3.5"
  ulimits: { nofile: { soft: 200000, hard: 200000 } }   # SSE 并发需要高 fd 上限
  volumes:
    - newapi-data:/data
    - ./logs:/app/logs
  networks: [app-net, data-net]
  depends_on:
    redis:      { condition: service_healthy }
    postgres:   { condition: service_healthy }
    clickhouse: { condition: service_started }
  env_file: [.env.prod]
  environment: &newapi-env
    GIN_MODE: "release"
    TZ: "Asia/Manila"
    PORT: "3000"
    ERROR_LOG_ENABLED: "true"
    BATCH_UPDATE_ENABLED: "true"
    MEMORY_CACHE_ENABLED: "true"
    SYNC_FREQUENCY: "30"
    SESSION_COOKIE_SECURE: "true"
    SESSION_COOKIE_TRUSTED_URL: "https://api.example-ph.com"
    TRUSTED_PROXIES: "172.20.0.0/16,10.0.0.0/8"
    SHUTDOWN_TIMEOUT_SECONDS: "150"
    STREAMING_TIMEOUT: "300"
    RELAY_RESPONSE_HEADER_TIMEOUT: "600"
    RELAY_MAX_IDLE_CONNS: "2000"
    RELAY_IDLE_CONN_TIMEOUT: "90"
    SQL_MAX_OPEN_CONNS: "200"
    SQL_MAX_IDLE_CONNS: "50"
    SQL_SLOW_THRESHOLD_MS: "200"
    REDIS_POOL_SIZE: "30"
    LOG_SQL_CLICKHOUSE_TTL_DAYS: "90"
    ENABLE_PPROF: "false"

services:
  # ---------------- 网关实例（多副本 + 灰度双轨） ----------------
  new-api-stable-1:
    <<: *newapi-common
    container_name: new-api-stable-1
    environment:
      <<: *newapi-env
      NODE_NAME: "mnl-stable-1"
      NODE_TYPE: "slave"
    labels: { track: "stable" }

  new-api-stable-2:
    <<: *newapi-common
    container_name: new-api-stable-2
    environment:
      <<: *newapi-env
      NODE_NAME: "mnl-stable-2"
      NODE_TYPE: "slave"
    labels: { track: "stable" }

  new-api-canary:
    <<: *newapi-common
    container_name: new-api-canary
    environment:
      <<: *newapi-env
      NODE_NAME: "mnl-canary-1"
      NODE_TYPE: "slave"
      NEWAPI_IMAGE_TAG: "${NEWAPI_CANARY_VERSION:-}"
    labels: { track: "canary" }

  # master：唯一执行迁移与 master-only 任务的节点，不接业务流量
  new-api-master:
    <<: *newapi-common
    container_name: new-api-master
    read_only: false          # 迁移与插件临时文件需要写自身目录
    environment:
      <<: *newapi-env
      NODE_NAME: "mnl-master-1"
      NODE_TYPE: "master"

  # ---------------- 基础设施 ----------------
  redis:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/redis:7.4-alpine
    container_name: new-api-redis
    restart: unless-stopped
    command:
      - redis-server
      - --requirepass
      - ${REDIS_PASSWORD:?}
      - --maxmemory
      - 3gb
      - --maxmemory-policy
      - allkeys-lru
      - --appendonly
      - "yes"
      - --appendfsync
      - everysec
      - --save
      - "900 1"
      - --tcp-backlog
      - "4096"
    volumes: [ redis-aof:/data ]
    networks: [ data-net ]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      timeout: 3s
      retries: 3
    # 生产强烈建议改用阿里云 Tair，删除本服务并把 REDIS_CONN_STRING 指向 Tair

  postgres:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/postgres:15.7-alpine
    container_name: new-api-pg
    restart: unless-stopped
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?}
      POSTGRES_DB: newapi
      POSTGRES_INITDB_ARGS: "--data-checksums"
      TZ: "UTC"
    command:
      - postgres
      - -c
      - shared_buffers=4GB
      - -c
      - work_mem=32MB
      - -c
      - max_connections=600
      - -c
      - log_min_duration_statement=200
      - -c
      - shared_preload_libraries=pg_stat_statements
      - -c
      - wal_level=logical
    volumes: [ pg-data:/var/lib/postgresql/data ]
    networks: [ data-net ]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d newapi"]
      interval: 10s
      timeout: 5s
      retries: 5
    # 生产建议改用 RDS 高可用版并删除本服务

  clickhouse:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/clickhouse-server:24.8-alpine
    container_name: new-api-clickhouse
    restart: unless-stopped
    ulimits: { nofile: { soft: 20000, hard: 20000 }, memlock: { soft: -1, hard: -1 } }
    environment:
      CLICKHOUSE_DB: newapi_logs
      CLICKHOUSE_USER: newapi
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD:?}
      CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: "1"
    volumes:
      - ck-data:/var/lib/clickhouse
      - ./deploy/clickhouse/users.xml:/etc/clickhouse-server/users.d/users.xml:ro
    networks: [ data-net ]
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- 'http://newapi:${CLICKHOUSE_PASSWORD}@localhost:8123/?query=SELECT%201' | grep -q 1"]
      interval: 15s
      timeout: 5s
      retries: 5

  # ---------------- 可观测 sidecar ----------------
  prometheus-node-exporter:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/prometheus/node-exporter:v1.8.2
    pid: host
    network_mode: host
    restart: unless-stopped
    volumes: [ /:/host:ro,rslave ]
    command: [ "--path.rootfs=/host", "--web.listen-address=:9101" ]

  cadvisor:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    devices: [ /dev/kmsg ]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [ app-net ]

  prometheus:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/prometheus/prometheus:v2.54.1
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=30d
      - --web.enable-lifecycle
    volumes:
      - ./deploy/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./deploy/prometheus/alert.rules.yml:/etc/prometheus/alert.rules.yml:ro
      - prom-data:/prometheus
    networks: [ app-net ]

  grafana:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/grafana/grafana:11.2.0
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin
      GF_AUTH_ANONYMOUS_ENABLED: "false"
      GF_SERVER_ROOT_URL: "https://ops.example-ph.com"
    secrets: [ grafana_admin ]
    volumes: [ grafana-data:/var/lib/grafana, ./deploy/grafana/provisioning:/etc/grafana/provisioning:ro ]
    networks: [ app-net ]

  alertmanager:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/prometheus/alertmanager:v0.27.0
    container_name: alertmanager
    restart: unless-stopped
    command: [ "--config.file=/etc/alertmanager/alertmanager.yml" ]
    volumes: [ ./deploy/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro ]
    networks: [ app-net ]

  # SLS Logtail（阿里云日志采集）；ACK 场景改用 logtail-ds DaemonSet
  logtail:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/log-service/logtail:latest
    container_name: logtail
    restart: unless-stopped
    command: [ "-service", "ilogtail" ]
    environment:
      ALIYUN_LOGTAIL_USER_ID: "${ALIYUN_UID}"
      ALIYUN_LOGTAIL_USER_DEFINED_ID: "new-api-mnl"
      ALIYUN_LOGTAIL_CONFIG: "/etc/ilogtail/conf/ap-southeast-6/ilogtail_config.json"
    volumes:
      - ./logs:/logtails/new-api:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [ app-net ]

  # 备份 sidecar：每日逻辑备份 + WAL 上传 OSS（使用 RDS 时可关闭）
  backup:
    image: registry-vpc.ap-southeast-6.aliyuncs.com/library/postgres:15.7-alpine
    container_name: new-api-backup
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        while true; do
          pg_dump -h postgres -U newapi -d newapi -Fc -f /backups/newapi-$$(date +%F).dump
          find /backups -name '*.dump' -mtime +14 -delete
          sleep 86400
        done
    volumes: [ backups:/backups ]
    networks: [ data-net ]

networks:
  app-net:  { driver: bridge }
  data-net: { driver: bridge, internal: true }   # 数据层禁止出公网

volumes:
  newapi-data:
  pg-data:
  redis-aof:
  ck-data:
  prom-data:
  grafana-data:
  backups:

secrets:
  grafana_admin: { file: ./secrets/grafana_admin.txt }
```

`.env.prod` 必配项（禁止使用仓库默认弱口令，仓库自带的 `123456` / `root` 全部必须替换）：

```bash
NEWAPI_VERSION=1.0.0-mnl            # 必须来自 CI 的 git sha，且同步写入镜像内 VERSION
NEWAPI_CANARY_VERSION=1.0.1-mnl
POSTGRES_PASSWORD=<KMS 生成>
REDIS_PASSWORD=<KMS 生成>
CLICKHOUSE_PASSWORD=<KMS 生成>
SQL_DSN=postgresql://newapi:...@pg-rw.internal:5432/newapi?sslmode=require
LOG_SQL_DSN=clickhouse://newapi:...@ck.internal:9000/newapi_logs
REDIS_CONN_STRING=redis://:...@tair.internal:6379
SESSION_SECRET=<openssl rand -base64 48，全实例全区域一致>
```

### 7.6 裸机 systemd（第三备选，仅小型环境）

`new-api.service` 已在仓库提供。多机部署要点：`ExecStart=/usr/local/bin/new-api --log-dir /var/log/new-api`、`LimitNOFILE=200000`、`Restart=always`、`After=network-online.target`，前置 Nginx 做 `proxy_read_timeout 900s; proxy_buffering off;`（SSE 必须关 buffering）。

### 7.7 发布与灰度流水线

```mermaid
flowchart LR
  A["PR 合并 main"] --> B["CI: go vet 与 make test<br/>relaykit GOWORK=off 独立构建<br/>bun typecheck lint test"]
  B --> C["构建镜像 多架构<br/>bun 前端阶段 注入 VERSION"]
  C --> D["推送 ACR + cosign 签名<br/>镜像 tag 等于 git sha"]
  D --> E["迁移预演<br/>对生产快照影子库跑 AutoMigrate 两次<br/>验证幂等与无重复 ALTER"]
  E --> F{"Schema 前向兼容检查<br/>禁止同窗口破坏性变更"}
  F -->|不通过| G["阻断发布 拆分为兼容发布与清理发布"]
  F -->|通过| H["GitOps 提交 canary 镜像"]
  H --> I["ACK 升级 master Deployment 完成迁移"]
  I --> J["canary 起 1 副本 readyz 通过"]
  J --> K["ALB 权重 5  percent"]
  K --> L{"自动门禁 15 分钟<br/>成功率 时延 5xx panic 对账"}
  L -->|失败| M["权重归零 + P1 告警"]
  M --> N["人工研判 回滚或修复"]
  L -->|通过| O["权重 20 到 50 到 100"]
  O --> P["stable 滚动升级 maxUnavailable 0"]
  P --> Q["canary 归位 0 权重保留 24 小时热回滚位"]
  Q --> R["更新发布记录 镜像 tag 与 sha 与 option 变更清单"]
```

**发布窗口与冻结策略**：菲律宾发薪日（每月 15/30 日）与当地工作时间 09:00–21:00 GMT+8 禁止发布；发布窗口固定在 **马尼拉时间 02:00–05:00**。错误预算燃尽 > 80% 时自动冻结非必要发布。

### 7.8 监控集成（阿里云侧）

| 数据面 | 阿里云产品 | 接入方式 | 保留 |
| --- | --- | --- | --- |
| 指标 | ARMS Prometheus 版 | ACK 装 arms-prometheus + ServiceMonitor 抓 `/metrics`（需补建）；ECS 场景用 prometheus agent 远程写 | 90 天热 + 2 年降采样 |
| 应用性能 | ARMS Application Monitoring | Go 应用接 OpenTelemetry SDK（需补建 R-07），或 eBPF 无侵入 | 30 天 |
| 持续剖析 | ARMS 持续剖析（Pyroscope 兼容） | `PYROSCOPE_*` 环境变量已内建 | 30 天 |
| 日志 | SLS | Logtail 采 `/app/logs` + stdout；`logs`/`audit_logs` 用 DTS 或应用双写投递 | sys 30 天 / audit 180 天 |
| 看板 | Grafana 服务 | 数据源 Prometheus + SLS；三块看板：SLA/SLO 燃尽、中继健康（模型 × 渠道）、容量与成本 | — |
| 拨测 | 云监控站点监控 | 探测点选马尼拉、曼谷、新加坡、东京、香港；断言 `success:true` + 版本匹配 | 15 个月 |
| RUM | 前端监控 ARMS RUM | 复用现有 Umami / GA 注入点（`main.go:248-289`）叠加 RUM | — |
| 告警 | ARMS 告警 + 云监控 | 钉钉/企业微信 + 短信 + 电话；P1 走电话，按 6.3.4 表落地；排班用告警值班表 | — |
| 审计合规 | 操作审计 ActionTrail + DB 审计 | 云 API 变更全部留痕；RDS SQL 洞察开启 | 180 天 |

### 7.9 环境矩阵与发布验证

| 环境 | 区域 | 数据库 | 用途 | 门禁 |
| --- | --- | --- | --- | --- |
| dev | 本地 | SQLite + `docker-compose.dev.yml` | 功能开发 | `bun run lint`、`make test` |
| staging（pre） | 新加坡 | RDS PG + Tair + ClickHouse | 集成与三数据库矩阵 | 每次合并主干；`SQL_DSN` 分别用 MySQL 8.2 / PG 15 / SQLite 跑同一套 E2E |
| perf | 新加坡 | 同 staging + mock 上游 | 3.9 压测场景矩阵 | 相对基线劣化 > 10% 阻断 |
| prod mnl | 马尼拉 | RDS PG HA + Tair + CH | 菲律宾流量 | 灰度门禁 |
| prod bkk | 曼谷 | RDS PG HA + Tair + CH | 泰国流量 | 与 mnl 错峰发布（先 bkk 后 mnl 或反之） |
| dr | 新加坡 | DTS 只读副本 + 冷备 ACK | 区域级灾备 | 每季度切换演练 |

**三数据库强制验证（AGENTS.md 要求，不可省略）**：任何影响 DB 行为的改动（模型/GORM 标签/迁移/DSN/驱动/Scanner-Valuer/原生 SQL/事务/行锁）必须在**真实** SQLite、MySQL ≥ 5.7.8（建议 8.2）、PostgreSQL ≥ 9.6（建议 15）上验证，日志库涉及 ClickHouse 时一并覆盖；迁移需在新建库 + 由上一发布版本产生的存量库上各跑，并至少启动两次证明幂等，且记录数据库版本、命令与结果。

### 7.10 成本结构（估算口径，需按实际报价校准）

| 项 | 说明 |
| --- | --- |
| 计算 | 每区域 4×`g8i.2xlarge`（可扩至 16），按量转包年包月可省 30–40% |
| 数据 | RDS PG 高可用版 16C64G + 只读实例 ×2 区域；Tair 4 GB 主备 ×2 |
| 日志 | ClickHouse 2 节点 ×2 区域，随 TTL 90 天与采样策略线性 |
| 网络 | ALB LCU 费用与 **出站带宽** 是主要成本项；LLM 流式响应出站带宽大，建议与 DCDN 动静态分离并对上游出口走 GA |
| 上游 token | 与网关 SLA 解耦，独立列预算；第九章 R-30 要求建立客户维度成本告警 |

---

## 八、SLA 99.95% 达成方案

### 8.1 SLA 定义与度量口径

**必须先定义清楚，否则 99.95% 无法验收：**

| 项 | 定义 |
| --- | --- |
| 服务窗口 | 7×24，按自然月统计（30 天 = 43,200 分钟） |
| 不可用 | 在探测区域内，对 `/v1/chat/completions`（mock 上游固定回包）或 `/api/status` 连续 2 个 15 s 周期返回 5xx / 连接失败 / 超 10 s 无响应 |
| 计划内维护 | 提前 72 h 公告、每月 ≤ 30 min，且必须通过灰度实现 **零停机**（零停机时不计入不可用） |
| 部分降级 | 成功率 < 99.5% 或 p95 > 阈值持续 5 min，计入 **SLO 违约**但不计入"完全不可用"，用错误预算单列跟踪 |
| 排除项 | ① 上游供应商自身故障（new-api 只做透传与切换，不计网关 SLA）；② 阿里云公告的区域级 IaaS 故障；③ 客户侧网络与证书问题；④ 超出限流配额的 429 |
| **月度不可用预算** | 43,200 × 0.05% = **21.6 分钟**（周预算 5.04 分钟，日预算 0.72 分钟） |

### 8.2 可用性推导（为什么必须按下面这样部署）

目标：整体 ≥ 99.95%。单点不可能达成，必须靠冗余把各环节抬高：

| 环节 | 配置 | 期望可用性 | 备注 |
| --- | --- | --- | --- |
| DNS/GTM + 就近解析 | 双区域 + 健康探测切换 | 99.99% | 单区域故障 60 s 内切走 |
| WAF + ALB | 阿里云多 AZ 实例，SLA 99.99% | 99.99% | SSE 超时配置正确，避免"假可用" |
| ACK 控制面 | Pro 托管版多 AZ | 99.95% | 控制面故障不影响已运行 Pod 的数据面 |
| 网关数据面 | 每区域 ≥ 4 副本跨 2 AZ、`maxUnavailable=0`、PDB、preStop 排空 | 99.99% | 单实例 99.5% × 4 副本并联 |
| 主库 | RDS 高可用版跨 AZ 主备 + 自动切换 | 99.99% | 切换期 30 s 内，写入短暂失败由重试吸收 |
| 缓存 | Tair 主备 | 99.99% | **注意**：Redis 故障时限流 fail-closed 返回 500（`middleware/rate-limit.go:117`），实际会把可用性拉低到 Redis 的可用性 → 必须改造为降级放行（R-05） |
| 日志库 | ClickHouse（可写失败降级） | 99.9% | 写日志失败绝不能阻塞中继主链路（需在改造中显式保证） |
| 跨区数据 | DTS 双向 + 区域自治 | 99.9% | 区域间链路劣化时本站点仍可用 |

串联（近似独立）：`0.9999 × 0.9999 × 0.9999 × 0.9999 × 0.9999 ≈ 0.9996`，仍高于 99.95% 目标，留出 ~0.01% 给"人因与变更"（业界的最大故障源）。**结论：双区域 + 每区域 ≥ 4 副本 + RDS 高可用 + Redis 降级改造** 是达成 99.95% 的最低配置；单区域 3 副本约等于 99.9%（99.95 不达标）。

### 8.3 错误预算管理

```mermaid
flowchart TD
  A["每月错误预算 21.6 分钟"] --> B["实时消耗<br/>按 5 分钟窗口累计不可用与 SLO 违约"]
  B --> C{"燃尽比例"}
  C -->|低于 50 百分比| D["正常发布"]
  C -->|50 到 80 百分比| E["发布需双人审批<br/>灰度观察窗口翻倍"]
  C -->|高于 80 百分比| F["冻结非必要发布<br/>只允许修复与止血"]
  C -->|燃尽全部预算| G["停止所有变更 进入稳定期<br/>触发正式事件复盘"]
  D --> H["变更类型统计<br/>若多数故障源于变更 则收紧门禁"]
  E --> H
  F --> H
```

### 8.4 故障域与韧性设计

| 故障域 | 检测 | 自动处置 | 人工处置 | RTO |
| --- | --- | --- | --- | --- |
| 单 Pod OOM / panic | readiness 失败 + Recovery 中间件 500 | K8s 重启，ALB 摘除 | 看 pprof / Pyroscope | 秒级 |
| 单可用区故障 | 云监控 + GTM 探测 | Pod 反亲和 + `DoNotSchedule` 保证另一 AZ 有容量 | 扩容 | ≤ 2 min |
| 整区域故障 | GTM 健康检查连续失败 | DNS 切到他区（容量已预留 1.5 倍） | 确认后手工降级非核心功能 | ≤ 5 min |
| 上游供应商区域性故障 | 渠道批量自动禁用（status=3）+ 告警 | `RetryTimes` 换渠道 + 优先级分层 + `status_code_mapping` | 切备用渠道 / 改 `model_mapping` | ≤ 60 s（轮询） |
| Redis 故障 | `newapi_redis_up == 0` | 限流降级内存滑动窗口（需改造），用户/令牌缓存回落 DB | 立即恢复 Tair | 分钟级 |
| 主库故障 | 连接错误 + RDS 事件 | RDS 主备自动切换；应用重连（`SQL_MAX_LIFETIME=60` 加速收敛） | 确认切换后校验额度一致性 | ≤ 60 s |
| 磁盘打满 | 5 s 采样 > 95% → 503 摘流 | 自动拒绝新请求保护进程 | 清磁盘缓存接口 `/api/performance/disk_cache` | 分钟级 |
| 慢客户端拖垮连接 | `active_connections` + `STREAMING_TIMEOUT` | 120 s（默认）无事件即断；写 deadline `ExtendWriteDeadline` | 调 `USER_SESSION_*` 与限流 | — |
| 迁移失败 | 启动探针不过 + 日志 `failed to initialize database` | `Restart=unless-stopped` 反复失败 → 告警 | 回滚镜像 + 前向修复（无 down） | 10 min |
| 配置误改 | 变更后 5 min 内成功率/时延劣化 | 无法自动识别（缺配置基线） | 依审计日志 key 回滚旧值 | ≤ 2 min |

### 8.5 容量规划与压测验收

- **单实例基线**（须由 3.9 的 S1/S2 实测替换）：非流式 800 QPS、并发 SSE 1,500、内存 2 GiB 工作集、fd 需求 = 并发 × 2（客户端 + 上游）+ 余量，故 `nofile=200000`。
- **区域容量**：峰值按日均 3 倍估算；每区域预留 **1.5 倍单区域全量能力**（保证另一区域故障时单区域可扛全量）。
- **带宽**：单路流式响应约 20–50 KB/s，1,000 并发 ≈ 40 Mbps，出站流量费用与 ALB LCU 需按此线性预留。
- **连接数预算**：`SQL_MAX_OPEN_CONNS=300 × 实例数 ≤ RDS max_connections × 0.8`。16 实例时必须配 PgBouncer（或 RDS 代理），否则 4,800 连接会打爆 PG。
- **上游出口**：NAT 固定 EIP 池（≥ 4 个 /28）用于供应商白名单；每渠道独立 host 连接上限，避免单渠道占满 `MaxIdleConnsPerHost=400`。

### 8.6 灾备演练（季度必做）

1. 区域切换演练：GTM 强制切单区域，验证容量与延迟（目标：TH 用户到马尼拉 RTT 上升 < 90 ms 且成功率不降）。
2. RDS PITR 演练：从备份恢复到新实例，跑额度对账（验证 RPO/RTO）。
3. Redis 摘除演练：确认降级路径不返回 5xx 雪崩（当前会 fail-closed，见 R-05）。
4. 版本回滚演练：从 canary 门禁失败到权重归零，实测止血耗时（目标 < 60 s）。
5. 上游全体故障演练：mock 上游 100% 5xx，验证退款不重复、额度不超扣、错误日志不写爆磁盘。

---

## 九、系统不足与改进措施

> 完整清单。`影响` 一列写的是"对 99.95% SLA 或正确性的具体威胁"；`优先级` P0 = 阻断上线，P1 = 上线后 1 个季度内，P2 = 半年内。

### 9.1 可用性与可观测（最威胁 SLA 的一组）

| 编号 | 不足 | 事实依据 | 影响 | 改进措施 | 优先级 / 工作量 |
| --- | --- | --- | --- | --- | --- |
| R-01 | **无 `/health`、`/ready`、`/metrics` 端点，无 Prometheus exporter** | 全仓库唯一 prometheus import 用于探测上游（`controller/channel_inference.go:195`）；健康探测靠 `GET /api/status`（`controller/misc.go:44`） | K8s/ALB 探针只能读业务接口，无法区分"进程活着"与"依赖就绪"；无法做自动灰度门禁与 SLO 计算，**直接使 99.95% 不可验收** | 新增 `GET /healthz`（无依赖）与 `GET /readyz`（Ping 主库 + 日志库 + Redis + 渠道缓存已初始化）；新增 `/metrics` 导出 6.3.3 列出的指标，`perf_metrics` 内存桶直接导出避免二次统计 | **P0** / 3–5 人日 |
| R-02 | **`VERSION` 文件为空 + `Cache-Version` 硬编码** | `VERSION` 为 0 字节；`Dockerfile:27` 用 `$(cat VERSION)` 注入 → 线上版本为空；`middleware/cache.go:14` 写死 SHA | 事故时无法确认线上版本，回滚无依据；发版后 CDN/浏览器缓存不刷新，SPA chunk 404 白屏 | CI 用 git tag/sha 强制写 `VERSION`；`Cache-Version` 改为构建期注入（ldflags 或 embed 生成文件），并把 `index.html` 设为 `no-cache`、带指纹资源设长缓存 | **P0** / 1–2 人日 |
| R-03 | **无版本化迁移、无 down migration、AutoMigrate 只加不删** | 仅有 `model/main.go:337-373` AutoMigrate + 手工幂等修复；`bin/` 只有 v0.2–v0.4 历史 SQL | schema 无法回滚；发布即单向门；废弃列/索引永久泄漏；破坏性变更无法与代码发布解耦 | 引入 **golang-migrate 或 goose** 版本化迁移（保留 AutoMigrate 用于开发）+ `schema_migrations` 版本号；制定"加列 → 双写 → 切读 → 清理"四步跨发布流程；迁移在影子库预演两次以证明幂等（AGENTS.md 已要求） | **P0** / 10–15 人日 |
| R-04 | **迁移只在 master 执行，slave 无 schema 就绪屏障** | `model/main.go:262-267`；`common.IsMasterNode = NODE_TYPE != "slave"` | 混版本集群中 slave 可能在 schema 就绪前接流，产生 500 与脏数据 | 部署侧：master Deployment 先滚动且 `readyz` 包含"迁移版本号达标"；代码侧：slave 启动时轮询 `schema_migrations`/`setups.version` 直到满足才通过就绪 | **P0** / 3 人日 |
| R-05 | **Redis 单节点客户端 + 限流 fail-closed 返回 500** | `common/redis.go:16-54` 用 `redis.ParseURL` 的 v8 单节点客户端，无 Cluster/Sentinel；`middleware/rate-limit.go:117-120,236-240` Redis 错误直接 500 | Tair 抖动 1 分钟即可让全站 5xx，把整体可用性拉低到 Redis 水平；同时无法水平扩展 Redis | 限流改为 **fail-open 到内存滑动窗口**（`email-verification-rate-limit.go:25-28` 已有此降级范式，统一到全局路径）并打降级指标；Redis 客户端升级 go-redis/v9 universal client 支持 Cluster/Sentinel/Tair 主备自动切换 | **P0** / 5 人日 |
| R-06 | **日志非结构化 + 按行数轮转 + 无 log-dir 环境变量** | `logger/logger.go:115-122`（`maxLogCount = 1000000` 行）；目录仅 CLI 参数 `-log-dir`（`common/init.go:22`） | 无法在 SLS 做字段级查询与聚合；单文件可能极大（100 万行）触发磁盘告警 | 输出 JSON 结构化日志（含 `request_id`/`trace_id`/`node_name`/`version`）；轮转改为按大小 + 按天 + `max-backups`，并支持 `LOG_DIR` 环境变量；容器内统一写 stdout，由平台落盘 | **P1** / 4 人日 |
| R-07 | **无分布式追踪，链路只有两个 ID** | 仅 `X-Oneapi-Request-Id` 与 `logs.upstream_request_id`（`model/log.go:78-79`） | 跨中间件/上游/DB 的耗时归因靠人工拼日志，MTTR 高；无法证明"网关自身延迟 ≤ 80 ms" | 接 OpenTelemetry SDK，对中继全链路（鉴权 → 选路 → 上游 TTFB → 转换 → 结算）建 span，并把 `trace_id` 写入 `logs.other` 与响应头 | **P1** / 8 人日 |
| R-08 | **无 `artifacts`/`files` 表，产物依赖上游 URL** | 产物地址存于 `tasks.private_data` / `midjourneys`（`model/task.go:111-134`） | 上游链接过期即产物丢失，客户投诉"生成结果打不开"；无幂等重下载 | 新增 `task_artifacts` 表（key、mime、size、oss_key、expires_at、checksum），成功任务异步转存 OSS，读取走签名 URL；配生命周期策略 | **P1** / 6 人日 |
| R-09 | **限流粒度不足、无标准退避头** | 只有 IP / 用户 / 分组维度（`middleware/rate-limit.go`、`model-rate-limit.go`）；全仓库无 `X-RateLimit-*` | 单个 API Key 下的多个应用互相挤占；客户 SDK 无法自适应退避，重试风暴放大故障 | 增加 token 维度与 **TPM（每分钟 token）** 维度限流；响应统一返回 `Retry-After` + `X-RateLimit-Limit/Remaining/Reset`；429 返回体与 OpenAI/Anthropic 对齐 | **P1** / 5 人日 |
| R-10 | **过载保护阈值两处不一致，且无并发上限** | `setting/performance_setting/config.go:30-40` Disk 95 vs `common/performance_config.go:17-22` Disk 90；并发仅 `middleware/stats.go` 计数不设限 | SSE 场景真正的杀手是 fd/内存而非 CPU；无并发上限会导致 OOM 而不是优雅 503 | 单一配置源（删除硬编码默认或让 setting 覆盖）；新增 `MAX_CONCURRENT_STREAMS` 与 `MAX_CONCURRENT_REQUESTS` 信号量，超限返回 503 + `Retry-After`，纳入过载保护统一决策 | **P1** / 4 人日 |
| R-11 | **无熔断与 per-channel 超时** | 无 `breaker` 符号；超时只有全局 `RELAY_TIMEOUT`（默认 0 = 不限）、`RELAY_RESPONSE_HEADER_TIMEOUT` 1800 s、`STREAMING_TIMEOUT` 300 s；渠道级仅 `Proxy`/`HTTPProtocol`/`HTTP2ConnectionShards`（`relaykit/dto/channel_settings.go:13-28`） | 慢渠道会占满客户端连接与 goroutine，形成"一个坏上游拖垮全站"；1800 s 响应头超时对多数供应商过长 | 引入 per-channel 熔断（错误率 + 连续失败 + 半开探测，状态存 Redis 跨实例共享）；`channels.settings` 增加 `timeout_seconds`/`max_concurrency`；把默认响应头超时降到 60–120 s 并按渠道覆盖 | **P1** / 8 人日 |

### 9.2 正确性与数据安全

| 编号 | 不足 | 事实依据 | 影响 | 改进措施 | 优先级 / 工作量 |
| --- | --- | --- | --- | --- | --- |
| R-12 | **无跨表额度对账任务** | 额度分布在三处：`users.quota`、Redis `user:<id>` 哈希、批量合并器内存（`model/utils.go:16-41`）；`subscription_pre_consume_records` 只做请求级幂等 | 进程异常退出时未落库的合并写会丢失；长期漂移无法发现，最终表现为"客户余额不对" | 新增每日对账系统任务：`sum(logs.quota where type in (1,2,6))` vs `delta(users.used_quota/quota)`，与 Redis 哈希三方比对，差异写 `audit_logs` 并告警；批量合并器在 `preStop`/SIGTERM 时强制 flush（当前只在 `DataExportEnabled` 时保存看板数据，`main.go:241-244`） | **P0** / 5 人日 |
| R-13 | **渠道凭据明文入库** | `channels.key` / `open_ai_api_key` 明文列（`model/channel.go:20-60`） | 一次 SQL 注入或备份泄露即所有上游 key 失窃，可被刷爆账单 | 静态加密（AES-GCM，主密钥在 KMS，支持轮换 + 懒迁移）；控制台永不回显明文；上游调用只在内存解密；RDS 审计与 KMS 审计联动 | **P0** / 6 人日 |
| R-14 | **`options` 无值级历史** | 变更审计只记 key 不记 value（`controller/option.go:499`），`options` 表每键一行 | 配置回滚需人工从代码默认值或聊天记录推断，止血慢 | `options` 增加 `revision` 与 `updated_by`，或新增 `option_revisions` 历史表并提供"一键回滚到上一版本" | **P2** / 4 人日 |
| R-15 | **人机验证失败返回 HTTP 200** | `middleware/turnstile-check.go:20-59` 所有拒绝均 200 + `success:false` | 网关侧 5xx/4xx 指标看不到攻击，WAF/告警策略失准，安全事件延迟发现 | 保留业务兼容性的同时新增可观测：打点专用计数器与专用日志类型；或对新客户端提供 `X-Auth-Reject-Reason` 头与 4xx 选项 | **P2** / 2 人日 |
| R-16 | **`&Log{}` 留在主库 AutoMigrate 列表** | `model/main.go:349` | 日志库分离部署时主库出现空 `logs` 孤儿表，运维误判与后续迁移歧义 | 按 `UsingLogDatabase()` 分支决定是否纳入主库迁移列表 | **P2** / 0.5 人日 |
| R-17 | **ClickHouse 表结构不随 Go 模型演进** | 建表为 raw `CREATE TABLE IF NOT EXISTS`（`model/main.go:436-463`、`model/audit_log.go:247-255`） | 新增 `Log`/`AuditLog` 字段后，CH 环境静默丢列或查询报错，且只在生产暴露 | 增加 CH 专用迁移器（比对 `system.columns` 后 `ALTER TABLE ADD COLUMN`），并纳入 CI 的 ClickHouse 冒烟 | **P1** / 4 人日 |
| R-18 | **`perf_metrics` 默认永不清理；`audit_logs` 无保留策略** | `setting/perf_metrics_setting/config.go:12-16` `RetentionDays: 0`；`model/audit_log.go:24-25` 有意不接清理 | 指标表按月增约 48 万行（4.9）永久累积，主库膨胀拖慢 AutoMigrate 与备份 | 默认 `RetentionDays=30`；审计按合规要求设定保留期并归档到 OSS（热 90 天 + 冷 180 天） | **P1** / 1 人日 |

### 9.3 一致性与多实例语义

| 编号 | 不足 | 事实依据 | 影响 | 改进措施 | 优先级 / 工作量 |
| --- | --- | --- | --- | --- | --- |
| R-19 | **配置与路由一致性依赖轮询，最长 60 s（现网默认）** | `main.go:115` `SyncOptions`、`model/channel_cache.go:109` `SyncChannelCache`、`authz.StartPolicySync`；唯一 pub/sub 是渠道关闭广播（`pkg/wsmanager/wsmanager.go:113-155`） | 灰度放量、紧急止血、权限收紧都有分钟级滞后；不同实例短时间内行为不一致（同一用户两次请求命中不同渠道集） | 轮询改为 **Redis pub/sub 失效通知 + 轮询兜底**（版本号比对，收到消息只重载变化的域）；把"关键开关"（禁用、限流、熔断）传播目标降到 ≤ 5 s | **P1** / 6 人日 |
| R-20 | **跨区双写的会话/限流语义不一致** | 会话与缓存 key 依赖 `SESSION_SECRET`（必须全局一致），限流 key 无区域前缀 | 双区域 Active-Active 下同一用户会话在不同区 Redis 中互相不可见，导致随机登出与限流配额双倍 | 明确"会话与限流状态存全局 Tair（新加坡中心 + 本地只读缓存）"，或按区域分片用户（GTM 粘性 + 区域归属字段），并在文档中固化为部署约束 | **P1** / 6 人日 |
| R-21 | **`abilities` 与内存快照双源，无版本号** | 物理路由表 `abilities` 与 `group2model2channels` 快照并存（`model/channel_cache.go:20-107`） | 双源不一致时难以判定"哪个是真相"，选路问题排查成本高 | 快照带 `generation` 单调版本号，`/readyz` 与日志暴露当前 generation，并在请求 `logs.other` 记录命中的 generation | **P2** / 3 人日 |
| R-22 | **默认 `RetryTimes = 0`、默认重试状态码区间宽** | `common/constants.go:134` 默认 0；`setting/operation_setting/status_code_ranges.go:21-38` 默认可重试区间 | 默认配置下不具备跨渠道容灾（SLA 依赖运维显式设置 option）；宽区间叠加无熔断会造成重试放大 | 生产基线配置模板固化 `RetryTimes=2` + 熔断 + 预算式重试上限（同一请求重试总耗时/总次数双限制） | **P1** / 2 人日 |
| R-23 | **无租户级隔离（noisy neighbor）** | 分组仅有倍率与限流语义，无独立并发/带宽配额，无排队 | 单一大客户突发流量会挤占同分组其他客户的 SSE 容量与 DB 连接 | 引入客户维度并发与令牌桶（Redis 全局）+ 优先级队列（大客户预留并发槽位）+ 公平调度（加权公平队列） | **P2** / 10 人日 |

### 9.4 发布工程与测试

| 编号 | 不足 | 事实依据 | 影响 | 改进措施 | 优先级 / 工作量 |
| --- | --- | --- | --- | --- | --- |
| R-24 | **无灰度发布与自动回滚机制** | 仓库只有 `Dockerfile` / `docker-compose.yml` / systemd 单元，无 K8s manifests、无 Helm、无 Argo Rollouts/Flagger | 发布只能"全量替换"，任何回归都是全站故障，与 99.95% 冲突（变更是最大故障源） | 落地 6.5.2 与 7.4/7.7：ALB 权重双轨 + Argo Rollouts（或 Flagger）+ 自动门禁（依赖 R-01 指标） | **P0** / 8 人日 |
| R-25 | **E2E 覆盖极薄、无黑盒压测资产** | `e2e/` 仅 1 个测试文件；无 k6/vegeta/wrk/hey/fortio 配置（3.9） | 中继主链路（鉴权 → 选路 → 转换 → 计费 → 退款）缺乏端到端回归，容量指标无基线 | 按 3.9 建 `perf/` 场景矩阵并入 CI 门禁；补 3 条关键 E2E：流式计费一致性、失败退款幂等、渠道故障切换 | **P1** / 10 人日 |
| R-26 | **CI 无三数据库矩阵、无安全扫描** | `.github/workflows/ci.yml` 只做 Go vet/build + `make test`（内存 SQLite）+ bun typecheck/test | AGENTS.md 强制要求的 SQLite/MySQL/PG 真实验证靠人工，容易漏；无 SAST/依赖漏洞/镜像扫描门禁 | CI 加 dialect 矩阵 job（PG 9.6+ 与最新、MySQL 5.7.8 与 8.2、SQLite）+ ClickHouse job；加 `govulncheck`、`trivy`、`gosec`、cosign 验证；影子库 AutoMigrate 预演 job | **P1** / 6 人日 |
| R-27 | **前端与后端耦合发布** | `main.go:44` `//go:embed web/dist`，无独立前端产物发布通道 | 文案/i18n 级别的前端修复也要重编 Go 二进制并走全量灰度，恢复慢 | 静态资源改投 OSS + CDN，`index.html` 由网关按版本头回源；或提供 `FRONTEND_BASE_URL` 独立发布通道（该变量已在 `router/main.go:25-40` 存在，可沿用） | **P2** / 5 人日 |
| R-28 | **无 API 版本治理与废弃策略** | `/v1/*`、`/v1beta/*`、`/pg/*`、`/mj/*` 并存（`router/relay-router.go`），无弃用头与变更日志 | 破坏性变更只能靠"直接改"，客户无预警 | 引入 `Deprecation` / `Sunset` 响应头 + 版本公告页 + 变更日志；`/v1beta/*` 设明确 EOL | **P2** / 3 人日 |

### 9.5 合规与区域特定事项（菲律宾 / 泰国）

| 编号 | 事项 | 影响 | 措施 | 优先级 |
| --- | --- | --- | --- | --- |
| R-29 | **数据出境与内容合规**：菲律宾 DPA（Data Privacy Act 2012）与泰国 PDPA 对个人信息与内容留存有要求 | 提示词与响应内容含个人数据，日志留存与区域放置需可证明 | 明确数据驻留（PH 数据留马尼拉、TH 数据留曼谷或明示同意）；提供数据保留期配置与"按用户删除"接口（配合 `users` 软删除 + 日志脱敏）；DPA 条款与处理者协议落地 | **P1** |
| R-30 | **成本与预算护栏缺失** | LLM 上游按 token 计费，客户侧滥用（脚本刷量、密钥泄露）会在告警前形成巨额账单 | 增加"消费熔断"：用户/令牌级日预算上限，超限自动禁用令牌并告警；上游 key 侧同步设 provider 配额；财务维度看板与客户账单导出 | **P1** |
| R-31 | **安全响应头基线未在应用层固化** | CSP/HSTS/X-Content-Type-Options 等依赖 ALB 或前置代理，环境间不一致，换入口即失效 | 在 `middleware/` 统一注入安全头（HSTS、CSP、`X-Frame-Options: DENY`、`Referrer-Policy`），并通过配置校验确保 `SESSION_COOKIE_SECURE=true` 时 `SESSION_COOKIE_TRUSTED_URL` 精确 HTTPS Origin（该约束已在 compose 注释中，需代码强制） | **P1** |

### 9.6 改进路线图

```mermaid
flowchart LR
  P0["第一阶段 0 到 1 个月 上线闸门<br/>R-01 探针与指标 R-02 版本与缓存<br/>R-03 版本化迁移 R-04 迁移屏障<br/>R-05 Redis 降级 R-12 额度对账<br/>R-13 凭据加密 R-24 灰度与自动回滚"]
  P1["第二阶段 1 到 3 个月 SLO 稳固<br/>R-06 结构化日志 R-07 链路追踪<br/>R-08 产物落库 R-09 限流粒度<br/>R-10 并发上限 R-11 熔断与超时<br/>R-17 CH 迁移 R-18 保留策略<br/>R-19 配置秒级传播 R-20 跨区一致<br/>R-22 重试基线 R-25 压测 R-26 CI 矩阵<br/>R-29 PDPA R-30 预算护栏 R-31 安全头"]
  P2["第三阶段 3 到 6 个月 体系化<br/>R-14 配置版本化 R-15 人机验证可观测<br/>R-16 孤儿表 R-21 路由版本 R-23 租户隔离<br/>R-27 前端独立发布 R-28 API 版本治理"]
  P0 --> P1 --> P2
  P0 -.-> GATE{"阶段闸门<br/>99.9 达成且零 P1 遗留"}
  GATE -.->|通过| P1
  P1 -.-> GATE2{"99.95 连续 2 个自然月<br/>错误预算未燃尽"}
  GATE2 -.->|通过| P2
```

### 9.7 未验证事项（诚实声明）

以下结论受本次分析范围限制，标注为待验证，**不得**作为已达标项引用：

1. 上游各供应商在菲律宾/泰国的实际可达性与延迟（需按 8.5 拨测建立基线）。
2. 单实例真实容量数字（800 QPS / 1,500 并发 SSE 为待压测校准的工程假设，非实测）。
3. 阿里云 `ap-southeast-6` / `ap-southeast-7` 的具体规格可售性与报价（区域产品覆盖会变化）。
4. 三数据库真实矩阵验证（SQLite/MySQL/PostgreSQL）与 ClickHouse 冒烟本次 **未执行**，属于 R-26 改进项；本文档所有数据库结论来自代码阅读。
5. 前端各 feature 的运行时行为与无障碍达标情况未做浏览器实测验证。

---

## 十、附录

### 10.1 关键环境变量与配置项速查

| 类别 | 名称 | 默认值 | 来源 | 是否热更新 |
| --- | --- | --- | --- | --- |
| 数据库 | `SQL_DSN` | 空 → SQLite `one-api.db`（WAL + busy_timeout 30000 + txlock=immediate） | `common/database.go:64`、`model/main.go` | 否（重启） |
| 日志库 | `LOG_SQL_DSN` | 空 → 复用主库 | `model/main.go:230-238` | 否 |
| 日志库 | `LOG_SQL_CLICKHOUSE_TTL_DAYS` | **0（不自动删除）** | `model/main.go:413-434` | 否 |
| 连接池 | `SQL_MAX_IDLE_CONNS` / `SQL_MAX_OPEN_CONNS` / `SQL_MAX_LIFETIME` | 100 / 1000 / 60 | `model/main.go:258-260` | 否 |
| 慢查询 | `SQL_SLOW_THRESHOLD_MS` | 200 | `model/gorm_logger.go:20-47` | 否 |
| 缓存 | `REDIS_CONN_STRING` / `REDIS_POOL_SIZE` | 空（禁用）/ 10 | `common/redis.go:16-54` | 否 |
| 缓存 | `MEMORY_CACHE_ENABLED` / `SYNC_FREQUENCY` | false / **60** | `main.go:83-86`、`common/init.go` | 否 |
| 节点 | `NODE_NAME` / `NODE_TYPE` | `os.Hostname()` / 非 `slave` 即 master | `common/node_identity.go`、`common/init.go:89` | 否 |
| 批量写 | `BATCH_UPDATE_ENABLED` / `BATCH_UPDATE_INTERVAL` | false / 默认间隔秒 | `main.go:164`、`model/utils.go` | 否 |
| 看板 | `DATA_EXPORT_ENABLED` / `DATA_EXPORT_INTERVAL` | false / 分钟 | `model/usedata.go:41-49` | 部分（option） |
| 中继超时 | `RELAY_TIMEOUT` / `RELAY_RESPONSE_HEADER_TIMEOUT` / `RELAY_IDLE_CONN_TIMEOUT` / `RELAY_MAX_IDLE_CONNS` / `RELAY_MAX_IDLE_CONNS_PER_HOST` | 0（不限）/ 1800 / 90 / 500 / 100 | `service/http_client.go:79-131` | 否 |
| 流式 | `STREAMING_TIMEOUT` | 300 s（SSE 事件间空闲） | `common/init.go:179`、`relay/helper/stream_scanner.go:94` | 否 |
| 优雅停机 | `SHUTDOWN_TIMEOUT_SECONDS` | 120 | `main.go:236` | 否 |
| 请求体 | `MAX_REQUEST_BODY_MB` / `ANONYMOUS_REQUEST_BODY_LIMIT_KB` | 128 / 512 | `common/init.go:184`、`common/request_body_limit.go:5-12` | 否 |
| 限流 | `GLOBAL_API_RATE_LIMIT(_ENABLE/_DURATION)` | true / 360 / 180 | `common/init.go:123-137` | 否 |
| 限流 | `GLOBAL_WEB_RATE_LIMIT*` / `CRITICAL_RATE_LIMIT*` / `SEARCH_RATE_LIMIT*` | 120/180、20/1200、10/60 | 同上 | 否 |
| 限流 | `ModelRequestRateLimit*`（option 键族） | false / 0 / 1 / 1000 | `setting/rate_limit.go:21-25` | **是** |
| 会话 | `SESSION_SECRET` / `SESSION_COOKIE_SECURE` / `SESSION_COOKIE_TRUSTED_URL` | 空 / false / 空 | compose 注释 + `middleware/auth_origin.go` | 否（多机必须一致） |
| 会话 | `USER_SESSION_ACTIVE_LIMIT` / `_ISSUANCE_LIMIT` / `_ISSUANCE_WINDOW_SECONDS` / `_REVOKED_RETENTION_DAYS` / `_HOURLY_ALERT_THRESHOLD` | 50 / 100 / 86400 / 7 / 5000 | `service/auth_session.go`、`model/user_session.go:22-25` | 否 |
| 网络 | `TRUSTED_PROXIES` | 未配置时信任回环/RFC1918/fc00::/7 并告警，`none` 为严格模式 | `middleware/trusted_proxies.go` | 否 |
| 错误日志 | `ERROR_LOG_ENABLED` | false | `constant` + `model/log.go:278-322` | 部分 |
| 任务 | `TASK_TIMEOUT_MINUTES` / `TASK_PLUGIN_PROTOCOL_TIMEOUT_SECONDS` / `DISABLE_TASK_POLLING_SLEEP` | 见 `common/init.go:203-208` | 任务超时 | 否 |
| 渠道 | `CHANNEL_UPDATE_FREQUENCY` / `CHANNEL_TEST_FREQUENCY` / `CHANNEL_TEST_ENABLED` | 空 / 见 `setting/operation_setting/monitor_setting.go:18-59` | 上游模型同步与自动测试 | 部分（option） |
| 性能 | `ENABLE_PPROF` / `PYROSCOPE_*` | false / 空 | `main.go:167-175` | 否 |
| 前端 | `VITE_REACT_APP_VERSION` / `VITE_REACT_APP_SERVER_URL` / `FRONTEND_BASE_URL` | — / `http://localhost:3000` / 空 | `rsbuild.config.ts:19-24`、`router/main.go:25-40` | 否（构建期） |
| 分析 | `UMAMI_WEBSITE_ID` / `UMAMI_SCRIPT_URL` / `GOOGLE_ANALYTICS_ID` | 空 | `main.go:248-289` | 否 |

### 10.2 端口与探针

| 端口 | 用途 | 暴露策略 |
| --- | --- | --- |
| 3000 | 业务 HTTP（`/v1/*`、`/api/*`、控制台 SPA） | ALB 后端，公网经 WAF |
| 8005 | pprof（仅 `ENABLE_PPROF=true`） | **仅内网，禁止公网与跨区** |
| 5173 | 前端 dev server（仅开发） | 本机 |
| 9101 / 8080 / 9090 / 3000(grafana) | node-exporter / cadvisor / prometheus / grafana | 仅内网 |

探针落地路径（改造前后）：

| 用途 | 现状可用 | 目标 |
| --- | --- | --- |
| liveness | TCP 3000 或 `GET /api/status` | `GET /healthz` |
| readiness | `GET /api/status`（返回 `version`、`start_time`） | `GET /readyz`（依赖 + 迁移版本 + 缓存就绪） |
| metrics | 无 | `GET /metrics`（内网 ACL） |
| 业务存活（含依赖） | `GET /api/status`、`GET /api/about` | 保留 |

### 10.3 术语表

| 术语 | 含义 |
| --- | --- |
| 分组（group） | 用户/令牌/渠道/abilities 共用的路由与倍率作用域，非数据库表 |
| 令牌（token） | 客户侧 API Key（`sk-...`），Redis 缓存键为其 HMAC |
| PAT / Access Token | 控制台个人访问令牌，审计中以 SHA-256 指纹 `token_ref` 表示 |
| 能力（ability） | `(group, model, channel_id)` 三元组路由事实表 |
| 会话亲和（channel affinity） | 会话 → 渠道的稳定映射，Redis TTL 默认 3600 s |
| 请求策略（request policy） | 每请求的重试/pin/严格会话决策与事件记录 |
| 围栏（fence） | 缓存写前排栏，防止旧快照覆盖新状态 |
| 系统任务租约 | `system_task_locks`（主键 = 任务类型）的 `locked_until` 分布式锁 |
| 任务插件 | `plugins/tasks/<vendor>/plugin.js`，由 Sobek 沙箱执行的异步任务协议扩展 |
| 轨道 A / 轨道 B 灰度 | A = 业务配置灰度（分组/权重/映射，分钟级、免发版）；B = 代码版本灰度（ALB 权重双 Deployment） |
| 错误预算 | `100% − SLO` 允许的月度不可用时长（99.95% ⇒ 21.6 分钟） |

### 10.4 文档渲染与校验

- 全部 24 个 mermaid 图已在 **mermaid v11 解析器**上逐个通过语法校验（`flowchart` 9、`sequenceDiagram` 14、`erDiagram` 1）。渲染方式：GitHub/GitLab 原生渲染、VS Code Markdown Preview Mermaid 插件、或 `npx -y @mermaid-js/mermaid-cli -i impl_tech.md -o impl_tech.html`。
- 文档中的 5 个 YAML 代码块（ConfigMap/Secret/Deployment/Service/AlbConfig/Ingress/Compose）已通过 YAML 语法解析校验，但**未在真实 ACK/ALB 环境应用**；上线前需在 staging 集群 `kubectl apply --dry-run=server` 与 `docker compose config` 双重验证，并按 7.9 完成三数据库矩阵验证。
- `文件:行号` 引用基线为 commit `972aed197`；代码演进后行号可能漂移，路径与函数名仍可作为定位依据。


---

## 附录A：阿里云负载均衡选型与使用指南（ALB / NLB / CLB）

> 本附录关键参数均已按阿里云官方文档核实（2026-09）；产品约束会演进，上线前以官方"ALB 版本与配额""监听配置"文档为准。正文 7.4.3 的 AlbConfig/Ingress 示例与本附录口径一致。

### A.1 产品家族定位

阿里云负载均衡（SLB）家族现役三款：

- **CLB（传统型负载均衡，原 SLB）**：上一代产品，同时提供四层（TCP/UDP）与七层（HTTP/HTTPS）能力，功能面窄，官方定位为存量维护，新产品不再推荐选型。
- **NLB（网络型负载均衡）**：新一代**四层**专用产品，主打超大规模并发与超低时延，支持 TCP/UDP/TCPSSL，可透传客户端真实源 IP，与 ACK 的集成方式是 Service `type: LoadBalancer`（CCM 管理）。
- **ALB（应用型负载均衡）**：新一代**七层**专用产品，面向 HTTP/HTTPS/QUIC/gRPC，提供基于 Host/Path/Header/Cookie/Query 的内容路由、按权重与按 Header 的灰度发布、TLS 卸载、访问控制与可观测能力，与 ACK 的集成方式是 **ALB Ingress**（`AlbConfig` CRD + `IngressClass`）。

本项目主入口选型为 **每区域一个公网 ALB（标准版 II）+ ACK ALB Ingress**，理由与详细配置见 A.4/A.5。

```mermaid
flowchart TD
  START["新流量入口需要负载均衡"] --> P{"业务协议?"}
  P -- "HTTP/HTTPS/gRPC/WebSocket/SSE/QUIC" --> ALB["ALB 七层"]
  P -- "TCP/UDP 裸转发或 TLS 端到端透传" --> NLB["NLB 四层"]
  P -- "仅存量系统" --> CLB["CLB 不再新建, 规划迁移到 ALB/NLB"]
  ALB --> A1{"需要 60s idle 上限满足不了的长静默连接或 UDP?"}
  A1 -- "是" --> SW["改走 NLB, 证书与协议下沉到网关自管"]
  A1 -- "否" --> A2{"体量与容量诉求?"}
  A2 -- "中大型/需容量预留" --> A3["ALB 标准版 II"]
  A2 -- "小型/验证环境" --> A4["ALB 标准版或基础版"]
```

### A.2 三款产品对比总表

| 维度 | CLB（传统型） | NLB（网络型） | ALB（应用型） |
| --- | --- | --- | --- |
| 协议层级 | 四层 + 七层 | 四层 | 七层 |
| 监听协议 | TCP/UDP/HTTP/HTTPS | TCP/UDP/TCPSSL | HTTP/HTTPS/QUIC |
| 内容路由（path/header/cookie/query） | 七层仅基础转发 | 不支持（不解析七层） | 支持，含自定义转发规则、脚本 |
| 灰度发布 | 无权重灰度语义 | 无（四层无法按请求分流） | `canary-weight` / `canary-by-header` / `canary-by-cookie`（Ingress 层） |
| TLS | 监听上卸载 | TCPSSL 监听卸载，或纯 TCP 透传 | 监听上卸载（SNI 多证书、TLS 安全策略），亦支持 gRPC |
| HTTP/3 QUIC | 不支持 | 不支持 | 支持（监听开启 QUIC） |
| UDP | 支持 | 支持 | **不支持** |
| 连接空闲超时 | 参数面旧 | IdleTimeout 1–60 s（ROS 资源定义） | IdleTimeout 1–60 s，默认 15 s |
| 请求超时 | 监听级配置 | 无七层请求超时语义 | RequestTimeout 1–180 s，默认 60 s，超时返回 504 |
| 真实客户端 IP | 四层 FULLNAT 可见；七层 XFF | 四层原生透传，可选 Proxy Protocol v2 | 仅 `X-Forwarded-For` 头（代理型，后端看到回源地址） |
| 后端 | ECS 等旧模型 | ECS/ECI/IP 等，同地域 | ECS/ECI/IP/函数等，**同地域同 VPC**，要求 ≥2 可用区 |
| 入口形态 | 固定 IP 为主 | DNS 名（地址可能变化） | DNS 名（**IP 会漂移，禁止固化 A 记录**） |
| K8s 集成 | 旧 CCM LoadBalancer | Service `type: LoadBalancer` | ALB Ingress（`AlbConfig` CRD） |
| 计费 | 实例/规格 + 带宽流量 | 实例费 + LCU | 实例费 + LCU（连接/数据量/规则评估多维取峰值） |
| 定位 | 存量维护 | 高性能四层入口 | 功能丰富的七层入口 |

### A.3 优缺点与最佳使用场景

**ALB**

- 优点：七层路由与灰度能力最全（权重/Header/Cookie 金丝雀、蓝绿、重定向、重写）；TLS 卸载 + QUIC + gRPC；与 ACK/ACM 证书/云防火墙/可观测（访问日志、全链路追踪）原生集成；实例费低、按 LCU 弹性。
- 缺点：idle 上限 60 s、request 上限 180 s，**无法关闭**；无 UDP；真实 IP 只走 XFF；后端限同地域同 VPC；LCU 计费维度多、长连接型业务成本需预估。
- 最佳场景：公网 API 网关入口（本项目 `/v1/*`、`/api/*`、SPA 控制台）、需要按权重/Header 灰度的多版本流量切分、需要 QUIC/gRPC 的接入。

**NLB**

- 优点：四层超大并发、微秒级转发；支持 UDP 与 TCPSSL；客户端真实源 IP 原生可见（可选 PPv2）；无七层请求超时——后端"首包慢"不会被 LB 判 504；TCP 长连接只要不静默超过 idle 上限即可长期保持。
- 缺点：不解析 HTTP——没有 path 路由、没有灰度、没有 TLS 卸载（除非 TCPSSL 监听）；证书与协议兼容要在网关侧自管；idle 同样 1–60 s 封顶。
- 最佳场景：UDP/实时音频类流量、要求 TLS 端到端（证书放网关）的合规透传、极致性能或超长"静默首包"型请求的旁路入口。

**CLB**

- 优点：老牌稳定，四层 + 七层一站备齐；部分老部署（固定 IP 白名单、经典网络）依赖它。
- 缺点：功能代差（无权重灰度规则语义、无 QUIC/gRPC/自定义转发）、性能上限低、官方明确引导迁移；新系统不应再引入。
- 最佳场景：仅存量维护，并规划向 ALB（七层）/NLB（四层）迁移。

### A.4 本项目（new-api）选型结论

| 流量 | 产品 | 关键配置 |
| --- | --- | --- |
| 公网 `/v1/*` 中继（HTTP/SSE/WebSocket） | ALB 标准版 II（每区域 1 个，多 AZ） | AlbConfig listener：`idleTimeout: 60`、`requestTimeout: 180`；管理后台开启 ping keepalive 并设 15–20 s |
| 灰度发布（轨道 B 代码灰度） | 同主 ALB | canary Ingress + `canary-weight`，后端指向独立 canary Service（见 7.4.3） |
| 首包可能超 180 s 的非流式请求 | ALB 不可达上限 → 改造为异步任务（现状任务接口本就走轮询）或 NLB TCP 旁路 | 监控 TTFT/首包 P99，保证远小于 180 s |
| Realtime/音频 UDP（若启用） | NLB（TCPSSL 或 UDP 监听） | 直连网关 Pod（Terway）或内网 ALB 之外的四层入口 |
| 控制台/运维内网入口 | 私网 ALB（第二个 AlbConfig） | `addressType: Intranet` + ACL 收紧 |
| 跨地域（马尼拉/曼谷）容灾 | 不用 LB 做跨域 —— DNS + GTM 切换 ALB DNS 名 | 严禁把 ALB 解析 IP 写进任何白名单/客户端 |

### A.5 ALB Ingress on ACK 使用指南（分步）

1. **安装组件**：ACK 集群组件管理安装 **ALB Ingress Controller**（它负责把 `AlbConfig`/Ingress 声明同步为云上 ALB 实例与监听/规则/服务器组）。集群与目标 ALB 必须同 VPC、同地域。
2. **创建 `AlbConfig`**：声明云上实例（可用区 vSwitch、公网/私网、 edition）与**监听级参数**——`idleTimeout`/`requestTimeout`/gzip/QUIC/安全策略等**只能在这里配**，Ingress 注解里没有对应键：

   ```yaml
   apiVersion: alibabacloud.com/v1
   kind: AlbConfig
   metadata:
     name: new-api-alb
   spec:
     config:
       name: new-api-alb
       addressType: Internet        # 内网管理入口用 Intranet
       # zoneMappings:              # ALB 要求至少 2 个可用区
       #   - vSwitchId: vsw-xxxx-mnl-a
       #   - vSwitchId: vsw-xxxx-mnl-b
     listeners:
       - port: 443
         protocol: HTTPS
         idleTimeout: 60            # 取值 1–60，默认 15；上限就是 60，写 900 非法
         requestTimeout: 180        # 取值 1–180，默认 60；超时 ALB 直接回 504
       - port: 80
         protocol: HTTP             # 仅用于 301 跳转 HTTPS（ssl-redirect 注解）
         requestTimeout: 30
   ```
3. **绑定 IngressClass**：`spec.controller: ingress.k8s.alibabacloud/alb`，`parameters` 指向上面的 `AlbConfig`（完整示例见 7.4.3）。
4. **Service**：`type: ClusterIP`；stable 与 canary 各自一个 Service，选择器分别锁 `track: stable` / `track: canary`。
5. **主 Ingress**：host/path → stable Service；常用注解：`backend-protocol`（http/https/grpc）、`ssl-redirect`、`healthcheck-enabled/-path/-interval-seconds/-timeout`、`healthy-threshold-count`/`unhealthy-threshold-count`（[2,10]，默认 3）、`connection-drain-enabled` + `connection-drain-timeout`（发布摘流）、`sticky-session*`、`order`（多 Ingress 规则优先级）。
6. **灰度 Ingress**：新建**第二条** Ingress，host+path 与主 Ingress 一致，后端指向 canary Service，注解只放 `canary: "true"` + `canary-weight: "5"`（键名是 `canary-weight`，**不存在** `canary-by-weight`；`900`/`0` 之类超时注解也无效且不该出现）；可按需叠加 `canary-by-header` 给内部账号白名单；权重由 GitOps 按 5 → 20 → 50 → 100 推进。
7. **证书**：`tls` 段引用 Secret，或经 ACM 证书 ID 挂载；多域名注意证书数量配额。
8. **验证**：`kubectl describe albconfig` 看控制器同步事件；ALB 控制台核对监听超时、服务器组健康状态；压测环境跑 30 min 长 SSE 与首包 170 s 的慢请求各一组，确认无 504/断流。配额（监听数、规则数、服务器组数）在配额中心提前提额。

### A.6 坑点清单（new-api 场景逐条给结论）

1. **超时上限误解**：ALB `idleTimeout` 最大 60 s、`requestTimeout` 最大 180 s，均不能设 0/"不限"，也不能用 Ingress 注解配置——"把超时调到 900 s 保 SSE"这条路**不存在**；正确方案是 AlbConfig 顶格 + 应用层心跳。
2. **SSE 保活开关默认关闭且默认间隔踩线**：`ping_interval_enabled` 默认 `false`、`ping_interval_seconds` 默认 `60`（`setting/operation_setting/general_setting.go:26-33`），60 s 恰好等于 ALB idle 上限，属危险值。上线动作：管理后台开启 ping 并设 **15–20 s**（≤ idleTimeout/3）；关闭 ping 时上游"深度思考"60 s 无字节即被 ALB 切断，客户端拿到半截流。ping 最长持续 30 分钟（`relay/helper/stream_scanner.go:170`）。
3. **requestTimeout 语义是"等后端首包"**，不是整条流时长：SSE 收到响应头后不再受它约束；受影响的是一次性长响应（非流式大上下文/推理模型首包 >180 s），ALB 会代回 **504**。缓解：网关侧 `RELAY_RESPONSE_HEADER_TIMEOUT`（默认 1800 s）远大于 ALB 上限，真正卡点在 ALB——对客引导 `stream: true`，或该路由改走 NLB。
4. **504/499 归属难查**：ALB 生成的 504 不落网关访问日志。排障时对齐三处：ALB 访问日志、网关日志按 request_id 反查、响应头里 ALB 注入的标记；不要把它误判为网关故障。
5. **真实客户端 IP 只走 XFF**：ALB 是代理型 LB，后端看到的源地址是回源网段。网关必须把 `TRUSTED_PROXIES` 配成 ALB 回源交换机网段（`middleware/trusted_proxies.go`），否则限流/审计把"所有人"当同一个 IP，或者信任过宽导致 XFF 可伪造。NLB 四层则相反——直接可见真实源 IP，可再开 Proxy Protocol v2 携带 VPC 信息。
6. **域名 ≠ 固定 IP**：ALB/NLB 交付的是 DNS 名，底层地址会随扩缩容/故障切换漂移。用户侧与 GTM 一律 CNAME 到 LB 域名；任何防火墙白名单写死解析 IP 的做法都会在变更后瞬间雪崩。
7. **健康检查阈值抖动摘除**：`healthcheck-interval-seconds` 默认 2 s、阈值次数 [2,10]；本项目当前 `/api/status` 只代表进程活着，不探 DB/Redis（就绪语义缺失见 10.2 / R 项），高负载 GC 停顿也可能连续超时被摘。生产取值 interval 10 s + unhealthy 2–3 次是折中；readyz 落地前，摘除≠健康这种误判要写进 runbook。
8. **滚动发布断连**：SSE 长连接不随 keep-alive 迁移，Pod 终止必须先摘流：readiness 置灰 → `connection-drain-enabled` + `connection-drain-timeout`（对齐 `SHUTDOWN_TIMEOUT_SECONDS` 120 s）→ preStop sleep（7.4.2 已配 15 s）。三者缺一就会有 502/连接重置尖峰。
9. **灰度注解三要件**：canary 注解必须放在第二条 Ingress 上、第二条 Ingress 后端必须是**独立 canary Service**、与主 Ingress 的 host+path 完全一致；用一个同时选择 stable/canary Pod 的 Service 做不了权重分流（那是 kube-proxy 轮询，与 ALB 规则无关）。键名是 `canary-weight`，写 `canary-by-weight` 会被静默忽略。
10. **ALB 没有 UDP 监听**：Realtime/音频 UDP 流量只能走 NLB；在 ALB 上配 UDP 后端组会直接失败。
11. **gRPC/QUIC 的隐性前置**：gRPC 后端要 `backend-protocol: grpc` 且走 HTTPS/TLS 监听；QUIC 要在监听上显式开启并配好证书，HTTP/3 场景客户端 SDK 兼容性要先验证。
12. **后端同地域同 VPC**：ALB/NLB 不能挂跨地域后端；马尼拉/曼谷双活只能靠 DNS+GTM 切流量（第八章），不存在"一个 ALB 两地后端"的选项。AlbConfig 建实例要求 ≥2 可用区的 vSwitch。
13. **LCU 计费与长连接**：LCU 按新建连接、并发连接、数据处理量、规则评估等维度**取峰值**计费——SSE 万级并发长连接会持续推高"并发连接"维度，费用模型要在压测里带上 LB LCU 观测；灰度扩量用权重数字而不是"每版本一条转发规则"，规则数同样进计费与配额。
14. **版本差异**：基础版缺自定义转发规则等高级能力，标准版 II 面向大流量与容量预留；三者间功能差异以官方版本对比文档为准，上线前逐项核对（本项目灰度依赖的权重规则在标准版以上才完整）。
15. **TLS 兼容与配额**：菲律宾/泰国存量低端机型 TLS 栈偏旧，安全策略强制 TLS1.3-only 会切断部分客户；推荐 TLS1.2+1.3 并保留观测。SNI 证书数量、监听数、服务器组数都有配额，多域名+双站点部署前先去配额中心提额。
16. **勿用 CLB 承接新流量**：CLB 属于上一代，功能、灰度、可观测全面落后；只有存量场景保留，并应排期迁移到 ALB/NLB。

### A.7 参考资料

- [负载均衡 SLB 产品家族介绍](https://help.aliyun.com/zh/slb/product-overview/slb-overview)
- [ALIYUN::ALB::Listener（IdleTimeout 1–60 / RequestTimeout 1–180 取值定义）](https://help.aliyun.com/zh/ros/developer-reference/aliyun-alb-listener)
- [ALIYUN::NLB::Listener（IdleTimeout 取值、TCP/UDP/TCPSSL、Proxy Protocol v2）](https://help.aliyun.com/zh/ros/developer-reference/aliyun-nlb-listener)
- [ALB Ingress 配置词典（注解全集；超时仅 AlbConfig 可配）](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/alb-ingress-configuration-dictionary)
- [通过 ALB Ingress 实现灰度发布](https://www.alibabacloud.com/help/zh/ack/ack-managed-and-ack-dedicated/user-guide/use-alb-ingresses-to-perform-canary-releases-1)
- [ALB Ingress 服务高级用法](https://help.aliyun.com/zh/ack/ack-managed-and-ack-dedicated/user-guide/advanced-alb-ingress-configurations)

---

## 附录B：主节点故障容灾设计

> 触发背景：官方文档《集群部署》页（docs.newapi.ai cluster-deployment）仍按 one-api 时代拓扑描述"主节点负责处理所有写操作，从节点处理读请求"，并给出固定的单 Master + 多 Slave 架构图。该口径与**当前代码不符**，容易让人误判 Master 是写链路的单点。本附录先澄清 master 的真实职责，再给出其故障时的影响面、容灾设计与 RTO 预算，作为 7.4.2 部署方案与第八章 SLA 的补充。

### B.1 当前代码中 master 的真实职责

`IsMasterNode` 仅由环境变量决定：`NODE_TYPE != "slave"`（`common/init.go:89`）。生产代码中全部 master 判定如下——**没有一处拦截业务写请求**：

| 职责 | 代码位置 | master 缺席时的影响 |
| --- | --- | --- |
| 主库 / 日志库 AutoMigrate、审计日志迁移 | `model/main.go:215、235、262` | 仅影响"新版本首次启动时的 schema 升级"，稳态运行无影响 |
| 退役前端 option 迁移 | `main.go:333` | 同上，启动期一次性 |
| Casbin 内置角色/策略 seed | `service/authz/enforcer.go:34、57` | 仅新集群初始化需要 |
| 系统任务 runner（调度 + 执行） | `service/system_task.go:124-127` | **后台任务停摆**（见下行） |
| 渠道自动测试、上游模型同步、异步任务轮询（Midjourney/Suno/视频）注册为定时系统任务 | `main.go:153-158` | 视频/MJ 任务停留在非终态直到 master 恢复；渠道健康检测暂停 |
| 订阅额度重置 / 会话清理 / Codex 凭证刷新 | `service/subscription_reset_task.go:31`、`service/auth_cleanup.go:16`、`service/codex_credential_refresh_task.go:37` | 对应任务延迟执行（均可幂等补跑） |
| 前端 BaseUrl 注入 | `router/main.go:24` | 边缘配置 |

中继链路上的写——额度扣减、`logs`/`usedata` 落库、渠道管理 API——**任何 slave 节点都直接写共享 PostgreSQL**（slave 跑完整 relay 链路有测试佐证，如 `router/relay_router_test.go:103` 显式设 `IsMasterNode=false`）；配置一致性靠各节点轮询（`SYNC_FREQUENCY`），不存在"写必须过主"。因此写吞吐的扩展瓶颈在 PG（用 `BATCH_UPDATE_ENABLED` 合并额度写、只读实例分流看板查询），网关节点包括 master 都不是写路径瓶颈。

### B.2 故障影响面（按场景）

| 场景 | 用户可见影响 | 预计持续 |
| --- | --- | --- |
| master 进程崩溃 / Pod 驱逐（K8s 自动重建） | 无感；仅后台任务暂停 | 60–120 s |
| master 所在节点宕机 | 同上，Pod 跨节点重调度 | 60–120 s |
| master 滚动升级 | 同上；新旧 master 短暂并存，由租约去重 | ≈0（并存期无双跑） |
| master 长期未恢复（配置错误/镜像拉取失败） | 主 API 仍可用；异步任务出结果延迟、渠道健康检测停摆、订阅重置推迟 | 分钟→小时，需告警介入 |
| **PG 主库故障**（真正的数据面单点） | 全部写失败 | RDS HA 自动切换 30–60 s |

结论：master 挂掉**不丢请求、不丢数据**（状态全在 PG/Redis），丢的是"定时任务的执行权"，且任务全部设计为可补跑。

### B.3 容灾设计（与 7.4.2 部署方案配套）

1. **角色化单副本**：master 是独立 Deployment（`replicas: 1`、`strategy: Recreate`、不在 Service 选择器内、不接 ALB 流量），故障由 K8s 控制面自动重建——**容灾主体是"角色可重建"，不是"节点保活"**。
2. **接管时序**：

```mermaid
sequenceDiagram
  participant K8S as ACK 控制面
  participant M2 as 新 master Pod
  participant DB as PostgreSQL
  participant SL as slave 节点组
  Note over M2: t=0 原 master 故障, 任务租约未释放(等待 60s TTL 过期)
  K8S->>M2: Recreate 重建并调度到健康节点
  M2->>DB: InitDB + 幂等 AutoMigrate
  M2->>DB: StartSystemTaskRunner 抢占 system_task_locks 租约
  M2->>DB: 15s idle tick 立即 claim 到期任务并补跑
  SL-->>DB: 全程中继额度与日志写入不受影响
  Note over M2: t 约 60-120s 后台任务全部恢复
```

3. **双 master 安全（租约去重）**：调度型系统任务靠 `system_task_locks` 的 DB 租约防双跑——锁 TTL 60 s、调度与 idle tick 15 s、stale lock 清理 30 s（`service/system_task.go:20-27`），注册逻辑明确按"跨 master 的 DB 租约去重 + 执行历史"设计（`main.go:153-156`）。因此滚动升级/故障接管窗口内新旧 master 并存也不会双扣费、双结算。
4. **补跑语义**：异步任务轮询是无状态重查——任务行在 `tasks` 表，上游（视频/MJ）结果不会因暂停而丢失，master 恢复后下一轮 tick 即推进到终态；订阅重置、会话清理按时间戳幂等，延迟执行只会推迟不会重复。
5. **可选增强（把 RTO 压到 ≈15 s）**：将 master 改为 **2 副本候选、同设 `NODE_TYPE=master`**，租约天然保证单执行，一侧挂掉另一侧在下一个 15 s tick 接管。前置条件：启动期 AutoMigrate 需要互斥——当前两个 master 同时首启会并发执行迁移（PG 下 DDL 并发可能报错），须先补一把"迁移启动锁"（可复用 `system_task_locks` 模式）并把该增强与 R-04 的迁移治理合并实施；未补锁之前**保持单副本 Recreate**。

### B.4 RTO 与 99.95% 错误预算核算

月度预算 21.6 min（99.95%）：

| 失效域 | 机制 | RTO | 预算占比 |
| --- | --- | --- | --- |
| master 单点 | K8s 自动重建 + 租约接管 | 60–120 s | ≤9.3% |
| 网关节点 | ALB 健康摘除 + 多副本 | ≈0 | — |
| PG 主库 | RDS 高可用版自动切换 | 30–60 s | ≤4.6% |
| 单可用区 | ALB/RDS/Tair 跨 AZ | 秒级–分钟级 | 计入区域演练 |
| 整区域 | GTM 切曼谷 | 300–600 s | 年度演练，不占月度预算常态 |

对比：若按官方文档的 Docker Compose 手工集群，master 故障需人工改 `NODE_TYPE` 提升从节点，RTO ≥10 min 且不可保证——**一次故障吃掉近半预算，该方式不适用于 99.95% SLA 的生产环境**，仅适合演示或小规模内网。

### B.5 验证与反馈项

- **混沌演练（staging，季度）**：`kubectl delete pod <master>`，断言：① 中继成功率无 dip；② 任务执行间隔 ≤ 2 min；③ `system_task` 执行历史无双跑记录；④ 视频任务在恢复后推进到终态。
- **双 master 演练**：临时 scale master 至 2 副本，验证租约去重（对应 B.3 第 5 条增强前的基线行为）。
- **文档反馈**：向 docs.newapi.ai《集群部署》页提 issue——"主节点负责所有写操作"与架构图已过时，应改为"master 仅承担迁移与定时任务，业务写由各节点直连共享数据库"，并补充故障接管说明。
---

**文档结束。** 本文对当前工程的分层架构、代码目录、数据存储、核心链路时序、日志/监控/限流/灰度/回滚能力、阿里云菲律宾+泰国双区域部署方案、99.95% SLA 达成路径与 31 项系统不足及改进措施做了完整说明，附录A 另给出阿里云 ALB / NLB / CLB 负载均衡的选型指南、使用步骤与坑点清单，附录B 补充集群 master 节点职责澄清与故障容灾设计；其中标注 **[需补建]** 与 R-01 ~ R-31 的条目为当前工程尚未实现的能力，须在落地阶段按 9.6 路线图逐项闭环。
