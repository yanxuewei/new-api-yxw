# 任务 33 · 场景验收汇总（2026-10-20）

环境：`new-api-perf`（雅加达 dev）· `perf-new-api-slave` **2 副本**（未使用 `perf-new-api-master`）· mock 上游 6 副本 · k6 0.54.0。
路径：S1–S5/S10 走 **ClusterIP 内网**；S9 走 **公网 ALB**（`https://perf.likha.hk`，受 EIP 5Mbps 限制，仅用于长流验证）。

| 场景 | 参数 | RPS | 错误率 | P95 首字 | 判定 | 报告 |
|---|---|---|---|---|---|---|
| S1 常态 | 500 VU × 120s | 255.5 | 0.00% | 398ms | ✅ PASS | `perf_report_stage-clusterip-vu500-dur120s_20261020-191524.html` |
| S2 峰值 | 1500 VU × 120s（2 副本） | 701.6 | 0.00% | 578ms | ✅ PASS | `perf_report_dual-slave2-vu1500-dur120s_20261020-191748.html` |
| S3 突发 | 0→1500 in 30s，保持 90s | 604.3 | 0.00% | 540ms | ✅ PASS | `perf_report_burst-vu1500-dur90s_20261020-192056.html` |
| S4 管理面（默认限流） | 800 QPS × 60s | 799.4 | **99.25%（429）** | — | ❌ 被应用全局限流拦截 | `perf_report_admin-vu1-dur60s_20261020-192331.html` |
| S4 管理面（限流放开后） | 800 QPS × 60s | 797.7 | 0.00% | 7.2ms(P95 时延) | ✅ PASS | `perf_report_admin-vu1-dur60s_20261020-192612.html` |
| S5 上游劣化 | 300 VU × 90s，mock 50% 5xx + 5s | 48.5 | 50.99% | 5.34s | ✅ 符合注入（网关未被拖死，restarts=0） | `perf_report_degrade-vu300-dur90s_20261020-192737.html` |
| S9 长流 | 单请求，连续流 12m04s | — | 0.00% | — | ✅ ALB 未在 600s 切断（600s 是空闲超时） | `perf_report_long-vu1_20261020-193201.html` |
| S10 发布并发 | 300 VU × 120s，中途 rollout restart | 156.8 | **0.14%（27/19096）** | 363ms | ❌ 未达「5xx=0」 | `perf_report_rolling-vu300-dur120s_20261020-192934.html` |
| S6 Redis 故障 | — | — | — | — | ⏭ 跳过：Tair 与 dev/pre 共用实例（db=2 隔离），停实例会波及邻居；需 pod 级断连方案 | — |
| S8 DB 主备切换 | — | — | — | — | ⏭ 跳过：dev RDS 为 Basic 单机，无备节点可切 | — |

## 关键结论

1. **容量**：2 副本可稳定承接 **1500 并发 SSE**（701.6 rps、0% 5xx、P95 578ms），S1/S2/S3 全绿；单副本拐点约 1000 并发流（见 §23）。
2. **管理面**：默认 `GLOBAL_API_RATE_LIMIT=360/180s`（≈2 rps/IP）会对高 QPS 管理面全量 429 ⇒ **800 QPS 目标在默认限流下不可达**；临时放开后 2 副本可跑到 797.7 rps（P95 时延 7.2ms）。上线前需按"管理面来源 IP/账号分桶"重新设计限流，或对内部调用豁免。
3. **S5**：错误率与注入比例一致（50.99%），首字被拉到 5.34s，但网关进程零重启、剩余流量正常 ⇒ 上游劣化不拖死自身。
4. **S9**：连续流 12m04s 未被 ALB 切断 ⇒ 文档里"ALB 600s 上限"应表述为**空闲超时**，不是单请求总时长上限。
5. **S10**：滚动重启期间 0.14% 连接级错误（27 条）⇒ 未达 0；需 `maxUnavailable=0`、`preStop sleep`、就绪摘流延迟三项加固后复测。
