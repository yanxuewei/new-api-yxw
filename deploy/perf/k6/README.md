# 任务 33 压测工具（k6，雅加达 `new-api-perf`）

> 2026-10-20 从一次性 /tmp 脚本整理而成，统一走 `deploy/lib/ack_remote_jkt_dev.sh`（云助手 → 节点内 kubectl）。
> 客户端必须与被测同集群（坑 1：客户端自己成为瓶颈会测出"没问题"）。

## 目录

| 文件 | 位置 | 作用 |
|---|---|---|
| `sse.js` | 集群内 k6 | SSE 打流；`VUS`/`DUR`/`BASE`/`MODEL`/`TOKEN` 全走 env；首字用 `http_req_waiting`(TTFB) 代理 |
| `run.sh` | 本机 | 入口：打包 `sse.js` + 动作体，投递到节点执行 |
| `bodies/stage.sh` | 节点 | 单副本阶梯（恒定 VU × DUR），采 CPU 峰值并打印摘要 |
| `bodies/dual1500.sh` | 节点 | 双副本并行（master/slave 各 `VUS_EACH`，默认 750+750=1500） |
| `bodies/summary.sh` | 节点 | 打印 k6 Job 摘要（不传参=最近 3 个） |
| `bodies/readback.sh` | 节点 | 只读回读：副本/CPU/mock 指标/Service 端点/DNS 自检 |

## 用法

```bash
# 单副本阶梯（100/300/600/900/1200 依次跑，找拐点）
bash deploy/perf/k6/run.sh stage perf-new-api-slave 300 120s

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
- **判据**：`http_req_failed < 0.05%`、`P95 TTFB < 800ms`（S1/S2）。1200 VU 单副本实测 P95 949ms ⇒ 单副本 C≈1000–1100。
- **token 不进命令行**：Job 里用 `secretKeyRef` 取 `perf-load-test-credentials/token_key`；脚本自己拼 `sk-` 前缀。
- **mock 参数切换**：用 `deploy/perf/mock-upstream/mock_ctl.sh`（全副本广播），不要直接打 Service 的 `/__ctrl`（只命中一个 Pod）。
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

报告内容：摘要卡（最优通过档 / 单副本拐点 / 1500 并发所需副本）、每次运行明细表（RPS、P50/P95/P99 首字、端到端 P95、错误率、checks、CPU/内存峰值、下行 Mbps、PASS/FAIL）、两张内联 SVG 趋势图（P95 vs VU、RPS vs VU）、瓶颈判定（事实/推断分开）、理想 QPS 与资源效率、完整公式段。

```bash
# 手动重生成（例如补了历史日志、或改了 EIP 带宽口径）
python3 deploy/perf/k6/report.py --log-dir deploy/perf/perf_reports \
  --out deploy/perf/perf_reports/index.html --eip-mbps 5
```

**带宽判定**：公网路径（k6→NAT→EIP→ALB）先撞 EIP 带宽时，表现为「RPS 塌陷 + 连接级失败 + 应用侧无 5xx + CPU 很低」。`run.sh` 用 `EIP_MBPS`（默认 5，雅加达 dev 现网实测 5 Mbps）把这条写进报告；此时**首个破线档不参与拐点插值**，卡片明确标注“拐点不可用，改用内网直连档位”。

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
   NAT/ALB/Ingress 目前无逐跳埋点，合并为“网关+链路”= waiting_p90 − 300ms；要再拆需接 SLS 访问日志或 trace（未做，不填假数据）。
3. **标签遮挡**：去掉条形图内的长标签，改为图下表格（模块/耗时/占比/数据来源），彻底避免“上游首字”和“网关+链路”文字重叠。
4. 每个 body 的日志过滤已包含四个阶段指标；`report.py` 取**有阶段数据的最优档**画链路图（`best_phase`）。
