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
  const res = http.get(`${BASE}/api/channel/`, {
    headers: { Authorization: `Bearer ${data.token}` },
    tags: { type: 'admin' }, timeout: '10s',
  });
  check(res, { 'status 200': (r) => r.status === 200 });
};
