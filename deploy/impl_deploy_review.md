# impl_deploy.md 双区域部署方案核实报告

| 项目 | 内容 |
| --- | --- |
| 核实日期 | 2026-09-21 |
| 代码基线 | commit `972aed197`（与 `impl_deploy.md` 声明一致） |
| 核实范围 | `impl_deploy.md` 第七章（阿里云部署）、第八章（SLA 99.95%）中「双区域 Active-Active + DTS 双向同步」方案的三个待确认点 |
| 核实方式 | 仓库代码检索（`search_file` / `search_content` / 逐文件阅读）+ 文档交叉比对 |

> 本报告只陈述可在仓库中验证的事实。凡涉及阿里云侧实际配置（DTS 冲突策略、GTM 记录、ALB 证书）的内容，仓库中不存在对应配置文件，只能给出「必须由部署方确认」的结论与验证方法。

---

## 结论速览

| # | 缺口 | 判定 | 严重度 | 后果 |
| --- | --- | --- | --- | --- |
| 1 | 备用区域（曼谷）入口 host/TLS 未定义 | **确认存在**（文档无、仓库无） | 高 | GTM 切区后 PH 用户 TLS 握手失败或 404，属「完全不可用」而非降级 |
| 2 | DTS 冲突解决策略缺失 | **确认存在**（文档仅写「冲突检测」；代码内所有幂等键均为库内约束） | 高 | 计费/额度两库不收敛，对账永久不平 |
| 3 | 数据库租约去重跨区失效 | **确认存在**（`model/system_task.go` 代码级证据） | 高 | 两区 master 同时执行同一任务：重复轮询、重复结算、重复清理 |

三者都指向同一个结构性问题：**`impl_deploy.md` 采用「双库可写 + DTS 双向同步」，但应用侧所有互斥与幂等机制（DB 租约、唯一索引、行锁、CAS）的作用域都是单个数据库。** 7.2 资源清单只写了「DTS 双向增量、冲突检测、延迟告警 > 5 s」，没有为这个前提变化补齐应用层语义。

---

## 缺口一：备用区域入口（host / TLS / Ingress）未定义

### 证据

1. **仓库中不存在任何 K8s / ALB 清单。**
   - `*.yaml` 全仓库仅命中：`web/cz.yaml`、`i18n/locales/{en,zh-CN,zh-TW}.yaml`。
   - `*.yml` 仅命中 `docker-compose*.yml`、`.github/**`。
   - `impl_deploy.md` 里的 `# deploy/aliyun/00-namespace-config.yaml` 等路径是**文档内嵌示例**，不是仓库中真实存在的文件。

2. **文档中唯一的 Ingress 定义属于马尼拉**，`impl_deploy.md:402-451`：

```yaml
  tls:
    - hosts: [ "api.example-ph.com" ]
      secretName: api-example-ph-com-tls
  rules:
    - host: api.example-ph.com
```

   canary Ingress（`:432-451`）使用同一个 host。**曼谷侧的 Ingress / TLS 在第七章中不存在**，7.1 拓扑与 7.2 清单只把曼谷描述为「ALB 多可用区 / ACK Pro / RDS / Tair / ClickHouse / OSS」，没有 host 或证书信息。

3. **域名方案本身在文档内部不一致**：
   - 7.4.1 ConfigMap（`:201`）：`SESSION_COOKIE_TRUSTED_URL: "https://api.example-ph.com,https://api.example-th.com"` → 暗示双域名。
   - 7.5 Compose（`:500`）：`SESSION_COOKIE_TRUSTED_URL: "https://api.example-ph.com"` → 只有单域名。

### 影响

7.1 与 8.4 都声明由 GTM 在区域故障时把流量「切到他区」。DNS 切换只改变域名解析结果，**不改变客户端请求的 Host 与 SNI**。因此：

- 若曼谷 ALB 未配置 `api.example-ph.com` 的监听规则 → 请求落到默认后端，返回 404；
- 若曼谷 ALB 未挂载包含该域名 SAN 的证书 → TLS 握手直接失败，客户端拿到证书错误；
- 两种情况下 GTM 的健康探测（探测备用区域自己的健康检查路径）都是通过的，**系统不会告警**，故障表现为「静默全损」。

