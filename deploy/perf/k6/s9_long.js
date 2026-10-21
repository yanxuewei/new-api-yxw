// s9_long.js —— S9 长流：单请求、单 VU，观察 ALB 600s 上限行为（配合 mock 把 tokens_per_response 调大）
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE;
const MODEL = __ENV.MODEL || 'mock-gpt';
const TOKEN = __ENV.TOKEN;

export const options = {
  scenarios: {
    long: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 1,
      maxDuration: '14m',
    },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.post(`${BASE}/v1/chat/completions`, JSON.stringify({
    model: MODEL, stream: true, messages: [{ role: 'user', content: 'perf-s9' }],
  }), {
    headers: { Authorization: `Bearer sk-${TOKEN}`, 'Content-Type': 'application/json' },
    timeout: '800s', tags: { type: 'sse' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
