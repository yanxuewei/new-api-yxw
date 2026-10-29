# 路② 收尾 G1：TLS Secret 定时刷新执行器 —— 设计与裁定（2026-10-16）

> 状态：**设计已逐条对齐，尚未实现、未落任何云写**。
> 本文是对话产物的忠实记录，用于后续接续实现时不必重走访谈。
> 关联台账：`deploy/cert/targets.yaml` 的 `renewal`（R1–R5）与 `evidence_20261015`、
> `deploy/manifests/ingress-alb-tls-anchor.yaml`、指南 v2.0 任务 3 卡。

---

## 1. 背景与目标

- 2026-10-15 路② 落地后，两地（`ack-newapi-mnl` / `ack-newapi-sg`）443 的**实际出证来源**变成
  `Ingress/spec.tls` 引用的 `Secret/new-api-tls`，它**压过** AlbConfig 钉死的 `CertificateId`。
  ⇒ 只改 AlbConfig 不再足以恢复 443，`renewal.R5`（刷 Secret）成为必需路径。
- CAS 侧 `AutoReissue=enable` 只保证**签出新证**，不会把新证送进集群。
- **G1 = 目标状态里唯一未兑现的一项**：没有"把 CAS 新证自动刷进两地 Secret"的执行器。
  在它就绪之前，2027-03-29 窗口这次续签仍需**人工按 R5 执行**。
- 本执行器要兑现的判据是"免人工"，不是"免观测"——它必须每天留下可查的 ground truth。

## 2. 上下文查证（本轮做的，全部本地元数据 / 仓库证据，零云调用）

| 结论 | 依据 |
|---|---|
| CAS 原生部署任务**打不到集群 Secret** ⇒ 路② 的 Secret 只能自己刷 | `aliyun cas ListCloudResources --help` 的 `CloudProduct` 枚举（aliyun 侧只有 SLB/LIVE/webHosting/VOD/CR/DCDN/DDOS/CDN/ALB/APIGateway/FC/GA/MSE/NLB/OSS/SAE/WAF），无 ACK/Secret |
| 取新证**唯一程序化通道**是 `GetUserCertificateDetail --CertId <int>`，且它**同时返回 Cert 与 Key**（私钥过 API）；`--CertFilter true` 才屏蔽内容字段 | `aliyun cas GetUserCertificateDetail --help` |
| `GetCertificateDetail` 明文写明"不返回证书内容与私钥" ⇒ 不可用于本目的 | 同上 API 描述 |
| `deploy/lib/aliyun_rpc.py` 可复用其 SigV1 签名逻辑，但**不支持 STS 临时凭据**（grep `SecurityToken` 无命中，`_creds()` 只取 AK/SK）⇒ RRSA 路线必须补这一处 | `deploy/lib/aliyun_rpc.py:50-60` |
| RRSA 曾被裁定停建，但**集群侧开关仍是开的** ⇒ 建角色是可复用的既有模板，不是新机制 | `deploy/tasks/task17/rrsa.sh`（含"两地两个角色，因信任策略绑集群专属 OIDC"的注释）、指南 2586/2869 行（mnl/sg `rrsa_config.enabled=true`） |
| 现网 stdout 采集**只收容器名为 `new-api` 的容器** ⇒ 执行器复用该通道的前提是容器名（不是 Pod 名）也叫 `new-api` | `deploy/sls/clusterpipelineconfig-app-stdout.yaml:46` `IncludeLabel: io.kubernetes.container.name: new-api` |
| 现网业务镜像运行时是 `debian:bookworm-slim`，显式只装 `ca-certificates tzdata libasan8 wget`，无 python/curl ⇒ 执行器需要自己的极瘦镜像 | `Dockerfile:31-36` |

## 3. 四条裁定（逐条问过，选定的那条）

1. **执行位与身份**＝集群内 CronJob + RRSA 临时凭据。
   放弃：集群内挂长期 AK（AK 明文进 etcd、权限面大）、集群外定时机 + 甲通道下发（依赖本机开机、私钥再走一遍 RunCommand 正文）。
   记录一个**有据例外**：2026-10-05「RRSA 角色今后一概不建」的裁定，当年的成本理由是 **KMS 实例**；
   **RRSA 本身不计费**，本任务为此重建两个只读角色。
2. **权限边界**＝只读 CAS + 只写目标 Secret。
   `cas:DeleteUserCertificate`（清理控制器上传的旧证）与 R2（改 AlbConfig）**执行器只检测+告警，不代劳**；
   不给任何云侧写/删权限，也不做"自动回滚旧证"（与路② "坏 Secret 会接管该监听全部域名出证"叠加会让调试面变复杂）。
3. **镜像与脚本分发**＝新建极瘦 `Dockerfile.tlsrotator`（`python:3.12-slim` + `ca-certificates`，digest 锁定，**不打脚本**）
   + 脚本走 **ConfigMap 挂载** ⇒ 改校验逻辑不用重建镜像，CronJob 下一个 Job 自动生效。
