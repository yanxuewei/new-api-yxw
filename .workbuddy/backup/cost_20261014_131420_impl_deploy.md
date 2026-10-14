# new-api 部署与 SLA 方案（impl_deploy.md）

| 项目 | 内容 |
| --- | --- |
| 文档版本 | v1.1 |
| 编写日期 | 2026-09-22 |
| 适用代码基线 | 分支 `main`，commit `972aed197`（`fix(log): derive response model mismatch from names instead of a stored flag (#7464)`） |
| 目标读者 | 架构 / 后端 / 前端 / SRE / 运维 |
| 部署目标 | 阿里云（菲律宾主站点：马尼拉 `ap-southeast-6`；泰国主站点：曼谷 `ap-southeast-7`；两地共用备 region：新加坡 `ap-southeast-1`），主要服务菲律宾与泰国客户 |
| 可用性目标 | 系统整体 SLA ≥ **99.95%** |

> 说明：本文档聚焦**部署落地**与**SLA 达成**两部分，所有事实均来自当前仓库代码的实际阅读，并在需要处标注 `文件:行号`。凡标注 **[现状]** 的是仓库中已经实现的能力；凡标注 **[需补建]** 的是当前工程缺失、需要在落地部署时补齐的能力。「系统不足与改进措施」的完整清单化梳理见 `impl_tech.md` 第九章，请勿与本文档混读。

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
| 区域延迟 | 菲律宾用户 RTT ≤ 15 ms，泰国用户 RTT ≤ 45 ms | 阿里云地域选择 + 就近站点部署（**不依赖 GA**，理由见 7.1） |


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

  EGR["上游出口 NAT + 固定 EIP 池<br/>同一 EIP 池也是备 region 访问主库的白名单来源<br/>不使用 GA：上游看到的源 IP 即该固定 EIP"]
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
  EGR --> UPSTREAM
  ACK1 -.-> MON
  ACK2 -.-> MON
  ACK3 -.-> MON

  %% 不可见连线：仅用于强制子图自上而下排列，不代表数据流
  RDS1 ~~~ ALB2
  RDS2 ~~~ ALB3
  UPSTREAM ~~~ MON