对照 8.1 的不可用定义（连续 2 个 15 s 周期 5xx/连接失败），这属于**计入 SLA 违约的真实不可用**，不是「降级可用」。

### 修复方案

应用层无需改动：`SESSION_COOKIE_TRUSTED_URL` 已同时列出两个域名（`:201`），OriginGuard 按「请求自身 Origin + 可信列表」判定（`docs/authentication.md:99-103`），因此备用区域承接主区域域名时，刷新/登出仍会通过。

需要补齐的是接入层，三种做法（推荐 A）：

**A. 双域名 SAN 互认（改动最小，保留现有域名体系）**

两个区域各自声明两个 host，证书使用包含双方 SAN 的同一张证书（或 AlbConfig 多证书 SNI）：

```yaml
# 两个区域都配置
apiVersion: v1
kind: Secret
metadata: { name: api-shared-tls, namespace: new-api }
type: kubernetes.io/tls
data:
  tls.crt: <SAN = DNS:api.example-ph.com, DNS:api.example-th.com>
  tls.key: <...>
---
# 马尼拉 Ingress
spec:
  tls: [ { hosts: ["api.example-ph.com", "api.example-th.com"], secretName: api-shared-tls } ]
  rules:
    - host: api.example-ph.com
      http: { paths: [ { path: /, pathType: Prefix, backend: { service: { name: new-api, port: { number: 80 } } } } ] }
    - host: api.example-th.com        # 备用承接泰国域名
      http: { paths: [ { path: /, pathType: Prefix, backend: { service: { name: new-api, port: { number: 80 } } } } ] }
---
# 曼谷 Ingress：host 集合完全一致，只是后端指向曼谷 Service
```

**B. 单域名 + GTM（结构最简单）**

对外只暴露一个 `api.example.com`，GTM 按延迟解析到就近区域，两个区域的 Ingress 都声明该 host 与同一张证书。代价是 `SESSION_COOKIE_TRUSTED_URL`、前端 `FRONTEND_BASE_URL`、CORS 与文档中的示例域名需全部统一，且失去了「PH/TH 各自域名」的可运营性。

**C. 仅靠 GTM 不做证书对齐（禁止）**：DNS 层无法保证证书一致，必然出现证书错误。

**无论选哪种，必须补一项演练**：8.6 的季度演练目前只验证「TH 用户到马尼拉 RTT 上升 < 90 ms 且成功率不降」，需增加「**用 PH 域名从 PH 探测点访问已切换的备用区域**」用例，断言 TLS 校验通过且 `/api/status` 返回成功。

---

## 缺口二：DTS 双向同步的冲突解决策略未定义

### 证据

1. 文档对同步只有一句话描述：`impl_deploy.md:161` / `impl_tech.md:1505`

```
| 同步 | DTS | 小型 | 2 链路 | 双向增量、冲突检测、延迟告警 > 5 s | 跨区 DR |
```

   没有写：冲突判定维度、胜负规则（目标端覆盖 / 源端优先 / 报错人工介入）、冲突后的对账方式。

2. **代码中所有幂等与互斥机制都是库内约束**：

| 机制 | 位置 | 作用域 |
| --- | --- | --- |
| 订阅预扣费幂等键 `request_id` 唯一索引 | `model/subscription.go:1240` | 单库 |
| 预扣费查重（事务内 `WHERE request_id = ?`） | `model/subscription.go:1312-1318` | 单库 |
| 退款行锁 `lockForUpdate(tx)` | `model/subscription.go:1408` | 单库 |
| 系统任务 `task_id` / `active_key` 唯一索引 | `model/system_task.go:30,33` | 单库 |
| 任务状态 CAS `WHERE status = ?` | `model/task.go:533-539` | 单库 |

3. `model/task.go:524-532` 的注释明确指出 CAS 的语义边界：「if **another process** already moved the task out of fromStatus」——实现是 `WHERE status = fromStatus` 的条件 UPDATE，只对同一数据库内的并发有效。

### 影响

双库可写时，同一个逻辑操作可以在两个库各自成功一次：

- **预扣费**：两区各自的 `WHERE request_id = ?` 都查不到对方（DTS 尚未送达），两次 `Create` 各自成功。DTS 回放时对端撞唯一索引，结果取决于冲突策略：
  - 忽略 → 两库各留自己的记录，`Status` 可能一侧 `consumed`、另一侧 `refunded`，**对账永久不平**；
  - 覆盖 → 用户额度列被对端旧值覆盖，**可能退掉已消费的钱或多扣**。
