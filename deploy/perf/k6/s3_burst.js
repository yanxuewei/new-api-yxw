// s3_burst.js —— S3 突发：0 → VUS（默认 1500）在 30 秒内拉起，保持 DUR，再 10s 降回 0
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const sseComplete = new Rate('sse_complete');

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
    http_req_failed: ['rate<0.01'],
    sse_complete: ['rate>0.99'],
    'http_req_waiting{type:sse}': ['p(95)<1500'], // 突发期 TTFB；汇总指标不证明恢复时间
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
  let done = false;
  let finished = false;
  let valid = true;
  const events = typeof res.body === 'string' ? res.body.split(/\r?\n\r?\n/) : [];
  for (const event of events.slice(0, -1)) {
    const payload = event.split(/\r?\n/).filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).replace(/^ /, '')).join('\n');
    if (!payload) continue;
    if (done) { valid = false; break; }
    if (payload === '[DONE]') { done = finished; break; }
    try {
      const chunk = JSON.parse(payload);
      if (!chunk || chunk.error) { valid = false; break; }
      if (Array.isArray(chunk.choices) && chunk.choices.some((choice) =>
        choice.index === 0 && ['stop', 'length', 'tool_calls', 'function_call'].includes(choice.finish_reason))) {
        finished = true;
      }
    } catch (_) {
      valid = false;
      break;
    }
  }
  sseComplete.add(res.status === 200 && valid && done);
  check(res, { 'status 200': (r) => r.status === 200, 'has [DONE]': () => done });
}
