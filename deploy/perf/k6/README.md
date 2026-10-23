# 任务 33 压测工具（k6，雅加达 `new-api-perf`）

> 2026-10-20 从一次性 /tmp 脚本整理而成，统一走 `deploy/lib/ack_remote_jkt_dev.sh`（云助手 → 节点内 kubectl）。
> 客户端必须与被测同集群（坑 1：客户端自己成为瓶颈会测出"没问题"）。

## 目录

| 文件 | 位置 | 作用 |
|---|---|---|
| `sse.js` | 集群内 k6 | SSE 打流；`VUS`/`DUR`/`BASE`/`MODEL`/`TOKEN` 全走 env；首字用 `http_req_waiting`(TTFB) 代理 |
| `run.sh` | 本机 | 入口：打包 `sse.js` + 动作体，投递到节点执行 |
| `bodies/stage.sh` | 节点 | 单档压测（恒定 VU × DUR），采 CPU 峰值并打印摘要；`REQ_REPLICAS` 可先 scale 再压 |
| `bodies/dual1500.sh` | 节点 | 双副本并行（master/slave 各 `VUS_EACH`，默认 750+750=1500） |
| `bodies/scale.sh` | 节点 | 只调副本数并等就绪（压测后恢复现场） |
| `bodies/summary.sh` | 节点 | 打印 k6 Job 摘要（不传参=最近 3 个） |
| `bodies/readback.sh` | 节点 | 只读回读：副本/CPU/mock 指标/Service 端点/DNS 自检 |

## 用法

```bash
# 单档定点
bash deploy/perf/k6/run.sh stage perf-new-api-slave 300 120s

# 阶梯递增找瓶颈（自动破线即停）
bash deploy/perf/k6/run.sh ramp perf-new-api-slave            # 300→3000，步长300，每档90s

# 副本阶梯：先 1 副本压到瓶颈，再扩到 2 副本用同一套参数重压
bash deploy/perf/k6/run.sh ladder perf-new-api-slave          # 默认 1,2 副本
bash deploy/perf/k6/run.sh ladder perf-new-api-slave 600 600 6000 90s 1,2,3

# 压完恢复现场
bash deploy/perf/k6/run.sh scale 2

# 1500 并发验收（双副本并行）
bash deploy/perf/k6/run.sh dual1500            # 默认 750+750 × 120s
bash deploy/perf/k6/run.sh dual1500 900 90s   # 也可自定义每副本 VU 与时长

# 看结果
bash deploy/perf/k6/run.sh summary                 # 最近 3 个 job
bash deploy/perf/k6/run.sh summary k6-1500-m k6-1500-s

# 环境自检（跑前先看一眼）
bash deploy/perf/k6/run.sh readback
```

## 口径与已知边界

- **首字延迟 = `http_req_waiting`（TTFB 代理）**：k6 不做半流式读取，SSE 下响应头+首块几乎同时到达，可作近似；毫秒级 P95 由 k6 统计，节点侧只做秒级粗验。
- **稳态判据**：请求失败率 `< 0.05%`、`P95 TTFB < 800ms`、完整流成功率 `> 99.95%`，等于边界也不通过。完整流须 HTTP 200、包含成功 `finish_reason`、随后收到完整 `[DONE]` 事件，不能只有网关补发的结束标记。
- **其他场景**：突发场景为 P95 `< 1500ms`、失败率 `< 1%`、完整流成功率 `> 99%`；管理面为 `type:admin` 端到端 P95 `< 1000ms`、失败率 `< 1%`、业务成功 checks `> 99%`，且不能丢弃计划迭代。突发汇总通过不代表已验证恢复时间。
- **四态判定**：`PASS`（通过）、`FAIL`（已知指标失败）、`INCOMPLETE`（执行异常/数据不完整）、`UNASSESSED`（尚无专属验收标准）。旧日志只可确认已有指标失败，不凭旧 checks 证明完整流或业务成功；`degrade`、`rolling`、`long` 暂为待评估。
- **token 不进命令行**：Job 里用 `secretKeyRef` 取 `perf-load-test-credentials/token_key`；脚本自己拼 `sk-` 前缀。
- **mock 参数切换**：用 `~/git_code/service_ops/mock-upstream/mock_ctl.sh`（全副本广播），不要直接打 Service 的 `/__ctrl`（只命中一个 Pod）。
- **窗口上限**：单次云助手命令 900s；两档 120s 串跑会踩线，必要时分两次调用。
- 采集结果同时落台账：`deploy/jakarta_dev_ledger.md` §21/§23、`deploy/logs/perf_task33_20261020/`。