- **计数器类字段**（`users.quota`、`tokens.remain_quota`、`channels.used_quota`）由「读当前值 → 计算 → 写绝对值」产生。若两区基于不同基数各写一次，行级合并后保留的是其中一次的绝对值，**不是两次效果之和**，差额静默丢失。
- 1.3 声称「计费误差 = 0，手段是 `subscription_pre_consume_records.request_id` 唯一索引 + 对账任务」——该手段**只在单库成立**。

### 修复方案

**R2-1｜明确并落地 DTS 冲突策略（必须做，配置层）**

在阿里云 DTS 控制台为两条链路显式选择冲突处理方式，并写入文档：

- 目标端覆盖（推荐用于「以主区域为准」的灾备式同步）；
- 或忽略冲突 + 冲突明细投递到 SLS，作为对账输入。

无论选哪种，**不能停留在「配置了冲突检测」这句话**——检测不等于有确定结果。需在 `impl_deploy.md` 7.2 表格中补上策略名称与判定键（主键 / 唯一键 / 时间戳）。

**R2-2｜数据面收敛为单写（首选，结构上消除冲突）**

把 DTS 双向改为**单向 + 回切重建**：

- 常态：`MNL → BKK` 单向实时同步，BKK 只读；
- 故障：GTM 切流后，BKK 侧写入本地库，**暂停反向同步**；
- 恢复：以 BKK 为源做一次校验后反向回灌，再切换回单向。

代价：违背 8.2「区域间链路劣化时本站点仍可用」的双写承诺。这是**产品决策而非技术缺陷**，必须由需求方明确取舍：要 99.95% 的「不断服」，还是要计费绝对准确。若选择保留双写，则必须同时落地 R2-3 与 R2-4。

**R2-3｜幂等键全局化**

把 `request_id` 从「服务端生成 + 库内唯一」升级为「**含区域前缀的全局唯一 ID**」（例如 `mnl-<snowflake>` / `bkk-<snowflake>`，或 ULID）。这样两区生成的键天然不同，不会互相碰撞，也便于对账时定位来源。

```go
// 生成侧（示意）：区域前缀 + 单调 ID
requestId := fmt.Sprintf("%s-%s", common.RegionID, common.GenerateUniqueKey())
```

注意：仅全局化 ID **不能**解决「同一逻辑请求在两区各扣一次」的问题，它只消除唯一键碰撞。真正的幂等仍需 R2-4。

**R2-4｜新增跨区对账任务（必须做）**

按小时比对两库同一时间窗内的：`quota_data` 聚合值、`users.quota` 累计变化、`subscription_pre_consume_records` 的状态分布。差异超阈值即告警，人工介入修账。这是「计费误差 = 0」在双写下唯一可执行的兜底。

---

## 缺口三：数据库租约去重跨区失效（代码级确认）

### 证据链

1. **锁表结构 = 每库每种任务一条锁**

```43:49:model/system_task.go
type SystemTaskLock struct {
	Type        string `json:"type" gorm:"type:varchar(64);primaryKey"`
	TaskID      string `json:"task_id" gorm:"type:varchar(64);index"`
	LockedBy    string `json:"locked_by" gorm:"type:varchar(128);index"`
	LockedUntil int64  `json:"locked_until" gorm:"bigint;index"`
	UpdatedAt   int64  `json:"updated_at" gorm:"bigint;index"`
}
```

2. **抢锁过程全部是单库操作**（`model/system_task.go:313-352`）：先 `DB.Create(lock)`，靠主键唯一冲突失败；失败后读现有锁，若 `existing.LockedUntil < now` 则执行 `WHERE type = ? AND locked_until < ?` 的条件 UPDATE 抢过来。

3. **只有 master 启动任务调度器**

```123:127:service/system_task.go
func StartSystemTaskRunner() {
	systemTaskRunnerOnce.Do(func() {
		if !common.IsMasterNode {
			return
		}
```

4. **每个区域各有一个 master**：`common/init.go:89` 定义 `IsMasterNode = os.Getenv("NODE_TYPE") != "slave"`；`impl_deploy.md:345` 要求「必须存在一个 `NODE_TYPE=master` 的 Deployment」；7.4.2 的部署顺序是「先升级 master → 再滚动 stable slave」。

