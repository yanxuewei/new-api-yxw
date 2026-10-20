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
# 【SUPERSEDED 2026-10-19 · 请勿再跑】本文件已被拆成两步并各自实测通过：
#     wire_perf_a_setup.sh（恢复 + setup + 口令即时落 Secret）→ wire_perf_b_channel.sh（登录/渠道/令牌/SSE 验收）
#   停用原因（不是"没跑通"，是"跑不通且会误导"）：① 单文件 16519B，超 ECS RunCommand 的 15000B 硬门禁；
#   ② 本文件内残留 `base_url=.../v1`（约 116 行），而 relay 的 `GetFullRequestURL` 会再拼一次 `/v1/chat/completions`
#      ⇒ `/v1/v1/...` 404（`bad_response_status_code`，实测踩过）。留着它等于留一个已知错的模板。
#   保留理由：其中两处自曝（`POST /api/token/` 不回 data.id、`constant.Setup` 的恢复路径）是**证据**，不销毁。
# bodies/wire_perf_relay.sh —— 打通「网关 → 渠道 → mock」压测链路（**只写 new-api-perf**）
# 上一版（同一天首跑）的自曝两处错：
#   ① `POST /api/token/` 只回 `{"message":"","success":true}`，**没有 data.id** ⇒ 我按 data.id 取值取空就 exit，
#      而"把口令写进 Secret"排在它后面 ⇒ 生成出来的管理员口令随那次 shell 一起没了（perfroot 已入库但无人持有口令）。
#      本版的顺序修正：**setup 成功立刻落 Secret**，后面任何一步失败都不会再丢凭据；token id 改从列表接口取。
#   ② 常量语义没查就动手：`constant.Setup` 由 `model.CheckSetup()` 在启动时读 `setups` 表决定（本仓
#      `createRootAccountIfNeed` 无调用点），所以恢复办法是"删 setups+root 行 → 重启 → 重新 setup"，不是"再发一次 POST /api/setup"（会被"系统已经初始化完成"挡掉）。
# 凭据纪律（§18.7）：口令/PAT/key 全部节点现生成或从 Secret 读，命令体无凭据字面量，输出只出 md5 指纹。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
[ -n "$GWC" ] || { echo "    [XX] 取不到网关 ClusterIP"; exit 0; }
fp() { printf '%s' "$1" | md5sum | cut -c1-10; }
jval() { python3 -c "import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    d = d.get(k) if isinstance(d, dict) else None
print('' if d is None else d)"; }
printf '=== X0 网关=%s\n' "$GW"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-wire, namespace: new-api-perf, labels: {app: t2p-wire, track: perf, env: dev}}
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
kubectl -n $NS wait --for=condition=Ready pod/t2p-wire --timeout=240s >/dev/null 2>&1 || echo "    [!] psql Pod 未就绪"
Q() { kubectl -n $NS exec -i t2p-wire -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== X1 现状清点（setups / perfroot / Secret / 上次留下的渠道令牌）"
SROWS=$(Q "select count(*) from setups"); UROWS=$(Q "select count(*) from users where username='perfroot'")
CHROWS=$(Q "select count(*) from channels where name='mock-perf'"); TROWS=$(Q "select count(*) from tokens where name='perf-load'")
HAVESEC=$(kubectl -n $NS get secret $SEC -o jsonpath='{.metadata.name}' 2>/dev/null)
printf '      setups=%s perfroot=%s channel(mock-perf)=%s token(perf-load)=%s secret=%s\n' \
  "${SROWS:-?}" "${UROWS:-?}" "${CHROWS:-?}" "${TROWS:-?}" "${HAVESEC:-无}"

if [ "${SROWS:-0}" != 0 ] && [ -z "$HAVESEC" ]; then
  echo "=== X2 恢复半初始化态（就是我上一版造出来的那个态）：删 setups+root+残渠道/令牌 → 重启网关 → 重新 setup"
  Q "delete from setups; " ; Q "delete from tokens where name='perf-load';"; Q "delete from channels where name='mock-perf';"
  Q "delete from user_sessions where user_id in (select id from users where username='perfroot');"
  Q "delete from users where username='perfroot';"
  kubectl -n $NS rollout restart deploy/new-api-perf 2>&1 | sed 's/^/      /'
  kubectl -n $NS rollout status deploy/new-api-perf --timeout=240s 2>&1 | tail -2 | sed 's/^/      /'
  GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r'); GW="http://${GWC}:${GWP:-80}"
  printf '      重启后网关=%s；setup 门=%s\n' "$GW" "$(curl -sS -m 10 "$GW/api/setup" 2>&1 | head -c 120)"
fi

echo "=== X3 管理员口令：Secret 有就用它，没有就现生成 + POST /api/setup + **立刻**落 Secret"
if [ -n "$HAVESEC" ]; then
  ADMIN_PW=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' | base64 -d 2>/dev/null)
  printf '      复用 Secret 里的口令（指纹 %s）\n' "$(fp "$ADMIN_PW")"
else
  ADMIN_PW=$(python3 -c 'import secrets;print(secrets.token_urlsafe(18))')
  R=$(curl -sS -m 15 -H 'Content-Type: application/json' --data \
    "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\",\"confirmPassword\":\"$ADMIN_PW\",\"SelfUseModeEnabled\":true,\"DemoSiteEnabled\":false}" "$GW/api/setup" 2>&1)
  printf '      setup success=%s msg=%s\n' "$(printf '%s' "$R" | jval success)" "$(printf '%s' "$R" | jval message | cut -c1-40)"
  case "$R" in *'"success":true'*) : ;; *) echo "      [XX] setup 失败 ⇒ 停（不猜口令、不改生产）"; exit 0 ;; esac
  kubectl -n $NS create secret generic $SEC --from-literal=admin_username=perfroot \
    --from-literal=admin_password="$ADMIN_PW" --from-literal=token_id=0 --from-literal=token_key=none \
    --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
  printf '      已落 Secret（口令指纹 %s）\n' "$(fp "$ADMIN_PW")"
