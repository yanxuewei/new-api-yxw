## Day 4 · 验收、压测、接管演练、正式上线与移交

> **本日主线**：容量压测（任务 33）→ 备 region 接管演练（任务 36，含 49 预热前置与 39 拨测拦截）→ 限流校准（任务 51）→ 上线检查与正式发布（任务 34）→ 移交运维（任务 35）。
> **本日硬性约束**：压测与接管演练全部在 perf / 备站完成，生产压测**禁止**（会污染额度与上游配额）；M4 上午判定、M5 晚间判定，任一硬门槛不过 → 立即触发裁剪预案（§13.8），不允许"带病上线"。

### Day 4 · 任务 33｜容量与压测验收（并发 SSE 1500 / 管理面 800 QPS，场景 S1–S10）（人员A 主导 + 人员B 观测，4 人时，08:30–12:30）

**前置/状态**：Day 3 出口（M3）已过：ALB/WAF/GTM 生效、安全可观测收口、单实例容量基线 C 已实测（1500 并发 ÷ C ≤ 16 或已提配额）；perf 命名空间 `new-api-perf` 与独立库 `newapi_perf` 就绪（Day 2）；G8 `/metrics` 已合并，观测指标可抓。

**操作步骤（CLI-first）**：

1. **环境与上游**：perf 命名空间（同规格、同节点池参数、独立 DB `newapi_perf`）。上游用 **mock 上游**（可控延迟、可控 token 速率、可注入 429/5xx）。真实上游压测会把厂商打死并触发风控。

```bash
# 0) 先断言压测打的是 perf 库，不是生产库（坑 3）
psql "${PERF_DSN}" -Atc 'select current_database()'
```

期望输出：

```
newapi_perf
```

2. 部署 mock 上游：

```yaml
# 简易 mock：Nginx/Go 实现 SSE，延迟可配
apiVersion: apps/v1
kind: Deployment
metadata: {name: mock-upstream, namespace: new-api-perf}
spec: {replicas: 6, template: {spec: {containers: [{name: mock, image: ${MOCK_IMAGE},
  env: [{name: FIRST_TOKEN_DELAY_MS, value: "300"}, {name: TOKEN_INTERVAL_MS, value: "30"},
        {name: ERROR_RATE, value: "0.001"}, {name: SSE, value: "true"}]}]}}}
```

```bash
kubectl --context perf -n new-api-perf apply -f mock-upstream.yaml
kubectl --context perf -n new-api-perf get pods -l app=mock-upstream
```

期望输出：`6/6 Running`。

3. 场景矩阵（每个场景 ≥10 分钟稳态 + 3 分钟突发），执行器 `hey`/`vegeta`/`k6` 任选：

| 场景 | 内容 | 关键断言 |
| --- | --- | --- |
| S1 常态 | 500 并发 SSE，30% 命中缓存 | P95 首字 ≤ 800ms；5xx ≤0.05% |
| S2 峰值 | **1500 并发 SSE** | HPA 扩到位，无 Pending；FD/内存不触顶 |
| S3 突发 | 0 → 1500 并发 30 秒内 | 冷启动窗口错误率 ≤1%，30s 内回稳 |
| S4 管理面 | 800 QPS 登录/列渠道/看板 | 无 DB 慢查询堆积；登录限流不误伤 |
| S5 上游劣化 | 上游 50% 请求 5xx / 延迟 5s | 自身不被拖死；错误归类为 `upstream_error`；熔断生效 |
| S6 Redis 故障 | kill Tair 连接 | **降级放行而非 fail-closed**（G8）；额度不出错 |
| S7 日志库故障 | 断开 `LOG_SQL_DSN` | 业务不阻塞；降级计数上升 |
| S8 DB 主备切换 | 切换中打流 | 5xx 窗口 ≤60s 且自愈（Day 3 已演练，此处带流复验） |
| S9 长流 | 单请求 12 分钟 | **确认 ALB 600s 上限行为**（P0-5），产品侧要有明确文案 |
| S10 发布并发 | 压测中滚动发布 | 5xx = 0 |

```bash
# 示例：S2 峰值
k6 run -e VUS=1500 -e DURATION=10m perf/s2_peak_sse.js
# 示例：S3 突发（30s 内 0→1500）
k6 run -e DURATION=13m perf/s3_burst.js
```

期望输出（S2 摘要示例）：

```
http_req_failed......: 0.04%   ✓ < 0.05%
iterations...........: 540000
sse_first_token_p95..: 760ms   ✓ <= 800ms
```

4. 观测采集：抓取时**必须**同时抓以下五类，缺一不算完整报告：

```bash
curl -sG "${PROM_URL}/api/v1/query" \
  --data-urlencode 'query=sum(container_cpu_cfs_throttled_periods_total{namespace="new-api-perf"})' \
  --data-urlencode 'query2=process_open_fds' | jq . > .deploy/evidence/d4/s2-throttle-fds.json
# 另三类：pg_stat_activity 快照、NAT 出流量、WAF 拦截数（【控制台】→ Grafana/NAT 监控页导出）
```

`【控制台】Grafana 压测面板导出 S1–S10 曲线 PNG`
`[图 D4-4｜拍摄对象：压测期间 QPS/P95/错误率/HPA 副本数四联曲线；打码：Prometheus 外部访问地址、NAT EIP 明细]`

