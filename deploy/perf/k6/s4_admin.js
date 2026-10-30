// s4_admin.js —— S4 管理面：恒定到达率 RATE（默认 800 QPS）打读接口 /api/channel/
// 登录在 setup() 里做一次；每请求带 JWT。管理面目标是吞吐能力，不是 SSE。
import http from 'k6/http';
import { check } from 'k6';

const RATE = Number(__ENV.RATE || 800);
const DUR = __ENV.DUR || '60s';
const BASE = __ENV.BASE;
const USER = __ENV.ADMIN_USER;
const PASS = __ENV.ADMIN_PASS;

export const options = {
  scenarios: {
    admin: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DUR,
      preAllocatedVUs: Math.max(50, Math.ceil(RATE / 20)),
      maxVUs: Math.max(200, RATE),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    dropped_iterations: ['count==0'],
    'http_req_duration{type:admin}': ['p(95)<1000'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  const r = http.post(`${BASE}/api/user/login`, JSON.stringify({ username: USER, password: PASS }), {
    headers: { 'Content-Type': 'application/json' }, timeout: '10s',
  });
  const body = r.json() || {};
  return { token: (body.data || {}).access_token || '' };
}

export default (data) => {
  const headers = { Authorization: `Bearer ${data.token}` };
  // §3.9 S3 要求同时覆盖「渠道列表」与「日志分页」；两次请求沿用同一 tag(type=admin)，
  // 以复用文件上方已有的 thresholds（否则阈值因无样本而报 error）。
  const urls = [
    `${BASE}/api/channel/?p=0&page_size=100`,
    `${BASE}/api/log/?p=0&page_size=100&type=0`,
  ];
  for (const url of urls) {
    const res = http.get(url, { headers, tags: { type: 'admin' }, timeout: '10s' });
    let success = false;
    try {
      const body = res.json();
      success = res.status === 200 && body !== null && body.success === true;
    } catch (_) {
      success = false;
    }
    check(res, { 'admin success': () => success });
  }
};