```

> **上图读法**：主干自上而下为「用户 → 全球接入 → 主站点 / 备 region → 上游出口 → 上游 AI 供应商」，`~~~` 仅为排版用的不可见连线。备 region 到主库的公网读写路径以 `SGWAN` 节点呈现（**有意不再画跨区域连线**，否则会触发 mermaid 把整张图横向铺开）：PH 备 → 马尼拉主库、TH 备 → 曼谷主库，仅故障接管时生效且不双写。若渲染器版本低于 mermaid 10.2（不支持 `~~~`），删除末三条不可见连线即可，其余语法不受影响。

> **上游出口不使用 GA（全球加速）**：出站链路为 `Pod → NAT 网关 + 固定 EIP → 公网 → 供应商`，供应商 IP 白名单即这批固定 EIP。GA 的加速段是"客户端就近接入我的服务"，终端节点是**我方后端**，无法改善"我方 → 上游"的出站跨境链路；若强行把上游地址配为其终端节点，只会把源 IP 变成 GA 侧地址而破坏白名单模型，并同时破坏上游基于域名的 SNI/TLS 校验，还新增一笔按出站流量计费的开销（LLM 流式出站带宽极大，见 8.5 与 7.10）。因此 **7.1 结构图、7.2 云资源清单、7.10 成本结构均不含 GA**；跨境链路质量由多供应商 / 多渠道路由与重试兜底（见 8.4）。若后续出现明确的"其他地区用户就近接入"诉求，应把 GA 放在 `用户 → ALB` 这一段单独评估，而不是挂在出口之后。

#### 7.1.1 接入链路 TLS 终止点与回源协议

**当前设计的 TLS 收敛点是各站点 ALB 的 443 监听**（`AlbConfig.spec.listeners`，见 7.4.3）：`ssl-redirect` 使 ALB 成为全站唯一的 301/HSTS 下发点；网关进程只监听明文 `PORT=3000`，Service 以 `targetPort: 3000` + `backend-protocol: "http"` 挂载，**ALB → Pod 这一段是 VPC 内明文 HTTP**（Terway 下 Pod IP 即 VPC IP，不再套一层 TLS；如需服务网格 mTLS 属于后续增强，本方案不做）。需要提醒的是：**一旦 WAF 采用 CNAME 接入，WAF 自己就会成为一个额外的 TLS 终止点**，"收敛到一处"随即被打破。因此接入链路上真正需要决策的只有两件事：**WAF 用什么方式接入**、**它到 ALB 的回源段是否加密**。

| 方案 | 证书份数 | 回源段协议 | 代价 | 结论 |
| --- | --- | --- | --- | --- |
| ① WAF 3.0 **云原生 / 服务化接入 ALB** | **1 份**（只在 ALB Secret） | 无独立回源跳（同 region 内网，ALB 前置/内嵌） | 依赖目标区域可售性与规则能力等价（**未验证**，见 impl_tech.md 9.7） | **首选** |
| ② WAF CNAME 接入 + **HTTPS 回源** | ≥ 2 份（WAF + ALB） | 必须 HTTPS | 多一跳延迟与一套超时预算；证书需同步 | 可售性不满足时的**回退方案** |
| ③ WAF CNAME 接入 + HTTP 回源 | 1 份 | 明文 | — | **一票否决** |

方案③被否决的理由不是"不够严谨"，而是这条链路上跑的是**长期可用的凭据**：`Authorization: Bearer <API Key>`、session cookie 与个人访问令牌都在请求头里。CNAME 接入的回源段要出 WAF 的公网接入点、再进入我们侧的 ALB，属于会经过不可信网络的跳，明文即等于把可用令牌放到公网上；这违反 OWASP ASVS 的通信安全要求（V9 Communication Security：机密路径上的全部数据必须加密）与 [Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) 对会话令牌"整链路 TLS、不得存在明文段"的要求。同理，DCDN → 源站、以及新加坡备 region → 主库（7.4.4）这些**出 VPC 的段**一律要求 TLS 且校验证书。

**证书单点真源**（避免"同一张证书要维护两份"）：

- **方案①**：cert-manager 走 **DNS-01**（云解析 DNS 的 RAM 子账号只授权 `_acme-challenge` TXT 记录）签发，写入 `api-example-ph-com-tls` Secret，ALB Ingress 用 `secretName` 引用；WAF 侧不存在独立证书，续期由 cert-manager 单链路完成，天然无同步问题。**用 DNS-01 而非 HTTP-01** 的原因：HTTP-01 的校验路径会穿过 WAF 的防护规则与 CC 限流，灰度期容易被自家防护拦掉。
- **方案②**：把 **CAS（数字证书管理服务）作为唯一真源**，由它签发/托管并用"云产品部署"把同一张证书同时下发到 WAF 与 ALB；此时**不要**再并存一套 cert-manager 链路，否则两个真源互相覆盖、回滚时无法判断哪份生效。注意云产品部署是异步任务，续期窗口内可能出现"WAF 已换新、ALB 仍是旧证"，因此 CAS 自动续期提前量取 ≥ 30 天，并把"到期 21 天内两产品证书指纹不一致"列入 7.8 告警。
- **不采用**：私有 CA（PCA）签回源证书、让公网证书不出 WAF。它依赖 WAF 是否支持用自定义 CA 校验回源证书，且 ALB 要信任该私有 CA，链路最重、收益与方案①重叠。

**回源/中间段协议一览**：用户 → WAF/DCDN 为 TLS 1.2+1.3；WAF → ALB 按方案①/②（②必须 HTTPS）；ALB → Pod 为 VPC 内明文 HTTP；DCDN → OSS 显式设为 HTTPS 并在 bucket 上开启"仅允许 HTTPS"；`index.html` 强制 `no-cache`，带指纹 chunk 缓存 7 天。数据库的 `sslmode=require`（主站内网）/ `verify-full`（备 region 公网）属于另一条链路，不与接入层证书混用同一份材料。

**两项必须同步重算的工程约束**：

1. **SSE 保活预算**：接入层每多一跳就引入一个独立的空闲超时，而 ALB `idleTimeout` 已到产品上限 60 s。网关 ping 心跳间隔（15–20 s）必须小于**链路上最小的那个空闲超时**，方案①少一跳、预算最好算。灰度门禁与压测用例必须包含"穿过完整接入链路后 SSE 持续 60 s 不断流"这一条，而不是只测 Pod 直连。
2. **`TRUSTED_PROXIES` 与 XFF 层数**：真实客户端 IP 的解析深度随接入方式变化（方案②为 `用户 → WAF → ALB → Pod` 两级代理，方案①层数不同）。选定方式后必须据此重算 ConfigMap 里的 `TRUSTED_PROXIES`（当前为 `10.0.0.0/8`），否则取到的是代理 IP，会导致 `GLOBAL_API_RATE_LIMIT`、7.2 的 WAF CC 阈值与审计日志的 IP 归属同时失真——这类失真不会报错，只会让限流和风控静默失效。

### 7.2 云资源清单（生产最小高可用配置）

| 层 | 产品 | 规格建议 | 数量 | 关键配置 | 可用性贡献 |
| --- | --- | --- | --- | --- | --- |
| 接入 | 云解析 DNS + GTM | 旗舰版 | 1 | **池间语义 = 主备（failover），不是多池分摊**：菲律宾业务主地址池集合 = 马尼拉 ALB、泰国业务主地址池集合 = 曼谷 ALB，**备地址池集合 = 新加坡 ALB（常驻但权重 0）**，生效地址池切换策略 = **自动切换** → 主池健康时 DNS **只返回主池 IP**，备池常态**零用户流量**；池内负载均衡策略「返回全部地址」仅用于同区域 ALB 跨 AZ 的多个 IP，**不得把跨区域 ALB 放进同一地址池**；**可用 IP 最小数量阈值 = 1**（马尼拉 ALB 多 AZ 仅 2 个 IP，阈值设 2 会因单 AZ 抖动整池判不可用 → 误切跨区）；HTTP 探测 `/api/status` 15 s、超时 5 s、连续 3 次失败判不可用（最坏 ≤ 60 s），探测源 IP 需加 WAF 白名单 | 单主站点故障自动切到备 region |
| 接入 | DCDN | 按量 | 1 | `index.html` 强制 `no-cache`，带指纹的 chunk 缓存 7 天；**回源协议显式 HTTPS**，OSS bucket 开启"仅允许 HTTPS" | — |
| 接入 | WAF 3.0 | 企业版 | 3（马尼拉 / 曼谷 / 新加坡各 1） | **优先云原生 / 服务化接入 ALB**（证书只在 ALB 一份、无回源跳），该方式在目标区域不可用时回退为 CNAME 接入 + **强制 HTTPS 回源**（选型见 7.1.1）；放行支付回调路径；CC 防护阈值对齐 `GLOBAL_API_RATE_LIMIT`；按所选方式重算 `TRUSTED_PROXIES` | 抗 L7 |
| 接入 | 证书 | cert-manager（DNS-01）或 CAS 云产品部署 | 每域名 1 份真源 | 方案①：cert-manager DNS-01 → `api-example-ph-com-tls` Secret，ALB Ingress `secretName` 引用；方案②：CAS 托管 + 云产品部署同时下发 WAF/ALB，自动续期提前量 ≥ 30 天。**两套签发链路不并存** | — |
| 接入 | ALB | 标准版 II | 3（每站点 1 组多 AZ） | `AlbConfig` listeners：`idleTimeout=60`、`requestTimeout=180`（均为产品上限，SSE 靠网关 ping 保活）、HTTPS TLS1.2+1.3（唯一的 TLS 终止与 HSTS 下发点）、`canary-weight` 灰度 | 99.99% |
| 计算 | ACK Pro 托管版 | 控制面 SLA 99.95% | 3 集群（马尼拉、曼谷主集群 + 新加坡备 region 集群） | Kubernetes 1.31+，CNI Terway，多 AZ | 99.95% |
| 计算 | ECS 节点池 | `g9i.2xlarge`(8C32G)（**g8i 全系未在马尼拉上架**，2026-09-25 实测；备选 `g8ine.2xlarge`） | 马尼拉 / 曼谷各常态 4、自动伸缩 4–8（跨 2 AZ）；新加坡备常态 2、自动伸缩 2–12 | 系统盘 100 G ESSD PL1 + 数据盘 300 G ESSD（`/data` 与 `/app/logs`）；节点池必须开启自动伸缩，否则 HPA 扩到上限会因无节点而 Pending | — |
| 数据 | RDS PostgreSQL 高可用版 | pg 15，`rds.pg.c2.4xlarge` 或 16C64G | **2：马尼拉 1（菲律宾唯一主库）+ 曼谷 1（泰国唯一主库）**，可选每站点 1 只读实例 | 主备跨 AZ、PITR 保留 7 天、每日全量 + WAL 归档到 OSS、`max_connections` 按主站点 + 备 region 连接总和核算 | 99.99% |
| 数据 | RDS 公网访问（SSL） | 按量 | 2（马尼拉、曼谷各开 1 个公网地址） | **仅新加坡备 region 使用**：`sslmode=verify-full` + RDS CA 校验 + 白名单只放新加坡 VPC 的 NAT EIP；主站点流量一律走内网地址 | 备 region 接管 |
| 数据 | 连接池收敛层 | RDS 数据库代理（独享型）或 ACK 内自建 PgBouncer 3 副本 | 每站点 1 套（代理随 RDS 售卖；自建池复用 ACK 节点，另加 2 个小规格节点池） | `pool_mode=transaction`，按 7.4.5.1 的 I-2/I-3 核算 `max_client_conn`、`default_pool_size × 副本数`；master 迁移路径直连不走池 | 防连接打爆导致整站不可用 |
| 缓存 | Tair（Redis 兼容）| 主备版 4 GB（生产建议集群版） | 3（马尼拉 / 曼谷 / 新加坡各 1） | 跨 AZ、密码 + 内网 ACL、`maxmemory-policy allkeys-lru` | 99.99% |
| 日志 | 云数据库 ClickHouse | 24.8 社区版 2 节点 | 3（马尼拉 / 曼谷 / 新加坡各 1） | 仅 `LOG_SQL_DSN`、`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` | — |
| 存储 | OSS | 标准 + 低频生命周期 | 3 bucket（马尼拉 / 曼谷 / 新加坡各 1） | 同城冗余 ZRS、版本开启、生命周期 90 天转归档、防盗链 + 签名 URL | 99.995% |
| 观测 | SLS + ARMS + Prometheus（ARMS Prometheus 版）+ Grafana 服务 | 按量 | 1 套 | 见 7.8 | — |
| 观测 | 云监控拨测（站点监控） | 菲律宾 + 泰国 + 新加坡探测点 | 3+ | 探测 `GET /api/status` 与 `GET /healthz`，1 min 间隔 | 真实用户视角 |
| 安全 | KMS 凭据管家 | 软件密钥 | 1 | 托管 `SQL_DSN`、`REDIS_CONN_STRING`、`SESSION_SECRET`、支付密钥 | — |
| 网络 | VPC + vSwitch + NAT + EIP | /16 与 3 个 /20 | 3 套（马尼拉 / 曼谷 / 新加坡） | 私有子网跑 Pod 与 DB，仅 ALB 在公网子网；NAT 出口固定 EIP 池用于上游白名单，同一 EIP 池同时作为新加坡备 region 访问主库的白名单来源 | — |

> **相对旧方案的两项结构性变化**：① **取消 DTS 链路**——菲律宾与泰国各自只有一个主库，跨区不存在任何数据库复制关系，故本表不再保留 `DTS` 条目；② **新增新加坡备 region 的接入与计算资源**，但**新加坡不部署任何 RDS 实例**，备 region 通过 RDS 公网地址读写主站点主库（部署细节见 7.4.4）。

> **上游出口不使用 GA（全球加速）**：上游调用链路为 `Pod → NAT 网关 + 固定 EIP → 公网 → 供应商`，供应商侧 IP 白名单即这批固定 EIP（见本表"网络"行）。GA 的加速段是"客户端就近接入我方服务"、终端节点是**我方后端**，无法改善"我方 → 上游"的出站跨境链路；若把上游地址配为其终端节点，只会把上游看到的源 IP 变成 GA 侧地址而破坏白名单模型，同时破坏上游基于域名的 SNI/TLS 校验，并新增一笔按出站流量计费的开销（LLM 流式出站带宽极大，见 8.5）。因此**本表不含 GA 条目**，跨境链路质量由多供应商 / 多渠道路由与重试兜底（见 8.4）。若后续出现明确的"其他地区用户就近接入"诉求，应按 `用户 → GA(Anycast) → ALB` 的位置单独评估，而不是挂在出口之后。

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
  SQL_MAX_OPEN_CONNS: "300"         # 需 < RDS 最大连接数 / 实例数；启用 7.4.5 的连接池后语义变为"到池的客户端连接上限"，RDS 侧真实连接由 7.4.5.1 的 I-3 约束
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
  # 启用 7.4.5 的连接池后，主站点此项改为指向集群内 pgbouncer Service（或 RDS 代理地址），见 7.4.5.3
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
  minReplicas: 4                    # 跨 2 AZ 的高可用下限：单 AZ 故障仍剩 2 副本
  maxReplicas: 16                   # = 日均容量基准 4 副本 × 3 倍峰值（12）上取整 + 灰度/突发余量；推导与反算规则见 8.5
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

> **HPA 上限（16）与备 region 接管容量（24）的口径关系**：`maxReplicas: 16` 是**主站点自身**的容量上限，推导为"日均容量基准 4 副本 × 3 倍峰值 = 12，上取整并留灰度与突发余量 → 16"（完整推导链见 8.5）。区域故障时的接管方是**新加坡备 region**，其接管上限取 `被接管站点 maxReplicas × 1.5 = 16 × 1.5 = 24` 副本（部署细节见 7.4.4）。**这三处数量必须联动**：`maxReplicas`、备 region 接管上限、节点池自动伸缩区间；任何一处变化都要重算另外两处，并复核 7.4.5.1 的 I-2 / I-3。
>
> **扩容的两个前置条件（缺一不可）**：① 节点池必须开启自动伸缩，否则 HPA 扩到上限时新 Pod 会因无节点而 Pending（见 7.2 ECS 行）；② 必须启用 7.4.5 的连接池，否则 `300 × 16 = 4,800` 条直连会顶穿 RDS `max_connections`。

> **master 节点单独处理**：**每个主站点（马尼拉、曼谷）各需一个 `NODE_TYPE=master` 的 Deployment**（`replicas: 1`、`strategy: Recreate`、独立 PVC `ReadWriteOnce`），各自只对自己站点的 RDS 主库执行 AutoMigrate 与 master-only 迁移；它**不接 ALB 流量**（不在 Service 选择器内），只跑后台任务与迁移。**新加坡备 region 的 PH 备 / TH 备工作负载必须固定 `NODE_TYPE=slave`**：备 region 与主站点访问的是同一个主库，若备 region 也起 master 会与主站点 master 并发迁移同一 schema。滚动发布顺序：先升级 master → schema 就绪 → 再滚动 stable slave → 最后升级 canary → 最后预热新加坡备 region。这是解决 1.2 中"非 master 从不迁移"风险（R-04）的部署侧手段；master 故障后的接管时序、租约去重与 RTO 预算见附录B。

#### 7.4.3 AlbConfig、Service 与 ALB Ingress（含灰度）

> **官方核实后的关键事实**：ALB listener `idleTimeout` 取值 1–60 s（默认 15）、`requestTimeout` 取值 1–180 s（默认 60，超时由 ALB 直接返回 504），二者**只能在 `AlbConfig` CRD 的 `spec.listeners` 配置，不存在对应 Ingress 注解**；早期草案里 `idle-timeout: "900"` / `request-timeout: "0"` 均为无效写法。SSE 长流不被切断的前提是网关持续产生心跳事件（ping 默认关闭，须开启并设 15–20 s），完整论证见附录A.6。**TLS 在 ALB 443 终止、`ssl-redirect` 为唯一重定向点**；WAF 的接入方式与回源协议选型见 7.1.1。

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

| 工作负载 | 归属 | `SQL_DSN` 目标 | 触发接管 | 常态副本 | **接管上限** |
| --- | --- | --- | --- | --- | --- |
| `new-api-ph-standby` | 菲律宾 | 马尼拉 RDS **公网地址** | GTM 探测到马尼拉不可用 | 2（热备）/ 0（冷备） | **24 副本** |
| `new-api-th-standby` | 泰国 | 曼谷 RDS **公网地址** | GTM 探测到曼谷不可用 | 2（热备）/ 0（冷备） | **24 副本** |

> **接管上限 24 副本的算法与配套约束**：`被接管站点 maxReplicas(16) × 1.5 = 24`（8.5 的"1.5 倍"以**部署上限**为基准，而非未知的真实峰值——真实峰值须由压测替换，见 8.5）。配套三件事必须同时成立：
> 1. **节点**：`24 × requests 2 vCPU = 48 vCPU`，按 `g8i.2xlarge` 可分配约 7.9 vCPU/节点并留 ≥ 20% 给 kube-system（等效业务可用 `7.9 × 0.8 = 6.32 vCPU/节点`，`48 ÷ 6.32 ≈ 7.6` 上取整），**新加坡节点池需自动伸缩到 ≥ 8 节点**（即 64 vCPU；7.2 本期区间 `2–8` 覆盖该需求）；
> 2. **连接**：`24 × SQL_MAX_OPEN_CONNS(300) = 7,200` 条客户端连接，**必须经 7.4.5 的连接池**（`max_client_conn × N_pb = 3,000 × 3 = 9,000 ≥ 7,200`，I-2 成立）；
> 3. **冷备形态**：常态 0 副本时必须预置"扩到 24 副本 + 节点池扩容"的一键脚本，并把该扩容路径纳入 8.6 的接管演练——否则冷备的 RTO 无法验收。

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
  replicas: 2                          # 常态热备；成本优先可置 0（冷备，RTO 由秒级变为分钟级）。接管上限 24 副本见上表与 8.5
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
- **接管容量不得合并计算（R-33）**：PH 备与 TH 备的 24 副本上限是**各自独立**的容量预算，不能理解为"两者合计 24 副本"。若两地**同时**需要接管（该场景**仅在二期引入 TH 备后才成立**，本期不适用），新加坡集群要按 48 副本核算（`48 × 2 vCPU = 96 vCPU`，含 ≥ 20% 系统组件余量需 **≥ 16 节点 / 128 vCPU**，超出 7.2 本期给出的 `2–8` 区间），该场景**不在本方案的 99.95% 承诺内**；已登记为 8.1 排除项 ⑥ / 8.4 故障域 / 9.5 的 R-33，触发时按 8.4 手工降级非核心功能。
- **共享故障域（R-32，已知残余风险）**：新加坡同时承载 PH 备与 TH 备，一旦新加坡自身故障，两地的接管能力**同时失效**。这是"单备 region 承载两地"架构的固有代价；本方案**不提供**"新加坡故障时回切到另一个主站点"的二次接管。该风险已登记为 8.1 排除项 ⑤ / 8.4 故障域 / 9.5 的 R-32，并由 GTM 探测点的独立部署（**不得只放在新加坡**）来保证"新加坡故障可被检出"。

### 7.4.5 数据库连接池收敛（RDS 代理 / PgBouncer）

网关侧的 `SQL_MAX_OPEN_CONNS` 只能约束**单个进程自己**的连接数（`model/main.go:211-213` 经 `sql.DB.SetMaxOpenConns`，日志库同参数在 `model/main.go:258-260`），无法约束"副本数 × 每副本连接数"的总量。主站点按 7.4.2 扩到 16 副本时，`300 × 16 = 4,800` 条到 RDS PostgreSQL 的连接会直接顶穿实例的 `max_connections`——PG 是"一连接 = 一后端进程"，每进程常驻数 MB 内存，超限后新连接报 `FATAL: too many connections`，且已有连接的性能也会劣化。本节给出收敛层的位置、模式选择、容量换算与 ACK 落地清单。

#### 7.4.5.1 三条必须成立的不变量

设 `N_pod` = 网关副本数，`C_pod` = 单副本 `SQL_MAX_OPEN_CONNS`，`N_pb` = 连接池副本数，`P_pb` = 每池对单库单用户的后端连接上限。

| # | 不变量 | 本方案取值 |
| --- | --- | --- |
| I-1 | 应用侧逻辑连接：`C_pod ≥ 峰值单副本并发事务` | `300`（保持不变，语义降级为"到池的客户端连接上限"） |
| I-2 | 池的客户端总容量：`max_client_conn × N_pb ≥ C_pod × N_pod` | `3000 × 3 ≥ 300 × 24 = 7200`（`N_pod` 取主站点 `maxReplicas` 16 与**备 region 接管上限 24** 的较大值，见 7.4.4） |
| I-3 | **PG 真实连接：`P_pb × N_pb + 直连与运维连接 ≤ RDS max_connections × 0.8`** | `60 × 3 + 预留 40 ≈ 220 ≤ 800 × 0.8` |

> **最易漏算的是 I-3**：PgBouncer 副本之间**不共享**后端连接，每个副本各自持有一整份 `default_pool_size`。所以后端总连接是 `P_pb × N_pb`，不是 `P_pb`。`default_pool_size` 是"每 (db, user) 组合"的上限，多库（主库 + `LOG_SQL_DSN` 若同实例）与多账号要分别乘。副本扩容前先复算 I-3。
>
> **`N_pod` 不进 I-3，这正是必须上池的原因**：网关从常态 16 副本扩到接管时的 24 副本，只改变 I-2 左侧的需求（`300 × 24 = 7,200`），**完全不改变 PG 的真实连接数**（仍由 `P_pb × N_pb = 60 × 3` 决定）。池副本数固定 3 且**禁止挂 HPA**（见 7.4.5.3）；因此"扩容副本"与"扩容主库连接"被彻底解耦。反过来说，若某处为了提速给池加了 HPA，I-3 会立刻失效。

后端连接需求的算法用 Little's law：`P_pb ≈ 峰值 DB 事务数/秒 × 平均事务时长(s) × 1.5`。本项目的计费写已合并（`BATCH_UPDATE_ENABLED`，见 7.4.1），明细日志走 ClickHouse，主库侧属于"短事务、低并发"，实测通常在 `20–60` 条后端连接即饱和；**若 I-3 算出的 `P_pb` 超过 100，先查慢 SQL 与长事务，不要靠加连接解决**。

#### 7.4.5.2 三种收敛方式选型

| 方式 | 位置 | 优点 | 代价 / 风险 | 结论 |
| --- | --- | --- | --- | --- |
| **A. RDS PostgreSQL 数据库代理（独享型，内建连接池）** | RDS 侧，应用改连代理地址 | 免运维、与主备切换/只读分离天然集成、SLA 由云产品承担 | 按量/独享规格额外成本；池模式与参数可配项少于自建；跨 region 场景仍需另想 | **默认首选**（单站点内收敛） |
| **B. 自建 PgBouncer（ACK 内独立 Deployment）** | 网关 Pod 与 RDS 之间 | 参数完全可控、可同时收敛"跨 region 公网"连接、白名单可进一步收紧、可观测自定义 | 多一个要监控/发布/演练的组件；需自行处理 prepared statement 兼容与连接排水 | **需要跨 region 收敛或精细控制时采用**（见 7.4.5.3 清单） |
| C. PgBouncer sidecar（每网关 Pod 一个） | Pod 内容器 | 无跨 Pod 网络跳数、随应用发布 | **不做全局收敛**：`P_pb × N_pod` 仍随副本数线性增长，I-3 不成立 | 仅用于本地 keepalive，**不作为本方案的收敛层** |

主站点用 A（或 B）二选一即可；新加坡备 region（7.4.4）经公网读写主站点主库，**推荐额外加一层 B**：常态 `2 Pod × 150 = 300` 条、接管期扩到 24 副本后 `24 × 300 = 7,200` 条客户端连接，都被收敛为 `8–16` 条跨区后端连接（`max_client_conn × N_pb = 3,000 × 3 = 9,000 ≥ 7,200`，I-2 成立），既守住马尼拉/曼谷 RDS 的公网白名单与连接额度，也避免接管瞬间的跨区 TCP 重连风暴。**备 region 的池必须与"扩到 24 副本"的接管预案一起演练**；池副本数固定 3（I-3），不要给池挂 HPA。

#### 7.4.5.3 自建 PgBouncer 的 ACK 部署清单

模式统一取 `pool_mode = transaction`（事务结束立即归还后端，收敛比最高）。**HPA 严禁作用于连接池**：池副本数变化会改变后端总连接（I-3），且新池需重新建连，扩缩抖动直接打到主库。固定 3 副本 + 跨 AZ 打散。

```yaml
# deploy/aliyun/30-pgbouncer.yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: pgbouncer-ini, namespace: new-api }
data:
  pgbouncer.ini: |
    [databases]
    # 主站点：RDS 内网地址；备 region 改成马尼拉/曼谷的公网地址并启用 server_tls_*
    newapi = host=pg-mnl-rw.pg.rds.aliyuncs.com port=5432 dbname=newapi
    [pgbouncer]
    listen_addr = 0.0.0.0
    listen_port = 6432
    unix_socket_dir = /var/run/pgbouncer      # 容器内无本地套接字需求，置空亦可
    pool_mode = transaction                   # 唯一被本方案认可的收敛模式，理由见 7.4.5.4
    max_client_conn = 3000                    # 每副本，满足 I-2
    default_pool_size = 60                    # 每 (db,user)，参与 I-3：60 × 3 副本
    min_pool_size = 8                         # 抵消 RDS 主备切换后的建连冷启动
    reserve_pool_size = 5
    reserve_pool_timeout = 3
    server_idle_timeout = 60                  # 与网关 SQL_MAX_LIFETIME=60 同量级
    server_lifetime = 1800                    # 必须 > SQL_MAX_LIFETIME，避免两侧同时回收抖动
    server_connect_timeout = 5
    login_timeout = 5
    query_timeout = 0                         # 交给网关侧 RELAY_RESPONSE_HEADER_TIMEOUT，不在此掐
    query_wait_timeout = 30                   # 客户端排队上限，防止雪崩时无限堆积
    server_reset_query_always = 0             # transaction 模式下不可用 DISCARD ALL 类会话清理，见 7.4.5.4
    max_prepared_statements = 200             # >=1.21 才支持；transaction 模式下转发命名预处理语句
    ignore_startup_parameters = extra_float_digits,options,client_encoding
    # ---- 认证：口令哈希算法必须与 RDS 账号的 password_encryption 一致 ----
    auth_type = md5                           # 若 RDS 为 scram-sha-256，改用 auth_query 或 auth_type=scram
    auth_file = /etc/pgbouncer/userlist.txt
    admin_users = pgbouncer_admin
    stats_users = pgbouncer_stats
    # ---- TLS：主站点内网可按零信任要求开启；备 region 到主库必须 verify-full ----
    client_tls_sslmode = disable              # [需补建] 生产开启需挂证书
    server_tls_sslmode = disable              # 备 region 改 verify-full + server_tls_ca_file
    stats_period = 30                         # SHOW STATS 聚合周期，配合 7.4.5.5 抓取