**验证方法**：以 **S2 通过 + S3 收敛 + S5/S6/S7 不致命** 为硬门槛；任何一项不过 → 触发裁剪预案讨论（延后上线 or 降 SLA 承诺），不允许"带病上线"。报告（含曲线截图）归档 `.deploy/evidence/d4/s1-s10-report.md`。

**不通过时修复**（速查表）：

| 现象 | 定位 | 处置 |
| --- | --- | --- |
| 1500 并发时 FD 打满 | `process_open_fds` 逼近 limit | nofile（Day 2 节点参数）+ 提升副本（分母）|
| CPU throttle 严重但 CPU 不高 | CFS quota 太紧 | request=limit 或去掉 limit.cpu；GOMAXPROCS |
| P95 随并发线性恶化 | DB 连接排队 | PgBouncer `default_pool_size`/连接预算（Day 1 §连接数三不变量）|
| 内存持续涨不回落 | SSE 未释放/缓冲无上限 | 检查流关闭与 `bufio` 大小；限每请求缓冲 |
| 扩容后错误率反升 | 冷连接池 + 冷缓存 | 预热（任务 49）|

**坑**：
- **坑 1｜压测客户端自己成了瓶颈。** 后果：测出"没问题"。改进：客户端与被测同 region（新加坡/马尼拉），并监控客户端 CPU/端口耗尽。
- **坑 2｜用真实 API Key 压 mock 之外的真实渠道。** 后果：产生真实费用 + 触发厂商封禁。改进：压测渠道全部 `status=disabled` 的真实渠道 + mock。
- **坑 3｜压测数据留在生产库。** 改进：perf 独立库；压测前 `select count(*) from logs` 断言不是生产库。

### Day 4 · 任务 36｜备 region 接管演练（GTM 强制切换）（人员A 操作 + 人员B 观测 + 值班双人确认，3.5 人时，13:00–16:30）

**前置/状态**：任务 33 已给出 C 基线复核（备站 24 副本 = 峰值 ×1.5/C 成立）；任务 49 预热三步与任务 39 拨测拦截逻辑已就绪；GTM 备用访问池"常驻但权重 0"决策已书面确认；`SESSION_SECRET` 双 region 同源（KMS）；发布已冻结、值班到位。这是 **M4 的唯一硬证据**，必须在本窗口内完整跑一遍。

**强制顺序（顺序错了就不是演练，是制造事故）**——由三步预热顺序驱动：

```
0) 冻结发布，通知窗口，确认主站无异常，值班到位
1) 备站预热：HPA min 抬到目标副本（按峰值×1.5/C 计算）→ 等全 Ready → 记录耗时 Tw
2) Tair / DB 连接池 warmup（预热）（任务 49）→ 记录耗时 Twarm
3) 备用访问池健康检查全绿 + WAF 规则一致性 diff
4) GTM：将 pool-sg 加入备用访问池 → 强制切换
5) 观察：dig 生效时间、备站 QPS 上升曲线、错误率、P95、DB 连接数
6) 稳定 15 分钟 → 回切主站 → 再稳定 10 分钟
7) 出报告：切换耗时、影响面、回切耗时、发现的问题与整改项
```

> **两条不可交换的顺序约束**：① **先抬 HPA、再切流量**——反过来做等于让 2 副本冷集群瞬间接全站流量，冷启动加 JIT 加连接建立会把 P95 拉到分钟级，然后被 GTM 判不健康又切回去，形成抖动；② **先 warmup、再入池**——Tair 未预热时命中率接近 0，所有请求穿透到马尼拉主库，跨区 RTT 会把连接占用时间放大 5~10 倍，最容易在这里触发 `too many clients`。

**操作步骤（CLI-first）**：

1. 抬备站 HPA（目标 **24 副本**，即主站峰值 16 副本 × 1.5）：

```bash
kubectl --context sg -n new-api patch hpa new-api -p '{"spec":{"minReplicas":24}}'
time kubectl --context sg -n new-api wait --for=condition=available \
  --timeout=20m deploy/new-api
kubectl --context sg -n new-api get pods -l app=new-api -o wide | awk 'END{print NR-1}'
```

期望输出：`24`，把 `time` 的 real 值记为 **Tw** 写入报告。

2. 执行任务 49 的 warmup（记录 **Twarm**），随后校验备用访问池健康与 WAF 一致性：

```bash
diff <(jq -S 'del(.InstanceId,.RequestId)' /tmp/waf-mnl.json) \
     <(jq -S 'del(.InstanceId,.RequestId)' /tmp/waf-sg.json)
```

期望输出：空（两条规则集一致）。

3. `【控制台】` GTM「全局流量管理 → 访问池切换」：pool-sg 加入备用访问池并**强制切换**（或 OpenAPI 调权重/摘主访问池）；操作人 + 值班第二人双确认。
`[图 D4-1｜拍摄对象：GTM 强制切换前后的访问池状态与权重；打码：账号 UID、ALB DNS 名之外的内部标识]`

4. 取证：DNS 生效与切换窗口数据（含 **0–120s DB QPS / P99 曲线**，见任务 49 验收）：

```bash
dig +short api.likha.com @8.8.8.8   # 期望：返回新加坡 ALB 地址，记录首个生效时间
curl -sG "${PROM_URL}/api/v1/query_range" \
  --data-urlencode 'query=sum(rate(newapi_db_query_seconds{quantile="0.99"}[30s]))' \
  --data-urlencode "start=${T_SWITCH}" --data-urlencode "end=$((T_SWITCH+120))" \
  --data-urlencode step=5s > .deploy/evidence/d4/takeover-0-120s-p99.json
```