fi

echo "=== X4 登录取短期 access_token"
AT=$(curl -sS -m 15 -H 'Content-Type: application/json' --data "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\"}" \
  "$GW/api/user/login" 2>&1 | jval data.access_token)
[ -n "$AT" ] || { echo "      [XX] 登录失败"; exit 0; }
printf '      access_token len=%s 指纹=%s\n' "${#AT}" "$(fp "$AT")"

echo "=== X5 渠道（指向 mock 的 OpenAI 兼容渠道；已存在就不重复建）"
if [ "${CHROWS:-0}" = 0 ]; then
  CR=$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" --data \
    '{"mode":"single","channel":{"name":"mock-perf","type":1,"key":"mock-key-no-auth","base_url":"http://mock-upstream.new-api-perf.svc.cluster.local/v1","models":"mock-gpt","group":"default","status":1,"weight":0,"priority":0,"proxy":""}}' \
    "$GW/api/channel/" 2>&1)
  printf '      add success=%s msg=%s\n' "$(printf '%s' "$CR" | jval success)" "$(printf '%s' "$CR" | jval message | cut -c1-60)"
fi
printf '      回读渠道 id/name/base/status：%s\n' "$(Q "select coalesce(id::text,'-')||' | '||coalesce(name,'-')||' | '||coalesce(base_url,'-')||' | '||coalesce(status::text,'-') from channels where name='mock-perf' limit 1" | head -1)"

echo "=== X6 令牌：add 不回 id ⇒ 从列表接口取 id，再取 key，然后**回写 Secret**"
[ "${TROWS:-0}" = 0 ] && curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" \
  --data '{"name":"perf-load","status":1,"unlimited_quota":true,"expired_time":-1,"group":"default"}' "$GW/api/token/" >/dev/null 2>&1
TKID=$(Q "select id from tokens where name='perf-load' order by id limit 1" | tr -dc '0-9')
printf '      token id=%s\n' "${TKID:-取不到}"
[ -n "$TKID" ] || { echo "      [XX] 令牌没入库 ⇒ 停"; exit 0; }
TKKEY=$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" --data '{}' \
  "$GW/api/token/$TKID/key" 2>&1 | jval data)
[ -n "$TKKEY" ] || TKKEY=$(Q "select key from tokens where id=$TKID" | head -1 | tr -d ' \r')
[ -n "$TKKEY" ] || { echo "      [XX] 取不到 token key"; exit 0; }
printf '      token key len=%s 指纹=%s\n' "${#TKKEY}" "$(fp "$TKKEY")"
kubectl -n $NS create secret generic $SEC --from-literal=admin_username=perfroot \
  --from-literal=admin_password="$ADMIN_PW" --from-literal=token_id="$TKID" --from-literal=token_key="$TKKEY" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
kubectl -n $NS get secret $SEC -o jsonpath='      Secret 键：{.data}{"\n"}' 2>&1 | cut -c1-140

echo "=== X7 经网关的 SSE 实测（渠道缓存未热就重试；只在真失败时才考虑重启）"
SSE=/tmp/perf_wire_$$.sse
OK=0
for i in 1 2 3 4 5 6; do
  M=$(curl -sS -m 30 -N -o "$SSE" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer} total=%{time_total}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
  ND=$(grep -c '^data:' "$SSE" 2>/dev/null)
  printf '      #%s %s data=%s\n' "$i" "$(printf '%s' "$M" | tr -d '\r' | cut -c1-80)" "${ND:-0}"
  [ "${ND:-0}" -ge 3 ] && { OK=1; break; }
  [ "$i" = 1 ] && { echo "      首次响应体[:200]：$(head -c 200 "$SSE" | tr -d '\n\r')"; }
  sleep 12
done
[ "$OK" = 1 ] && echo "    判定 网关→渠道→mock：PASS（可进压测）" || echo "    判定 网关→渠道→mock：FAIL（看上面的响应体定位）"
rm -f "$SSE" 2>/dev/null

echo "=== X8 终态只读回读（logs 行数应 ≥1 = 计费/日志链也过了）"
Q "select 'users='||count(*) from users" ; Q "select 'channels='||count(*) from channels" ; Q "select 'tokens='||count(*) from tokens"
Q "select 'logs='||count(*) from logs" ; Q "select 'setup_rows='||count(*) from setups"
kubectl -n $NS delete pod t2p-wire --ignore-not-found --wait=false >/dev/null 2>&1
echo "      临时 Pod 已清理：$(kubectl -n $NS get pod t2p-wire -o name 2>&1 | head -1)"
echo "--- X0–X8 结束"
exit 0