⇒ **两个区域的 master 各连自己的主库，各自的 `system_task_locks` 互不可见，同一任务类型在两区同时执行。**

### 受影响任务清单

注册位置：`controller/system_task_handlers.go:20-24`

| 任务类型 | 周期 | 双区同时执行的实际后果 |
| --- | --- | --- |
| `channel_test` | 监控配置（默认 10 min） | 全部渠道被测试两遍，上游探测开销与额度消耗翻倍；两端渠道状态写入各自库后互相覆盖 |
| `model_update` | `CHANNEL_UPSTREAM_MODEL_UPDATE_TASK_INTERVAL_MINUTES`（默认分钟级） | 两区各自探测上游模型列表，可能各自自动应用到自己的库 → 渠道 `models` 字段写冲突 |
| `midjourney_poll` | 15 s | 两区各自向上游查询同一批未完成任务 |
| `async_task_poll` | 15 s | 两区各自轮询**并各自触发结算/退款** |

任务外的 master-only 后台任务同样双份执行：

| 任务 | 位置 | 备注 |
| --- | --- | --- |
| 会话 / AuthFlow 清理 | `service/auth_cleanup.go:15-21` | 幂等删除，影响较小 |
| 订阅额度重置 | `service/subscription_reset_task.go:29-35` | 绝对值写 `AmountUsed = 0`；与另一区的扣费交错时结果不确定 |
| Codex 凭证自动刷新 | `service/codex_credential_refresh_task.go:35-39` | 重复刷新上游凭证 |
| Casbin 角色 / 策略 seed | `service/authz/enforcer.go:34,57` | 两区各写一份规则，内容相同则收敛 |

### 结算环节的保护为什么不够

轮询结算确实有 CAS 保护：

```596:620:service/task_polling.go
	isDone := task.Status == model.TaskStatusSuccess || task.Status == model.TaskStatusFailure
	if isDone && snap.Status != task.Status {
		won, err := task.UpdateWithStatus(snap.Status)
		...
	if shouldFinalizeBilling {
		billingSettled := settleTaskBillingOnComplete(ctx, adaptor, task, taskResult)
		if task.Status == model.TaskStatusFailure && !billingSettled && task.Quota != 0 {
			RefundTaskQuota(ctx, task, task.FailReason)
		}
	}
```

但 `UpdateWithStatus` 是 `WHERE status = fromStatus` 的**单库条件更新**（`model/task.go:533-539`）。两库各自都满足条件、各自 `won = true`、各自结算一次。仅当两侧基数完全相同时，绝对值写入才可能收敛到相同结果；一旦一侧先扣、另一侧基于旧基数计算，差额即丢失。日志与流水则**必然各写一份**。

### 连带发现

- **日志库不参与同步**：7.2 中 ClickHouse 是「每区域 2 节点」，`LOG_SQL_DSN` 指向本区域实例，DTS 只同步主库。切区后 PH 用户的用量日志写入 CH2，控制台按区域读库 → 用户看到「历史明细丢失」。
- **统计按节点分维度**：`model/usedata.go:19-25` 的 `QuotaData` 带 `node_name` 字段并参与唯一键匹配（`:108-114`）。双区写入的是不同 node 的行，**不会双倍计数，但会分裂成两行**，看板需按区域聚合。
- **Redis 计数各区域独立**：限流额度按区域分别计数（`docs/authentication.md:20-24` 的多节点拓扑表），双区部署下全局额度最坏约为配置值 × 区域数。

### 修复方案

**R3-1｜立即（纯部署，零代码）：单点调度权**

只在一个区域运行 master：备用区域的 master Deployment 设 `replicas: 0`。

```yaml
# 备用区域（曼谷）的 master Deployment
spec:
  replicas: 0          # 平时不运行；切区时手工拉起
```

- 优点：立刻消除重复执行；迁移也只在主区域进行。
- 代价与必须补的 runbook：
  1. 备用区域 schema 不会自动迁移 → **切区前必须先在备用区域拉起 master 完成 AutoMigrate**；
  2. 切区后原区域若恢复，需先停掉原 master 再拉起备用 master，避免两个 master 并存；
  3. 切换窗口内备用区域无后台任务（轮询、清理、重置均停摆），需在 SLA 口径中明确。