---
apiVersion: v1
kind: Secret
metadata: { name: pgbouncer-users, namespace: new-api }
type: Opaque
stringData:
  # userlist 第 2 字段是 md5<sha256 前的 PG 形式> 或明文，禁止与 new-api 共用高权限账号
  userlist.txt: |
    "newapi" "md5REPLACE_ME"
    "pgbouncer_admin" "md5REPLACE_ME"
    "pgbouncer_stats" "md5REPLACE_ME"
  # 口令由 KMS 凭据管家注入（同 7.4.1 的 ExternalSecret / RRSA 机制），禁止入 Git
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: new-api
  labels: { app: pgbouncer }
spec:
  replicas: 3                                 # 固定副本，不参与 HPA（见上文理由）
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  selector:
    matchLabels: { app: pgbouncer }
  template:
    metadata:
      labels: { app: pgbouncer }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9127"            # pgbouncer-exporter sidecar
    spec:
      terminationGracePeriodSeconds: 60
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway     # 池副本缺一只降收敛容量，不该阻塞调度
          labelSelector: { matchLabels: { app: pgbouncer } }
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector: { matchLabels: { app: pgbouncer } }
      containers:
        - name: pgbouncer
          image: registry-vpc.<REGION_ID>.aliyuncs.com/newapi/pgbouncer:1.24.0   # 自建镜像推 ACR 企业版，见 7.4.5.6
          securityContext: { runAsNonRoot: true, runAsUser: 101, readOnlyRootFilesystem: true }
          ports: [ { containerPort: 6432, name: pgbouncer } ]
          resources:
            requests: { cpu: "500m", memory: 256Mi }   # 单副本承载 ~1500 客户端连接
            limits:   { cpu: "2",     memory: 512Mi }  # 内存按 max_client_conn × 数 KB 核算，勿低于 limits 触发 OOMKill
          volumeMounts:
            - { name: ini, mountPath: /etc/pgbouncer/pgbouncer.ini, subPath: pgbouncer.ini, readOnly: true }
            - { name: users, mountPath: /etc/pgbouncer/userlist.txt, subPath: userlist.txt, readOnly: true }
            - { name: run, mountPath: /var/run/pgbouncer }
          readinessProbe:
            exec: { command: ["pg_isready", "-h", "127.0.0.1", "-p", "6432", "-U", "pgbouncer_stats"] }
            periodSeconds: 5
            failureThreshold: 2
          livenessProbe:
            tcpSocket: { port: 6432 }
            initialDelaySeconds: 10
            periodSeconds: 10
        - name: exporter                     # [需补建] 仓库当前无 pgbouncer 指标，接入 ARMS Prometheus 用
          image: registry-vpc.<REGION_ID>.aliyuncs.com/newapi/pgbouncer-exporter:latest
          args: ["--pgBouncer.connectionString", "postgres://pgbouncer_stats:REPLACE_ME@127.0.0.1:6432/pgbouncer?sslmode=disable"]
          ports: [ { containerPort: 9127, name: metrics } ]
      volumes:
        - { name: ini, configMap: { name: pgbouncer-ini } }
        - { name: users, secret: { secretName: pgbouncer-users } }
        - { name: run, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: pgbouncer, namespace: new-api }
