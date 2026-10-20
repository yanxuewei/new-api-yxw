#!/bin/bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件内的对象名已失效
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   ⇒ 凡出现旧名的 kubectl 操作：只读诊断会 NotFound；apply / patch / scale 类会
#     重新造出旧对象并与新对象抢标签 ⇒ **不要重跑本文件**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**，只读诊断仍可用。
# =============================================================================
# bodies/fix_perf_channel_url.sh —— 把 mock-perf 渠道的 base_url 改成"不带 /v1"，并复测经网关的 SSE
# 依据（代码事实，不是试错猜出来的）：relay/common/relay_utils.go:26 `GetFullRequestURL` =
#   `fmt.Sprintf("%s%s", baseURL, requestURL)`，requestURL 就是 `/v1/chat/completions`；
#   `TrimPrefix(requestURL,"/v1")` 只对 `https://gateway.ai.cloudflare.com` 前缀生效。
#   ⇒ base_url 写成 `http://mock…/v1` 会拼成 `/v1/v1/chat/completions` ⇒ mock 404 ⇒ 网关包成
#   `bad_response_status_code`（B4 实测 6 次全 404，且 401 已先被修掉：见 D 段诊断）。
# 做法：删掉我自己 5 分钟前建的那条错渠道（DELETE /api/channel/:id），再按正确形态 POST 一条；不碰别人的对象。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
ADMIN_PW=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' | base64 -d)
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' | base64 -d)
TKID=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_id}' | base64 -d)
jval() { python3 -c "import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    d = d.get(k) if isinstance(d, dict) else None
print('' if d is None else d)"; }
printf '=== F0 网关=%s token_id=%s keylen=%s\n' "$GW" "${TKID:-?}" "${#TKKEY}"
AT=$(curl -sS -m 15 -H 'Content-Type: application/json' --data "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\"}" \
  "$GW/api/user/login" 2>&1 | jval data.access_token)
[ -n "$AT" ] || { echo "    [XX] 登录失败"; exit 0; }
printf '    登录 OK（access_token 指纹 %s）\n' "$(printf '%s' "$AT" | md5sum | cut -c1-10)"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-fix, namespace: new-api-perf, labels: {app: t2p-fix, track: perf, env: dev}}
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
kubectl -n $NS wait --for=condition=Ready pod/t2p-fix --timeout=240s >/dev/null 2>&1
Q() { kubectl -n $NS exec -i t2p-fix -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== F1 现状（错 base_url 的渠道）"
Q "select id||' | '||name||' | '||base_url from channels where name='mock-perf'" | sed 's/^/      /'
BADID=$(Q "select id from channels where name='mock-perf' and base_url like '%/v1'" | tr -dc '0-9')
if [ -n "$BADID" ]; then
  echo "=== F2 删除错渠道 id=$BADID（只删这条），再按正确形态新建"
  printf '      delete 应答=%s\n' "$(curl -sS -m 20 -X DELETE -H "Authorization: Bearer $AT" "$GW/api/channel/$BADID" 2>&1 | head -c 120)"
else
  echo "=== F2 没有带 /v1 的 mock-perf 渠道 ⇒ 不删，只确保存在正确形态"
fi
printf '      add 应答=%s\n' "$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" --data \
  '{"mode":"single","channel":{"name":"mock-perf","type":1,"key":"mock-key-no-auth","base_url":"http://mock-upstream.new-api-perf.svc.cluster.local","models":"mock-gpt","group":"default","status":1,"weight":0,"priority":0,"proxy":""}}' \
  "$GW/api/channel/" 2>&1 | head -c 140)"
Q "select '现在渠道：'||id||' | '||base_url||' | status='||status::text from channels where name='mock-perf'" | sed 's/^/      /'

echo "=== F3 经网关的 SSE 复测（ttfb / 分块数 / 端到端耗时）"
SSE=/tmp/fix_$$.sse; OK=0
for i in 1 2 3 4 5 6; do
  M=$(curl -sS -m 30 -N -o "$SSE" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer} total=%{time_total}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
  ND=$(grep -c '^data:' "$SSE" 2>/dev/null)
  printf '      #%s %s data=%s done=%s\n' "$i" "$(printf '%s' "$M" | tr -d '\r' | cut -c1-80)" "${ND:-0}" "$(grep -c '\[DONE\]' "$SSE" 2>/dev/null)"
  [ "${ND:-0}" -ge 3 ] && { OK=1; break; }
  [ "$i" = 1 ] && echo "        首次体[:150]=$(head -c 150 "$SSE" | tr -d '\n\r')"
  sleep 12
done
rm -f "$SSE"
if [ "$OK" = 1 ]; then
  echo "    判定 网关→渠道→mock：PASS ⇒ 压测先决条件全部闭合（鉴权、路由、URL 拼接、SSE 分块）"
else
  echo "    判定 网关→渠道→mock：FAIL ⇒ 停下上报，不带着断链跑压测"
  kubectl -n $NS logs "$(kubectl -n $NS get pod -l track=perf -o jsonpath='{.items[0].metadata.name}')" --tail=12 2>&1 \
    | sed -E 's/(sk-)[A-Za-z0-9]+/\1***/g' | tail -6 | sed 's/^/      /'
fi

echo "=== F4 计费/日志链是否落库（logs 行数）"
Q "select 'logs='||count(*) from logs"; Q "select 'token_used='||coalesce(used::text,'-')||' accessed='||coalesce(accessed_time::text,'-') from tokens where id=${TKID:-0}" | sed 's/^/      /'
kubectl -n $NS delete pod t2p-fix --ignore-not-found --wait=false >/dev/null 2>&1
echo "      临时 Pod 清理=$(kubectl -n $NS get pod t2p-fix -o name 2>&1 | head -1)"
echo "--- F0–F4 结束"
exit 0
