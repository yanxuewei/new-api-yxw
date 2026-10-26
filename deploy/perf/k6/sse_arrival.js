// sse_arrival.js —— SSE 开环到达率压测（constant-arrival-rate）
//
// 与 sse.js 的 constant-vus 不同：这里按目标 RPS 发请求，不受单请求耗时反压，
// 用于回答“网关能承接多少 QPS”。1500 rps × 1.8s ≈ 2700 并发，需按 RATE 设置足够的
// preAllocatedVUs/maxVUs，并做好多 Job 分片（单 k6 进程 CPU 有限）。
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const sseComplete = new Rate('sse_complete');
const status0 = new Counter('status_0');
const status4xx = new Counter('status_4xx');
const status5xx = new Counter('status_5xx');
const errSample = new Counter('err_sample');

const BASE = __ENV.BASE;
const MODEL = __ENV.MODEL || 'mock-gpt';
const TOKEN = __ENV.TOKEN;
const TOKENS = (__ENV.TOKENS || '').split(',').map((s) => s.trim()).filter(Boolean);
const SHARD = __ENV.SHARD || '0';
const RATE = Number(__ENV.RATE || 100);
const DUR = __ENV.DUR || '120s';

export const options = {
  scenarios: {
    sse_rate: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DUR,
      preAllocatedVUs: Number(__ENV.PRE_VUS || Math.ceil(RATE * 2)),
      maxVUs: Number(__ENV.MAX_VUS || Math.ceil(RATE * 4)),
      gracefulStop: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.0005'],
    sse_complete: ['rate>0.9995'],
    'http_req_waiting{type:sse}': ['p(95)<800'],
    dropped_iterations: ['count==0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const body = JSON.stringify({
    model: MODEL,
    stream: true,
    messages: [{ role: 'user', content: 'perf-arrival' }],
  });
  const res = http.post(`${BASE}/v1/chat/completions`, body, {
    headers: {
      Authorization: `Bearer sk-${TOKENS.length ? TOKENS[(__VU - 1) % TOKENS.length] : TOKEN}`,
      'Content-Type': 'application/json',
    },
    timeout: '120s',
    tags: { type: 'sse', shard: SHARD },
  });
  if (res.status === 0) status0.add(1);
  else if (res.status >= 500) {
    status5xx.add(1);
    errSample.add(1, { msg: String(res.body || '').replace(/[^\x20-\x7e]/g, ' ').slice(0, 90) });
    if (__VU <= 5) {
      console.log(`ERR vu=${__VU} status=${res.status} err=${res.error || ''} code=${res.error_code || ''} body=${String(res.body || '').slice(0, 160)}`);
    }
  } else if (res.status >= 400) status4xx.add(1);
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
