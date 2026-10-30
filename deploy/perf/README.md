# perf 目录索引（任务 33 压测资产）

| 路径 | 作用 |
|---|---|
| `~/git_code/service_ops/mock-upstream/` | mock 上游（Go，6 副本，SSE/JSON、延迟与错误注入、`mock_ctl.sh` 全副本广播）；**已移出本仓库**，镜像用 `deploy/ops/push.sh -n dev --module ~/git_code/service_ops/mock-upstream` 构建推送 |
| `k6/` | 压测执行器：`run.sh`（本机入口）+ `bodies/{stage,arrival,sharded,dual1500,summary,readback}.sh` + `sse.js` / `sse_arrival.js` + **场景脚本 `relay-chat.js`（S1/S2）、`s4_admin.js`（S3）** |
| `场景矩阵.md` | **§3.9 的 S1–S6 场景定义、判据、运行命令与未完成项**（入口文档，先看这份） |
| `cvm/` | **普通 CVM/ECS 上的压测**：`run.sh` 单档（流式/非流式）、`qps_ceiling.sh` 阶梯找 QPS 上限；量「入口+网关」端到端 |
| `vegeta/` | 常量 QPS 交叉验证（`targets` + `body.json`），与 k6 开环互为对照 |
| `baseline/` | 压测基线归档与回归门禁（`README.md` 规则 + `<date>-<sha>.md` 报告） |
| `channel_patch.sh` | **channel 局部更新**（只提交可变字段，见下） |
| `cluster-service-dns.md` | 集群内 Service 地址（`mock-upstream.new-api-perf.svc.cluster.local`）的来历与自查方法 |

## channel_patch.sh —— 只提交可变字段

**为什么要它**：把 `GET /api/channel/:id` 的整个对象回写 `PUT /api/channel/` 会带上 `status` 等只读字段，后端直接回 `Invalid parameters`（`controller/channel.go:1134` 显式拒绝 body 含 `status`）。本脚本只发 `id` + 你显式给的字段，状态另走 `POST /api/channel/:id/status`。

```bash
bash deploy/perf/channel_patch.sh --show --id 3                       # 只读回读
bash deploy/perf/channel_patch.sh --id 3 --base-url http://mock-upstream.new-api-perf.svc.cluster.local
bash deploy/perf/channel_patch.sh --id 3 --models mock-gpt --weight 1 --priority 10
bash deploy/perf/channel_patch.sh --id 3 --status 2                   # 2=禁用，1=启用
bash deploy/perf/channel_patch.sh --id 3 --key-file /tmp/k            # 改密钥，值不进 argv
```

**语义边界**：后端 `model.Channel.Update()` 用 GORM `Updates(struct)`，**只更新非零值字段** ⇒ 无法通过它把字段改回空/0（清空 `base_url`、`weight` 归零要用控制台或 SQL）。脚本每次执行都会打印 before/after 供判效，输出已脱敏：`key` 只报长度，`base_url` 内嵌的 `user:pass@` 替换为 `<redacted>@`；patch 内容经 base64 传给节点，临时脚本 600 权限且退出即删。

## 压测路径选择

| 方式 | 命令 | 说明 |
|---|---|---|
| 集群内直连（测应用本身） | `run.sh stage perf-new-api-slave 300 120s` | 走 ClusterIP，不含 ALB/NAT |
| **公网 ALB 路径（本轮要求）** | `run.sh stage https://perf.likha.hk 300 120s` | k6 在集群内 → NAT → ALB → 网关；含真实入口开销 |
| 双副本 1500（内网） | `run.sh dual1500` | 仅把 slave 扩到 2 副本，单个 Job 打 Service，总并发 1500 |
| **找非流式 QPS 上限** | `run.sh qps perf-new-api-slave 200 200 4000 60s 8` | 开环阶梯，逐档升 rps，首个破 SLO 即停（默认走 `relay-chat.js`） |

> URL 模式判定：`stage` 第一参含 `://` 即按 URL 直用；否则按 Service 名解析 ClusterIP。
> 注意：`cpu_peak` 采样对 ≥60s 的档才可靠（短档在采样前就跑完了）。