5. 稳定 15 分钟 → GTM 回切主访问池（`【控制台】`，同 D4-1 补拍回切后状态）→ 再稳定 10 分钟；**主站恢复后等待 ≥15 分钟再回切**的规则一并演练记录。

**验证方法**（判据全过才允许把演练记为 M4 通过）：

| 指标 | 通过标准 |
| --- | --- |
| 授权切换 → 备用访问池加入 → GTM 解析到 SG ALB 完成 | ≤ 90 秒（其中含 DNS TTL 60s 理论值） |
| 预热耗时 Tw + Twarm | 若走"自动感知故障"路径则全部计入 RTO；M4 口径要写清 |
| 切换期间用户侧错误率 | 由 §12 排除项口径决定；目标 ≤0.5% 且无 5xx 尖刺持续 >60s |
| 会话保持 | 主站签发的 token 在备站直接可用（无 401 潮） |
| 额度一致性 | 切换前后 `sum(quota)` 对账差异 = 0 |
| 回切 | 同样 ≤90 秒，且主站无需重启即承接 |
| 客户端真实迁移 | SG ALB 访问日志中新连接来源占比上升（不止验 GTM 解析） |

**不通过时修复**：预热不足 → 复核任务 49 清单；`too many clients` → 按连接数三不变量复核 24×连接池洪峰预算（§5.6 三不变量），必要时降 `default_pool_size` 并提 `max_connections` 配额；GTM 抖动 → 检查健康探测阈值与 warmup 是否提前入池；对账差异 ≠ 0 → 先查 `BATCH_UPDATE_ENABLED` 合并写未落库窗口（见 12.3 风险表），停回切、留现场。

**坑**：
- **坑 1｜为了"演练顺利"提前把备用访问池加入生产 GTM。** 后果：真实故障时无法解释"为什么没切"或"为什么乱切"。改进：加入备用访问池本身就是**变更**，需审批；演练报告里明确"备用访问池常态是否常驻"的最终决策（推荐：**常驻但权重 0**，切换由自动化 + 人工双确认）。
- **坑 2｜接管后发现新加坡的渠道配置/费率与主站不同。** 后果：计费错误（资金事故）。改进：配置以**同一 DB** 为唯一事实源（本方案正是如此），但要确认 `MEMORY_CACHE_ENABLED=false` 且备站已完成一轮 `SYNC_FREQUENCY` 收敛。
- **坑 3｜接管后限流失效。** 两侧 Redis 计数独立 → 接管瞬间用户可短时超量。改进：明确"接管后限流重新计数"是可接受行为并写进口径；对高价值用户可加 DB 侧兜底额度检查。
- **坑 4｜回切时机太早。** 备站刚预热就切回，等于把预热的算力丢掉，且真实故障时同样会反复抖动。改进：演练里包含"**主站恢复后等待 ≥15 分钟再回切**"的规则并写入应急预案。
- **坑 5｜只验 GTM，没验"客户端真的换过去了"。** 部分 SDK 长连接/DNS 缓存不重解析。改进：验证里包含"新连接建立到 SG ALB 访问日志的来源占比"。

### Day 4 · 任务 49｜备 region Tair 预热与接管前 warmup（人员B，1.5 人时，13:20–14:30，并入任务 36 第 1–3 步之间执行）

**前置/状态**：本卡是任务 36 的**前置独立小节**：在 36 第 1 步（HPA 抬满、Pod 全 Ready）之后、第 4 步（GTM 入池切换）之前执行；备站 Tair 实例与 `newapi_sg` 数据库账号已就绪。接管瞬间的三件冷启动：**DB 连接池、Redis 缓存（渠道/用户/配置）、JIT/连接握手**。

**操作步骤（CLI-first）**：

```bash
# warmup Job（切流前跑，也可作为接管自动化的一步）
kubectl --context sg -n new-api create job warmup --image=${ACR_SG_PREFIX}:${SHA} -- sh -c '
  i=0
  while [ $i -lt 30 ]; do
    wget -qO- "http://127.0.0.1:3000/api/status" >/dev/null
    i=$((i+1)); sleep 1
  done'
# 真实预热要对热点键：按 top-N 活跃用户/渠道各拉一次轻量读接口
```

预热清单（逐项打勾）：

| 对象 | 做法 | 验收 |
| --- | --- | --- |
| DB 连接池 | `initContainer` / warmup 请求打并发读 | `pg_stat_activity` 里 `newapi_sg` 达到 `min_pool` 且无 handshake 失败 |
| Tair | 预载渠道配置、模型列表、费率（`redis-cli --pipe` 或后台导出） | 接管后前 60s 的 **DB QPS 不出现尖刺**（关键指标） |
| HTTP 上游连接 | 预建 TLS 会话（打一次 `/v1/models` 类轻接口） | 首批请求 P99 不劣于稳态 1.5× |
| Pod 磁盘/页缓存 | 日志目录预创建 | 无首写延迟 |

**验证方法**：接管演练（任务 36）报告里必须有一张"**接管后 0–120s 的 DB QPS / P99 曲线**"（取证文件 `.deploy/evidence/d4/takeover-0-120s-dbqps-p99.png`，数据源 JSON 同目录）。有 warmup 与无 warmup 各跑一次对比（在 perf 环境）。