4. **失败通知**＝执行器只打一行结构化 ERROR，交给 **SLS 告警**，并且**先把通知渠道配通**
   （顺带闭合任务 32 的"已建规则 ≠ 能打电话"残留）。
   未选：CMS 站点监控独立拨测、ACK 事件中心 FailedJob、集群内状态位 + 堡垒机巡检——
   但 CMS 那一条仍是**推荐的后续第二通道**（理由见 §6）。

## 4. 核心循环模型：选甲

- **甲（选）**：每次运行都对账。取 CAS 本实例当前 issued 证 → 门禁 → 与集群 Secret 现值比 **serial** → 不同才写，相同一行 `NOOP` → 写完立即回读复验。
  额外守卫：**单调不降级** —— 新证 `notAfter` 必须晚于现 Secret，否则拒写并告警（防 CAS 侧返回旧证把好证盖掉）。
- 乙（弃）：只在剩余有效期 < N 天才去碰 CAS ⇒ 平时不调 CAS 也就平时不知道有没有新证，与"免人工要求的可观测性"相反，且 N 是新魔法数。
- 丙（弃）：CAS 事件驱动 ⇒ 要建 MNS/函数计算与触发链路，而"CAS 是否提供续签成功事件推送"本身未证。

## 5. 第 1 节 · 架构（已呈现，未收点头）

```
CAS 托管续签(已开) ──签出新证──> CAS 实例
                                    │  ①只读（RRSA 临时凭据）
                                    ▼
                         CronJob tls-rotator（ns=new-api，每 12h）
                    ②取 Cert+Key → ③写前门禁 → ④serial 对账 → ⑤PATCH
                                    │
                                    ▼
                       Secret/new-api-tls ──ALB 控制器──> 监听证书（路②：Secret 优先）
                                    │
                                    └─ stderr 一行结构化日志 → SLS app-stdout → ERROR 告警
```

三个架构决定：

- **执行器不直碰 ALB / AlbConfig**。它只把 Secret 刷成"门禁通过且 notAfter 更晚的那张证"；换绑由 ALB Ingress Controller 负责，
  R2（AlbConfig 钉死值）与旧上传证清理**仍属人工**，执行器只在日志里提示这两件事到期。
- **不改现网采集规则**。执行器 Pod 的**容器名就叫 `new-api`** 以命中 `IncludeLabel`，零改动进
  `k8s-log-<clusterId>/app-stdout`；告警语句用 `_pod_name_: new-api-tls-rotator*` 区分业务与执行器。
  （动那条 pipeline 的风险远大于收益——该文件头部记了三个反复试错的坑。）
- **G0 必须先证，不靠文档推断**：见 §6。

## 6. 未证前提（诚实缺口）

| 编号 | 未证内容 | 影响 | 怎么证 |
|---|---|---|---|
| **G0** | **改 Secret 内容**（非创建）是否触发控制器重新上传+换绑监听。10-15 的证据只到"创建时绑上了" | 若不触发，整个执行器白干 | 演练：PATCH 一次同内容 + 无害注解 bump，观察 `ListListenerCertificates` 的 Secret 证 `CertificateId` 是否变化、443 基线 `RuleId` 是否被动。兜底设计 = PATCH 后 bump 锚定件注解强制 reconcile |
| **G1** | 执行器本身（本设计的全部产物） | 现状仍需人工 R5 | 本任务 |
| **G2** | Secret 内证书**已过期**时是否仍优先于钉死证（现证据只到"有效期更短但未过期仍胜出"） | 决定"执行器漏刷一次"是延迟爆炸还是立即故障 | 探针代价 = 生产 443 短时出错误证（覆盖是**监听级**，与 `tls.hosts` 无关）⇒ 须单独授权 |
| **G3** | 续签后私钥是否不变 | 决定刷新要不要连私钥一起写 | 执行器内**按实测处理**：比对 `GetUserCertificateDetail` 返回 Key 的 `-modulus` md5 与现 Secret Key；不等就成对写（门禁仍校验配对）。默认**不假设**可只换公钥 |
| — | CAS 读接口在国际站账号下的**正确端点/地域**（`ap-southeast-1` vs `cn-hangzhou`：控制器上传证只在 cn-hangzhou 可见） | 决定 env `CAS_ENDPOINT` 取值 | 只读探针 P1 |
| — | `openssl` CLI 是否在新镜像内可用；CAS 读权限能否按具体证书实例收窄（资源级鉴权粒度） | 门禁实现方式 / 策略能写多小 | 本地构建后验证 + RAM 策略实测 |

## 7. 第 2 节 · 组件与接口（已呈现，未收点头）