**R3-2｜短期（小改动，推荐）：给租约加「调度归属」**

把锁表主键从 `Type` 改为复合主键 `(Scope, Type)`，`Scope` 取自新增环境变量（如 `TASK_SCOPE`，默认 `REGION_ID`）：

```go
type SystemTaskLock struct {
	Scope       string `json:"scope" gorm:"type:varchar(64);primaryKey"`
	Type        string `json:"type" gorm:"type:varchar(64);primaryKey"`
	TaskID      string `json:"task_id" gorm:"type:varchar(64);index"`
	LockedBy    string `json:"locked_by" gorm:"type:varchar(128);index"`
	LockedUntil int64  `json:"locked_until" gorm:"bigint;index"`
	UpdatedAt   int64  `json:"updated_at" gorm:"bigint;index"`
}
```

再配合一个「当前 active 区域」开关：两库不互通，开关只能放在两边都能读到的地方（OSS 对象 / 运维同步的 ConfigMap / 外部仲裁服务）。`StartSystemTaskRunner` 启动前与每轮 pass 中检查「本区域是否 active」，非 active 直接跳过调度。

- 迁移警告：修改主键在 SQLite 上不支持 `ALTER COLUMN`；SQLite / MySQL / PG 三者的重建行为不同，必须按 `AGENTS.md` 的三数据库要求在**真实**实例上验证迁移幂等（新建库 + 存量库各跑、连续启动两次）。

**R3-3｜长期（架构级）：把调度权外置为全局单点**

双库架构下没有全局点（Tair 也是每区域一套），因此真正的全局互斥只能来自区域外：一个部署在新加坡的轻量仲裁服务（etcd / Redis），或基于 OSS 的 CAS leader 文件。

**结论：如果坚持「双区域双向双活」，必须新增一个跨区域仲裁点；否则 R3-1 或 R3-2 是唯一务实选择。**

---

## 验证清单（验收标准）

| # | 验证项 | 方法 | 通过标准 |
| --- | --- | --- | --- |
| 1 | 备用区域能承接主区域域名 | 用 PH 域名 + PH 探测点，从客户端（含 JVM / 固定 IP 的 SDK）访问已切区的曼谷 | TLS 校验通过、`/api/status` 成功、控制台可登录、恢复时间符合 7.2 的 ≤ 60 s 或 8.4 的 ≤ 5 min |
| 2 | 完整切区演练 | 关停马尼拉 ALB，观察 GTM 探测 → DNS 切换 → 业务恢复 | 探测到切换的实测耗时；PH 用户 RTT 落入 60–90 ms；BKK 容量未过载 |
| 3 | 双主任务互斥 | 两区域 master 同时运行，注入一条 pending 的 async task | `system_task_locks` 不出现两条同类型记录；结算日志与流水只有一份；`quota_data` 不出现同 request 的两条 |
| 4 | DTS 冲突行为 | 两区域用**相同 `request_id`** 并发调用 `PreConsumeUserSubscription` | 观察到确定的合并结果（非静默覆盖）；对账任务能识别并告警差异 |
| 5 | 迁移幂等（若实施 R3-2） | 在真实 SQLite / MySQL ≥ 5.7.8 / PG ≥ 9.6 上：新建库跑一次、存量库升级跑一次、再各启动两次 | 无重复 `ALTER TABLE`、无数据/索引/约束丢失，`cd relaykit && GOWORK=off go build ./...` 通过 |
| 6 | 跨区对账 | 按小时比对两库 `quota_data` / `users.quota` / 预扣费记录状态分布 | 差异为 0；非 0 时产生可定位的告警明细 |

---

## 附：与本次核实无关但值得记录的两个事实

1. 仓库中**没有任何部署清单**（无 `deploy/` 目录、无 K8s YAML）。`impl_deploy.md` 第七章的所有 YAML 均为文档内嵌示例，落地时需从零创建并纳入 GitOps。
2. `docs/authentication.md` 是登录会话与鉴权模型的权威文档，其中「数据库是 Session 状态的最终权威，Redis 只是缓存」的结论，是判断跨区切换后能否登录的关键依据（结论：能登录，前提是 `SESSION_SECRET` 全区域一致）。