`[图 D4-2｜拍摄对象：接管后 0–120s DB QPS 与 P99 双轴曲线（有/无 warmup 两条对比）；打码：RDS 内网地址、监控面板账号信息]`

**不通过时修复**：前 60s DB QPS 尖刺 → Tair 预载键集不全，补齐渠道/费率/模型列表三类并核对 TTL；`newapi_sg` 连接数不足 `min_pool` → 检查 initContainer 是否被 PDB/资源配额卡住；首批 P99 超 1.5× → 上游 TLS 预建未生效，确认 `/v1/models` 轻接口真的穿透到了 mock/上游。

**坑**：
- **坑 1｜预热键与生产 TTL 不一致，接管后立刻过期。** 改进：预热带原 TTL 或从主站 Redis `DUMP/RESTORE` 迁移（跨区需走安全通道，不要 `KEYS *` 扫全库）。
- **坑 2｜warmup 脚本打的是写接口。** 后果：制造垃圾数据/额度。改进：**只打幂等读接口**。

### Day 4 · 任务 39｜备 region 链路拨测与告警（不健康时阻止接管）（人员B，1 人时，10:30–11:30 复核，全天常驻生效）

**前置/状态**：拨测基线（blackbox + 云监控站点监控 + GTM 探测三重之一）Day 3 已建立；本窗口在任务 36 之前**复验"不健康→阻止接管"闭环**一次。接管的前提是"链路健康"。这条链路（SG→MNL RDS 公网）本身就是**接管期的唯一生死线**。

**操作步骤（CLI-first）**：

```yaml
# blackbox-exporter 探测 TCP 5432 + PG 握手
modules:
  tcp_pg:
    prober: tcp
    timeout: 5s
  pg_auth:
    prober: http
    # 用 sidecar 跑 psql -c 'select 1' 并暴露 /healthz 由 G8 提供
```

```bash
kubectl --context sg -n monitoring get deploy blackbox-exporter
curl -s "http://blackbox.monitoring:9115/probe?target=${RDS_MNL_PUBLIC_HOST}%3A5432&module=tcp_pg" \
  | grep probe_success
```

期望输出：`probe_success 1`。

告警规则（P1 联动 GTM 备用池权重置 0 的自动化脚本 `prevent-takeover.sh` 已注册到 Alertmanager webhook）：

| 条件 | 级别 | 动作 |
| --- | --- | --- |
| SG→MNL RDS TCP 探测失败率 >10%（1min） | **P1** | 电话 + **自动禁止 GTM 切到备用访问池**（把备用访问池权重置 0） |
| RTT p95 > 150ms 持续 5min | P2 | 通知，接管前需人工确认 |
| `newapi_sg` 连接数 > 预算 80% | P2 | 阻止继续扩容备站副本 |
| TLS 握手失败（证书到期/地址漂移） | **P1** | 立即，接管能力视为失效 |

**验证方法**：临时把 SG 一个弹性公网 IP（EIP）从 RDS 白名单摘掉，复验后加回：

```bash
# 摘掉 SG 白名单中的一个 EIP（列表为其余 7 个）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_INSTANCE} \
  --SecurityIps "${SG_EIP_WHITELIST_WITHOUT_ONE}"
# 期望：3 分钟内 P1 电话触达 + GTM 备用访问池权重被自动置 0
# 复验完成后立即加回：
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_INSTANCE} \
  --SecurityIps "${SG_EIP_WHITELIST_FULL}"
# 期望：告警自动回正，备用访问池权重恢复
```

**不通过时修复**：P1 未触达 → 查 Alertmanager webhook 与电话通道余额（云监控电话告警国际站可用性必须先实测，不可用则 ARMS/第三方值班并在验收记录实际通道）；权重未置 0 → 查 `prevent-takeover.sh` 的 OpenAPI 凭证与幂等锁；探测自身造成连接压力 → 降频到 ≤10s 并用独立低权限账号。

**坑**：
- **坑 1｜"链路不健康就阻止接管"在真故障时可能是致命逻辑。** 后果：主站挂了 + 链路恰好也不稳 → 系统**拒绝接管** → 全站不可用（本想保数据一致，结果放弃了唯一可用性）。改进：这是**产品决策**，必须与 SLA 口径（G12）一起签字确认。建议折中：链路"完全不通"→ 阻止并电话；链路"劣化（RTT 高）"→ **仍然接管**（劣化可用 > 完全不可用）。
- **坑 2｜拨测探测本身消耗 RDS 连接。** 改进：探测复用连接或用独立低权限账号 + 频率 ≤10s。

### Day 4 · 任务 51｜上游渠道 RPM/TPM 配额盘点与限流参数校准（人员B + 商务/TAM，2 人时，16:30–18:30）

**前置/状态**：任务 33 已实测单实例容量基线 C（副本容量口径成立）；Day 0 前厂商白名单/配额工单已批复（外部等待项不占本日窗口）；`GLOBAL_API_RATE_LIMIT` 与单用户限流默认值（360 请求/180s 为代码默认）已在 Day 2 ConfigMap 落地。

**操作步骤（CLI-first）**：

| 步骤 | 内容 |
| --- | --- |
| 1 | 逐渠道登记：RPM、TPM、并发上限、突发桶、超额行为（429 硬拒 / 排队 / 降级） |
| 2 | 按 **8 个 EIP 合计** 与厂商确认白名单+配额是否按 IP 维度计 |
| 3 | 把业务峰值 QPS（C × 副本）折算成 RPM，与配额比对，得出**真实系统上限** |
| 4 | 校准 `GLOBAL_API_RATE_LIMIT`：应用侧限流应**严于**上游配额（宁可自己 429，也不要被上游封） |
| 5 | 设计超额降级：渠道 failover 顺序、超时与重试预算（避免重试放大） |

