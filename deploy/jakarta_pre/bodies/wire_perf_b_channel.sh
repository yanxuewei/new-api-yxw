#!/bin/bash
# bodies/wire_perf_b_channel.sh —— 压测链路第 2 步：登录 → 建渠道(→mock) → 建令牌 → 经网关跑通 1 条 SSE
# 前置：wire_perf_a_setup.sh 已把管理员口令落在 Secret `perf-load-test-credentials`（本步从那里读口令，不猜）。
# 实测契约（本步踩点记录）：`POST /api/token/` **不返回 data.id** ⇒ 令牌 id 用 SQL 回读取；
#   `POST /api/token/:id/key` 的 key 在 `data`；渠道 add 成功时 `data.id` 也为空 ⇒ 一律以 DB 回读为准（报错输出≠对象不存在）。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
fp() { printf '%s' "$1" | md5sum | cut -c1-10; }
jval() { python3 -c "import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    d = d.get(k) if isinstance(d, dict) else None
print('' if d is None else d)"; }
ADMIN_PW=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d)
[ -n "$ADMIN_PW" ] || { echo "    [XX] Secret 里没有 admin_password ⇒ 先跑 wire_perf_a_setup.sh"; exit 0; }
printf '=== B0 网关=%s 口令指纹=%s\n' "$GW" "$(fp "$ADMIN_PW")"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-wire2, namespace: new-api-perf, labels: {app: t2p-wire2, track: perf, env: dev}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 560"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-wire2 --timeout=240s >/dev/null 2>&1 || echo "    [!] psql Pod 未就绪"
Q() { kubectl -n $NS exec -i t2p-wire2 -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== B1 登录"
AT=$(curl -sS -m 15 -H 'Content-Type: application/json' --data "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\"}" \
  "$GW/api/user/login" 2>&1 | jval data.access_token)
[ -n "$AT" ] || { echo "      [XX] 登录失败（不重试猜口令）"; exit 0; }
printf '      access_token len=%s 指纹=%s\n' "${#AT}" "$(fp "$AT")"

echo "=== B2 渠道 mock-perf（幂等：已存在就不重复建）"
CHN=$(Q "select count(*) from channels where name='mock-perf'" | tr -dc '0-9')
if [ "${CHN:-0}" = 0 ]; then
  # base_url **不带 /v1**：relay/common/relay_utils.go 的 GetFullRequestURL 是 `base_url + "/v1/chat/completions"`
  #   （只有 cloudflare gateway 前缀才会 TrimPrefix("/v1")）⇒ 写 `.../v1` 会拼成 `/v1/v1/chat/completions`，
  #   mock 直接 404，网关报 `bad_response_status_code`。2026-10-19 实测踩过。
  CR=$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" --data \
    '{"mode":"single","channel":{"name":"mock-perf","type":1,"key":"mock-key-no-auth","base_url":"http://mock-upstream.new-api-perf.svc.cluster.local","models":"mock-gpt","group":"default","status":1,"weight":0,"priority":0,"proxy":""}}' \
    "$GW/api/channel/" 2>&1)
  printf '      add 应答=%s\n' "$(printf '%s' "$CR" | head -c 140)"
else
  echo "      渠道已存在 ⇒ 跳过 add"
fi
printf '      DB 回读：%s\n' "$(Q "select id||' | '||name||' | '||coalesce(base_url,'-')||' | status='||status::text||' | models='||coalesce(models,'-') from channels where name='mock-perf'" | head -1)"

echo "=== B3 令牌 perf-load（add 不回 id ⇒ SQL 取 id 再取 key，随后回写 Secret）"
# 实测订正（D 段诊断的结论）：`POST /api/token/:id/key` 的 `data` 是**对象**不是字符串，
#   旧写法 `jval data` 会把 dict 直接 print 出来（len=59、不含 `sk-`），拿去当 Bearer 必然
#   `ValidateUserToken: record not found` ⇒ 401。库里 `tokens.key` 的真实形态是 **48 位、无连字符、不带 sk- 前缀**。
#   ⇒ key 一律以 SQL 回读为准，并校验形态后才用。
TNN=$(Q "select count(*) from tokens where name='perf-load'" | tr -dc '0-9')
[ "${TNN:-0}" = 0 ] && printf '      add 应答=%s\n' \
  "$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" \
    --data '{"name":"perf-load","status":1,"unlimited_quota":true,"expired_time":-1,"group":"default"}' "$GW/api/token/" 2>&1 | head -c 120)"
TKID=$(Q "select id from tokens where name='perf-load' order by id limit 1" | tr -dc '0-9')
printf '      token id=%s\n' "${TKID:-无}"
[ -n "$TKID" ] || { echo "      [XX] 令牌未入库 ⇒ 停"; exit 0; }
TKKEY=$(Q "select key from tokens where id=$TKID" | head -1 | tr -d ' \r\n')
KLEN=${#TKKEY}; KHASDASH=$(printf '%s' "$TKKEY" | tr -cd '-' | wc -c)
printf '      key 形态：len=%s 连字符=%s 前缀sk-=%s 指纹=%s（值不外显）\n' \
  "$KLEN" "$KHASDASH" "$(case "$TKKEY" in sk-*) echo YES ;; *) echo NO ;; esac)" "$(fp "$TKKEY")"
if [ "$KLEN" -lt 20 ] || [ "$KHASDASH" != 0 ]; then
  echo "      [XX] key 形态不符合鉴权规则（middleware 会 TrimPrefix sk- 再按 '-' 切第一段）⇒ 停，不拿脏值去压"
  exit 0
fi
kubectl -n $NS create secret generic $SEC --from-literal=admin_username=perfroot \
  --from-literal=admin_password="$ADMIN_PW" --from-literal=token_id="$TKID" --from-literal=token_key="$TKKEY" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
echo "      已回写 Secret（压测驱动以后从 Secret 取 key，不经命令体）"

echo "=== B4 经网关跑通 1 条 SSE（渠道缓存未热就重试）"
SSE=/tmp/perf_b_$$.sse; OK=0
for i in 1 2 3 4 5 6; do
  M=$(curl -sS -m 30 -N -o "$SSE" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer} total=%{time_total}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
  ND=$(grep -c '^data:' "$SSE" 2>/dev/null)
  printf '      #%s %s data=%s\n' "$i" "$(printf '%s' "$M" | tr -d '\r' | cut -c1-84)" "${ND:-0}"
  [ "${ND:-0}" -ge 3 ] && { OK=1; break; }
  [ "$i" = 1 ] && echo "        首次响应体[:200]=$(head -c 200 "$SSE" | tr -d '\n\r')"
  sleep 12
done
[ "$OK" = 1 ] && echo "    判定 网关→渠道→mock：PASS ⇒ 可进 S2 降档压测" || echo "    判定 网关→渠道→mock：FAIL ⇒ 按上面响应体定位"
rm -f "$SSE"
echo "=== B5 终态只读回读"
Q "select 'channels='||count(*) from channels"; Q "select 'tokens='||count(*) from tokens"; Q "select 'logs='||count(*) from logs"
kubectl -n $NS delete pod t2p-wire2 --ignore-not-found --wait=false >/dev/null 2>&1
echo "      临时 Pod 清理=$(kubectl -n $NS get pod t2p-wire2 -o name 2>&1 | head -1)"
echo "--- B0–B5 结束"
exit 0
