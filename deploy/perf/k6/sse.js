// sse.js —— 任务 33 的 SSE 打流脚本（k6 0.5x）
//
// 口径说明：
//   - k6 的 http 模块不做"半流式读取"，因此 **首字延迟用 `http_req_waiting`（TTFB）** 近似 ——
//     SSE 下响应头先到、首块紧随，mock 的首字延迟=300ms，TTFB 可作 P95 首字的代理指标。
//   - 一次迭代 = 一条完整 SSE（默认 50 token × 30ms ≈ 1.8s）+ 建连，恒定 VU 下 QPS ≈ VU / 2.1s。
//   - token 从环境变量传入（k8s secretKeyRef 注入 TOKEN=token_key，脚本自己加 sk- 前缀），
//     绝不出现在命令行/仓库里。
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const sseComplete = new Rate('sse_complete');

const VUS = Number(__ENV.VUS || 50);
const DUR = __ENV.DUR || '120s';
const BASE = __ENV.BASE;
const MODEL = __ENV.MODEL || 'mock-gpt';
const TOKEN = __ENV.TOKEN;
// 多用户压测：TOKENS 为逗号分隔的令牌列表，按 VU 轮转，避免所有请求命中同一用户/令牌热行。
const TOKENS = (__ENV.TOKENS || '').split(',').map((s) => s.trim()).filter(Boolean);
const SHARD = __ENV.SHARD || '0';   // 分片编号（多 Job 并行时用于区分指标）

export const options = {
  scenarios: {
    sse: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DUR,
      gracefulStop: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.0005'],
    sse_complete: ['rate>0.9995'],
    'http_req_waiting{type:sse}': ['p(95)<800'], // P95 首字（TTFB 代理）
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const body = JSON.stringify({
    model: MODEL,
    stream: true,
    messages: [{ role: 'user', content: 'perf-s1' }],
  });
  const res = http.post(`${BASE}/v1/chat/completions`, body, {
    headers: {
      Authorization: `Bearer sk-${TOKENS.length ? TOKENS[(__VU - 1) % TOKENS.length] : TOKEN}`,
      'Content-Type': 'application/json',
    },
    timeout: '120s',
    tags: { type: 'sse', shard: SHARD },
  });
  // 逐事件 JSON.parse 在 1500 VU 下本身就会拖慢压测客户端（每请求 ~50 次解析），
  // 因此改为单次正则校验：结束帧完整、且有成功 finish_reason、全程无 error 事件。
  const text = typeof res.body === 'string' ? res.body : '';
  const done = /(?:^|\n)data: ?\[DONE\]\r?\n\r?\n\s*$/.test(text);
  const finished = /data: ?\{[^\n]*"finish_reason": ?"(?:stop|length|tool_calls|function_call)"/.test(text);
  const errored = /data: ?\{[^\n]*"error"/.test(text);
  sseComplete.add(res.status === 200 && done && finished && !errored);
  check(res, {
    'status 200': (r) => r.status === 200,
    'has [DONE]': () => done,
  });
}