```bash
# 步骤 3：折算（示例，C 以实测值替换）
python3 - <<'EOF'
C = float(open('.deploy/evidence/d4/capacity-C.csv').read().splitlines()[1].split(',')[1])
print("peak RPM =", int(16 * C * 60))   # 主站 16 副本口径
EOF

# 步骤 4：核对生产限流参数已按校准值下发
kubectl --context mnl -n new-api get cm new-api-config -o jsonpath='{.data.GLOBAL_API_RATE_LIMIT}'
```

盘点表归档 `.deploy/evidence/d4/upstream-quota-roster.csv`；`【控制台】` 各厂商控制台配额页逐项截图登记。
`[图 D4-3｜拍摄对象：厂商控制台 RPM/TPM 配额与实测超额行为（429/排队）页；打码：API Key、账号邮箱、账单余额]`

**验证方法**：`curl` 打满应用限流阈值 → 期望应用侧 429，且上游侧观测不到超额 RPM（厂商控制台确认）；渠道 failover 在注入 5xx 后 ≤10s 生效。

```bash
for i in $(seq 1 400); do
  curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer ${RATE_TEST_TOKEN}" -H 'Content-Type: application/json' \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}]}' \
    https://api.likha.com/v1/chat/completions
done | sort | uniq -c
# 期望：约前 360 个 200/流式成功，其余 429（带 Retry-After）
```

**不通过时修复**：应用未先 429 → 检查 `GLOBAL_API_RATE_LIMIT` 是否被 ConfigMap 收敛窗（30s）延迟或 Redis 计数失效；上游已超额仍 200 → 限流值与配额表不符，回步骤 1 重盘点；failover >10s → 查熔断阈值与渠道权重表。

**坑**：
- **坑 1｜把限流值设成"厂商给的配额"。** 后果：所有租户共享配额，一个突发用户吃光全站 → 全员 429。改进：**全局配额 + 单用户配额**双层；单用户默认值保守（360/180s 已是代码默认）。
- **坑 2｜上游配额是"按 key"而接管后新加坡用同一 key。** 后果：主备共享配额，接管后并发翻倍直接撞墙。改进：主备分 key 或与厂商确认；在风险表记为 R-上游配额。
- **坑 3｜重试无预算。** 后果：一次上游抖动引发重试风暴把配额瞬间打光（retry storm）。改进：指数退避 + 重试预算 ≤10% + 熔断。

### Day 4 · 任务 34｜上线检查表、发布窗口冻结与正式上线（全员，2.5 人时，19:30–23:30）

**前置/状态**：本日任务 33/36/49/39/51 全部通过并归档证据；19:30 起发布窗口冻结（只允许回滚，不允许功能变更）；商务在场完成 G12 口径签字。

**操作步骤（CLI-first）**——上线检查表（全部为"是"才允许切 DNS 到生产入口）：

```
【门禁】
☐ G0 13 项全过（前置打勾表已归档；4 天口径下须在 Day 0 前完成）
☐ M1–M4 证据齐，无未闭环 P0/P1 缺陷
【容量与韧性】
☐ S2(1500 并发)/S3(突发)/S5/S6/S7 场景通过
☐ 单实例容量 C 实测；16 副本能扛 1.5× 峰值
☐ 备站 24 副本可达 + warmup 时长实测
☐ RDS 主备切换演练通过；PITR 演练通过（RPO/RTO 实测）
☐ 备 region 接管与回切演练通过，额度对账 0 差异
【安全】
☐ 安全核查 15 项通过或已签字豁免
☐ 白名单：RDS 三组 / 8 EIP 上游 / 支付回调三层 全通过
☐ 证书：SNI 校验、链完整、到期 ≥25 天、自动续期任务在
☐ 无 0.0.0.0/0 入向非 80/443；伪造 Host 反例返回非 200
【可观测】
☐ SLO 看板数字与原始查询一致；P1 电话实测触达
☐ 三重拨测（GTM/云监控站点监控/blackbox）独立产出
☐ 日志脱敏抽查通过；audit 180 天投递可查
【运维】
☐ 运维访问面：私网端点、最小 RBAC、60min kubeconfig、变更审批
☐ Runbook 与应急预案评审通过，值班表生效
☐ 成本看板与预算告警（80%）生效
【商务/口径】
☐ G12 SLA 五条口径 + 4 排除项书面签字
☐ 泰国用户接入马尼拉（RTT 55–80ms）偏差已书面说明
☐ 发布窗口冻结期已通知（建议上线后 72h）
```

正式上线步骤：

```bash
# 1) DNS 正式切到 GTM（若之前直连 ALB 做验收）
dig +short api.likha.com @8.8.8.8
# 期望：返回 GTM 接入地址（而非直连 ALB DNS 名）
# 2) 小流量观察（若有灰度开关/白名单用户优先放行）
# 3) 30/60/120 分钟三次快照：错误率、P95、DB 连接、上游 429、账单速率
#    快照导出到 .deploy/evidence/d4/release-snapshot-{30,60,120}.json
# 4) 宣布上线完成，进入 72h 冻结窗口（只允许回滚，不允许功能变更）
```

