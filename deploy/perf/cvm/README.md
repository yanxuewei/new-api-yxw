# deploy/perf/cvm —— 普通 CVM/ECS 上的黑盒压测

从**被测集群之外**发压，量的是「入口（ALB/NAT/EIP）+ 网关」的端到端能力；`deploy/perf/k6`（集群内 Job）量的是网关自身。两者必须分开看，否则会把入口开销算到应用头上，或者把客户端瓶颈算成系统瓶颈。

## 前置（工具缺失会自动安装）

| 项 | 要求 |
|---|---|
| 工具 | `k6` 0.54.x、`vegeta` 12.13.x；**缺失时脚本自动安装**，最多重试 3 次 |
| 回退 | 安装失败且机器有 `docker` ⇒ 自动改用容器（`grafana/k6:0.54.0` / `peterevans/vegeta`） |
| 网络 | 能到目标地址；公网走 `https://perf.likha.hk`，内网走 ALB/内网 IP |
| 凭据 | `TOKEN`（perf 专用 token，见下） |
| 机型 | 单机跑 1000+ rps 建议 ≥4C8G；k6 自身是单进程，CPU 先满就换多机或回集群内压 |

### 自动安装的行为

- 安装位置：`${PERF_BIN_DIR:-$HOME/.local/bin}`（**不需要 root**），成功后临时加入 `PATH`；
- 下载源：GitHub Releases 官方 tar.gz（`k6-v0.54.0-linux-<arch>.tar.gz` / `vegeta_12.13.0_linux_<arch>.tar.gz`）；
- 每次尝试都必须满足「能执行 + `version` 有输出」才算成功，否则重试；
- 3 次都失败时**不会静默继续**，会打印：失败原因清单 + 四条自助路径（手动安装命令 / 改用 docker / 配代理 / 换内网镜像）+ 验证标准，然后退出。

可调参数：

```bash
PERF_BIN_DIR=/usr/local/bin PERF_RETRIES=3 K6_VERSION=0.54.0 VEGETA_VERSION=12.13.0 ./run.sh ...
```

取 token：

```bash
kubectl -n new-api-perf get secret perf-load-test-credentials -o jsonpath='{.data.token_key}' | base64 -d
```

## 单档

```bash
export TOKEN=<perf token>

# 非流式：800 QPS、120s、响应 128 token
./run.sh https://perf.likha.hk 800 120s nostream 128

# 流式：1500 并发、1000 chunk
./run.sh https://perf.likha.hk 1500 120s stream 1000

# 交叉验证：同一目标用 vegeta 再跑一遍（排除压测工具自身偏差）
./vegeta_run.sh https://perf.likha.hk 800 120s
```

> `run.sh` 里流式/非流式都走 `constant-arrival-rate`（按 rps 发压）；需要"恒并发"验收时用集群内 `run.sh shard`，那边能精确控 VU。

## 找 QPS 上限（阶梯）

```bash
# 200 起、步长 200、到 2000、每档 60s
./qps_ceiling.sh https://perf.likha.hk 200 200 2000 60s nostream 128

# 流式同样适用（判据仍是错误率/P95/完整流）
./qps_ceiling.sh https://perf.likha.hk 100 100 1000 60s stream 1000
```

判据：错误率 `< SLO_ERR`（默认 0.05%）、P95 TTFB `< SLO_P95`（默认 800ms）、`dropped_iterations=0`、实得 `≥ TOL×目标`（默认 98%）。可覆盖：

```bash
SLO_ERR=0.5 SLO_P95=1000 TOL=0.95 ./qps_ceiling.sh ...
```

## 判读：先确认"不是压测机不够"

| 现象 | 含义 |
|---|---|
| 实得远低于目标、`dropped_iterations > 0`、错误率 0、P95 正常 | **压测机/单进程不够**，不是被测系统 |
| 错误率 0、`dropped=0`、P95 随档位明显上升并突破阈值 | 被测系统的真实容量边界 |
| 出现 5xx 或完整流下降 | 服务端接不住（真实故障点） |

单机 k6 的硬上限：约 1 进程能稳定发 1–3k rps（取决于响应体大小与 chunk 数）。超过就该换多机（多台 CVM 各压一部分）或改用集群内 N 分片。

## 与目标值对照

`impl_tech.md §3.9` 的目标（800 QPS/实例、1500 并发/实例、P99 ≤ 80ms 网关内）**是网关内口径**。CVM 端到端跑出来的数字必然更大（多了入口链路），不能直接判定 §1.3 达标，只能作为"对外可用能力"的上界参考。

## 坑

1. **公网路径有 EIP 带宽上限**：先确认带宽规格，否则高 rps 时 `receiving` 会异常、RPS 塌陷，看起来像服务端崩。
2. **SSE 的 `http_req_waiting` 是 TTFB**，不是总时长；判 P95 时别拿 `http_req_duration` 比 800ms。
3. **`max_tokens` 必须与 mock 配置一致**，否则客户端以为的 token 数和上游返回不一致，tps 统计会偏。
4. **一次只改一个变量**：换机型、换路径、改 mock 参数都会让结果不可比，基线条目里要写清口径。
