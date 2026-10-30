// deploy/perf/k6/relay-chat.js —— S1（非流式）/ S2（流式）中继主链路压测脚本
//
// 设计要点（对应 impl_tech.md §3.9）：
//   · 同时支持开环（constant-arrival-rate）与闭环（constant-vus）：
//       EXECUTOR=arrival → 回答"能接多少 QPS"（S1/S3 用）
//       EXECUTOR=vus     → 保持并发（S2 的 1500 并发 SSE 用）
//   · 首字用 http_req_waiting 作 TTFB 代理（非流式时等价于整请求时延）
//   · 输出 relay_success / relay_ttft_ms / relay_tps，供 report 与 1.3 目标逐项比对
//
// 必需 env：BASE（如 http://perf-new-api-slave.new-api-perf.svc.cluster.local）、TOKEN
// 可选 env：STREAM(true|false) MODEL MAX_TOKENS DUR VUS RATE PRE_VUS MAX_VUS EXECUTOR
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate } from 'k6/metrics';

const BASE = (__ENV.BASE || '').replace(/\/$/, '');
const TOKEN = __ENV.TOKEN || '';
const MODEL = __ENV.MODEL || 'mock-gpt';
const STREAM = (__ENV.STREAM || 'false') === 'true';
const MAX_TOKENS = Number(__ENV.MAX_TOKENS || 128);
const DUR = __ENV.DUR || '60s';
// EXECUTOR 未显式指定时按入参推断：arrival.sh 会注入 RATE，stage.sh 只注入 VUS
const EXECUTOR = ((__ENV.EXECUTOR || (__ENV.RATE ? 'arrival' : 'vus')) === 'arrival') ? 'arrival' : 'vus';
const RATE = Number(__ENV.RATE || 100);
const PRE = Number(__ENV.PRE_VUS || RATE * 3);
const MAXV = Number(__ENV.MAX_VUS || RATE * 6);
const VUS = Number(__ENV.VUS || 100);

export const ttft = new Trend('relay_ttft_ms', true);
export const success = new Rate('relay_success');
export const tps = new Trend('relay_tps', true);

export const options = {
  scenarios: {
    main: EXECUTOR === 'arrival'
      ? {
          executor: 'constant-arrival-rate',
          rate: RATE, timeUnit: '1s', duration: DUR,
          preAllocatedVUs: PRE, maxVUs: MAXV, gracefulStop: '30s',
        }
      : { executor: 'constant-vus', vus: VUS, duration: DUR, gracefulStop: '30s' },
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const payload = JSON.stringify({
    model: MODEL,
    stream: STREAM,
    max_tokens: MAX_TOKENS,
    messages: [{ role: 'user', content: 'perf' }],
  });

  const res = http.post(`${BASE}/v1/chat/completions`, payload, {
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    timeout: '60s',
    tags: { type: STREAM ? 'sse' : 'json' },
  });

  const okReq = check(res, { 'status 200': (r) => r.status === 200 });
  if (STREAM) {
    check(res, { 'has [DONE]': (r) => (r.body || '').indexOf('[DONE]') >= 0 });
  }
  success.add(okReq);
  ttft.add(res.timings.waiting);

  // tps：优先取上游 usage，缺失时按 max_tokens 估算（mock 不一定返回 usage）
  let tokens = MAX_TOKENS;
  try {
    const j = JSON.parse(res.body);
    if (j && j.usage && j.usage.completion_tokens) tokens = j.usage.completion_tokens;
  } catch (e) { /* SSE 正文不是 JSON，忽略 */ }
  const sec = res.timings.duration / 1000;
  if (sec > 0) tps.add(tokens / sec);
}
