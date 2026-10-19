#!/bin/bash
# bodies/diag_perf_403.sh —— 800 档那 10976 个 http_403 到底是什么（只读）
# 假设（可证伪）：不是容量问题，也不是限流，而是**账号额度耗尽**——累计成功流 40591 条，
#   每条按 mock-gpt 计费扣 users.quota（root 初始 1e8）。若成立，则"现在单发一条"也会立刻 403，
#   且 users.quota 应已归零/转负、used 明显上涨；限流类假设则表现为"现在重试就通"。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' | base64 -d)

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-q, namespace: new-api-perf, labels: {app: t2p-q, track: perf, env: dev}}
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
kubectl -n $NS wait --for=condition=Ready pod/t2p-q --timeout=240s >/dev/null 2>&1
Q() { kubectl -n $NS exec -i t2p-q -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== H1 额度与用量（quota 归零/转负 ⇒ 假设成立）"
# 列名以 fork 实际模型为准：users 是 quota + used_quota（不是 used），tokens 是 remain_quota + used_quota
Q "select 'users: id='||id::text||' quota='||quota::text||' used_quota='||used_quota::text||' req='||request_count::text||' status='||status::text from users order by id" | sed 's/^/      /'
Q "select 'tokens: id='||id::text||' status='||status::text||' unlimited='||unlimited_quota::text||' remain='||remain_quota::text||' used='||used_quota::text||' expired='||expired_time::text from tokens order by id" | sed 's/^/      /'
Q "select 'logs: 总数='||count(*)::text from logs" | sed 's/^/      /'
Q "select 'logs: type 分布='||string_agg(type::text||':'||c,',' ) from (select type, count(*) c from logs group by type order by type) t" 2>&1 | sed 's/^/      /'
Q "select 'logs: 动作分布(前6)='||string_agg(action_total,',' ) from (select coalesce(action,'(空)')||'='||count(*)::text action_total from logs group by action order by count(*) desc limit 6) t" 2>&1 | sed 's/^/      /'

echo "=== H2 现在单发一条（若额度耗尽，此刻也应 403，且能拿到 message 原文）"
OUT=/tmp/h2_$$.body
M=$(curl -sS -m 25 -N -o "$OUT" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}' \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
  --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
printf '      %s\n      body[:260]=%s\n' "$(printf '%s' "$M" | tr -d '\r')" "$(head -c 260 "$OUT" | tr -d '\n\r')"
rm -f "$OUT"

echo "=== H3 网关日志里这一族的真实错误（脱敏 tail）"
POD=$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
kubectl -n $NS logs "$POD" --tail=400 2>&1 | grep -iE '403|quota|额度|forbidden|limit|频繁|ban' | tail -10 \
  | sed -E 's/(sk-|key=|token=|password=)[A-Za-z0-9_+=-]+/\1***/g' | sed 's/^/      /'

echo "=== H4 限流相关 option 的实际值（值是配置项，非凭据）"
Q "select key||'='||coalesce(value,'(空)') from options order by key" 2>&1 | grep -iE 'limit|quota|rate|group|ban' | head -14 | sed 's/^/      /'
Q "select 'options 总数='||count(*)::text from options" | sed 's/^/      /'
kubectl -n $NS delete pod t2p-q --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- H1–H4 结束（只读）"
exit 0