**验证方法**：上线判定依据是 **SLO 面板 + 拨测**，不是 `rollout status`；三次快照（30/60/120 分钟）各项均在基线带内且检查表勾选已签字归档 `.deploy/evidence/d4/go-live-checklist-signed.md`。
`[图 D4-5｜拍摄对象：上线后 30/60/120 分钟 SLO 面板（错误率/P95/上游 429/账单速率）；打码：用户标识、账单明细金额]`

**不通过时修复**：任一项为"否"→ **不切 DNS、不上线**，回到对应任务卡修复后仅复验失败项与受牵连项；快照异常 → 按回滚 SOP 回滚（回滚方案已在 Day 3 演练，发布后 24h 内回滚必须可用，expand-contract 保证 24h 内不 Contract）。

**坑**：
- **坑 1｜上线即改配置。** 后果：出问题无法归因（是新版本还是新配置？）。改进：冻结窗口内**只回滚不前进**。
- **坑 2｜回滚方案未演练。** 后果：真要回时才发现 DB 已 Contract。改进：明确"发布后 24h 内回滚必须可用"，且 expand-contract 保证 24h 内不 Contract。
- **坑 3｜把"部署成功"当"服务健康"。** 改进：上线判定依据是 **SLO 面板 + 拨测**，不是 `rollout status`。

### Day 4 · 任务 35｜移交运维（人员C（运维主导）+ 人员A/B 交底，3 人时，17:00–20:00 备料，上线签字后生效）

**前置/状态**：任务 34 检查表"运维"段全过；Runbook/应急预案评审已通过；4 天口径下移交包在上线前完成备料、上线签字后双方签署生效。移交物（每项都要有可执行路径，不接受"口述"）：

**操作步骤（CLI-first）**：

按九件套逐项核对，缺任一件不允许签字：

| 交付 | 内容 | 验收方式 |
| --- | --- | --- |
| Runbook | P1 场景 × 处置：站点不可用 / DB 不可写 / Redis 挂 / 上游全挂 / 证书到期 / 备站接管 / 回切 / 密钥轮换 | **新人照做能恢复一次**（在 perf 抽考） |
| 应急预案 | 全部条目 + 决策树 + 联系人升级路径 | 桌面推演一次 |
| 值班表 | 2 人轮换 + 项目负责人升级；P1 电话可达 | 实拨一次 |
| 拓扑与访问路径图 | VPC/SG/NAT/ALB/WAF/GTM/ACK/RDS 全链路 + 运维入口 | 评审签字 |
| 权限矩阵 | RAM ↔ RBAC ↔ 白名单 ↔ 密钥归属 | 抽查 3 个身份 |
| 成本看板 | 上季度实际 + 弹性敏感度 + 超预算处置阈值 | 能按标签（tag）出账 |
| 已知限制清单 | 21 项差异中的残余项（如 APM 未确认、马尼拉 2AZ、600s 上限、DTS 决策理由、接管后限流重计数） | **接手方确认知悉** |
| 巡检节奏 | 日：错误预算/账单突增/回调 4xx；周：migrate up-down-up、备份恢复抽样、证书剩余天数；月：白名单漂移、EIP 一致性 | 日历/工单已建 |
| 变更 SOP | 灰度权重推进、SESSION_SECRET 轮换、节点池扩缩、DNS/GTM 变更 | 每 SOP 有一次演练记录 |

抽考用 CLI 取证示例（新人按 Runbook 在 perf 独立复现一次故障恢复）：

```bash
kubectl --context perf -n new-api-perf exec deploy/new-api -- sh -c \
  'wget -qO- http://127.0.0.1:3000/api/status' | jq -r .status
# 期望：恢复动作完成后返回正常 status；全过程录屏 + 命令历史归档
```

移交文档索引归档 `.deploy/evidence/d4/handoff-9kit.md`（九件套各自路径 + 抽考记录 + 影子值班排班表）。

**验证方法**：九件套逐项签字 + 新人抽考通过 + **2 周影子值班**计划落地（Day 5–Day 18：运维主导、原执行人旁观，验收单双方签字）。

**不通过时修复**：抽考失败 → 修订 Runbook 对应条目后 24h 内重考一次（4 天口径下不允许无限轮次，两次失败则上线暂缓，走裁剪预案）；权限矩阵抽查不通 → 按最小权限补 RBAC 绑定并重新出表。

**坑**：
- **坑 1｜移交 = 丢文档。** 后果：D10 起所有问题回来找原执行人，等于没移交。改进：安排 **2 周影子值班**（运维主导、原执行人旁观），并在验收单上双方签字。
- **坑 2｜已知限制没写下来。** 后果：接手方把架构决策当 bug 反复排查（典型："为什么不建新加坡库""为什么 ALB 入向是全开"）。改进：`impl_deploy.md` 与本指南差异表一起归档，并在每个"看起来像漏洞"的配置旁写一句 reason（**注释即文档**）。
- **坑 3｜密钥归属不清。** 后果：轮换无人执行、到期才发现。改进：每个 KMS Secret 有 owner + 轮换周期字段（网络与安全规划表已列，交接时复述）。

### Day 4 出口（M5）

```
☐ S1–S10 全场景压测报告（含曲线截图）
☐ 备 region 接管/回切完整演练报告（0–120s DB QPS 与 P99 曲线）
☐ 上线检查表 100% 勾选并归档
☐ 正式发布完成，72h 冻结窗无 P1/P2（冻结窗延续至 Day 5–Day 7）
☐ 移交包九件套齐全 + 新人抽考通过 + 2 周影子值班计划落地
```

