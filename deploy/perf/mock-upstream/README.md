# mock 上游（任务 33 · 容量压测供流）

> 2026-10-19 建立并验证。部署位置：雅加达 dev 集群 `new-api-perf`（6 副本）。
> 用途：替换真实厂商上游 —— 真实 Key 压测会触发厂风控 + 产生费用（任务 33 坑 2）。

## 组成

| 文件 | 作用 |
|---|---|
| `main.go` | 单文件 Go 服务：OpenAI 兼容 `/v1/chat/completions`（SSE + JSON）、`/v1/models`、`/healthz`、`/metrics`、`/__state`、`/__ctrl` |
| `Dockerfile` | `alpine:3.20` + 静态二进制（本机 `CGO_ENABLED=0` 交叉编译） |
| `mock-upstream.yaml` | Deployment（6 副本）+ Service；参数矩阵与偏差说明在文件头 |
| `mock_ctl.sh` | **全副本广播**控制（`normal` / `s5` / `429` / `raw`）；节点侧执行，经 `deploy/lib/ack_remote_jkt_dev.sh` 投递 |

## 镜像与部署（实测记录）

- 镜像：`acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/mock-upstream:20261019-4788bec2e`（digest `sha256:4c11c425…`）
- 仓库先在 EE 里显式创建（`crr-bsp8w2gs5iiwe1jm`），否则 push 回 `insufficient_scope`；docker 登录用 `aliyun cr GetAuthorizationToken` 临时口令
- 部署：`kubectl apply -f mock-upstream.yaml`（tag 用 `__IMAGE_TAG__` 占位，apply 前渲染）→ `6/6 Running`
- Service（供 new-api channel Base URL 用）：`http://mock-upstream.new-api-perf.svc.cluster.local:80`

## 参数旋钮（env 或 `POST /__ctrl` 热改）

| 字段 | 默认 | 说明 |
|---|---|---|
| `first_token_delay_ms` | 300 | 首字延迟（卡面口径） |
| `token_interval_ms` | 30 | token 间隔（卡面口径） |
| `tokens_per_response` | 50 | 单响应 token 数 ⇒ SSE 时长 ≈ 300ms + 50×30ms |
| `token_text_bytes` | 12 | 每 token 文本字节（坑 3：调大以贴近真实响应体） |
| `error_rate` / `error_status` | 0 / 500 | 失败注入；**默认 0**（卡面 0.001 会顶破 S1/S2 的 5xx≤0.05% 判据，偏差已记台账） |
| `extra_latency_ms` | 0 | 额外上游延迟（S5 用 5000） |

## 实测验证（2026-10-19）

| 项 | 结果 |
|---|---|
| `/v1/models`、非流式 JSON | 200，OpenAI 形状 ✅ |
| SSE | 52 个 `data:` 行 = 50 token + final + `[DONE]`；normal 档 2s（秒级计时）✅ |
| 延迟控制 | S5 档非流式 **5s**、SSE **7s** ✅ |
| 错误注入 | S5 档 6 发中 2 个 500（≈50% 抽样方差内）✅；429 档待 S3/S4 用 |
| 全副本广播 | `mock_ctl.sh normal/s5` 均 6/6 命中 ✅ |
| `/metrics` | `mock_requests_total / errors / streams / tokens / active_conns` 可抓 ✅ |

## 已知边界

1. **`/__ctrl` 直接走 Service 只命中一个副本**（ClusterIP 轮询）⇒ 场景切换必须用 `mock_ctl.sh`（按 podIP 广播）。本机/节点不能解析集群 DNS，Service 级测试须在 Pod 内跑。
2. **perf 侧 new-api 负载尚未部署**：`new-api-perf.yaml` 要求独立节点池（g9i.xlarge + taint）且被"新增 ECS 费用"红线卡住（台账 §17/§18）⇒ 本 mock 目前只证明"供流侧就绪"，端到端（new-api → mock）待 perf 负载落地后补一次 channel 冒烟。
3. 节点侧计时只能用秒级（busybox `date` 无 `%N`）；毫秒级 P95 由 k6/vegeta 在客户端计。