## 公网 ALB 路径与 channel 变更

- **走公网 ALB 压测**：`bash deploy/perf/k6/run.sh stage https://perf.likha.hk 300 120s`（`stage` 第一参含 `://` 即按 URL 直用，否则按 Service 名解析 ClusterIP）。k6 在集群内 → NAT → ALB → 网关，含真实入口开销。
- **改 channel 用** `deploy/perf/channel_patch.sh`（只提交可变字段）：`--show` / `--base-url` / `--models` / `--weight` / `--priority` / `--status`（独立状态接口）/ `--key-file`。**不要**把网关自己的域名填进 channel 的 API 地址（自环 401，见台账 §23.1）。
- `cpu_peak` 采样对 ≥60s 的档才可靠；URL 模式会取 master/slave 两侧的最大值。

## 自动 HTML 报告（2026-10-20 起）

每次 `stage` / `dual1500` 跑完，`run.sh` 会自动：
1. 把远端输出落盘到 `deploy/perf/perf_reports/<时间戳>-<tag>.log`（报告的数据源）；
2. 调 `report.py` 生成**本次运行**的单文件报告：`deploy/perf/perf_reports/perf_report_<参数摘要>_<启动时刻>.html`（如 `perf_report_stage-public-vu100-dur15s_20261020-175609.html`）。

报告内容：摘要卡（稳态 SSE 最优通过档 / 可比容量分组 / 1500 VU 实测通过副本配置）、逐运行指标与四态判定及原因、分组容量边界表、趋势图和资源参考指标。没有通过记录时明确显示“无通过档”，不使用失败记录或管理面记录补值。1500 VU 是否通过只认对应档位的实际测试，不推算最少副本数。

```bash
# 手动重生成（例如补了历史日志、或改了 EIP 带宽口径）
python3 deploy/perf/k6/report.py --log-dir deploy/perf/perf_reports \
  --out deploy/perf/perf_reports/index.html --eip-mbps 100
```

**带宽判定**：公网路径（k6→NAT→EIP→ALB）先撞 EIP 带宽时，表现为「RPS 塌陷 + 连接级失败 + 应用侧无 5xx + CPU 很低」。`run.sh` 用 `EIP_MBPS`（默认 100，雅加达 dev 现网实测 100 Mbps）把这条写进报告；此时**首个破线档不参与拐点插值**，卡片明确标注"拐点不可用，改用内网直连档位"。

**已知边界**：2026-10-20 17:22 之前的 3 条日志因抓取过滤漏了 `http_req_duration`，明细表「P95 端到端」显示 0；新日志已含该行。

## 完整报告（2026-10-21 起）

每次 `stage`/`dual1500`/场景跑完，除"本次报告"外，还会聚合 `deploy/perf/perf_reports` + 历史 `deploy/logs/perf_reports` 生成**完整报告**：
`perf_report_ALL_<时间戳>.html`，并同步覆盖 `perf_report_ALL_latest.html`。