---

## 里程碑与验收（4 天口径重排）

> 本节将 v2.1 的 D1–D9 里程碑（原 M1=D1–D2、M2=D3–D4、M3=D5–D6、M4=D7–D8、M5=D8–D9）重排到 4 天日历。**判定标准与出口证据内容不变，只压缩时间跨度**；证据目录约定为 `.deploy/evidence/<d1|d2|d3|d4>/`，每项都必须是"可点开看的产物"（命令输出、导出文件、截图），不接受口头汇报。

### 门禁与里程碑（M1–M5，4 天口径）

| 里程碑 | 判定 | 出口证据（必须可点开看） |
| --- | --- | --- |
| **G0（Day 0 前）** | T-5/T-3 十三项前置全部完成（**4 天口径下全部提前到 Day 0 之前**，任一项"已提工单待回"= 未过，D1 不得启动） | 实名批复截图、配额工单批复号、`dig` NS 生效输出、证书签发详情（含 Sans/到期）、11 类产品开通列表、**G8 合并 commit + CI 绿**、连接数预算表、SLA 口径签字页、staging 方案确认 |
| **M1（Day 1 出口：网络 + 数据底座）** | VPC/10 vSwitch 网段照 §2.2 落地且地址基线记录；RDS 高可用两 AZ、Tair、日志库决策全部就绪 | `.deploy/evidence/d1/vswitch-ip-baseline.txt`（`DescribeVSwitchAttributes` 的 `AvailableIpAddressCount`）；`d1/rds-ha-status.png`【控制台】两 AZ 主备状态；`d1/tair-policy.txt`（`allkeys-lru` 输出）；`d1/ck-decision.md`（ClickHouse A0/A/B/C 决策落地）；`d1/eip-roster.csv`（8 EIP 登记）；`d1/sg-bindings.txt`（SG 绑定 `sg-mnl-app`，非 127.0.0.1） |
| **M2（Day 2 出口：集群 + 应用底座 + 入口）** | 双集群跨 AZ 可调度、镜像流水线通、stable 与备站跑通、主站 token 在备站可用 | `d2/nodes-zones.txt`（两集群 `kubectl get nodes` 跨 AZ）；`d2/node-fd-limit.txt`（`ulimit -n`=200000）；`d2/migration-idempotent.txt`（master 二次启动 DDL=0）；`d2/stable-sg-running.txt`；`d2/cross-region-token.json`（主站 token 在备站可用） |
| **M3（Day 3 出口：安全可观测 + 演练）** | ALB/WAF/GTM 对外生效、安全收口、三重拨测、灰度与故障演练全过 | `d3/alb-waf-gtm.txt`（生效验证）；`d3/sg-negative-test.txt`（SG 反例自查输出为空、伪造 Host 非 200）；`d3/triple-probe.md`（GTM/云监控站点监控/blackbox 独立产出）；`d3/canary-weights.txt`（5/20/50/100 权重实测 + 归零 ≤30s）；`d3/security-audit-15.md`（15 项含豁免单）；`d3/rds-failover-60s.json`（主备切换 5xx 窗口 ≤60s 且自愈、额度对账 0 差异）；`d3/config-sync.txt`（30s 跨副本 + 60s 跨 region 收敛） |
| **M4（Day 4 上午～午后：容量与接管）** | 压测硬门槛过 + 接管演练判据全过（**本日任务 33/36/49/39 即其证据来源**） | `d4/capacity-C.csv`（单实例容量 C 表；1500 并发 ÷ C ≤ 16）；`d4/s1-s10-report.md`（含曲线截图）；`d4/hpa-scaling.txt`（主站 4–16 与备站 2–24 实测）；`d4/warmup-tw.txt`（备站 24 副本预热耗时 Tw/Twarm 实测）；`d4/takeover-0-120s-dbqps-p99.{json,png}`；`d4/takeover-report.md`（接管/回切 ≤90s、会话保持、对账 0 差异） |
| **M5（Day 4 晚：上线 + 移交）** | 正式发布完成 + 移交生效 | `d4/go-live-checklist-signed.md`（上线检查表 100% 勾选归档）；`d4/sla-caliber-signed.md`（SLA 五条口径 + 4 排除项书面签字）；`d4/release-snapshot-{30,60,120}.json`；`d4/handoff-9kit.md`（移交九件套 + 抽考记录 + 2 周影子值班计划）；72h 冻结窗监控延续记录（Day 5–Day 7） |

### SLA 99.95% 判定口径（与 G12 一致，必须书面签字）

以下五条口径与四条排除项为 G12 签字件原文，**原样保留，不因压缩工期而调整**：

- **测量源**：三重拨测（GTM 健康探测 ∪ 云监控站点监控 ∪ 集群外 blackbox），任一源判定"不可用"即计入；窗口 = 自然月。
- **不可用定义**：`GET /api/status` 在 3 个连续探测周期（45s）内失败 **或** 业务写接口 5xx 率 >5% 持续 ≥60s。
- **月度预算**：21.6 分钟；按 5min 粒度做燃烧率告警。
- **排除项（四条，逐条要客户确认）**：
 ① 上游模型厂商自身故障/限流（按 `upstream_error` 指标区分，非自身 5xx）；
 ② **region 级整体故障**（马尼拉 AZ/region 全挂）—— 因本次交付不含第三 region 主库，此类场景 RTO 由 RDS 恢复时间决定（实测 1.5–4h），**不构成违约**；
 ③ 计划内维护窗口（提前 48h 通知、月累计 ≤30 分钟、且落在业务低谷）；
 ④ 客户端 DNS 缓存导致的切换滞后（GTM TTL 60s 之后的部分）。
