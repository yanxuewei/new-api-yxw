# k6 详细指南（基于 new-api 任务 33 实践）

> 版本：2026-10-21 ｜ 适用环境：雅加达 dev 集群 `new-api-perf`（`perf-new-api-slave` 2 副本 + `mock-upstream` 6 副本）
> 本文所有数字、命令、脚本路径都来自本仓库的真实实践，可直接照抄执行；涉及集群内网的命令需要先具备 `deploy/lib/ack_remote_jkt_dev.sh` 通道权限。

---

## 0. 一句话结论

k6 是"用 JavaScript 写测试脚本、用 Go 跑并发"的压测工具。它把"一个虚拟用户（VU）"实现成一个独立的 JS 运行时 + 一条（组）HTTP 连接，按执行器（executor）规定的节奏反复执行 `default` 函数，同时把所有请求的阶段耗时、错误率、吞吐打成指标，用阈值（thresholds）判定通过/失败。

在本项目里，k6 不是"顺手用一下的脚本工具"，而是**验收判据的执行者**：S1–S10 的通过与否，取决于 k6 阈值是否成立（`http_req_failed < 0.05%`、`P95 首字 < 800ms` 等）。

---

## 1. 这次压测为什么用 k6

| 候选 | 为什么不选 |
|---|---|
| `ab` | 只支持 HTTP/1.0 风格短连接压测，不支持 SSE 流式读取，不能写业务断言 |
| `wrk` / `wrk2` | Lua 脚本、维护停滞；SSE 长连接场景需要自己改源码 |
| `vegeta` | 到达率模型好用，但脚本表达力弱（无 JS 逻辑、无 checks、无多场景编排） |
| `JMeter` | 图形化重、JVM 内存开销大；Git 里维护 `.jmx` 可读性差；SSE 需插件 |
| `curl` 循环 | 每次新建进程/连接，客户端自己先成为瓶颈；无统计口径（我们踩过：同一档位 P95 差 3 倍，见 §9.3） |
| **k6** | 单二进制、脚本可入库、原生支持多种执行器（恒定 VU / 突增 / 到达率）、阈值可作 CI 判据、指标口径统一 |

**关键需求**：本次要压的是 **SSE 流式接口**（一个请求持续约 1.9 秒、持续吐 token），需要"大量长连接同时驻留"。k6 的 VU 模型天然对应"驻留连接数"，而 `ab`/`curl` 这类"短请求 QPS 工具"会把语义搞错。

---

## 2. k6 的实现原理

### 2.1 进程与运行时

