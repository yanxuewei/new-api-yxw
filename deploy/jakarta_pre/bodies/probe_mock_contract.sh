#!/bin/bash
# bodies/probe_mock_contract.sh —— 压测前置：**只读**实测 mock-upstream 的接口契约
# 为什么要它：台账 §20.4 唯一没闭合的一点——从 perf Pod 打 `/` 拿到空 body，所以"6/6 Running"
#   证明不了"`/v1/chat/completions` 能出 SSE 流"。S1/S2 的首字判据全依赖这条链路。
# 上一版（2026-10-19 首跑）的自曝 bug：`CPod` 用 `{range} {.port}{" "}` 取到 `8080 `（带尾空格），
#   拼出来的 URL 变成 `http://ip:8080 /path` ⇒ curl `(3) Port number ended with ' '` ⇒ M3/M4/M5 全 000，
#   被我误读成"mock 不是 OpenAI 兼容 SSE"。同一次执行里 M6（ClusterIP）HTTP=200 + 10230 字节 +
#   `data: {"choices":[{"delta":...` 直接反证了那个 FAIL。⇒ 端口变量必须过 tr -d ' '。
# 合规：只做 GET/POST 与只读 get；不 apply/delete/patch；输出不含凭据。
set -uo pipefail
NS=new-api-perf
PROBE_TMP=$(mktemp -d /tmp/mockprobe.XXXXXX)
trap 'rm -rf "$PROBE_TMP"' EXIT