spec:
  type: ClusterIP                             # 不要用 headless：pgx 只在启动时解析一次 DNS，副本负载会失衡
  selector: { app: pgbouncer }
  ports: [ { name: pgbouncer, port: 6432, targetPort: 6432 } ]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: pgbouncer, namespace: new-api }
spec:
  minAvailable: 2                             # 单副本驱逐时仍有 2 份池，收敛容量不塌
  selector: { matchLabels: { app: pgbouncer } }
```

网关侧只改一行 Secret，其余不变：

```yaml
# deploy/aliyun/00-namespace-config.yaml（SQL_DSN 片段）
stringData:
  # 池化后：DSN 指向集群内 pgbouncer Service，不再直连 RDS
  SQL_DSN: "postgresql://newapi:REPLACE_ME@pgbouncer.new-api.svc.cluster.local:6432/newapi?sslmode=disable&default_query_exec_mode=cache_statement"
  #                                    ^^^ 该参数是否被 gorm.io/driver/postgres v1.5.9 透传，须按 7.4.5.4 实测后再定值
```

RDS 白名单随之收紧：主站点**只放行 PgBouncer Pod 所在 vSwitch/节点网段**（Terway ENI 模式下是 Pod IP 段，见 7.4.5.6），`new-api` Pod 不再直连 RDS；运维通道用独立的堡垒机 + 单独白名单条目，不与业务共用。

> **master 例外**：跑 `AutoMigrate` 的 master Deployment（7.4.2 中 `NODE_TYPE=master`）必须用独立 Secret 覆盖 `SQL_DSN` 为 RDS 直连地址，不走事务池——理由见 7.4.5.4 末行。若白名单已按上句收紧，需同时放行该 master Pod 所在网段。

#### 7.4.5.4 transaction 模式与本仓库代码的兼容性红线

`pool_mode = transaction` 的硬约束是"事务之外不存在可信的会话状态"。逐条对照当前代码：

| 用法 | 本仓库现状 | transaction 模式结论 |
| --- | --- | --- |
| 命名 prepared statement | 驱动链 `gorm.io/driver/postgres v1.5.9` → `jackc/pgx/v5 v5.9.2`（`go.mod:62,133`），pgx 默认 `QueryExecModeCacheStatement` 会缓存**命名**预处理语句 | **最高风险项**。后端在事务间被换走时，症状是 `prepared statement "pgx_N" does not exist` / `cached plan must not change result type`，且只在 DDL 或后端重连后偶发。缓解三选一：① PgBouncer ≥ 1.21 且 `max_prepared_statements > 0`（清单已给 `200`）；② DSN 降为 `default_query_exec_mode=exec` / `simple_protocol`；③ 该库改 `pool_mode=session`。**必须按下面步骤实测后定值** |
| `SELECT ... FOR UPDATE` | `model/locking.go:20-25` 的 `lockForUpdate(tx)` 只在事务内 | 兼容 |
| `pg_advisory_xact_lock` | `model/user.go:399`、`model/option_primary_key_migration.go:106` | 兼容（锁随事务释放）。**若将来改用会话级 `pg_advisory_lock`，事务池会串号，属禁止** |
| `SET LOCAL search_path` | 仅出现在迁移测试 `model/token_migration_test.go:237`、`model/prefill_group_migration_test.go:232` | 测试路径，不入生产；但**同一限制适用于任何会话级 `SET`/临时表/`LISTEN`/`NOTIFY`，生产代码不得新增** |
| 启动期 `AutoMigrate` / 迁移 | 仅 master 节点执行（`NODE_TYPE=master`，独立 Deployment，见 7.4.2 的 master 说明） | **迁移必须绕开事务池**：master 的 `SQL_DSN` 直连 RDS（`pool_mode=session` 亦可），避免迁移中的 `SET`/DDL 与池互相干扰；这也是 7.7 发布流程"先升级 master"的前置条件 |
| 空闲事务长期持有后端 | 后台任务、SSE 落库等长逻辑若误把事务包住远程调用 | 会造成后端饥饿（`cl_waiting` 堆积）。禁止在事务内调用上游 HTTP，属 code review 检查项 |

预处理语句实测步骤（上线前必做，SQLite/MySQL/ClickHouse 路径不受影响，只测 PostgreSQL）：

1. 起 1 个 PgBouncer 副本 + 1 个临时网关 Pod，`SQL_MAX_OPEN_CONNS=50`。
2. 在 PG 侧执行 `SELECT name FROM pg_prepared_statements;`（能看到 `pgx_N` 即命名预处理语句真的在跑），在 PgBouncer 控制台（`psql -h 127.0.0.1 -p 6432 -U pgbouncer_admin -d pgbouncer`）执行 `SHOW CONFIG;` 与 `SHOW DATABASES;`，确认 `max_prepared_statements` 的实际生效值与版本支持情况。
3. 压测中触发一次 RDS 主备切换或 `SELECT pg_terminate_backend(pid)` 杀后端，观察是否出现上述报错。
4. 任一报错 → 按①/②/③ 顺序降级，并重跑发布验证矩阵（7.9）。

> 未在真实 PostgreSQL 上完成本小节验证前，不得声称"连接池方案已落地"（对齐 `AGENTS.md` 的三库验证与 `superpowers:verification-before-completion` 口径）。

#### 7.4.5.5 观测与告警

| 指标 | 来源 | 告警阈值 |
| --- | --- | --- |
| 池排队 | exporter `pgbouncer_pools_client_waiting_connections` | `> 0` 持续 2 min → warning；`> 50` → critical（I-3 或 `query_wait_timeout` 前兆） |
| 后端利用率 | `pgbouncer_pools_server_active_connections / default_pool_size` | 峰值 `> 0.8` → 先查慢 SQL，再考虑提 `P_pb` |
| 客户端余量 | `SHOW CLIENTS;` / `cl_used` vs `max_client_conn` | `> 0.8 × max_client_conn` → critical |
| 认证/协议失败 | PgBouncer 日志 `login failed`、`prepared statement`、`unsupported` | 非零即告警（多为 7.4.5.4 的兼容性问题） |
| 主库真实连接 | RDS 控制台 `active_connections` / `pg_stat_activity` | `> max_connections × 0.8` → critical（对齐 8.5） |
| 池到 PG 往返 | `SHOW STATS;` 的 `sv_lifetime`、`tx_count` | 突变用于定位主备切换影响面 |

热更新配置用 `RELOAD;`（admin console），副本级变更走滚动发布。**排水**：PgBouncer 无优雅 draining，滚动更新会断该副本上的客户端连接——网关侧靠 `database/sql` 自动重连与 `RetryTimes` 兜底，事务中的请求会失败，因此发布窗口必须与 7.7 的灰度门禁对齐（先 `PAUSE newapi` → 等在途事务归零 → `RECONNECT newapi` → 摘流）。

#### 7.4.5.6 ACK 侧落地注意

1. **镜像**：`pgbouncer` 与 exporter 均需自建镜像入 ACR 企业版（VPC 域名 `registry-vpc.<REGION_ID>.aliyuncs.com`），基座 `postgres:15-alpine` + `apk add pgbouncer`，保留上游签名版本；跨 region 拉取用 ACR 同步规则，三个集群同 `:1.24.0` tag。集群侧用 ACK 免密拉取组件，不要在 Deployment 里写 `imagePullSecrets` 明文。
2. **网络**：CNI Terway 下 Pod IP 即 VPC IP，RDS 白名单加**PgBouncer Pod 所在 vSwitch 网段**；若节点池扩缩导致网段变化，白名单按 vSwitch 粒度维护，不要逐 IP。
3. **调度**：池与网关分开节点池（独立 label + taint），避免网关 OOM 或 CPU 压满时连带打挂收敛层；`readOnlyRootFilesystem: true` 需要 `/var/run/pgbouncer` 的 `emptyDir`。
4. **配置**：`pgbouncer.ini` 与 `userlist.txt` 用 ConfigMap/Secret 卷 `subPath` 挂载，保证文件级不可变；变更即滚动，不 in-place 改。
5. **可观测**：容器日志走 SLS（同 7.8），exporter 端口 9127 由 ARMS Prometheus 抓取；`SHOW STATS` 的 `query_wait_timeout` 触发次数需在 Grafana 面板与 8.5 压测报告单列。
6. **备 region 差异**：`server_tls_sslmode=verify-full` + `server_tls_ca_file`（RDS CA 证书经 Secret 挂载），`default_pool_size` 降到 `16`，`client_tls_sslmode` 按需开启，且客户端仍走 `SQL_MAX_OPEN_CONNS ≤ 150` 的公网侧约束（7.4.4）。

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
| 证书 | CAS 证书告警 + 云监控 | 剩余有效期 < 21 天告警；采用 7.1.1 方案②（CNAME 接入）时，额外断言 WAF 与 ALB 两侧证书指纹一致，不一致即告警——异步部署会造成"一侧已换新、一侧仍是旧证" | — |
| RUM | 前端监控 ARMS RUM | 复用现有 Umami / GA 注入点（`main.go:248-289`）叠加 RUM | — |
| 告警 | ARMS 告警 + 云监控 | 钉钉/企业微信 + 短信 + 电话；P1 走电话，按 6.3.4 表落地；排班用告警值班表 | — |
| 审计合规 | 操作审计 ActionTrail + DB 审计 | 云 API 变更全部留痕；RDS SQL 洞察开启 | 180 天 |

### 7.9 环境矩阵与发布验证

| 环境 | 区域 | 数据库 | 用途 | 门禁 |
| --- | --- | --- | --- | --- |
| dev | 本地 | SQLite + `docker-compose.dev.yml` | 功能开发 | `bun run lint`、`make test` |
| staging（pre） | 马尼拉（主站点命名空间 `new-api-staging`） | **复用主站 RDS 的逻辑隔离 schema** + Tair 独立 DB index + ClickHouse 独立 database | 集成与三数据库矩阵 | 每次合并主干；`SQL_DSN` 分别用 MySQL 8.2 / PG 15 / SQLite 跑同一套 E2E。**不新建 RDS 实例**，故不构成对 7.1「新加坡不部署 RDS PostgreSQL」红线的例外 |
| perf | 马尼拉（主站点命名空间 `new-api-perf`） | 同 staging + mock 上游 | 3.9 压测场景矩阵 | 相对基线劣化 > 10% 阻断 |
| prod mnl | 马尼拉 | RDS PG HA（菲律宾唯一主库）+ Tair + CH | 菲律宾流量（主站点） | 灰度门禁 |
| prod bkk | 曼谷 | RDS PG HA（泰国唯一主库）+ Tair + CH | 泰国流量（主站点） | 与 mnl 错峰发布（先 bkk 后 mnl 或反之） |
| standby sg | 新加坡 | **无本地 RDS**：PH 备 / TH 备经公网读写主站点 PG + 本地 Tair + CH | 两地共用的备 region | 区域接管演练；备工作负载先于主站点发布 |

**三数据库强制验证（AGENTS.md 要求，不可省略）**：任何影响 DB 行为的改动（模型/GORM 标签/迁移/DSN/驱动/Scanner-Valuer/原生 SQL/事务/行锁）必须在**真实** SQLite、MySQL ≥ 5.7.8（建议 8.2）、PostgreSQL ≥ 9.6（建议 15）上验证，日志库涉及 ClickHouse 时一并覆盖；迁移需在新建库 + 由上一发布版本产生的存量库上各跑，并至少启动两次证明幂等，且记录数据库版本、命令与结果。

### 7.10 成本结构（线上实测口径：官方单价 × 实际部署与用量，2026-10-14）

**口径**：全部 USD。本版**以线上实际部署的资源与真实账单为准重算**，与 2026-09-27 的「规划口径」（按《菲律宾部署方案》资源清单的计划规格估算）不同，差异逐项见 7.10.7。

**排列**：7.10.1 / 7.10.2 / 7.10.3 三表均按 **USD/月 从高到低**排序（免费项自然落末），便于一眼看出成本大头。
**「上量后」口径**：出口流量按 **100 MB/天**估算（2026-10-14 项目负责人给定），已作为独立行计入 7.10.1；单价取阿里云国际站官网公开价，标度表见 7.10.8。

**数据源**：

| 标记 | 含义 |
| --- | --- |
| `CLI` | `aliyun ecs\|rds DescribePrice` **2026-10-14 实测**（ECS / 磁盘 / RDS） |
| `账单` | `aliyun bssopenapi DescribeInstanceBill`（**2026-10 账期**，10-01~10-14 实际计费）反推的官方日率；订阅项取**实付金额** |
| `官网` | 阿里云国际站官方定价页公开价 |

**折月口径**：ECS / 磁盘等按量项按 **730 h/月**；账单反推的日率项按 **30.4167 天/月**（= 730 ÷ 24）。
⚠ **无「未公示项」** —— 本版所有单价均已实测或由账单反推，RDS / ACR 不再是估参。

**实测总账**（本版结论）：**生产两站 ≈ 4,301.55 USD/月**（马尼拉 3,205.85 + 新加坡 1,095.71）；含雅加达 dev ≈ **4,628.85 USD/月**。

#### 7.10.1 马尼拉主站点（ap-southeast-6）—— 实测

| # | 资源 | 实际规格（线上实测） | 计费方式 | 单价与算式 | USD/月 | 来源 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | ECS 节点池 ×4 | ecs.g9ae.2xlarge（8C32G）+ 100G ESSD PL1 系统盘 | 按量 | $0.44252/h → $323.04/台·月 × 4 | 1,292.16 | `CLI` |
| 2 | ClickHouse 企业版 ×1 | cc-5tsv2o51s1360b0pr（单 AZ / 2 server 节点 / OSS 存储 / Serverless 4–32CU） | 按量 | $35.587/天 → $1,082.44/月 | 1,082.44 | `账单` |
| 3 | ECS 数据盘 ×4 | 300G ESSD PL1（独立云盘） | 按量 | $0.07596/h → $55.45/台·月 × 4 | 221.80 | `CLI` |
| 4 | RDS PostgreSQL 高可用 ×1 | pg.n4.2c.2m（2C8G，1 主 1 备）+ 100G ESSD PL1 | 包月 | $168.26/月（CLI 实测 = 2026-09 实付） | 168.26 | `CLI` |
| 5 | ACR 企业版 ×1 | cri-avfqy9xkqi5bj8ee（基础版实例，两地共用） | 订阅 | $157.00/月（2026-09 实付） | 157.00 | `账单` |
| 6 | ACK Pro 托管版 ×1 | ack-newapi-mnl（cd57e40c…）控制面 99.95% | 按量 | $0.09/集群·h → $65.70/月 | 65.70 | `账单` |
| 7 | Tair（兼容 Redis）×1 | 企业版 主备 / redis.amber…1g.2db.0rodb.6proxy | 包月 | $64.63/月（2026-09 实付） | 64.63 | `账单` |
| 8 | 运维跳板节点 ×1 | ecs.c9i.large（2C4G）+ 40G ESSD PL1 | 包月 | $48.25/台·月 × 1 | 48.25 | `CLI` |
| 9 | NAT 网关 ×1 | ngw-5tss1ii3…（增强型 / 跨 AZ） | 按量 | $0.880/天（实例费+CU） → $26.77/月 | 26.77 | `账单` |
| 10 | EIP 保有费 ×6 | 4 个上游白名单 EIP + 2 个 ALB 自带 EIP（PayByTraffic） | 按量 | $0.120/天·IP → $3.65/IP·月 × 6 | 21.90 | `账单` |
| 11 | ALB ×1 | alb-1riqckb1h8ezm0y7s9（标准版 / Internet / Fixed / 2 AZ） | 按量 | $0.437/天（实例费+LCU） → $13.29/月 | 13.29 | `账单` |
| 12 | ACK 内网 CLB ×1 | ManagedK8SSlbIntranet-cd57e40c…（ACK 自动创建） | 按量 | $0.429/天 → $13.05/月 | 13.05 | `账单` |
| 13 | SLS 日志服务 | 7 个项目（sls-newapi-mnl + k8s-log-cd57… + ARMS/CMS 托管） | 按量 | 实测 $5.00 / 13.33 天 → $11.41/月 | 11.41 | `账单` |
| 14 | KMS 3.0 凭据管家 | kst-php6abb88e21s0imvefj | 按量 | $0.346/天 → $10.52/月 | 10.52 | `账单` |
| 15 | GTM 3.0 | gtm-post-2109945017262880768（postpay_standard，www.likha.hk） | 按量 | $0.221/天 → $6.72/月 | 6.72 | `账单` |
| 16 | 云监控 + 拨测 | 1 个站点拨测任务（www.likha.hk/api/status，5 min，PC 组） | 按量 | 实测 $0.678 / 13.33 天 → $1.55/月 | 1.55 | `账单` |
| 17 | 出口流量（上量后估算 100 MB/天） | EIP 出方向 $0.081/GB + NAT CU $0.043/CU（1 CU = 1 GB） | 按量 | 2.97 GB/月 × $0.124/GB → 估算 | 0.37 | `官网` |
| 18 | OSS ×3 | oss-newapi-mnl + img-likha + cri-…-registry（标准 LRS） | 按量 | 实测 $0.013 / 13.33 天 → $0.03/月 | 0.03 | `账单` |
| 19 | VPC / vSwitch / 安全组 / ActionTrail | —— | 免费 | 免费 | 0.00 | `官网` |
| | **小计** | | | | **3,205.85** | |

**马尼拉常态小计 ≈ 3,205.85 USD/月**（含 RDS 实测值，不再有未公示项）

> 与规划稿的三处结构性差异：① 节点机型实际开出 **`ecs.g9ae.2xlarge`**（非 `g9i.2xlarge`），且为**按量付费**（`PostPaid`）；② **无 staging/perf 节点**，压测环境实为**雅加达 dev 集群**（见 7.10.3）；③ **WAF / DCDN / 付费 DNS 均未开通**（见 7.10.7）。

#### 7.10.2 新加坡备 region（ap-southeast-1）—— 实测

| # | 资源 | 实际规格（线上实测） | 计费方式 | 单价与算式 | USD/月 | 来源 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | ECS 节点池 ×2 | 1×ecs.g8ine.2xlarge + 1×ecs.g9ae.2xlarge（8C32G）+ 100G ESSD PL1 系统盘 | 按量 | ($0.53832 + $0.49732)/h → $756.02/月 | 756.02 | `CLI` |
| 2 | ECS 数据盘 ×2 | 300G ESSD PL1（独立云盘） | 按量 | $0.07596/h → $55.45/台·月 × 2 | 110.90 | `CLI` |
| 3 | Tair 集群版 ×1 | tair.rdb.cluster.sharding.common（tair.rdb.with.proxy.1g ×2 shard / ESSD PL1 5G / 双 AZ） | 包月 | $88.02/月（2026-10 实付） | 88.02 | `账单` |
| 4 | ACK Pro 托管版 ×1 | ack-newapi-sg（ca75829e…）控制面 99.95% | 按量 | $0.09/集群·h → $65.70/月 | 65.70 | `账单` |
| 5 | NAT 网关 ×1 | ngw-t4n7gdnoh…（增强型 / 跨 AZ） | 按量 | $0.881/天 → $26.80/月 | 26.80 | `账单` |
| 6 | EIP 保有费 ×6 | 4 个上游白名单 EIP + 2 个 ALB 自带 EIP | 按量 | $0.120/天·IP → $3.65/IP·月 × 6 | 21.90 | `账单` |
| 7 | ALB ×1 | alb-amdwm60xmznh7s1nae（标准版 / Internet / Fixed / 2 AZ） | 按量 | $0.437/天 → $13.29/月 | 13.29 | `账单` |
| 8 | ACK 内网 CLB ×1 | ManagedK8SSlbIntranet-ca75829e…（ACK 自动创建） | 按量 | $0.429/天 → $13.05/月 | 13.05 | `账单` |
| 9 | OSS ×1 | oss-newapi-backup-sgp（标准 LRS，CRR 目标） | 按量 | 实测 → $0.03/月 | 0.03 | `账单` |
| 10 | VPC / vSwitch / 安全组 | —— | 免费 | 免费 | 0.00 | `官网` |
| | **小计** | | | | **1,095.71** | |

**新加坡常态小计 ≈ 1,095.71 USD/月**

> ⚠️ 两节点**规格不一致**：`i-t4nha3jicbebtvf3tr7v` = `ecs.g8ine.2xlarge`、`i-t4nb4aj0ssltm7jjawuv` = `ecs.g9ae.2xlarge`（节点池 `np-sg-ph-standby` 为多规格池）。备站**无 RDS、无 ClickHouse**（共用马尼拉主库与 CK），亦**无独立 ACR**（共用马尼拉 ACR 实例）。备站**当前未承接业务流量**（GTM 只挂马尼拉）⇒ 出口流量成本计 **$0**；一旦接管，按同口径 **$0.124/GB** 计算。

#### 7.10.3 雅加达 dev 环境（ap-southeast-5）—— 非生产 SLA 范围，独立列示

| # | 资源 | 实际规格（线上实测） | 计费方式 | 单价与算式 | USD/月 | 来源 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | ECS 节点池 ×2 | 1×ecs.g9ae.large（2C8G）+ 1×ecs.g9i.large（2C8G）+ 40G ESSD PL1 | 按量 | ($0.124328 + $0.112728)/h → $173.05/月 | 173.05 | `CLI` |
| 2 | RDS PG dev ×1 | pgm-d9j9p421lzx4gw73（pg.n2.2c.1m，2C4G，20G ESSD PL1，基础版） | 包月+后付 | $43.38/月 + 后付 $66.73/月 | 110.11 | `账单` |
| 3 | NAT 网关 ×1 | ngw-k1aij9gq…（增强型） | 按量 | $0.878/天 → $26.71/月 | 26.71 | `账单` |
| 4 | ACK 内网 CLB ×1 | ManagedK8SSlbIntranet-cb0abf5b… | 按量 | $0.429/天 → $13.05/月 | 13.05 | `账单` |
| 5 | EIP 保有费 ×1 | eip-k1ans4dq… | 按量 | $0.144/天 → $4.38/月 | 4.38 | `账单` |
| 6 | ACK Pro 控制面 | ack-newapi-jkt-dev（cb0abf5b…） | 按量 | ⚠ 账单未见计费（疑似账号首集群免费额度） | 0.00 | `账单` |
| | **小计** | | | | **327.30** | |

**雅加达 dev 小计 ≈ 327.30 USD/月**（该集群承载压测/冒烟，**不计入生产 SLA 成本**；原规划稿的「staging/perf 2 × g9i.xlarge」即此）

#### 7.10.4 汇总（实测）

| 口径 | 马尼拉 | 新加坡 | 雅加达 dev | 合计（USD/月） |
| --- | --- | --- | --- | --- |
| **常态（当前实况）** | 3,205.85 | 1,095.71 | 327.30 | **4,628.85** |
| **生产两站（不含 dev）** | 3,205.85 | 1,095.71 | — | **4,301.55** |
| 日烧钱速率 | — | — | — | ≈ **$152.18/天** |

**对照账号余额**：2026-10-14 **11:0x 最新实测可用余额 374.50 USD**（同日 09:5x 为 380.33、10-12 为 699.00；现金 374.50 / 信用 0.00）⇒ 日内 1.1 h 消耗 ≈ 5.8 USD，折 **≈130 USD/天**，与上表 **152.18 USD/天** 同量级（差额为一次性项与按量浮动）。✅ **已安排充值（受理中，2026-10-14）** ⇒ 此前「余额仅够约 2.4 天」的告警**解除**（⚠ 截至本次实测**充值尚未到账**）。⚠ 仍建议配置**余额 + 到期双告警**（建议阈值：余额 < 1,000 USD 或日均消耗 > 250 USD），避免再次出现余额见底才补的被动局面。

#### 7.10.5 2026-10 账期实付对照（真实账单）

| 产品 | 2026-09 全账期 | 2026-10（至 10-14，13.3 天） | 说明 |
| --- | --- | --- | --- |
| 云服务器 ECS（按量） | 98.07 | 975.59 | 6 节点 mnl+sg + 2 节点 jkt |
| 云数据库 ClickHouse | 21.20 | 474.49 | 企业版按量，单站 |
| 块存储（数据盘） | 15.78 | 145.41 | 6 × 300G ESSD PL1 |
| 云数据库 Tair | 64.63（订阅）+ 0.63（后付） | 88.02（订阅） | 09 月为 mnl；10 月为 sg |
| 容器服务 ACK | 6.12 | 57.60 | 2 集群（jkt 未计费） |
| 云数据库 RDS | 168.26（订阅）+ 0.54（后付） | 43.38（订阅）+ 25.40（后付） | 09 含 prod 首月；10 为 dev |
| NAT 网关 | 4.17 | 35.07 | 3 个（mnl/sg/jkt） |
| 负载均衡 | 1.35 + 0.10 | 26.22 | ALB ×2 + ACK 内网 CLB ×3 |
| 弹性公网 IP | 2.25 | 19.65 | 13 个保有费 |
| 数字证书 | — | 212.07 | **一次性**（DV 通配符实付；OV $997 已退款，见 7.10.6） |
| 域名注册 | — | 18.00 | **一次性** |
| 日志服务 SLS | 0.37 | 5.00 | — |
| 密钥管理 KMS | 0.00 | 4.50 | — |
| 云监控 + 拨测 | — | 0.68 | 1 个拨测任务 |
| 云解析 DNS（GTM） | — | 0.22 | GTM 3.0 按量 |
| 对象存储 OSS | 0.00 | 0.01 | 4 个 bucket，用量极小 |
| 容器镜像 ACR | 157.00（订阅） | — | 10 月未出账（订阅周期） |
| **合计（含一次性）** | **588.72** | **2,131.31** | 09 月为搭建期（09-24 起） |

> 上表口径为 `DescribeInstanceBill` 按实例汇总（`QueryBillOverview` 口径为 **2,137.82**，差 6.5 为抹零与未归类项）。
> 2026-09 含大量**搭建期临时实例**（短时 ECS / 磁盘，单笔 <$1，合计约 **$48**），已体现在 09 月合计中但未计入 7.10.1~7.10.3 的常态表。

#### 7.10.6 一次性 / 非经常项（不计入月度常态）

| 项 | 金额（USD） | 说明 |
| --- | --- | --- |
| DV 通配符证书 `*.likha.hk`（**生产在用**） | **212.07** | 订单 `cas_intl-sg-4rf4zyk0u00s`：新购 207.00 + 升级/降级 5.07；`CertIdentifier=606823-ap-southeast-1`，`issued`，**有效期至 2027-04-28** |
| ~~OV 通配符证书 `*.likha.hk`~~ | **0.00（已退款）** | 订单 `cas_intl-sg-9lu4zmk9e00m`：新购 997.00 + **退款 −997.00** ⇒ **净额 0** |
| 域名注册 | 18.00 | `ST49XLYWX261QWX` |
| 正式发布期待购 | — | WAF 3.0 企业版 / DCDN / 付费 DNS（若按原规划启用，见 7.10.7） |

> ✅ **证书一次性支出 = 212.07 USD（净额）** —— 2026-10-14 核实：**OV 通配符（$997）已退款**（账单实证 `cas_intl-sg-9lu4zmk9e00m`：新购 +997.00 / 退款 −997.00），**改为 DV 通配符**（`cas_intl-sg-4rf4zyk0u00s`：207.00 + 5.07 = **212.07**）。DV 覆盖 `*.likha.hk` + `likha.hk`、有效期至 **2027-04-28**，**较 OV 方案省 $784.93**。原「997 悬案」**已闭合**。

#### 7.10.7 与 2026-09-27 规划口径的差异（逐项）

| 项 | 规划稿（2026-09-27） | 线上实测（本版） | 差异主因 |
| --- | --- | --- | --- |
| ECS 节点机型 | `g9i.2xlarge` **包月** $232.37/台 | `g9ae.2xlarge` **按量** $323.04/台 | ① `g8i` 全系马尼拉无库存后实际开出 `g9ae`；② **2026-10-06 裁定：ECS 节点池维持按量付费** |
| staging / perf | 2 × `g9i.xlarge` 包月 $247.58 | **无**（改为雅加达 dev 集群，独立列） | 环境隔离改到 ap-southeast-5 |
| ACK Pro | 仅计 1 集群/地域 | 2 集群计费（jkt 未计费） | 集群数实测为 3 |
| ACR 企业版 | $113/月（2020 版 PDF，待复核） | **$157.00/月**（实付） | 旧价作废，已按实付更正 |
| ALB | $15.33 + LCU $27.59 | **$13.29/天·月**（实例费 + LCU 合并实测） | 实测 LCU 远低于假设 5.4 LCU |
| NAT | $31.39 + CU $169.51 | **$26.77/天·月**（实例费 + CU 合并实测） | 实测出口流量远低于假设 3,942 GB/月 |
| EIP | 保有 $17.52 + 出口流量 $319.30 | **$21.90**（保有费）+ 上量后估算 **$0.37** | 出口流量按 **100 MB/天** 估算（见 7.10.8），远低于原假设 |
| WAF 3.0 企业版 | $1,400/月 × 2 | **未开通**（$0） | 任务 20 未执行；账单与 `DescribeInstance` 双证 |
| DCDN | $60/月 | **未开通**（$0） | `DcdnServiceNotFound`：服务未激活 |
| 云解析 DNS | 企业旗舰版 $13.92/月 | **免费版**（$0）；GTM 3.0 独立 $6.72/月 | 实际用免费版 DNS + GTM 3.0 接入 |
| GTM | 旗舰版 $140/月 | **GTM 3.0 按量 $6.72/月** | 改用 GTM 3.0（postpay），探测 60 s × 3 节点 |
| OSS | $4.64 + $2.32 | **$0.03** | 实际用量极小 |
| SLS | $7.00 + $2.33 | **$11.41** | 写入量实测略高于假设（k8s-log 为主） |
| ARMS Prometheus | $8.80 | 已含在 SLS 项 | ARMS 实例为 remote-write，落 SLS |
| ARMS 应用监控 | $168.00 | **未开通**（$0） | 4 Agent 未接入 |
| 云监控拨测 | $145.15 | **$1.55** | 实测口径远低于 $8.4/万次 的假设 |
| Tair（mnl） | 4GB 主备 按量 $89.35 | 企业版主备 包月 **$64.63** | 规格改为 1G/2DB/6proxy；付费改包月 |
| Tair（sg） | 4GB 主备 按量 $99.28 | 集群版 包月 **$88.02** | 规格与付费方式均变 |
| ClickHouse | 社区版双副本 8C32G **包月** $1,728.32/站 × 2 站 | 企业版 **按量** 单 AZ 2 节点 / OSS 存储，**单站 $1,082.44** | ① 改为企业版按量；② **仅马尼拉 1 站**；③ 部署改单 AZ |
| RDS PG 高可用 | 未公示，参照 PolarDB $2,944.82/月 | **$168.26/月**（实测） | 规格由 16C64G 实为 **2C8G**；参照值虚高 17× |
| 运维跳板节点 | 未列 | **$48.25/月** | 新增（`newapi-ops-mnl`，包月） |
| ACK 内网 CLB | 未列 | **$39.15/月**（3 集群） | 新增（ACK 自动创建） |
| KMS 3.0 | 「暂计 0」 | **$10.52/月** | 新增（凭据管家已启用） |
| **合计（生产两站）** | **9,865.36** | **4,301.55** | ↓ 约 **56.40%** |

**降幅主因**：① **WAF 未开通**（−2,800/月）；② **CK 由 2 站包月改 1 站按量**（−2,374/月）；③ **RDS 参照值虚高**（−2,777/月）；④ 流量类（NAT CU + EIP 出口 + DCDN）与拨测实测远低于假设（−约 700/月）；⑤ GTM 由旗舰版订阅改 3.0 按量（−133/月）。
**升幅项**：ECS 由包月改按量（+363/月）、SLS（+2/月）、新增 ops 节点 / 内网 CLB / KMS（+98/月）。

#### 7.10.8 降本与优化（基于实测重算）

| 手段 | 空间（实测口径） | 代价 / 前提 |
| --- | --- | --- |
| **★ ECS 数据盘 300G → 100G** | 实测数据盘（挂 `/var/lib/container`，nvme1n1）**整盘 used 7.9 GiB** / 容量 290 GiB ⇒ 使用率 **2.7%**（该盘同时承载 `/var/lib/kubelet` + `/var/lib/containerd` + `/var/log/pods` 三个 bind 目录；仅 imageFs 口径为 4.4–4.8 GiB）⇒ 降 100G 后按现用量使用率 ≈ **8.2%**（≈ 12 倍余量）。省 = 每台 **$36.97/月**（$55.45→$18.48）：mnl 4 台 **$147.87/月** + sg 2 台 **$73.93/月** ⇒ **合计 $221.80/月**（年化 $2,661.64，占生产两站 $5.16%） | ⚠ 云盘**不支持原地缩容** ⇒ 须改节点池 `data_disks[0].size=100` 并**逐台轮转节点**（cordon → drain → 删除 → 节点池自动补新节点）；挂盘由 **ACK 内置 `[step=diskinit]` 步骤**自动完成（实测 `ack-deploy.log`），**无需改 `disk_init`** ⇒ 建议先灰度 1 台验证 |
| ClickHouse 降配 | 当前 **$1,082.44/月**，已是最大单项：调低 server 数 / 预留 CU / 缩短 `LOG_SQL_CLICKHOUSE_TTL_DAYS`（现 90 天） | 日志保留期缩短、查询性能下降 |
| 新加坡冷备 | 常态置 0 副本 → 省 2 节点 + 2 盘 ≈ **$861.46/月** | 接管 RTO 秒级 → 分钟级 |
| 备站「减配」 | 备站为低流量旁站，可评估降到 `g9ae.xlarge` 级规格 | 接管期容量需重新标定 |
| 雅加达 dev | 按需启停（当前 ≈ **$327.30/月**） | 压测窗口外无环境 |
| 拨测间隔 | 当前 5 min 已是低成本档（$1.55/月），无优化空间 | — |
| 出口流量 | 现测 NAT CU 极低（< 1 CU/天）；按 **100 MB/天** 估算仅 **$0.37/月** ⇒ 当前**不构成成本瓶颈**（标度表见下注） | 日均出口 > 27 GB 才破 $100/月；上量前考虑 NAT 资源包 |

**不计入本表**：① 上游 token 成本（与网关 SLA 解耦）；② **不含 GA**（理由见 7.1）；③ 跨区数据库读写公网流量（RDS 国际站公网流量 100% 折扣）；④ 一次性费用（证书 / 域名，见 7.10.6）。

**⚠ 流量口径与「上量后」估算（2026-10-14 更新）**：2026-10 账单中「云数据传输（CDT）」与 EIP 流量项均 ≈ $0 ⇒ **当前尚无真实业务出口流量**（未对上游发量，正式发布 = Day 4 任务 34）。按项目负责人给定口径「**上量后 ≈ 100 MB/天**」，已作为独立行计入 7.10.1（**+$0.37/月**）。

**流量类单价**（阿里云国际站官网公开定价页，2026-10-14 查证）：

| 计费项 | 单价 | 口径 |
| --- | --- | --- |
| EIP **出方向**流量（BGP 多线） | **$0.081/GB** | 新加坡 / 菲律宾马尼拉**同价**；雅加达 $0.090 |
| NAT 增强型**容量单位 CU** | **$0.043/CU**（跨 AZ）· $0.034（单 AZ，0~100 万 CU） | **1 CU = 处理流量 1 GB**（入 + 出**均计**） |
| **合计（生产口径）** | **$0.124/GB** | EIP $0.081 + NAT CU $0.043 |

**流量成本标度表**（mnl/sg 口径；折月按 30.4167 天，1 GB = 1,024 MB）：

| 出口流量 | 折月 | 流量成本/月 | 定位 |
| --- | --- | --- | --- |
| **100 MB/天（本次口径）** | **2.97 GB** | **$0.37** | 与账单 $0 档基本一致 ⇔ 「未上量」 |
| 1 GB/天 | 30.42 GB | $3.77 | 低强度试用 |
| 10 GB/天 | 304.17 GB | $37.71 | 小规模上线 |
| 100 GB/天 | 3.04 TB | $377.14 | 中等规模 |
| **1 TB/月** | 1,024 GB | **$127.02** | 标度基准（= 原提示口径） |

⇒ **结论**：当前流量成本**可忽略（< $0.4/月）**；只要**日均出口 ≤ 10 GB，流量费 ≤ $38/月，不改变成本结构**（仍由 ClickHouse + ECS 主导）。**突破 $100/月需日均出口 > 27 GB**，届时须重评 NAT CU 分档并考虑 NAT 资源包（按量→资源包可省约 20–30%）。

#### 7.10.9 单价来源

| 资源 | 实测单价 | 取证方式 |
| --- | --- | --- |
| ECS `g9ae.2xlarge`（mnl） | $0.44252/h（实例 + 100G 系统盘） | `aliyun ecs DescribePrice`，2026-10-14 |
| ECS `g9ae.2xlarge`（sg） | $0.49732/h | 同上 |
| ECS `g8ine.2xlarge`（sg） | $0.53832/h | 同上 |
| ECS `g9ae.large` / `g9i.large`（jkt） | $0.124328 / $0.112728 /h | 同上 |
| ESSD PL1 300G 数据盘 | $0.07596/h | 同上（两地同价） |
| `ecs.c9i.large` + 40G（包月） | $48.25/月 | 同上 |
| RDS `pg.n4.2c.2m` 2C8G HA + 100G ESSD PL1 | $168.26/月 | `aliyun rds DescribePrice` + 2026-09 实付 |
| Tair 企业版主备（mnl） | $64.63/月 | 2026-09 `DescribeInstanceBill` 实付 |
| Tair 集群版（sg） | $88.02/月 | 2026-10 `DescribeInstanceBill` 实付 |
| ACR 企业版基础版 | $157.00/月 | 2026-09 `DescribeInstanceBill` 实付 |
| ACK Pro 控制面 | $0.09/集群·h | 账单反推（$2.16/天/集群） |
| ALB 标准版（实例 + LCU） | $0.437/天 | 账单反推 |
| NAT 增强型（实例 + CU） | $0.880 ~ 0.881/天 | 账单反推 |
| EIP 保有费 | $0.120/天·IP（≈ $0.005/h） | 账单反推 |
| ClickHouse 企业版 | $35.587/天 | 账单反推 |
| GTM 3.0 / KMS / SLS / CMS / OSS | 见 7.10.1 | 账单反推 |
| ACK 内网 CLB | $0.429/天 | 账单反推 |
| **EIP 出方向流量** | **$0.081/GB**（mnl / sg）· $0.090/GB（jkt） | **阿里云国际站官网 EIP 定价页**，2026-10-14 |
| **NAT 增强型容量单位 CU** | **$0.043/CU**（跨 AZ）· $0.034（单 AZ，0~100 万 CU）；**1 CU = 1 GB** | **阿里云国际站官网 NAT 网关计费页**，2026-10-14 |

**官方定价页参考**：NAT [88658](https://www.alibabacloud.com/help/doc-detail/88658.htm) · EIP [pay-as-you-go](https://www.alibabacloud.com/help/en/eip/pay-as-you-go) · ALB [billing-rules](https://www.alibabacloud.com/help/en/slb/application-load-balancer/product-overview/alb-billing-rules) · GTM [gtm3-product-billing](https://www.alibabacloud.com/help/en/dns/gtm3-product-billing) · ACK [86759](https://www.alibabacloud.com/help/doc-detail/86759.htm) · ClickHouse [pricing](https://www.alibabacloud.com/help/en/clickhouse/product-overview/pricing/) · OSS [pricing-list](https://www.alibabacloud.com/product/oss-pricing-list) · SLS [billable-items](https://www.alibabacloud.com/help/en/log-service/latest/billable-items) · ARMS [pricing](https://www.alibabacloud.com/product/arms/pricing)

*成本表生成：`deploy/ops/gen_cost_table.py`（`--apply` 自动回写并备份）· 取证脚本：`deploy/logs/t_cost_*.sh|py` · 核价基准日 **2026-10-14** · 账期 **2026-10-01~10-14***
*更新 2（2026-10-14 10:5x）：① 余额告警解除（**充值受理中**）；② **OV 证书退款确认**（净额 0）⇒ 证书实付 **$212.07**；③ 新增**上量后出口流量估算**（100 MB/天 ⇒ $0.37/月）+ 标度表；④ 7.10.1/7.10.2/7.10.3 三表改按 **USD/月 降序**排列。*
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
| 排除项 | ① 上游供应商自身故障（new-api 只做透传与切换，不计网关 SLA）；② 阿里云公告的区域级 IaaS 故障；③ 客户侧网络与证书问题；④ 超出限流配额的 429；⑤ **新加坡备 region 自身故障**——PH 备与 TH 备同处新加坡，该区域故障会导致两地接管能力同时失效（见 8.4 与 R-32）；⑥ **两地主站点同时需要接管**——新加坡按单站点 24 副本独立核算，不具备"PH 备 + TH 备 合计 48 副本"的容量（见 7.4.4 与 R-33） |
| **月度不可用预算** | 43,200 × 0.05% = **21.6 分钟**（周预算 5.04 分钟，日预算 0.72 分钟） |

### 8.2 可用性推导（为什么必须按下面这样部署）

目标：整体 ≥ 99.95%。单点不可能达成，必须靠冗余把各环节抬高：

| 环节 | 配置 | 期望可用性 | 备注 |
| --- | --- | --- | --- |
| DNS/GTM + 就近解析 | 双主站点 + 新加坡备 region，健康探测切换 | 99.99% | 单站点故障 60 s 内切到备 region |
| WAF + ALB | 阿里云多 AZ 实例，SLA 99.99% | 99.99% | SSE 超时配置正确，避免"假可用" |
| ACK 控制面 | Pro 托管版多 AZ | 99.95% | 控制面故障不影响已运行 Pod 的数据面 |
| 网关数据面 | 每主站点常态 4 / 上限 16 副本跨 2 AZ（备 region 的 PH 备 / TH 备常态各 2、**接管上限各 24**）、`maxUnavailable=0`、PDB、preStop 排空 | 99.99% | 单实例 99.5% × 4 副本并联；副本口径见 8.5 推导链 |
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
| 主站点整站故障 | GTM 健康检查连续失败 | DNS 切到新加坡备 region（接管上限 24 副本 = 被接管站点 `maxReplicas` 16 × 1.5，见 7.4.4）；备 region 经公网读写主站点主库 | 确认后手工降级非核心功能 | ≤ 5 min |
| **新加坡备 region 自身故障（共享故障域，R-32）** | GTM 探测点（**必须部署在新加坡以外**，否则该故障无法被检出）+ 新加坡 ALB / ACK 健康检查连续失败 | **无自动处置**：PH 备与 TH 备同时失效，两地失去接管能力；两个主站点自身不受影响 | 维持主站点单点位运行并登记"零容灾窗口"；恢复新加坡后按 8.6 重新验证"扩到 24 副本"的接管路径；该窗口按 8.1 排除项 ⑤ 记 SLA 例外 | —（主链路不受影响） |
| **两地主站点同时需要接管（容量不足，R-33）** | 两个 GTM 主地址池同时判定对应主站点不可用 | **无自动处置**：新加坡按单站点 24 副本独立核算，不具备 48 副本容量（见 7.4.4） | 按本表原则手工降级非核心功能并排队；该场景**不在本方案 99.95% 承诺内**（见 8.1 排除项 ⑥） | 不承诺 |
| 上游供应商区域性故障 | 渠道批量自动禁用（status=3）+ 告警 | `RetryTimes` 换渠道 + 优先级分层 + `status_code_mapping` | 切备用渠道 / 改 `model_mapping` | ≤ 60 s（轮询） |
| Redis 故障 | `newapi_redis_up == 0` | 限流降级内存滑动窗口（需改造），用户/令牌缓存回落 DB | 立即恢复 Tair | 分钟级 |
| 主库故障 | 连接错误 + RDS 事件 | RDS 主备自动切换；应用重连（`SQL_MAX_LIFETIME=60` 加速收敛） | 确认切换后校验额度一致性 | ≤ 60 s |
| 连接池层故障（PgBouncer / RDS 代理） | 池 `cl_waiting` 堆积、`query_wait_timeout` 报错、池 Pod 非就绪 | PDB `minAvailable: 2` + 跨 AZ 3 副本兜住单副本；应用侧 `database/sql` 自动重连 + `RetryTimes` | `RELOAD`/滚动修复配置，必要时临时把 master 直连切回应急 DSN | ≤ 30 s（单副本）；全层故障需回退直连，分钟级 |
| 备 region→主库公网链路劣化 | 备 region 探针失败 / RTT 与连接失败率告警 | 备 region Pod 不就绪即不参与 GTM 接管，流量保留在主站点 | 排查公网段与 RDS 白名单；持续不达标则维持"备 region 不参与接管"并记录为已知风险（**不引入 GA**，理由见 7.1） | ≤ 5 min |
| 磁盘打满 | 5 s 采样 > 95% → 503 摘流 | 自动拒绝新请求保护进程 | 清磁盘缓存接口 `/api/performance/disk_cache` | 分钟级 |
| 慢客户端拖垮连接 | `active_connections` + `STREAMING_TIMEOUT` | 120 s（默认）无事件即断；写 deadline `ExtendWriteDeadline` | 调 `USER_SESSION_*` 与限流 | — |
| 迁移失败 | 启动探针不过 + 日志 `failed to initialize database` | `Restart=unless-stopped` 反复失败 → 告警 | 回滚镜像 + 前向修复（无 down） | 10 min |
| 配置误改 | 变更后 5 min 内成功率/时延劣化 | 无法自动识别（缺配置基线） | 依审计日志 key 回滚旧值 | ≤ 2 min |

### 8.5 容量规划与压测验收

- **单实例基线**（须由 3.9 的 S1/S2 实测替换）：非流式 800 QPS、并发 SSE 1,500、内存 2 GiB 工作集、fd 需求 = 并发 × 2（客户端 + 上游）+ 余量，故 `nofile=200000`。
- **区域容量与副本数推导链（全篇唯一权威口径；7.2 / 7.4.2 / 7.4.4 / 7.4.5 / 7.10 均引用此处）**：
  1. `minReplicas = 4`：跨 2 AZ 的高可用下限（单 AZ 故障仍剩 2 副本）；
  2. 峰值按**日均容量 3 倍**估算 → `4 × 3 = 12` 副本；
  3. 主站点 `maxReplicas = 16`：12 上取整，并留灰度（`maxSurge: 1`）与突发余量；
  4. **备 region 接管上限 = 被接管站点 `maxReplicas` × 1.5 = `16 × 1.5 = 24` 副本**。"1.5 倍"的基准是**部署上限**而非未知的真实峰值（后者必须由压测替换），因此该口径偏保守；
  5. 节点数按 Pod **`requests`** 反算（`副本数 × 2 vCPU ÷ (7.9 × 0.8 = 6.32 vCPU)`，即留 ≥ 20% 给 kube-system）：主站点 `16 → ≥ 6 节点`（`32 ÷ 6.32 = 5.06` 上取整）、备 region 接管 `24 → ≥ 8 节点`（`48 ÷ 6.32 = 7.59` 上取整）；`limits: 4 vCPU` 是单 Pod 的突发上限，**不参与节点数反算**；
  6. 客户端连接数 = `副本数 × SQL_MAX_OPEN_CONNS(300)`：主站点 `16 × 300 = 4,800`、备 region 接管 `24 × 300 = 7,200`，两者都必须经 7.4.5 的连接池（复核 I-2）。
  **反算规则（强制）**：若压测实测出的"日均容量基准"不等于 4 副本，必须按同口径同步上修第 3、4、5、6 步，并复核 7.4.5.1 的 I-2 / I-3；**不允许只改其中一处**。同理，PH 备与 TH 备的 24 副本是各自独立的预算，不可合并计算（见 7.4.4）。
- **带宽**：单路流式响应约 20–50 KB/s，1,000 并发 ≈ 40 Mbps，出站流量费用与 ALB LCU 需按此线性预留。
- **连接数预算**：启用 7.4.5 的连接池后，约束从"应用直连"变为三条不变量 I-1/I-2/I-3（见 7.4.5.1）。未启用池时必须满足 `(主站点 SQL_MAX_OPEN_CONNS × 副本数) + (备 region SQL_MAX_OPEN_CONNS × 副本数) ≤ RDS max_connections × 0.8`；主站点扩到 16 副本时 `300 × 16 = 4,800` 就已打爆 PG，**备 region 接管期 24 副本更是 `300 × 24 = 7,200`**，因此**必须**配 PgBouncer 或 RDS 代理（I-2 按 7,200 复核：`3,000 × 3 = 9,000` 成立）。启用后仍要复核 I-3：`default_pool_size × 池副本数` 才是 PG 真实连接数，池副本扩容等同于主库连接扩容，而应用副本扩容**不会**（见 7.4.5.1）。
- **上游出口**：NAT 固定 EIP 池（≥ 4 个 /28）用于供应商白名单；每渠道独立 host 连接上限，避免单渠道占满 `MaxIdleConnsPerHost=400`。

### 8.6 灾备演练（季度必做）

1. 备 region 接管演练：GTM 强制把菲律宾流量切到新加坡 PH 备、泰国流量切到新加坡 TH 备，验证备 region 经**公网**读写马尼拉 / 曼谷主库的容量与延迟（目标：接管期成功率不降，写入 P99 抬升 ≤ 80 ms）。**演练必须包含容量到位验证**：把备 region 从常态 2 副本扩到**接管上限 24 副本**（含节点池自动伸缩到 ≥ 8 节点、连接池 I-2 复核 `300 × 24 = 7,200 ≤ 3,000 × 3`）；采用冷备（0 副本）形态时，还要实测"一键扩容脚本 + 节点扩容"的端到端耗时并计入 RTO。
2. RDS PITR 演练：从备份恢复到新实例，跑额度对账（验证 RPO/RTO）。
3. Redis 摘除演练：确认降级路径不返回 5xx 雪崩（当前会 fail-closed，见 R-05）。
4. 版本回滚演练：从 canary 门禁失败到权重归零，实测止血耗时（目标 < 60 s）。
5. 上游全体故障演练：mock 上游 100% 5xx，验证退款不重复、额度不超扣、错误日志不写爆磁盘。
6. 连接池层演练（启用 7.4.5 后必做）：① 删除 1 个 PgBouncer 副本，验证 `cl_waiting` 无持续堆积、成功率不降；② 对全部池副本 `PAUSE newapi` 60 s，确认网关按 `query_wait_timeout` 快速失败并被 ALB/GTM 判定为劣化而非全站不可用；③ 在池存在时执行 RDS 主备切换，重点观察 7.4.5.4 的预处理语句报错是否复现。
7. 备 region 共享故障域演练（配合 R-32 / R-33，必做）：① 从**新加坡以外**的探测点验证"新加坡整体不可用"能被 GTM 检出——若探测点也在新加坡，该故障连告警都不会有；② 用容量核对脚本评估"PH 备 + TH 备同时扩到 24 副本"所需的 48 副本 / 96 vCPU（含 ≥ 20% 余量 = ≥ 16 节点 / 128 vCPU）是否超出 7.2 本期给出的 `2–8` 区间，并把结论回写 8.1 排除项 ⑥；③ 确认"新加坡故障期间两个主站点继续单点位服务"的降级动作已写入 Runbook，并明确该窗口为零容灾窗口。

---