完整报告额外包含：
- **趋势图每点可交互**：悬停显示简卡（场景/并发、RPS、P95/P99、错误率），单击弹出完整明细（时间、路径、副本、端到端 P95、checks、CPU/内存、下行）；深底亮字、高对比。
- **VU 的含义**与 Little 定律换算说明。
- **各 Job/动作的设计目的**对照表（stage/dual1500/burst/admin/degrade/rolling/long 为什么这么设计）。
- **一次请求的链路耗时分解图**（上游首字 300ms / 网关+链路开销 / 流式吐字 1500ms / 传输余量），附口径说明。
- 容量拐点只用**内网稳态档**（clusterip/clusterip-dual）计算；无破线档时用最小二乘外推并标注"外推值"。

## 2026-10-21 二次优化

1. **浮层可读性**：全局 `table{background:#fff}` 会盖掉 `.tip-t` 的深底，导致白底浅字；已加 `.tip table{background:transparent!important}` 与 `td{color:#f4fff9!important}`，标签列改亮绿加粗。
2. **链路耗时改为模块级**：用 k6 客户端阶段指标（`http_req_sending / connecting / tls_handshaking / waiting / receiving`）按 **p90** 实测分解；
   模块表：k6 发送 · DNS/TCP 连接 · TLS 握手 · **网关+链路（NAT/ALB/Ingress/鉴权/限流/选渠道）** · mock 首字(300ms) · mock 流式吐字(1500ms) · 客户端接收余量。
   NAT/ALB/Ingress 目前无逐跳埋点，合并为"网关+链路"= waiting_p90 − 300ms；要再拆需接 SLS 访问日志或 trace（未做，不填假数据）。
3. **标签遮挡**：去掉条形图内的长标签，改为图下表格（模块/耗时/占比/数据来源），彻底避免"上游首字"和"网关+链路"文字重叠。
4. 每个 body 的日志过滤已包含四个阶段指标；`report.py` 取**有阶段数据的最优档**画链路图（`best_phase`）。

## 副本阶梯（`ladder`，2026-10-22）

**为什么要分副本跑**：副本数不一致的档位不可比。历史数据里 VU=300 是 2 副本（156.4 RPS）、VU=600 是 1 副本（52.2 RPS、错误率 14.368%），混在一张表里会得出错误的拐点。报告的「副本数」行就是用来识别这件事。

`ladder` 的流程：

1. `scale deploy/perf-new-api-slave --replicas=1` → `rollout status` 等就绪；
2. 在该副本数下从 `start` 逐档加压，**每档用 `report.py --check` 判定 SLO**（P95 TTFB ≤800ms 且错误率 ≤0.05%）；
3. 首次破线即停（破线档仍入报告，作为拐点上限）；若跑到 `max` 仍未破线，提示加大 `max`；
4. 等 30s 排空连接，扩到下一副本数，用**完全相同的 VU 梯子**重跑；
5. 全部阶段聚合为一份报告，同一 VU 档横向对比即扩容收益。

判定用 `report.py --check <log>` 而非 k6 退出码：`stage.sh` 末尾是 `kubectl logs | grep | head`，rc 不可靠。

## 多 Job 分片并行（`shard`，2026-10-21）

单 Job 是单进程，1500 VU 已需要约 2 核/1Gi；3000+ 并发时用分片：

```bash
EIP_MBPS=100 bash deploy/perf/k6/run.sh shard 1500 120s 4    # 4 片 × 375 VU，打同一 Service
```

- 执行体 `bodies/sharded.sh`：按 `SHARDS` 均分 VU（余数给前几片），每片一个 Job（`k6-shard-N`），全部打同一个 `ClusterIP`；
- `sse.js` 支持 `SHARD` env → `tags:{type:'sse',shard:N}`，可按分片切片指标；
- 日志聚合：N 个摘要写进同一份日志，`report.py` 按"RPS 求和、错误率合并、P95 取最差分片"处理；
- 实测样例（3×80 VU）：分片 42.1/42.8/42.9 RPS → 聚合 **127.9 RPS**、P95 345.9ms；
- 注意：客户端总资源 = 分片数 × 单 Job limits；重跑前先删同名 Job；配额/限流是共池的。
