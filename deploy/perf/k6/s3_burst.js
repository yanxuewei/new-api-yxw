// s3_burst.js —— S3 突发：0 → VUS（默认 1500）在 30 秒内拉起，保持 DUR，再 10s 降回 0
import http from 'k6/http';
import { check } from 'k6';

const VUS = Number(__ENV.VUS || 1500);
const HOLD = __ENV.DUR || '90s';
const BASE = __ENV.BASE;
const MODEL = __ENV.MODEL || 'mock-gpt';
const TOKEN = __ENV.TOKEN;

export const options = {
  scenarios: {
    burst: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: VUS },
        { duration: HOLD, target: VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],            // 突发窗口容忍 ≤1%
    'http_req_waiting{type:sse}': ['p(95)<1500'], // 突发期首字放宽到 1.5s（S3 判据：30s 内回稳）
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.post(`${BASE}/v1/chat/completions`, JSON.stringify({
    model: MODEL, stream: true, messages: [{ role: 'user', content: 'perf-s3' }],
  }), {
    headers: { Authorization: `Bearer sk-${TOKEN}`, 'Content-Type': 'application/json' },
    timeout: '120s', tags: { type: 'sse' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