- k6 本体是 **Go 程序**；测试脚本是 **JavaScript（ES6 子集）**，由 [goja](https://github.com/dop251/goja) 引擎解释执行（不是 Node，不支持 npm 包、不支持 `require` 任意模块）。
- 启动时先把脚本的**init 阶段**（顶层代码）在每个 VU 的独立 JS 运行时里执行一次 —— 所以顶层不要放"只该跑一次"的重逻辑；需要全局共享的用 `setup()`。
- 每个 **VU = 一个 goroutine + 一个 JS 运行时 + 一组 HTTP 连接**。VU 之间内存隔离，不能共享 JS 变量（要共享用 `setup()` 返回值或 `SharedArray`）。
- `default` 函数是"一次迭代"：执行完就进入下一次，直到执行器说停。

```
进程
├── init（每个 VU 各执行一次顶层代码）
├── setup()（全进程执行一次，返回值作为 default 的入参）
├── VU 1 ─ default() → default() → …
├── VU 2 ─ default() → default() → …
└── teardown()（全进程执行一次）
```

### 2.2 执行器（executor）决定"怎么发压"

| 执行器 | 语义 | 本项目用于 |
|---|---|---|
| `constant-vus` | 固定 VU 数，跑满 duration | S1 常态、S2 峰值、S5 劣化 |
| `ramping-vus` | VU 数按 stages 线性变化 | S3 突发（0→1500 用 30s） |
| `constant-arrival-rate` | **每秒固定发起 N 个请求**，与 VU 数解耦（VU 只是执行者） | S4 管理面 800 QPS |
| `per-vu-iterations` | 每 VU 跑固定次数 | S9 长流（1 VU × 1 次） |
| `shared-iterations` | 总次数固定，VU 抢任务 | 一次性批量任务（本文未用） |

**为什么区分 VU 与到达率**：SSE 的"并发"是同时在途的流（VU），管理面的"QPS"是每秒新请求数（arrival-rate）。用 VU 模型压 800 QPS 会得到"取决于响应时长"的错误结论。

### 2.3 HTTP 客户端与阶段指标

k6 默认 **keep-alive + 连接复用**。每个请求会被拆成如下阶段（也是我们做"模块耗时分解"的数据来源）：

| 指标 | 含义 | 本次实测（内网 200VU 档 p90） |
|---|---|---|
| `http_req_blocked` | 等连接池可用 | ≈0 |
| `http_req_connecting` | TCP 建连 | 0（连接复用） |
| `http_req_tls_handshaking` | TLS 握手 | 0（复用） |
| `http_req_sending` | 发送请求 | 0.016 ms |
| `http_req_waiting` | **发出请求到收到首字节（TTFB）** | 341.9 ms |
| `http_req_receiving` | 接收响应体 | 1.6 s（50 token × 30ms + 传输） |
| `http_req_duration` | 端到端 = waiting + receiving（+ 少量开销） | 1.94 s |

> 这就是为什么"首字延迟"我们不用 `http_req_duration`，而用 `http_req_waiting`：k6 不做半流式读取，响应体收完才返回，`duration` 是"整条流"的时长。

### 2.4 指标类型与阈值

- 指标类型：`Counter`（累计）、`Gauge`（瞬时）、`Rate`（比例）、`Trend`（分布，出 p50/p90/p95/p99）。
- `http_req_failed` 是 **Rate**（非 2xx/3xx 或网络错误算失败），`http_req_waiting` 是 **Trend**。
- `thresholds` 里写的表达式在测试结束时判定；**任一阈值不成立，k6 退出码 = 99**（本次就踩过：Job 显示 failed，而我们的等待循环只判断 succeeded，白等了 900 秒）。
- 阈值失败**不会中断测试**（除非配 `abortOnFail`），只会让退出码非 0。

### 2.5 结果输出

| 方式 | 用途 | 本项目 |
|---|---|---|
| 默认文本摘要（stdout） | 人看 | 被抓取解析成 HTML 报告 |
| `--summary-export=xxx.json` | 机器读 | 未用（云助手输出有 24KB 上限） |
| `handleSummary(data)` | 自定义输出 | 未用（同上） |
| `--out json/csv` | 时序明细 | 未用（体积大） |
| Prometheus remote write / k6 Cloud | 长期观测 | 未用 |

---

## 3. 安装与环境

### 3.1 本机（仅用于调试脚本，不做正式压测）

```bash
#  macOS
brew install k6
#  Linux (deb)
sudo gpg -k && sudo apt install k6
#  容器
docker run --rm -i grafana/k6 run - <script.js
```

### 3.2 集群内（正式压测的唯一正确姿势）

```yaml
image: grafana/k6:0.54.0
args: ["run", "/scripts/sse.js"]
env:                      # 参数全部走 env，脚本里用 __ENV.XXX 取
  - {name: VUS, value: "1500"}
  - {name: BASE, value: "http://172.23.2.189"}
  - name: TOKEN           # 密钥走 secretKeyRef，绝不写进脚本/命令行
    valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
resources:
  requests: {cpu: 500m, memory: 256Mi}
  limits:   {cpu: "2",  memory: 1Gi}
```

**为什么必须在集群内跑**：压测客户端到被测服务的链路要尽量短且稳定；跑在笔记本上，你测的是"家里宽带 + 公网 + NAT"，而不是网关。本次客户端的 Pod 与被测 Pod 同集群，内网档完全不过 NAT/ALB。

### 3.3 运行形态选型：为什么用 Kubernetes Job，而不是 Pod / Deployment / 本机

k6 本身只是一个"跑完就退出"的进程，但**用什么形态承载它**会直接决定数据是否可信。本次统一用 `batch/v1 Job`，原因有五条：

**① 客户端必须贴近被测系统（位置决定数据是否可用）**

被测的 new-api（`perf-new-api-slave`）与 mock（`mock-upstream`）都在 `new-api-perf` 里，集群 API Server 只在内网。如果在本机跑 k6：

- 只能走公网入口 `perf.likha.hk`，路径变成 `本机 → 公网 → NAT/EIP → ALB → 网关`，测的是"家里宽带 + EIP 带宽"，不是网关容量；
- 内网 `ClusterIP` 本机完全连不上，做不了真正的容量档。

本次有一组现成对照：同一 600 VU 档，EIP **5 Mbps** 时是 **52 RPS / 14.37% 错误**，调到 **100 Mbps** 后变成 **290 RPS / 0%**。客户端若在集群外，还要再叠加本地上行带宽与运营商抖动，数字无法归因。

**② Job 的语义与"一次性压测"完全匹配**

```yaml
kind: Job
spec:
  backoffLimit: 0                 # 失败不重试（重试会污染数据）
  ttlSecondsAfterFinished: 7200   # 跑完自动清理，不堆垃圾
  template:
    spec:
      restartPolicy: Never
```

- 普通 **Pod**：没有 completion 状态可判断，容易残留、跑完无人回收；
- **Deployment**：语义是"长期维持副本数"，跑完会被重新拉起，完全不对；
- **CronJob**：定时任务，不匹配"人工触发一次验收"；
- **Job**：`Complete/Failed` 两个终态，`ttlSecondsAfterFinished` 自动清理。

**③ 结果是"可判定"的，能直接做门禁**

k6 阈值不成立时退出码为 **99**，Job 随之变成 `Failed`。这让"压测通过/不通过"成为集群里的客观状态，而不是靠人翻日志：

```bash
kubectl -n new-api-perf get job k6-stage-500 \
  -o jsonpath='{.status.succeeded}{"/"}{.status.failed}'
kubectl -n new-api-perf logs job/k6-stage-500
```

本项目脚本就是靠这个状态等待结束、抓摘要、再生成 HTML 报告。**踩过的坑也在这里**：最初的等待循环只判断 `succeeded`，遇到阈值破线（Job failed）就白等 900 秒（云助手超时），后来补上 `.status.failed` 判断才修好。

**④ 环境隔离与可复现**

| 维度 | Job 带来的约束 |
|---|---|
| 版本 | 镜像固定 `grafana/k6:0.54.0`，不会因本机升级导致数字漂移 |
| 参数 | `VUS/BASE/DUR` 走 env，token 走 `secretKeyRef`，不进命令行、不进仓库 |
| 资源 | `requests/limits` 限制客户端，避免 k6 抢走被测 Pod 的 CPU（客户端成为瓶颈是最常见的假数据来源） |
| 审计 | 每次运行 = 一个 Job 名 + 一份日志 + 一份报告，可回溯 |

**⑤ 与其他跑法的取舍**

| 方式 | 问题 | 结论 |
|---|---|---|
| 本机/笔记本跑 k6 | 只能走公网；受本地带宽、NAT、运营商影响；内网档做不了 | ✗ |
| 在节点上 curl 循环 | 每请求 fork 进程，800 并发时协调器自身成为瓶颈：同档位 P95 比 k6 高 **3 倍**（1.94s vs 713ms），数据不可用 | ✗（本项目上一轮踩过，见台账 §21） |
| 在节点上直接跑 k6 二进制 | 节点无 k6；裸进程绕过 cgroup limits，可能挤占 kubelet 与其他 Pod | ✗ |
| 单独买一台压测 ECS | 多一份费用与运维，还要处理它与集群的网络路径 | △ |
| **集群内 Job** | 路径最短、资源受控、状态可判定、跑完自清理 | ✓ 本次选择 |

**边界与注意事项**

- Job 里的 k6 仍是**单进程**：1500 VU 时客户端自身约需 2 核 / 1Gi 与数千连接，所以 `limits` 不能给小（本次 2 核 / 1Gi、`requests` 500m / 256Mi）；
- 若要压 5000+ 并发，应**拆成多个 Job 并行**打同一个 Service，而不是无限加大单 Job 资源——否则客户端先撞自己的天花板；
- Job 名复用前要先 `kubectl delete job`（本项目各 body 里都会先删再建），否则 apply 报不可变字段冲突；
- `backoffLimit: 0` 是刻意的：阈值失败后自动重试会让"失败"被重试掩盖，也会污染统计。

---

## 4. 最小可用脚本（先跑通再谈容量）

```js
// hello.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 10,
  duration: '30s',
  thresholds: { http_req_failed: ['rate<0.01'], http_req_duration: ['p(95)<500'] },
};

export default function () {
  const res = http.get('https://test.k6.io');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);          // 模拟用户思考时间；压 API 时通常不加
}
```

```bash
k6 run hello.js
# 退出码 0=阈值全过；99=有阈值不成立
```

---

## 5. 本项目压测架构

```
┌──────────────┐   内网档：ClusterIP        ┌────────────────────┐     ┌──────────────┐
│  k6 Job Pod  │ ─────────────────────────▶ │ new-api (2 副本)    │ ──▶ │ mock-upstream │
│  (new-api-perf)│                          │ perf-new-api-slave  │     │  6 副本       │
└──────┬───────┘                            └────────────────────┘     └──────────────┘
       │ 公网档：kubectl 出集群 → NAT(EIP) → 公网 → ALB → 同一 Service
       └──────────────▶ https://perf.likha.hk ──▶ 172.23.x.x:80
```

- **mock 上游**：`deploy/perf/mock-upstream/`（Go，OpenAI 兼容，可配首字延迟/token 间隔/错误注入；`mock_ctl.sh` 做全副本广播）。
- **被测入口**：`svc/perf-new-api-slave`（内网）或 `https://perf.likha.hk`（公网，经 EIP）。
- **执行器**：`deploy/perf/k6/run.sh`（本机入口）+ `bodies/*.sh`（节点侧，经云助手投递 kubectl）。

---

## 6. 本次使用的四个脚本逐段讲解

### 6.1 `sse.js` —— 恒定 VU 打 SSE（S1/S2/S5/S10）

```js
const VUS  = Number(__ENV.VUS || 50);
const DUR  = __ENV.DUR || '120s';
const BASE = __ENV.BASE;                 // 必传：http://ClusterIP 或 https://perf.likha.hk
const TOKEN = __ENV.TOKEN;               // 必传：从 Secret 注入，脚本自己拼 sk-

export const options = {
  scenarios: { sse: { executor: 'constant-vus', vus: VUS, duration: DUR, gracefulStop: '30s' } },
  thresholds: {
    http_req_failed: ['rate<0.0005'],               // 5xx ≤0.05%
    'http_req_waiting{type:sse}': ['p(95)<800'],    // 首字 P95 ≤800ms
  },
};

export default function () {
  const res = http.post(`${BASE}/v1/chat/completions`,
    JSON.stringify({ model: 'mock-gpt', stream: true, messages: [{ role: 'user', content: 'perf' }] }),
    { headers: { Authorization: `Bearer sk-${TOKEN}`, 'Content-Type': 'application/json' },
      timeout: '120s', tags: { type: 'sse' } });
  check(res, { 'status 200': r => r.status === 200, 'has [DONE]': r => r.body.includes('[DONE]') });
}
```

**要点**：
- `tags: { type: 'sse' }` 让阈值只作用于 SSE 请求（管理面脚本用 `type:admin` 分开）。
- `timeout` 必须显式给：k6 默认 60s，SSE 长流会被误杀。
- `check` 只做断言统计，**不影响** `http_req_failed`（那是按 HTTP 状态算的）。

### 6.2 `s3_burst.js` —— 突发（S3）

```js
stages: [
  { duration: '30s', target: 1500 },   // 30 秒拉到 1500
  { duration: '90s', target: 1500 },   // 保持
  { duration: '10s', target: 0 },      // 降载
]
```

突发场景的判据不是"平均 QPS"，而是：**拉起的 30 秒内错误率是否可控、P95 是否在保持段回稳**。

### 6.3 `s4_admin.js` —— 管理面到达率（S4）

```js
executor: 'constant-arrival-rate',
rate: 800, timeUnit: '1s', duration: '60s',
preAllocatedVUs: 50, maxVUs: 800,

export function setup() {                       // 只登录一次
  const r = http.post(`${BASE}/api/user/login`, JSON.stringify({ username: USER, password: PASS }), ...);
  return { token: (r.json().data || {}).access_token };
}
export default (data) => {
  const res = http.get(`${BASE}/api/channel/`, { headers: { Authorization: `Bearer ${data.token}` } });
  check(res, { 'status 200': r => r.status === 200 });
};
```

**到达率与 VU 的区别**：这里 VU 只是"执行者数量"，请求速率由 `rate` 控制；响应变慢时 k6 会自动加 VU（到 `maxVUs`），不会像 `constant-vus` 那样被动掉 QPS。

### 6.4 `s9_long.js` —— 长流（S9）

```js
executor: 'per-vu-iterations', vus: 1, iterations: 1, maxDuration: '14m'
// 请求 timeout: 800s
```

配合 `mock_ctl` 把 mock 改为 `tokens_per_response=24000`（24000×30ms≈12min），验证 ALB 的 600s 到底是"空闲超时"还是"总时长上限"。

---

## 7. 指标怎么看（口径与换算）

### 7.1 必看的六个数字

| 指标 | 含义 | 本次 S2（1500 VU / 2 副本） |
|---|---|---|
| `http_reqs` rate | 吞吐 RPS | 639.2 /s |
| `http_req_failed` | 错误率 | 0.00% |
| `http_req_waiting` p95 | 首字延迟（TTFB） | 792 ms |
| `http_req_duration` p95 | 整条流时长 | ≈2.1 s |
| `vus_max` | 实际并发 | 1500 |
| `checks` | 断言通过率 | 100% |

### 7.2 Little 定律（并发 ↔ 吞吐 ↔ 时长的桥）

```
N ≈ RPS × T_avg
N：并发（VU / 在途请求数）
T_avg：平均请求时长（秒）
```

本次：1500 VU ÷ 2.1 s ≈ 714 RPS（实测 639，差异来自请求时长分布与建连开销）。这个公式用来**校验数据自洽**：如果算出来的 N 和 `vus_max` 差一个数量级，说明客户端在排队或服务端在丢请求。

### 7.3 单副本容量与副本数

```
每副本并发      VU_per_replica = VU / 副本数
单副本拐点      VU_knee（P95 达到 800ms 时的每副本并发）
所需副本数      replicas = ceil(目标并发 / VU_knee)
```

本次：内网稳态点最小二乘外推 `VU_knee ≈ 978`，目标 1500 ⇒ `ceil(1500/978)=2` 副本（无余量，生产建议 3）。

### 7.4 资源效率

```
每请求 CPU     C_req = CPU_peak_cores / RPS          （核·秒/请求）
每千 RPS 用核  C_k   = C_req × 1000
每核小时请求数 Q     = RPS × 3600 / CPU_peak_cores
```

本次 S2：CPU 0.84 核 / 639 RPS ⇒ 每千 RPS 约 1.31 核，每核时约 76 万请求。

---

## 8. 最佳实践清单

### 8.1 脚本

1. **参数全走 `__ENV`**，不在脚本里写死地址/账号；密钥走 Secret → env，不进 argv。
2. **一个场景一个脚本**：不要在一个 `default` 里混 SSE 与管理面，指标会互相污染。
3. **显式 `timeout`**：SSE/长流 ≥ 请求预期时长的 2 倍。
4. **`tags` 分类**：`{type:'sse'}` / `{type:'admin'}`，阈值按 tag 写。
5. **`check` 只用于业务断言**，不要拿它当错误率（`http_req_failed` 才是 HTTP 层错误率）。
6. **不要 `sleep()` 压 API**；只有模拟"用户思考"时才加。
7. **`setup()` 里做登录/建数据**，`teardown()` 里清理。

### 8.2 环境隔离

1. **客户端必须与被测同集群/同区域**（本次内网档全程不过 NAT）。
2. **压测库/实例独立**（`newapi_perf`、mock 上游），避免污染 dev/生产；本次 Redis 与 dev 共用实例，所以 S6 只能做 pod 级断连，不能停实例。
3. **先确认没被应用自身限流**：本次管理面 800 QPS 被 `GLOBAL_API_RATE_LIMIT=360/180s` 打成 99.25% 429，放开后才测出真实能力。
4. **确认入口形态**：内网 ClusterIP 与公网 ALB 的数字不可混用；公网受 EIP 带宽限制（本次 5 Mbps 时 600 VU 直接塌成 52 RPS + 14% 错误）。

### 8.3 观测

1. 压测期间同时采 **应用 CPU/内存**（`kubectl top`）、**上游 mock 指标**、**节点负载**；
2. 记录**测试窗口的配置快照**（副本数、镜像 tag、限流参数、EIP 带宽）；
3. 报告里必须写清"这一档走的是内网还是公网"。

---

## 9. 最佳使用场景

| 场景 | 适用度 | 说明 |
|---|---|---|
| API 网关容量摸底（RPS / 并发 / P95） | ★★★★★ | 本次 S1/S2 主用途 |
| 长连接/SSE/WebSocket 并发驻留 | ★★★★☆ | VU 模型天然贴合；但 k6 不能半流读取，首字只能用 TTFB 代理 |
| 突发/弹性（HPA、冷启动） | ★★★★☆ | `ramping-vus`/`ramping-arrival-rate` |
| 到达率型接口（管理面 QPS、限流验证） | ★★★★★ | `constant-arrival-rate` |
| 发布期容量验证（滚动重启不掉请求） | ★★★★☆ | 本次 S10，配合 `rollout restart` |
| 上游劣化下的稳定性（错误注入） | ★★★★★ | 配合 mock 的 `error_rate`/`extra_latency_ms` |
| 浏览器端性能（LCP/FCP） | ★★☆☆☆ | 需 `k6 browser` 模块，资源开销大，不适合容量压测 |
| 复杂事务（多步下单、状态机） | ★★★☆☆ | 可写，但脚本复杂度上升，建议拆场景 |
| 协议非 HTTP（gRPC/WebSocket） | ★★★★☆ | 有 `k6/net/grpc`、`k6/ws` 模块 |

---

## 10. 优缺点

**优点**

- 单二进制、脚本进 Git，可 review、可复用；
- 执行器齐全，能精确表达"并发"与"到达率"两种负载；
- 阈值即判据，天然适合 CI/CD 门禁（退出码 99）；
- 指标口径统一（同一套 `http_req_*`），跨环境可比；
- 集群内以 Job 运行，资源可控、结果可归档。

**缺点**

- JS 运行时是 goja 子集，**不能用 npm 生态**，复杂逻辑要手写；
- **不支持响应流式读取**，SSE 只能测 TTFB + 总时长，测不到"第 N 个 token 的时间"；
- 单进程 VU 上限受客户端资源限制（本次单 Job 跑 1500 VU 需要 2 核 + 1Gi，且要留意连接数与文件描述符）；
- 默认摘要信息有限，要做多维度报告需自己解析或接 Prometheus；
- 阈值失败只影响退出码，不会中断测试，容易被"Job failed 但仍在跑"误导。

---

## 11. 坑点清单（全部为本项目实测踩过）

| # | 坑 | 现象 | 解法 |
|---|---|---|---|
| 1 | **云助手 900s 超时** | 两档 120s 串跑 + 等待被截断 | 一次调用只跑一档；或分多次 |
| 2 | **命令体 15KB 上限** | `命令内容超过长度限制` | 脚本 gzip+base64 压缩；精简 body；拆分动作 |
| 3 | **k6 阈值失败 → Job failed** | 等待循环只认 succeeded，白等 900s | 循环同时判断 `.status.failed` |
| 4 | **客户端不能在受测链路** | 本机压公网测的是自家宽带 | 客户端放到同集群（本次 k6 Job） |
| 5 | **`Connection: close` 与连接池口径差异** | 同档位 P95 差 3 倍（§9.3） | 统一客户端形态；报告注明连接是否复用 |
| 6 | **默认 timeout 60s** | 12 分钟长流被误杀 | 请求级 `timeout: '800s'` |
| 7 | **k6 无语义化 SSE 客户端** | 测不到首 token 精确时间 | 用 `http_req_waiting`（TTFB）代理，并在报告标注 |
| 8 | **busybox `date` 无 `%N`** | 计时恒为 0 | 用 `/proc/uptime` 或秒级计时 |
| 9 | **日志过滤漏指标** | 报告端到端 P95 显示 0 | grep 覆盖 `http_req_duration` 等全部需要的行 |
| 10 | **k6 时长单位** | 解析 `992.81µs`、`12m4.4s` 报错 | 解析器支持 µs/m/s/复合单位 |
| 11 | **Service DNS 只在 Pod 内可解析** | 节点上 curl 域名 NXDOMAIN | 节点侧用 ClusterIP/Pod IP；Service 级测试在 Pod 内跑 |
| 12 | **`/__ctrl` 走 Service 只命中一个 Pod** | 注入只对 1/6 副本生效 | 按 podIP 广播（`mock_ctl.sh`） |
| 13 | **带宽瓶颈误判为网关瓶颈** | RPS 塌 + 连接级错误，但应用 0 5xx、CPU 很低 | 看 `data_received` 速率与 EIP 标称带宽；报告用 `--eip-mbps` 判定，≥85% 时拒绝给拐点 |
| 14 | **管理面被应用限流** | 800 QPS 下 99.25% 429 | 先确认 `GLOBAL_API_RATE_LIMIT`；测容量时临时放开，测完恢复 |
| 15 | **ALB 600s 误解为总时长** | 以为 12 分钟流必断 | 实测连续流 12m04s 未被切；600s 是**空闲**超时 |
| 16 | **滚动重启掉连接** | 300 VU 下 0.14% 错误 | `maxUnavailable=0` + `preStop` + 就绪摘流；2 副本时复测为 0 |
| 17 | **Namespace Quota** | 探针 Pod 因缺 requests 被拒 | 所有临时 Pod 显式写 requests/limits |
| 18 | **Secret 里的 DSN 与 channel 地址混用** | 把网关自身域名填进 channel → 自环 401 | channel 填**上游**地址；网关入口只作为 k6 的 BASE |

---

## 12. 本次实践完整步骤（可复现）

### 12.1 前置条件

- `deploy/lib/ack_remote_jkt_dev.sh` 可用（云助手 → 节点 kubectl）；
- `new-api-perf` 命名空间内已有：`perf-new-api-slave`（2 副本）、`mock-upstream`（6 副本）、`Secret/new-api-secrets`、`Secret/perf-load-test-credentials`；
- channel `mock-perf` 的 API 地址指向 `http://mock-upstream.new-api-perf.svc.cluster.local`（**不是**网关域名）；
- mock 处于 normal 档。

### 12.2 自检

```bash
bash deploy/perf/k6/run.sh readback
# 期望：deploy/pod 正常、CPU 可见、mock /metrics 有 mock_requests_total、DNS 自检输出 FQDN + mock-gpt
```

### 12.3 逐场景执行

```bash
# S1 常态：500 并发，2 副本，内网
EIP_MBPS=100 bash deploy/perf/k6/run.sh stage perf-new-api-slave 500 120s

# 公网对照：600 并发经 ALB（需 EIP 带宽足够）
EIP_MBPS=100 bash deploy/perf/k6/run.sh stage https://perf.likha.hk 600 90s

# S2 峰值：1500 并发（把 slave 扩到 2 副本，单 Job 打 Service）
EIP_MBPS=100 bash deploy/perf/k6/run.sh dual1500 750 120s

# S3 突发：30s 内 0→1500
EIP_MBPS=100 bash deploy/perf/k6/run.sh burst 1500 90s

# S4 管理面：800 QPS（先临时放开全局限流，跑完恢复）
EIP_MBPS=100 bash deploy/perf/k6/run.sh admin 800 60s

# S5 上游劣化：mock 注入 50% 5xx + 5s
EIP_MBPS=100 bash deploy/perf/k6/run.sh degrade 300 90s

# S10 发布期：300 并发中滚动重启
EIP_MBPS=100 bash deploy/perf/k6/run.sh rolling 300 120s

# S9 长流：单请求约 12 分钟（公网 ALB）
EIP_MBPS=100 bash deploy/perf/k6/run.sh long 12
```

每条命令结束后会自动生成两份报告：

```
deploy/perf/perf_reports/perf_report_<参数摘要>_<时间戳>.html   # 本次
deploy/perf/perf_reports/perf_report_ALL_latest.html            # 全部运行聚合
```

### 12.4 本次实测结果（EIP 100 Mbps）

| 场景 | 参数 | RPS | 错误率 | P95 首字 | CPU 峰值 | 判定 |
|---|---|---|---|---|---|---|
| S1 | 500 VU / 2 副本 | 251.9 | 0.00% | 433 ms | 0.36 核 | ✅ |
| 公网对照 | 600 VU / 2 副本 | 290.1 | 0.00% | 482 ms | 0.42 核 | ✅ |
| S2 | 1500 VU / 2 副本 | 639.2 | 0.00% | 792 ms | 0.84 核 | ✅（贴线） |
| S3 | 0→1500/30s | 562.0 | 0.00% | 731 ms | 0.85 核 | ✅ |
| S4 | 800 QPS / 60s | 797.8 | 0.00% | 7.1 ms（时延） | 0.18 核 | ✅（需放开限流） |
| S5 | 300 VU，50% 5xx+5s | ≈48.5 | 50.99% | 5.34 s | — | ✅ 符合注入 |
| S9 | 12m04s 单流 | — | 0.00% | — | — | ✅ 未切断 |
| S10 | 300 VU + 滚动重启 | 159.5 | 0.00% | 344 ms | 0.23 核 | ✅ |

对照（同一 600 VU 公网档）：EIP 5 Mbps 时 **52 RPS / 14.37% 错误**；100 Mbps 时 **290 RPS / 0%**。这组对照是"先查链路、再谈容量"的最好教材。

### 12.5 报告解读

打开 `perf_report_ALL_latest.html`：

1. **摘要卡**：SSE 最优通过档、管理面峰值、单副本拐点、1500 并发所需副本；
2. **明细表**：每次运行的 RPS/首字 P50/P95/P99/端到端 P95/错误率/CPU/内存/下行/判定；
3. **趋势图**：每个点是一次运行，**悬停看简卡、单击看完整明细**；
4. **链路分解**：按 k6 阶段指标 p90 拆成 k6 发送 / 连接 / TLS / 网关+链路 / mock 首字 / 流式吐字 / 客户端接收余量；
5. **公式区**：口径、Job 设计目的、VU 定义、副本数计算。

### 12.6 多 Job 分片并行（客户端先撞天花板时）

**什么时候需要**：单个 k6 Job 是**单进程**，1500 VU 时客户端自身已占约 2 核 / 1Gi 和数千连接。要压 3000–5000+ 并发时，继续给单 Job 加 `limits` 只会让它先撞自己的 CPU/文件描述符，压出来的 P95 是客户端排队，不是服务端能力。

**做法**：把总并发切成 N 份，起 N 个 Job（各自独立进程、独立连接池），全部打同一个 Service；kube-proxy 仍按连接把流量分摊到后端副本。

```bash
# 总 1500 VU，分 4 片（每片 375 VU），打同一个 svc/perf-new-api-slave
EIP_MBPS=100 bash deploy/perf/k6/run.sh shard 1500 120s 4
```

执行体 `deploy/perf/k6/bodies/sharded.sh` 的关键逻辑：

```bash
BASE_VU=$((TOTAL / SHARDS)); REM=$((TOTAL % SHARDS))
for i in $(seq 0 $((SHARDS - 1))); do
  V=$BASE_VU; [ "$i" -lt "$REM" ] && V=$((V + 1))    # 余数分给前几片，保证总和精确等于 TOTAL
  kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: k6-shard-$i, namespace: new-api-perf, labels: {app: k6, shard: "$i"}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 7200
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          args: ["run", "/scripts/sse.js"]
          env:
            - {name: VUS, value: "$V"}
            - {name: DUR, value: "$DUR"}
            - {name: BASE, value: "http://$IP"}     # 同一个 ClusterIP
            - {name: SHARD, value: "$i"}            # 注入 tag，便于按分片看指标
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes: [{name: scripts, configMap: {name: k6-sse}}]
YAML
done
```

脚本侧只需一个可选参数（`sse.js` 已支持）：

```js
const SHARD = __ENV.SHARD || '0';
// …
tags: { type: 'sse', shard: SHARD },   // 指标可按分片切片：http_req_waiting{shard:"2"}
```

**聚合口径**：`sharded.sh` 把 N 个 Job 的摘要**依次打印到同一份日志**，`report.py` 按"一个日志多条摘要"聚合：

| 指标 | 聚合方式 | 原因 |
|---|---|---|
| `http_reqs` / RPS | **求和** | N 个分片是并行独立的吞吐 |
| `http_req_failed` | 分子分母分别求和后再算比例 | 避免"取平均"稀释错误 |
| `P50/P95/P99` 首字 | **取最差分片** | 保守口径，不掩盖某个分片劣化 |
| `vus` / `replicas` | 取 `RUN_META`（总量 / 后端副本数） | 分片是客户端侧的概念 |

**实测样例（3 分片 × 80 VU = 240 VU，2 副本，45s）**：

| 分片 | RPS | P95 首字 |
|---|---|---|
| shard-0 | 42.1 | 345.9 ms |
| shard-1 | 42.8 | 344.7 ms |
| shard-2 | 42.9 | 341.2 ms |
| **聚合** | **127.9** | **345.9 ms**（最差分片） |

报告文件名：`perf_report_shard-3x-vu240-dur45s_<时间戳>.html`（`shard` 动作已纳入自动报告）。

**坑点**：

1. **Job 名复用**：重跑前必须 `kubectl delete job k6-shard-<i>`（`sharded.sh` 已内置）；
2. **VU 取整**：`1500/4=375` 整除；若是 `1501/4`，余数按 `i < REM` 分给前几片，务必保证总和等于目标值，否则报告的"总并发"与实际不符；
3. **客户端总资源** = 分片数 × 单 Job `limits`。4 片 × 2 核 = 8 核上限，排到同一节点会互相抢；用 `nodeSelector`/反亲和或降低单片 `limits`；
4. **误差来源**：各分片的 `duration` 起点有几秒差异，聚合 RPS 是"平均速率之和"，不是严格同窗口；做 SLO 判定时以最差分片的 P95 为准更稳；
5. **配额/限流共池**：N 个分片共享同一个 token 配额与同一个限流桶（按 IP 或按用户），片数越多越容易触发 429——先用小档确认限流阈值；
6. **判定**：任一分片阈值破线，该 Job `failed`；等待逻辑需对每个分片判断 `succeeded||failed`（`sharded.sh` 已处理），否则会像早期 stage 脚本那样白等。

---

### 12.7 收尾

```bash
# 恢复被临时修改的限流配置
kubectl -n new-api-perf patch cm new-api-config --type json \
  -p '[{"op":"remove","path":"/data/GLOBAL_API_RATE_LIMIT"},{"op":"remove","path":"/data/GLOBAL_API_RATE_LIMIT_DURATION"}]'
kubectl -n new-api-perf rollout restart deploy/perf-new-api-slave
# 恢复 mock 正常档（degrade/long 会自动恢复，手动兜底）
bash deploy/lib/ack_remote_jkt_dev.sh deploy/perf/mock-upstream/mock_ctl.sh   # 默认 normal
```

---

## 13. 常见问题（FAQ）

**Q1：为什么不用 `http_req_duration` 判断首字？**
A：k6 收完整个响应体才返回，SSE 下 `duration` 是整条流时长。首字用 `http_req_waiting`（TTFB）。

**Q2：为什么 1500 VU 只跑出 639 RPS？**
A：每条流持续约 2.1s，`1500 ÷ 2.1 ≈ 714`，实测 639 属正常（建连、排队、tail）。要看真实"并发能力"就用 VU；要看 QPS 能力就用 `constant-arrival-rate`。

**Q3：阈值没过，为什么还在跑？**
A：阈值只在测试结束判定。要"一破线就停"需 `abortOnFail: true`（k6 0.5x 支持）。

**Q4：为什么 Job 显示 Failed，但日志里有完整摘要？**
A：阈值不成立 → 退出码 99 → Job failed。结果仍然有效，脚本要同时判断 `status.failed`。

**Q5：怎么测 SSE 的"第 N 个 token 时间"？**
A：k6 官方不支持半流读取。可选：① 用 `k6/x/` 扩展或自定义 Go 客户端；② 在网关/上游打点（trace）；③ 用 TTFB + `receiving` 估算。

**Q6：内网和公网数字能直接比吗？**
A：不能。公网多一跳 NAT/EIP + ALB，且受 EIP 带宽限制。报告里必须标注路径。

---

## 14. 一页速查表

```text
脚本骨架
  import http from 'k6/http'; import { check } from 'k6';
  export const options = { scenarios:{...}, thresholds:{...} };
  export default function(){ const r = http.post(url, body, {headers, timeout, tags}); check(r, {...}); }

执行器选择
  固定并发      → constant-vus
  阶梯/突发     → ramping-vus
  固定 QPS      → constant-arrival-rate（配 preAllocatedVUs/maxVUs）
  固定次数      → per-vu-iterations / shared-iterations

口径
  RPS       = http_reqs.rate
  首字      = http_req_waiting p95（TTFB 代理）
  端到端    = http_req_duration p95
  并发      ≈ RPS × avg_duration（Little）
  副本数    = ceil(目标并发 / 单副本拐点)

运行
  k6 run script.js            # 本地
  kubectl apply -f job.yaml   # 集群内（推荐）

判据
  阈值失败 → 退出码 99 → Job failed（结果仍有效）
```

---

## 15. 相关文件索引

| 路径 | 说明 |
|---|---|
| `deploy/perf/k6/sse.js` | 恒定 VU SSE |
| `deploy/perf/k6/s3_burst.js` | 突发 |
| `deploy/perf/k6/s4_admin.js` | 管理面到达率 |
| `deploy/perf/k6/s9_long.js` | 长流 |
| `deploy/perf/k6/run.sh` | 本机入口（stage/dual1500/shard/burst/admin/degrade/rolling/long/summary/readback） |
| `deploy/perf/k6/bodies/*.sh` | 节点侧执行体（`sharded.sh` = 多 Job 分片并行） |
| `deploy/perf/k6/report.py` | 单文件 HTML 报告生成 |
| `deploy/perf/mock-upstream/` | mock 上游与 `mock_ctl.sh` |
| `deploy/perf/perf_reports/` | 报告与日志 |
| `deploy/perf/README.md` / `deploy/perf/k6/README.md` | 目录索引与用法 |
| `deploy/jakarta_dev_ledger.md` §23/§24 | 本轮压测台账 |