# 端口解析（本版修的就是这里）：先去空白，再取第一个
EPPORT=$(kubectl -n $NS get endpoints mock-upstream -o jsonpath='{.subsets[0].ports[0].port}' 2>/dev/null | tr -dc '0-9')
[ -n "$EPPORT" ] || EPPORT=8080
SPORT=$(kubectl -n $NS get svc mock-upstream -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
CIP=$(kubectl -n $NS get svc mock-upstream -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r\n')
PODS=$(kubectl -n $NS get endpoints mock-upstream -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | tr -d ' \r' | grep -v '^$')
printf '=== P0 目标：svc=%s:%s  endpointPort=%s  后端 %s 个\n' \
  "${CIP:--}" "${SPORT:-?}" "$EPPORT" "$(printf '%s\n' "$PODS" | wc -l)"

echo "=== P1 路由应答矩阵（Pod 直连，第一个后端）"
PIP=$(printf '%s\n' "$PODS" | head -1)
for P in / /health /healthz /metrics /v1/models /v1/chat/completions; do
  printf '    GET %-21s ⇒ ' "$P"
  CODE=$(curl -sS -m 8 -o "$PROBE_TMP/b" -w '%{http_code}' "http://$PIP:$EPPORT$P" 2>"$PROBE_TMP/e")
  printf 'HTTP=%s bytes=%s  err=%s  body[:60]=%s\n' "${CODE:-000}" \
    "$(wc -c <"$PROBE_TMP/b" 2>/dev/null)" "$(head -c 40 "$PROBE_TMP/e" 2>/dev/null | tr -d '\n')" \
    "$(head -c 60 "$PROBE_TMP/b" 2>/dev/null | tr -d '\n\r')"
done

echo "=== P2 SSE 分块证据（关键判据：首块是否早于收尾）"
do_stream() {
  local url="$1" tag="$2" out="$PROBE_TMP/sse.$2"
  local t0 t1 meta
  t0=$(date +%s.%N)
  meta=$(curl -sS -m 30 -N -D "$PROBE_TMP/h.$tag" -o "$out" \
    -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer} total=%{time_total}' \
    -H 'Content-Type: application/json' \
    --data '{"model":"mock","messages":[{"role":"user","content":"hi"}],"stream":true}' "$url" 2>&1)
  t1=$(date +%s.%N)
  printf '    [%s] %s\n' "$tag" "$(printf '%s' "$meta" | tr -d '\r')"
  printf '      墙钟=%.2fs  data行数=%s  [DONE]=%s  role=assistant出现=%s\n' \
    "$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.2f", a-b}')" \
    "$(grep -c '^data:' "$out" 2>/dev/null)" "$(grep -c '\[DONE\]' "$out" 2>/dev/null)" \
    "$(grep -c '"role":"assistant"' "$out" 2>/dev/null)"
  echo "      content-type: $(grep -i '^content-type' "$PROBE_TMP/h.$tag" 2>/dev/null | tr -d '\r')"
  echo "      首块: $(head -c 130 "$out" 2>/dev/null | tr -d '\n\r')"
}
do_stream "http://$PIP:$EPPORT/v1/chat/completions" pod
do_stream "http://$CIP:$SPORT/v1/chat/completions" svc

echo "=== P3 非流式（网关 fallback 路径；ERROR_RATE=0 ⇒ 不该出现 5xx）"
printf '    非流式 ⇒ %s\n' "$(curl -sS -m 20 -w ' http=%{http_code} bytes=%{size_download} total=%{time_total}' \
  -H 'Content-Type: application/json' \
  --data '{"model":"mock","messages":[{"role":"user","content":"hi"}],"stream":false}' \
  "http://$CIP:$SPORT/v1/chat/completions" 2>&1 | head -c 260 | tr -d '\r')"

echo "=== P4 单连接时序自证：首 token 延迟应≈FIRST_TOKEN_DELAY_MS，块间隔≈TOKEN_INTERVAL_MS"
python3 - "$CIP" "$SPORT" <<'PY' 2>&1 | sed 's/^/    /'
import socket, time, sys
host, port = sys.argv[1], int(sys.argv[2])
body = b'{"model":"mock","messages":[{"role":"user","content":"hi"}],"stream":true}'
req = (b'POST /v1/chat/completions HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\n'
       b'Content-Length: %d\r\nConnection: close\r\n\r\n') % (host.encode(), len(body))
s = socket.create_connection((host, port), timeout=30)
t0 = time.time(); s.sendall(req + body)
first = None; gaps = []; n = 0; buf = b''
while True:
    try:
        chunk = s.recv(4096)
    except Exception:
        break
    if not chunk: break
    now = time.time()
    if first is None and b'data:' in chunk:
        first = now - t0
    buf += chunk
    while b'\n' in buf:
        line, buf = buf.split(b'\n', 1)
        line = line.strip()
        if line.startswith(b'data:'):
            prev = now
            n += 1
            gaps.append(now)
    if b'[DONE]' in chunk:
        break
s.close()
if len(gaps) >= 3:
    inter = [(gaps[i+1]-gaps[i])*1000 for i in range(len(gaps)-1)]
    inter = [x for x in inter if x > 0.5]
    med = sorted(inter)[len(inter)//2] if inter else 0
else:
    med = 0
print('首块=%.0fms  data块数=%d  块间隔中位=%.0fms  总时长=%.2fs' % (
    (first or 0)*1000, n, med, gaps[-1]-t0 if gaps else 0))
print('判定：与 env(FIRST_TOKEN_DELAY_MS=300 / TOKEN_INTERVAL_MS=30 / TOKENS_PER_RESPONSE=50) 对照 ⇒ '
      + ('一致，可控延迟上游可用' if (first or 0)*1000 < 900 and 5 <= med <= 90 and n >= 20 else '偏差，见下'))
PY

echo "=== P5 网关侧路由存在性（不带 key 应当 401/403，证明 /v1 通道在，而不是"根本没这个路由"）"
GPOD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
printf '    POD=%s\n' "${GPOD:-无}"
[ -n "$GPOD" ] && kubectl -n $NS exec "$GPOD" -- sh -c \
  'wget -S -qO- -T 8 --header="Content-Type: application/json" --post-data='\''{"model":"gpt-4","messages":[{"role":"user","content":"x"}],"stream":true}'\'' http://127.0.0.1:3000/v1/chat/completions 2>&1 | head -14' 2>&1 \
  | sed -E 's/(Bearer |api_key=|sk-)[A-Za-z0-9._-]+/\1***/g; s/^/      /'

echo "--- P0–P5 结束（只读；无 apply/delete/patch）"
exit 0