| # | 产物 | 位置 | 职责与接口 |
|---|---|---|---|
| 1 | `Dockerfile.tlsrotator` | 仓库根 | `python:3.12-slim`（digest 锁）+ `ca-certificates`；运行时只需 python3 + `openssl` + stdlib `urllib` |
| 2 | `rotator.py` | `deploy/tls-rotator/`，经 ConfigMap 挂载 | 唯一执行体，纯 stdlib 零 pip；自带 ~30 行 RPC 签名（抄 `aliyun_rpc.py` 的 SigV1 并**补 `SecurityToken`**） |
| 3 | `rbac.yaml` / `sa.yaml` | 同上 | `Role` 只含 `apiGroups:[""] resources:["secrets"] resourceNames:["new-api-tls"] verbs:["get","patch"]`；**无 create/delete**（Secret 被删属事故，应失败告警而非自我修复） |
| 4 | `cronjob-{mnl,sg}.yaml` | 同上 | schedule `17 3,15 * * *`（错开整点）、`concurrencyPolicy: Forbid`、`startingDeadlineSeconds: 600`、`successfulJobsHistoryLimit: 3`；两地差异**全走 env**，脚本一份 |
| 5 | `rrsa_tls_rotator_role.sh` | `deploy/ops/` | 两地各一 RAM 角色，信任策略绑各集群 OIDC 且 `oidc:sub` 锁到 ns/new-api 的 SA；策略仅 `cas:GetUserCertificateDetail`、`cas:ListInstances`、`cas:GetInstanceDetail` |
| 6 | `drill.sh` / `verify.sh` | 同上 | 演练与验收；集群侧动作一律经 `deploy/lib/ack_remote.sh <mnl\|sg>` |
| 7 | SLS 告警规则 | 复用 `deploy/task27_alert.sh` | `k8s-log-*` 项目一条 `_pod_name_: new-api-tls-rotator* and ERROR`；固化"最小 body 创建 → `UpdateAlert` 补全 → `GetAlert` 回读"；**先配通知渠道** |

`rotator.py` 契约：

- 输入全部来自 env：`CAS_INSTANCE_ID` / `CAS_ENDPOINT` / `EXPECT_SAN`（`www.likha.hk,sg.likha.hk,likha.hk`）/
  `SECRET_NS` / `SECRET_NAME` / `MODE=check|apply`。**没有任何参数能传私钥**（私钥不进 argv、不进 env、不进临时文件）。
- 输出**有且只有一行**结果（其余走 stderr）：
  `status=NOOP|UPDATED|REJECT|ERROR old_serial=… new_serial=… not_after=… gate=… reason=…`
  `REJECT`＝门禁或单调守卫不过 ⇒ **不写、不重试、退出码 1**；`ERROR`＝取不到/调不通 ⇒ 退出码 1。两者都让 Job 失败并命中告警。
- 校验全程走 `openssl` 的 **stdin 管道**（`-in /dev/stdin`）：`-modulus` 配对、SAN 覆盖、`-checkend` 未过期、链 3 块且 leaf 在前；
  **不落任何临时文件**（因此不需要 `/dev/shm`，也不需要 `shred`）。
- 写接口：`PATCH /api/v1/namespaces/new-api/secrets/new-api-tls`，`Content-Type: application/merge-patch+json`，
  用挂载的 SA token + `ca.crt` 走 https（无需 kubectl 二进制）。

## 8. 设计未覆盖 / 明确不做

- 不自动清理控制器上传的旧 CAS 证书（只告警）；不做 R2 的 AlbConfig 换绑；不碰 OSS（`img.likha.hk`）换证——那是**独立通道**，见 `targets.yaml` 的 `oss_note`。
- 不引入 cert-manager / ACME（换 CA 是另一件事，不在本任务）。
- 执行器自身不做 Secret 备份与回滚。
- 本任务顺带**必须**做的一件事：SLS 通知渠道配通（否则"失败告警"是空头承诺）。

## 9. 下一步（都要单独授权，本文未执行任何一条）

只读探针（建议顺序）：
P1 `GetUserCertificateDetail --CertId 606823` 定端点并确认可取到 Cert+Key（**只允许输出字节数与 md5，禁落原文**；同时能验 md5 是否 == 现网 `df343b7977ad59775bccf3ec5c128fac`）；
P2 RRSA 角色建成后集群内取凭据调通 CAS；P3 镜像内 `openssl` 可用性与 python 版本；P4 容器名 `new-api` 的日志是否真进 `app-stdout`；P5 = **G0 的换绑触发实验**。

写操作（各自单独授权、先查重再执行）：建 2 个 RAM 角色 + 策略（免费）；构建并推送 1 个 ACR 镜像；
两地 apply RBAC/ConfigMap/CronJob；建 SLS 告警规则并配通知渠道。

另待办的老台账：RDS `pgm-5tstdhko64x2c01w` 与马尼拉 Tair `r-5tsf1fe16543e274` **2026-10-28 到期**（无续费台账）、
ALB 入口收敛 A/B/C、canary 上 443、任务 40 甲类证据、S-0 跨区写 CK 三选一、新加坡 Tair 付款（余额 0）。
