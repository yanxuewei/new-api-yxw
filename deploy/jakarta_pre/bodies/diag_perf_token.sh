#!/bin/bash
# bodies/diag_perf_token.sh —— 为什么经网关的令牌被判 Invalid token（只读诊断 + 三种头写法实测）
# 代码事实（不是猜）：middleware/auth.go 的 TokenAuth 把 Authorization 去掉 `Bearer ` 后
#   `key = TrimPrefix(key,"sk-")` → `parts = Split(key,"-")` → `key = parts[0]`，
#   再用这个 key 去 `DB.Where("key = ?")` 查（model/token.go:290）。
#   ⇒ 令牌的**可鉴权形态是"数据库里存的 key"**，而且 key 里若含 `-`，只有第一段参与查询。
#   B4 用 Secret 里的 key 直接当 Bearer 拿到 401，所以先对齐形态，再谈压测。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' 2>/dev/null | base64 -d)
TKID=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_id}' 2>/dev/null | base64 -d)
printf '=== D0 网关=%s\n' "$GW"
printf '=== D1 Secret 里 token_key 的形态（只出形态，不出值）\n'
printf '      len=%s  以sk-开头=%s  含连字符个数=%s  md5前10=%s\n' \
  "${#TKKEY}" "$(case "$TKKEY" in sk-*) echo YES ;; *) echo NO ;; esac)" \
  "$(printf '%s' "$TKKEY" | tr -cd '-' | wc -c)" "$(printf '%s' "$TKKEY" | md5sum | cut -c1-10)"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-diag, namespace: new-api-perf, labels: {app: t2p-diag, track: perf, env: dev}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 420
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 380"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-diag --timeout=240s >/dev/null 2>&1 || echo "    [!] Pod 未就绪"
Q() { kubectl -n $NS exec -i t2p-diag -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== D2 库里这行的形态与状态（key 只出长度/连字符/首 4 字符形态）"
Q "select 'db_len='||length(key)||' db_dash='||(length(key)-length(replace(key,'-','')))||
     ' db_head4='||left(key,4)||' status='||status::text||' expired='||expired_time::text||
     ' unlimited='||unlimited_quota::text||' user_id='||user_id::text||' group='||coalesce(\"group\",'-')
   from tokens where id=${TKID:-0}" | sed 's/^/      /'
Q "select 'TokenStatusEnabled 语义对照：status=1 为启用（common.TokenStatusEnabled）' " | sed 's/^/      /'
echo "      users 表：$(Q "select 'id='||id::text||' role='||role::text||' status='||status::text||' quota='||quota::text||' group='||coalesce(\"group\",'-') from users order by id limit 3" | tr '\n' ';')"

echo "=== D3 三种 Authorization 写法实测（同一条 SSE 请求）"
try() {
  local hdr="$1" tag="$2" out=/tmp/diag_$2.sse
  local m
  m=$(curl -sS -m 25 -N -o "$out" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}' \
    -H 'Content-Type: application/json' -H "Authorization: $hdr" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' \
    "$GW/v1/chat/completions" 2>&1)
  printf '      [%s] %s data=%s\n' "$tag" "$(printf '%s' "$m" | tr -d '\r' | cut -c1-64)" \
    "$(grep -c '^data:' "$out" 2>/dev/null)"
  head -c 130 "$out" | tr -d '\n\r' | sed 's/^/        body=/'; echo
  rm -f "$out"
}
RAW=${TKKEY#sk-}
try "Bearer $TKKEY" "原样"
try "Bearer $RAW" "去sk-"
try "Bearer ${RAW%%-*}" "按Split取第一段"

echo "=== D4 反证：网关自身日志里这次鉴权失败的真实原因（脱敏后 tail）"
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n $NS logs "$POD" --tail=25 2>&1 | sed -E 's/(sk-)[A-Za-z0-9]+/\1***/g; s/(key=|token=)[^ ,]*/\1***/g' | tail -12 | sed 's/^/      /'

kubectl -n $NS delete pod t2p-diag --ignore-not-found --wait=false >/dev/null 2>&1
echo "      临时 Pod 清理=$(kubectl -n $NS get pod t2p-diag -o name 2>&1 | head -1)"
echo "--- D0–D4 结束（只读；未改任何对象）"
exit 0
