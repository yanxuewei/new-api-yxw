# new-api 技术设计文档（impl_tech.md）

| 项目 | 内容 |
| --- | --- |
| 文档版本 | v1.1 |
| 编写日期 | 2026-09-22 |
| 适用代码基线 | 分支 `main`，commit `972aed197`（`fix(log): derive response model mismatch from names instead of a stored flag (#7464)`） |
| 目标读者 | 架构 / 后端 / 前端 / SRE / 运维 |
| 部署目标 | 阿里云（菲律宾主站点：马尼拉 `ap-southeast-6`；泰国主站点：曼谷 `ap-southeast-7`；两地共用备 region：新加坡 `ap-southeast-1`），主要服务菲律宾与泰国客户 |
| 可用性目标 | 系统整体 SLA ≥ **99.95%** |

> 说明：本文档所有事实均来自当前仓库代码的实际阅读，并在需要处标注 `文件:行号`。凡标注 **[现状]** 的是仓库中已经实现的能力；凡标注 **[需补建]** 的是当前工程缺失、需要在落地部署时补齐的能力。本章之外的"第九章 系统不足与改进措施"对二者做了完整清单化梳理，请勿混读。

---

## 目录

1. [系统概述与设计目标](#一系统概述与设计目标)

7. [阿里云部署方案（菲律宾 + 泰国）](#七阿里云部署方案菲律宾--泰国)
8. [SLA 99.95% 达成方案](#八sla-9995-达成方案)
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

## 七、阿里云部署方案（菲律宾 + 泰国）

### 7.1 地域选择与网络拓扑

**延迟事实（公网 RTT 量级，用于决策，实际以拨测为准）**：

| 用户所在地 | 到马尼拉 `ap-southeast-6` | 到曼谷 `ap-southeast-7` | 到新加坡 `ap-southeast-1` |
| --- | --- | --- | --- |
| 菲律宾（马尼拉/宿务） | **5–15 ms** | 60–90 ms | 30–45 ms |
| 泰国（曼谷） | 55–80 ms | **5–20 ms** | 25–40 ms |
| 新加坡备 region 到主库（公网，仅接管时使用） | 45–70 ms | 40–65 ms | — |

结论：**双主站点 + 单备 region（Active-Standby）**。马尼拉承载菲律宾、曼谷承载泰国，二者均为承接本国客户常态流量的热主站点；**新加坡作为两地共用的备 region**，只部署网关计算与本地缓存/日志，**不部署 RDS PostgreSQL**：

- **RDS PostgreSQL 高可用版只存在于马尼拉（菲律宾唯一主库）与曼谷（泰国唯一主库）**，两库彼此独立，**取消 DTS 双向同步链路，不做双写**。
- 新加坡备 region 在接管时，**通过公网（RDS 公网地址 + 强制 TLS 证书校验 + IP 白名单）读写对应主站点的同一个库**：PH 备连马尼拉库，TH 备连曼谷库。任一时刻数据只有一份主库，从根上消除双写冲突、自增/序列错乱与计费对账分裂。
- 代价是备 region 写入额外叠加 40–70 ms 公网 RTT。该延迟只在"主站点整体不可用、流量被 GTM 切到备 region"期间生效，常态流量始终走主站点内网，不影响常态 TTFT。
- AI 网关是长连接流式场景，RTT 直接叠加到 TTFT 体感，**主站点不能只放一个区域**；备 region 的职责是承接"主站点整体不可用"这一最坏情形，而不是分担常态流量。

```mermaid
%% 布局：自上而下依次为 终端用户 → 全球接入 → 马尼拉主站点 → 曼谷主站点 → 新加坡备 region → 上游出口 → 上游供应商 → 可观测中心。
%% 说明：末尾三条 `~~~` 是不可见连线，仅用于强制上述纵向排列次序，不代表任何数据流。
flowchart TB
  subgraph USERS["终端用户"]
    PH["菲律宾客户"]
    TH["泰国客户"]
    OTHER["其他地区客户"]
  end

  subgraph ACCESS["阿里云全球接入"]
    GTM["云解析 DNS 全局流量管理 GTM<br/>按 Latency 就近解析 + 健康探测切换"]
    CDN["DCDN 静态加速<br/>web/dist 资源"]
    WAF1["WAF 3.0 实例 马尼拉"]
    WAF2["WAF 3.0 实例 曼谷"]
    WAF3["WAF 3.0 实例 新加坡"]
  end

  subgraph MNL["区域一 ap-southeast-6 马尼拉 主站点（菲律宾）"]
    ALB1["ALB 多可用区<br/>idleTimeout 60s + SSE 心跳保活"]
    ACK1["ACK Pro 集群<br/>可用区 A + B"]
    RDS1["RDS PostgreSQL 高可用版<br/>菲律宾唯一主库 主 A 备 B"]
    TAIR1["Tair 主备版"]
    CK1["云数据库 ClickHouse<br/>日志"]
    OSS1["OSS 同城冗余"]
  end

  subgraph BKKT["区域二 ap-southeast-7 曼谷 主站点（泰国）"]
    ALB2["ALB 多可用区"]
    ACK2["ACK Pro 集群 可用区 A + B"]
    RDS2["RDS PostgreSQL 高可用版<br/>泰国唯一主库"]
    TAIR2["Tair 主备版"]
    CK2["ClickHouse"]
    OSS2["OSS"]
  end

  subgraph SG["区域三 ap-southeast-1 新加坡 备 region（不部署 RDS）"]
    ALB3["ALB 多可用区"]
    ACK3["ACK Pro 集群<br/>PH 备 + TH 备 两套独立工作负载"]
    TAIR3["Tair 主备版 本地缓存"]
    CK3["ClickHouse 本地日志"]
    OSS3["OSS"]
    SGWAN["备 region 经公网 TLS 读写主库（仅接管时生效，不双写）<br/>PH 备 → pg-mnl-rw.pg.rds.aliyuncs.com<br/>TH 备 → pg-bkk-rw.pg.rds.aliyuncs.com<br/>sslmode=verify-full + IP 白名单"]
  end

  EGR["上游出口 NAT + 固定 EIP 池<br/>同一 EIP 池也是备 region 访问主库的白名单来源"]
  GA["全球加速 GA"]
  UPSTREAM["OpenAI / Anthropic / Google / Azure / AWS 等"]
  MON["可观测中心<br/>SLS + ARMS + Prometheus + Grafana + 拨测"]

  PH --> GTM
  TH --> GTM
  OTHER --> GTM
  GTM -->|"PH 用户 · 主"| WAF1
  GTM -->|"TH 用户 · 主"| WAF2
  GTM -.->|"PH / TH 故障接管"| WAF3
  CDN --> OSS1
  CDN --> OSS2
  CDN --> OSS3
  WAF1 --> ALB1 --> ACK1
  WAF2 --> ALB2 --> ACK2
  WAF3 --> ALB3 --> ACK3
  ACK1 --> RDS1
  ACK1 --> TAIR1
  ACK1 --> CK1
  ACK1 --> OSS1
  ACK2 --> RDS2
  ACK2 --> TAIR2
  ACK2 --> CK2
  ACK2 --> OSS2
  ACK3 --> TAIR3
  ACK3 --> CK3
  ACK3 --> OSS3
  ACK3 --> SGWAN
  ACK1 -->|上游调用| EGR
  ACK2 -->|上游调用| EGR
  ACK3 -->|上游调用| EGR
  EGR --> GA
  GA --> UPSTREAM
  ACK1 -.-> MON
  ACK2 -.-> MON
  ACK3 -.-> MON

  %% 不可见连线：仅用于强制子图自上而下排列，不代表数据流
  RDS1 ~~~ ALB2
  RDS2 ~~~ ALB3
  UPSTREAM ~~~ MON
```

> **上图读法**：主干自上而下为「用户 → 全球接入 → 主站点 / 备 region → 上游出口 → 上游 AI 供应商」，`~~~` 仅为排版用的不可见连线。备 region 到主库的公网读写路径以 `SGWAN` 节点呈现（**有意不再画跨区域连线**，否则会触发 mermaid 把整张图横向铺开）：PH 备 → 马尼拉主库、TH 备 → 曼谷主库，仅故障接管时生效且不双写。若渲染器版本低于 mermaid 10.2（不支持 `~~~`），删除末三条不可见连线即可，其余语法不受影响。

### 7.2 云资源清单（生产最小高可用配置）

| 层 | 产品 | 规格建议 | 数量 | 关键配置 | 可用性贡献 |
| --- | --- | --- | --- | --- | --- |
| 接入 | 云解析 DNS + GTM | 旗舰版 | 1 | 按延迟解析，HTTP 健康探测 15 s，故障切换 ≤ 60 s；菲律宾业务：主 → 马尼拉、备 → 新加坡；泰国业务：主 → 曼谷、备 → 新加坡 | 单主站点故障自动切到备 region |
| 接入 | DCDN | 按量 | 1 | `index.html` 强制 `no-cache`，带指纹的 chunk 缓存 7 天 | — |
| 接入 | WAF 3.0 | 企业版 | 3（马尼拉 / 曼谷 / 新加坡各 1） | 放行支付回调路径；CC 防护阈值对齐 `GLOBAL_API_RATE_LIMIT` | 抗 L7 |
| 接入 | ALB | 标准版 II | 3（每站点 1 组多 AZ） | `AlbConfig` listeners：`idleTimeout=60`、`requestTimeout=180`（均为产品上限，SSE 靠网关 ping 保活）、HTTPS TLS1.2+1.3、`canary-weight` 灰度 | 99.99% |
| 计算 | ACK Pro 托管版 | 控制面 SLA 99.95% | 3 集群（马尼拉、曼谷主集群 + 新加坡备 region 集群） | Kubernetes 1.31+，CNI Terway，多 AZ | 99.95% |
| 计算 | ECS 节点池 | `g8i.2xlarge`(8C32G) | 马尼拉 / 曼谷各 ≥ 4（跨 2 AZ）；新加坡备 ≥ 2（PH 备 + TH 备 各 1） | 系统盘 100 G ESSD PL1 + 数据盘 200 G ESSD（`/data` 与 `/app/logs`） | — |
| 数据 | RDS PostgreSQL 高可用版 | pg 15，`rds.pg.c2.4xlarge` 或 16C64G | **2：马尼拉 1（菲律宾唯一主库）+ 曼谷 1（泰国唯一主库）**，可选每站点 1 只读实例 | 主备跨 AZ、PITR 保留 7 天、每日全量 + WAL 归档到 OSS、`max_connections` 按主站点 + 备 region 连接总和核算 | 99.99% |
| 数据 | RDS 公网访问（SSL） | 按量 | 2（马尼拉、曼谷各开 1 个公网地址） | **仅新加坡备 region 使用**：`sslmode=verify-full` + RDS CA 校验 + 白名单只放新加坡 VPC 的 NAT EIP；主站点流量一律走内网地址 | 备 region 接管 |
| 缓存 | Tair（Redis 兼容）| 主备版 4 GB（生产建议集群版） | 3（马尼拉 / 曼谷 / 新加坡各 1） | 跨 AZ、密码 + 内网 ACL、`maxmemory-policy allkeys-lru` | 99.99% |
| 日志 | 云数据库 ClickHouse | 24.8 社区版 2 节点 | 3（马尼拉 / 曼谷 / 新加坡各 1） | 仅 `LOG_SQL_DSN`、`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` | — |
| 存储 | OSS | 标准 + 低频生命周期 | 3 bucket（马尼拉 / 曼谷 / 新加坡各 1） | 同城冗余 ZRS、版本开启、生命周期 90 天转归档、防盗链 + 签名 URL | 99.995% |
| 观测 | SLS + ARMS + Prometheus（ARMS Prometheus 版）+ Grafana 服务 | 按量 | 1 套 | 见 7.8 | — |
| 观测 | 云监控拨测（站点监控） | 菲律宾 + 泰国 + 新加坡探测点 | 3+ | 探测 `GET /api/status` 与 `GET /healthz`，1 min 间隔 | 真实用户视角 |
| 安全 | KMS 凭据管家 | 软件密钥 | 1 | 托管 `SQL_DSN`、`REDIS_CONN_STRING`、`SESSION_SECRET`、支付密钥 | — |
| 网络 | VPC + vSwitch + NAT + EIP | /16 与 3 个 /20 | 3 套（马尼拉 / 曼谷 / 新加坡） | 私有子网跑 Pod 与 DB，仅 ALB 在公网子网；NAT 出口固定 EIP 池用于上游白名单，同一 EIP 池同时作为新加坡备 region 访问主库的白名单来源 | — |

> **相对旧方案的两项结构性变化**：① **取消 DTS 链路**——菲律宾与泰国各自只有一个主库，跨区不存在任何数据库复制关系，故本表不再保留 `DTS` 条目；② **新增新加坡备 region 的接入与计算资源**，但**新加坡不部署任何 RDS 实例**，备 region 通过 RDS 公网地址读写主站点主库（部署细节见 7.4.4）。

### 7.3 应用部署形态选择

| 方案 | 适用 | 说明 |
| --- | --- | --- |
| **推荐：ACK + ALB Ingress + 双 Deployment（stable/canary）** | 生产（马尼拉、曼谷主站点） | 满足 99.95%、支持自动扩缩与灰度门禁；见 7.4 |
| **推荐：新加坡备 region 同构 ACK Pro（PH 备 + TH 备 两套独立 Deployment）** | 生产（两地共用备 region） | 只部署计算与本地 Tair/ClickHouse，**不含 RDS**；PH 备连马尼拉主库、TH 备连曼谷主库，均走公网 TLS；见 7.4.4 |
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
  TZ: "Asia/Manila"                 # 曼谷站点改 Asia/Bangkok；新加坡备 region 按所服务的站点改 Asia/Manila 或 Asia/Bangkok；统计按小时分桶建议统一 UTC 并单列展示时区
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
  # 主站点（马尼拉/曼谷）用本区域 RDS 内网地址；新加坡备 region 必须改用对应主库的 RDS 公网地址 + verify-full（见 7.4.4）
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

> **master 节点单独处理**：**每个主站点（马尼拉、曼谷）各需一个 `NODE_TYPE=master` 的 Deployment**（`replicas: 1`、`strategy: Recreate`、独立 PVC `ReadWriteOnce`），各自只对自己站点的 RDS 主库执行 AutoMigrate 与 master-only 迁移；它**不接 ALB 流量**（不在 Service 选择器内），只跑后台任务与迁移。**新加坡备 region 的 PH 备 / TH 备工作负载必须固定 `NODE_TYPE=slave`**：备 region 与主站点访问的是同一个主库，若备 region 也起 master 会与主站点 master 并发迁移同一 schema。滚动发布顺序：先升级 master → schema 就绪 → 再滚动 stable slave → 最后升级 canary → 最后预热新加坡备 region。这是解决 1.2 中"非 master 从不迁移"风险（R-04）的部署侧手段；master 故障后的接管时序、租约去重与 RTO 预算见附录B。

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

#### 7.4.4 新加坡备 region 部署（PH 备 + TH 备）

新加坡备 region **不部署 RDS PostgreSQL**，只部署两套互相独立的网关工作负载，各自通过 RDS 公网地址读写对应主站点的主库：

| 工作负载 | 归属 | `SQL_DSN` 目标 | 触发接管 | 副本 |
| --- | --- | --- | --- | --- |
| `new-api-ph-standby` | 菲律宾 | 马尼拉 RDS **公网地址** | GTM 探测到马尼拉不可用 | 2（热备） |
| `new-api-th-standby` | 泰国 | 曼谷 RDS **公网地址** | GTM 探测到曼谷不可用 | 2（热备） |

与主站点的差异只有环境变量、副本数、Secret 与 Service/Ingress 归属，容器模板复用 7.4.2：

```yaml
# deploy/aliyun/40-deployment-sg-standby.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: new-api-ph-standby            # 泰国备为 new-api-th-standby，仅 site 标签、Secret 与 GTM 归属不同
  namespace: new-api
  labels: { app: new-api, site: ph, track: standby, topology: sg }
spec:
  replicas: 2                          # 成本优先可置 0，改为 GTM 触发 + 预留容量预案（RTO 由秒级变为分钟级）
  strategy: { type: RollingUpdate, rollingUpdate: { maxSurge: 1, maxUnavailable: 0 } }
  selector:
    matchLabels: { app: new-api, site: ph, track: standby }
  template:
    metadata:
      labels: { app: new-api, site: ph, track: standby }
    spec:
      serviceAccountName: new-api
      terminationGracePeriodSeconds: 180
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { app: new-api, site: ph, track: standby } }
      containers:
        - name: new-api
          image: registry-vpc.ap-southeast-1.aliyuncs.com/newapi/new-api:STABLE_SHA
          args: ["--log-dir", "/app/logs"]
          ports: [ { containerPort: 3000, name: http } ]
          envFrom:
            - configMapRef: { name: new-api-env }
            - secretRef: { name: new-api-secret-sg-ph }      # SQL_DSN 指向马尼拉 RDS 公网地址
          env:
            - { name: NODE_TYPE, value: "slave" }            # 备 region 绝不跑 master 迁移
            - { name: SQL_MAX_OPEN_CONNS, value: "150" }     # 公网链路，压低连接占用
            - { name: SQL_MAX_LIFETIME, value: "60" }        # 让公网侧僵死连接尽快回收
            - { name: REDIS_CONN_STRING, value: "redis://:REPLACE_ME@tair-sg.redis.rds.aliyuncs.com:6379" }
            - { name: LOG_SQL_DSN, value: "clickhouse://default:REPLACE_ME@clickhouse-sg.clickhouse.rds.aliyuncs.com:9000/newapi_logs" }
          readinessProbe:
            httpGet: { path: /api/status, port: 3000 }       # 补建 /readyz 后切换（需含一次主库 SELECT 1）
            periodSeconds: 5
            failureThreshold: 2
```

对应的 Secret（`new-api-secret-sg-th` 同理，仅目标库换成曼谷）：

```yaml
apiVersion: v1
kind: Secret
metadata: { name: new-api-secret-sg-ph, namespace: new-api }
type: Opaque
stringData:
  # 新加坡访问马尼拉主库的「公网」接入点，强制证书校验，禁止 sslmode=disable / require
  SQL_DSN: "postgresql://newapi_sg:REPLACE_ME@pg-mnl-rw.pg.rds.aliyuncs.com:5432/newapi?sslmode=verify-full&sslrootcert=/etc/ssl/rds-ca.pem"
  SESSION_SECRET: "REPLACE_ME_32B_RANDOM_SAME_ACROSS_ALL_NODES_AND_REGIONS"
```

> 备 region 只需 **Service + Ingress**（`site: ph` / `site: th` 两组），GTM 接管时把对应业务域名解析直接指向新加坡 ALB 实例。备 region 与主站点共用同一份主库数据与同一个 `SESSION_SECRET`，因此接管瞬间控制台会话与 API 令牌无需重新登录。

**备 region 经公网读写主库的安全与容量约束（须逐条落实）**：

- **最小暴露面**：RDS 公网地址的白名单**只放新加坡 VPC 的 NAT EIP**（与上游出口复用同一 EIP 池）；备 region 使用独立低权限账号 `newapi_sg`，禁止与主站点共用账号。
- **强制加密与校验**：`sslmode=verify-full` + 下载 RDS CA 到镜像只读路径做校验；连接串不得出现 `sslmode=disable` 或 `require`。
- **连接数硬约束**：备 region 单实例 `SQL_MAX_OPEN_CONNS ≤ 150`，且 `主站点 SQL_MAX_OPEN_CONNS × 实例数 + 备 region × 实例数 ≤ RDS max_connections × 0.8`。
- **不双写**：同一主库同一时刻只允许"主站点"或"备 region"其一写入，切换由 GTM 健康探测 + 主站点 ALB 摘流共同收口；**禁止**在备 region 部署本地数据库、只读副本或任何 DTS 双向链路。
- **健康判定必须真读写**：GTM 与备 region 的就绪探针不得只打静态接口，`/readyz`（补建后）必须包含一次主库 `SELECT 1`；否则主库不可达时备 region 会被误判为健康并被接入话务。
- **延迟与流量**：新加坡 → 马尼拉 / 曼谷公网 RTT 约 40–70 ms，接管期写入 P99 抬升可接受；非接管期备 region 只承接 GTM 健康探测与内部验证流量，避免无谓的跨区写。

### 7.5 生产 Docker Compose 配置

两种用法：**(a)** 无 K8s 时的单机/多机快速生产部署；**(b)** 作为 ACK 之外的灾备冷站。相较仓库自带 `docker-compose.yml`（参考版，默认弱口令），下面这份是**生产加固版**：3 个网关实例做滚动发布单元、显式网络隔离、只读根文件系统、日志与指标 sidecar。

> **新加坡备 region 不适用下面的本地 `postgres` 服务**：备 region 必须把 `SQL_DSN` 指向马尼拉/曼谷 RDS 的**公网地址**（`sslmode=verify-full`），并在 `.env.prod` 中删除/停用本地 `postgres`、`pg-data` 卷与 `backup` sidecar；本地 `redis`、`clickhouse` 保留，仅作为备 region 的本地缓存与日志库。PH 备与 TH 备用两个独立 compose project（或两个 `--env-file`）区分 `SQL_DSN` 与端口。

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
    # 生产建议改用 RDS 高可用版并删除本服务；新加坡备 region 必须删除本服务，改连主站点 RDS 公网地址

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

新加坡备 region 若采用裸机形态，同样只把 `SQL_DSN` 指向主站点 RDS 的**公网地址**（`sslmode=verify-full` + IP 白名单）并固定 `NODE_TYPE=slave`，**不在本地部署 PostgreSQL**。

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

**新加坡备 region 的发布顺序**：PH 备 / TH 备工作负载连的是同一份生产主库、且固定为 `NODE_TYPE=slave`，是天然的"真实数据前置验证"环境。因此**先升级新加坡备 region 并观察一轮，再进入主站点的 canary 门禁**；备 region 版本落后于主站点时不允许让其参与 GTM 接管。

**发布窗口与冻结策略**：菲律宾发薪日（每月 15/30 日）与当地工作时间 09:00–21:00 GMT+8 禁止发布；发布窗口固定在 **马尼拉时间 02:00–05:00**。错误预算燃尽 > 80% 时自动冻结非必要发布。

### 7.8 监控集成（阿里云侧）

| 数据面 | 阿里云产品 | 接入方式 | 保留 |
| --- | --- | --- | --- |
| 指标 | ARMS Prometheus 版 | ACK 装 arms-prometheus + ServiceMonitor 抓 `/metrics`（需补建）；ECS 场景用 prometheus agent 远程写 | 90 天热 + 2 年降采样 |
| 应用性能 | ARMS Application Monitoring | Go 应用接 OpenTelemetry SDK（需补建 R-07），或 eBPF 无侵入 | 30 天 |
| 持续剖析 | ARMS 持续剖析（Pyroscope 兼容） | `PYROSCOPE_*` 环境变量已内建 | 30 天 |
| 日志 | SLS | Logtail 采 `/app/logs` + stdout；`logs`/`audit_logs` 由应用经 SLS SDK / Logtail 投递（**不再依赖 DTS**） | sys 30 天 / audit 180 天 |
| 看板 | Grafana 服务 | 数据源 Prometheus + SLS；三块看板：SLA/SLO 燃尽、中继健康（模型 × 渠道）、容量与成本 | — |
| 拨测 | 云监控站点监控 | 探测点选马尼拉、曼谷、新加坡、东京、香港；断言 `success:true` + 版本匹配 | 15 个月 |
| 备 region 链路 | 云监控 + RDS 监控 | 新加坡 → 马尼拉 / 曼谷 RDS 公网地址的 TCP 拨测：RTT、连接失败率、连接数占比；链路不健康时告警并阻止 GTM 接管到备 region | 15 个月 |
| RUM | 前端监控 ARMS RUM | 复用现有 Umami / GA 注入点（`main.go:248-289`）叠加 RUM | — |
| 告警 | ARMS 告警 + 云监控 | 钉钉/企业微信 + 短信 + 电话；P1 走电话，按 6.3.4 表落地；排班用告警值班表 | — |
| 审计合规 | 操作审计 ActionTrail + DB 审计 | 云 API 变更全部留痕；RDS SQL 洞察开启 | 180 天 |

### 7.9 环境矩阵与发布验证

| 环境 | 区域 | 数据库 | 用途 | 门禁 |
| --- | --- | --- | --- | --- |
| dev | 本地 | SQLite + `docker-compose.dev.yml` | 功能开发 | `bun run lint`、`make test` |
| staging（pre） | 新加坡 | RDS PG + Tair + ClickHouse | 集成与三数据库矩阵 | 每次合并主干；`SQL_DSN` 分别用 MySQL 8.2 / PG 15 / SQLite 跑同一套 E2E |
| perf | 新加坡 | 同 staging + mock 上游 | 3.9 压测场景矩阵 | 相对基线劣化 > 10% 阻断 |
| prod mnl | 马尼拉 | RDS PG HA（菲律宾唯一主库）+ Tair + CH | 菲律宾流量（主站点） | 灰度门禁 |
| prod bkk | 曼谷 | RDS PG HA（泰国唯一主库）+ Tair + CH | 泰国流量（主站点） | 与 mnl 错峰发布（先 bkk 后 mnl 或反之） |
| standby sg | 新加坡 | **无本地 RDS**：PH 备 / TH 备经公网读写主站点 PG + 本地 Tair + CH | 两地共用的备 region | 区域接管演练；备工作负载先于主站点发布 |

**三数据库强制验证（AGENTS.md 要求，不可省略）**：任何影响 DB 行为的改动（模型/GORM 标签/迁移/DSN/驱动/Scanner-Valuer/原生 SQL/事务/行锁）必须在**真实** SQLite、MySQL ≥ 5.7.8（建议 8.2）、PostgreSQL ≥ 9.6（建议 15）上验证，日志库涉及 ClickHouse 时一并覆盖；迁移需在新建库 + 由上一发布版本产生的存量库上各跑，并至少启动两次证明幂等，且记录数据库版本、命令与结果。

### 7.10 成本结构（估算口径，需按实际报价校准）

| 项 | 说明 |
| --- | --- |
| 计算 | 马尼拉 / 曼谷各 4×`g8i.2xlarge`（可扩至 16），新加坡备 region 常态 4×（PH 备 + TH 备各 2）；按量转包年包月可省 30–40% |
| 数据 | **RDS PG 高可用版 16C64G ×2（马尼拉 + 曼谷，各为本地唯一主库，无跨区副本）**；RDS 公网流量与连接许可为新增小额项；Tair 4 GB 主备 ×3 |
| 日志 | ClickHouse 2 节点 ×3 区域，随 TTL 90 天与采样策略线性 |
| 网络 | ALB LCU 费用与 **出站带宽** 是主要成本项；LLM 流式响应出站带宽大，建议与 DCDN 动静态分离并对上游出口走 GA；备 region 接管期的跨区数据库读写走公网计费，按小流量估算 |
| 优化 | 新加坡备 region 若采用"置 0 副本 + GTM 触发扩容"冷备形态，可省下常态计算成本，代价是接管 RTO 由秒级变为分钟级 |
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
| DNS/GTM + 就近解析 | 双主站点 + 新加坡备 region，健康探测切换 | 99.99% | 单站点故障 60 s 内切到备 region |
| WAF + ALB | 阿里云多 AZ 实例，SLA 99.99% | 99.99% | SSE 超时配置正确，避免"假可用" |
| ACK 控制面 | Pro 托管版多 AZ | 99.95% | 控制面故障不影响已运行 Pod 的数据面 |
| 网关数据面 | 每主站点 ≥ 4 副本跨 2 AZ（备 region 的 PH 备 / TH 备各 ≥ 2 副本）、`maxUnavailable=0`、PDB、preStop 排空 | 99.99% | 单实例 99.5% × 4 副本并联 |
| 主库 | RDS 高可用版跨 AZ 主备 + 自动切换 | 99.99% | 切换期 30 s 内，写入短暂失败由重试吸收 |
| 缓存 | Tair 主备 | 99.99% | **注意**：Redis 故障时限流 fail-closed 返回 500（`middleware/rate-limit.go:117`），实际会把可用性拉低到 Redis 的可用性 → 必须改造为降级放行（R-05） |
| 日志库 | ClickHouse（可写失败降级） | 99.9% | 写日志失败绝不能阻塞中继主链路（需在改造中显式保证） |
| 跨区数据 | 主库唯一 + 备 region 经公网直连（无 DTS、无双写） | 99.9% | 备 region 接管时写延迟抬升，但不存在双写冲突与对账分裂 |

串联（近似独立）：`0.9999 × 0.9999 × 0.9999 × 0.9999 × 0.9999 ≈ 0.9996`，仍高于 99.95% 目标，留出 ~0.01% 给"人因与变更"（业界的最大故障源）。**结论：双主站点 + 新加坡备 region + 每主站点 ≥ 4 副本 + RDS 高可用 + Redis 降级改造** 是达成 99.95% 的最低配置；单区域 3 副本约等于 99.9%（99.95 不达标）。

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
| 主站点整站故障 | GTM 健康检查连续失败 | DNS 切到新加坡备 region（容量已预留 1.5 倍）；备 region 经公网读写主站点主库 | 确认后手工降级非核心功能 | ≤ 5 min |
| 上游供应商区域性故障 | 渠道批量自动禁用（status=3）+ 告警 | `RetryTimes` 换渠道 + 优先级分层 + `status_code_mapping` | 切备用渠道 / 改 `model_mapping` | ≤ 60 s（轮询） |
| Redis 故障 | `newapi_redis_up == 0` | 限流降级内存滑动窗口（需改造），用户/令牌缓存回落 DB | 立即恢复 Tair | 分钟级 |
| 主库故障 | 连接错误 + RDS 事件 | RDS 主备自动切换；应用重连（`SQL_MAX_LIFETIME=60` 加速收敛） | 确认切换后校验额度一致性 | ≤ 60 s |
| 备 region→主库公网链路劣化 | 备 region 探针失败 / RTT 与连接失败率告警 | 备 region Pod 不就绪即不参与 GTM 接管，流量保留在主站点 | 排查公网段或改走 GA 优化回源 | ≤ 5 min |
| 磁盘打满 | 5 s 采样 > 95% → 503 摘流 | 自动拒绝新请求保护进程 | 清磁盘缓存接口 `/api/performance/disk_cache` | 分钟级 |
| 慢客户端拖垮连接 | `active_connections` + `STREAMING_TIMEOUT` | 120 s（默认）无事件即断；写 deadline `ExtendWriteDeadline` | 调 `USER_SESSION_*` 与限流 | — |
| 迁移失败 | 启动探针不过 + 日志 `failed to initialize database` | `Restart=unless-stopped` 反复失败 → 告警 | 回滚镜像 + 前向修复（无 down） | 10 min |
| 配置误改 | 变更后 5 min 内成功率/时延劣化 | 无法自动识别（缺配置基线） | 依审计日志 key 回滚旧值 | ≤ 2 min |

### 8.5 容量规划与压测验收

- **单实例基线**（须由 3.9 的 S1/S2 实测替换）：非流式 800 QPS、并发 SSE 1,500、内存 2 GiB 工作集、fd 需求 = 并发 × 2（客户端 + 上游）+ 余量，故 `nofile=200000`。
- **区域容量**：峰值按日均 3 倍估算；马尼拉 / 曼谷主站点各预留 **1.5 倍单站点全量能力**，且**新加坡备 region 必须具备单站点全量接管能力**（PH 备 + TH 备的可扩容上限 ≥ 被接管站点峰值 × 1.5）。
- **带宽**：单路流式响应约 20–50 KB/s，1,000 并发 ≈ 40 Mbps，出站流量费用与 ALB LCU 需按此线性预留。
- **连接数预算**：`(主站点 SQL_MAX_OPEN_CONNS × 实例数) + (备 region SQL_MAX_OPEN_CONNS × 实例数) ≤ RDS max_connections × 0.8`。主站点扩到 16 实例时必须配 PgBouncer（或 RDS 代理），否则 4,800+ 连接会打爆 PG。
- **上游出口**：NAT 固定 EIP 池（≥ 4 个 /28）用于供应商白名单；每渠道独立 host 连接上限，避免单渠道占满 `MaxIdleConnsPerHost=400`。

### 8.6 灾备演练（季度必做）

1. 备 region 接管演练：GTM 强制把菲律宾流量切到新加坡 PH 备、泰国流量切到新加坡 TH 备，验证备 region 经**公网**读写马尼拉 / 曼谷主库的容量与延迟（目标：接管期成功率不降，写入 P99 抬升 ≤ 80 ms）。
2. RDS PITR 演练：从备份恢复到新实例，跑额度对账（验证 RPO/RTO）。
3. Redis 摘除演练：确认降级路径不返回 5xx 雪崩（当前会 fail-closed，见 R-05）。
4. 版本回滚演练：从 canary 门禁失败到权重归零，实测止血耗时（目标 < 60 s）。
5. 上游全体故障演练：mock 上游 100% 5xx，验证退款不重复、额度不超扣、错误日志不写爆磁盘。

---