- **延迟口径**：主站常态 P95 首字 ≤800ms；**接管期**（流量在备 region）放宽至 ≤1500ms（跨区 SQL RTT 所致，Day 1 实测支撑）。
- **单请求上限**：ALB 600s 硬上限（P0-5），超 600s 的长任务须走异步 —— **产品文档与合同须一致说明**。
- **交付范围偏差声明**：泰国用户接入马尼拉（RTT 55–80ms），与 `impl_deploy.md` 1.2"主站点不能只放一个区域"的结论存在偏差；泰国为二期。

### 关键风险与残余（上线时仍存在的）

原 12.3 风险表**原样保留**，并按 4 天口径追加 g9i 机型与 `BATCH_UPDATE_ENABLED` 两行：

| 风险 | 现状 | 残余处置 |
| --- | --- | --- |
| 上游配额与白名单依赖外部审批 | 8 EIP 已确认，配额按 key 共享 | 主备分 key 谈判；应用侧限流严于配额 |
| ClickHouse 马尼拉不可用（P0-1） | 按日志库决策树选定方案落地 | 若选跨区方案：接管期日志延迟，日志不作为 SLA 证据源 |
| `/healthz`/`/readyz`/`/metrics` 未注册 | 探针降级用 `/api/status` | **G8 未完成则 SLA 承诺应下调**（DB 故障时无法自动摘流/扩容滞后） |
| ARMS APM 马尼拉未确认（P1-12） | 不纳入证据链 | 上线后提工单确认，再启用链路追踪 |
| 马尼拉仅 2 AZ（P1-8） | 3AZ 方案不可行 | 接受；region 级故障走排除项② |
| Managed Grafana 不在马尼拉（P1-11） | 建在新加坡 | 跨区看板读取延迟，非生产链路依赖 |
| 会话在接管后依赖两侧同 SESSION_SECRET | 已统一 KMS 源 | 轮换 SOP 强制双 region 同步；任务 36 覆盖 |
| Redis 独立导致接管后限流重计数 | 已知行为 | 写进口径；高价值用户 DB 侧兜底 |
| **g9i 机型依赖（原方案 g8i 全系未在马尼拉上架，2026-09-25 API 实测）** | 节点池已改 `g9i.2xlarge` 首位 + `g8ine.2xlarge`/`g9ae.2xlarge` 多机型 + 双可用区；§2.1 request/limit 按 g9i 实际 vCPU 重算 | 残余：g9i 单 AZ 库存波动 → Day 2/Day 4 扩容前各复跑一次 `DescribeAvailableResource`；库存告急时按机型列表顺延并复核 HPA 上限；**4 天口径下不允许压测当天首次验机型** |
| **`BATCH_UPDATE_ENABLED` 额度批量合并写的丢失窗口** | 额度增量先在内存按行聚合、按 `BatchUpdateInterval` 定时落库；Pod 优雅退出会 flush，但崩溃/SIGKILL 丢失至多一个周期的增量 | 接管/切换对账"差异 = 0"须在无流量稳定期读取 `sum(quota)`；`terminationGracePeriodSeconds` ≥ 合并周期；真实故障强杀场景对账容差 = 2× `BatchUpdateInterval`，超出即按额度事故升级；此残余写入已知限制清单交运维知悉 |

### 4 天压缩的已知取舍

对照 v2.1 的 9 天口径（D1–D9），v2.0 压缩为 4 天日历引入以下**明示风险**，签字方（开发/运维/商务）须逐条确认知悉：

1. **外部等待项必须在 Day 0 前完成，工期压缩不压缩审批**。实名审核、双 region 配额批复、域名 NS 生效、通配符证书签发、上游白名单与配额确认等均为 24–48h 起的外部依赖，不可并行进 Day 1–Day 4。G0 规则不变：任一项"已提工单待回"= 未过，Day 1 不得启动；Day 0 未完成即整体顺延，严禁边等边建。
2. **演练项无重排缓冲**。v2.1 中压测、接管演练、PITR、灰度分布在 D6–D9 有回炉余地；4 天口径全部压入 Day 3–Day 4，任一硬门槛（S2/S3/S5/S6/S7、接管判据表、拨测拦截闭环）失败即当场触发裁剪预案（延后上线 or 降 SLA 承诺），**没有"明早重练一次"的窗口**；失败复验仅限当日、且仅限失败项。
3. **人力缺口：3–4 人 × 10–12h**。v2.1 按人员A/人员B 两人 × 9 天排布（≈18 人日）；4 天口径要求至少 **3–4 人**（A 接入/集群、B 数据/可观测、C 运维接管、商务/TAM 外部接口）× 每日 10–12 小时，且 Day 4 晚发布窗口需额外轮值第三人在场。任何角色单点（如仅人员B 会 PgBouncer 连接预算）无人可替时，对应里程碑自动顺延，不得"换生手硬上"。
4. **未压缩项声明**：72h 发布冻结窗、2 周影子值班、SLA 五条口径与 4 排除项、G8 代码门禁、PITR/对账标准**均不在压缩范围内**，维持 v2.1 原值；压缩只发生在日历跨度与并行度上。
