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
# bodies/topup_perf_quota.sh —— 给 perf 压测账号补额度（只写 newapi_perf，与 pre/dev/正式完全隔离）
# 起因（实测，非推测）：diag_perf_403.sh 证实 800 档的 10976 个 http_403 = 钱包额度耗尽，
#   users.quota=-826490 / used_quota=100826490 / request_count=41532，单发一条也 403
#   body code=insufficient_user_quota。⇒ 那是**测试夹具的额度上限**，不是网关容量拐点。
# 判定依据（代码）：service/billing_session.go:388 走 model.GetUserQuota(userId, false)；
#   model/user.go:1245 只在 common.RedisEnabled 时才读缓存，否则直接查 DB。
#   ⇒ 本脚本先"只改 DB 不重启"试一条：通了就证明这条链路是 DB 直读（记下这个事实，省一次重启）；
#     不通才 rollout restart 清缓存。**额度是配额不是凭据，数值可进输出；DSN 一律脱敏。**
# 上限护栏：users.quota 列是 gorm `type:int` ⇒ PG integer，最大 2147483647。
#   按实测单条消耗 ≈2422（=100826490/41532），1.5e9 ⇒ ≈61.9 万条，够 800 档 60s（约 1.6 万条）用 38 倍。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
NEWQ=1500000000
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
TKKEY=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' | base64 -d)
[ "${#TKKEY}" -ge 20 ] || { echo "  [XX] 拿不到 token key ⇒ 先跑 wire/fix"; exit 0; }

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
      command: ["sh", "-c", "sleep 400"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-q --timeout=240s >/dev/null 2>&1 || {
  echo "  [XX] psql 辅助 Pod 未 Ready"; kubectl -n $NS delete pod t2p-q --ignore-not-found >/dev/null 2>&1; exit 0; }
Q() { kubectl -n $NS exec -i t2p-q -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== T0 先确认真的连到 newapi_perf（防串库；库名不对就停手）"
DBN=$(Q "select current_database()")
[ "$DBN" = "newapi_perf" ] || { echo "      [XX] current_database=$DBN ≠ newapi_perf ⇒ 拒绝写"; kubectl -n $NS delete pod t2p-q --ignore-not-found >/dev/null 2>&1; exit 0; }
printf '      current_database=%s\n' "$DBN"
Q "select '改前: uid='||id::text||' quota='||quota::text||' used='||used_quota::text||' req='||request_count::text from users order by id" | sed 's/^/      /'

echo "=== T1 写额度（只 UPDATE users.quota；used/request/logs 保留，供前后差值算单条消耗）"
[ "$NEWQ" -le 2147483647 ] || { echo "      [XX] 超出 PG integer 上限"; exit 0; }
Q "update users set quota=$NEWQ where quota < 0 returning '写入行数/值='||id::text||'/'||quota::text" | sed 's/^/      /'
Q "select '改后: quota='||quota::text||' used='||used_quota::text from users order by id" | sed 's/^/      /'

one() {  # 单发一条 SSE：只打印形态，不打印 key
  local M O=/tmp/t1_$$.b
  M=$(curl -sS -m 25 -N -o "$O" -w 'http=%{http_code} bytes=%{size_download} ttfb=%{time_starttransfer}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
    --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
  printf '      %s | head=%s\n' "$(printf '%s' "$M" | tr -d '\r')" "$(head -c 60 "$O" | tr -d '\n\r')"
  rm -f "$O"
}

echo "=== T2 不重启，直接单发一条（通 ⇒ quota 是 DB 直读；不通 ⇒ 需要清缓存）"
one
if curl -sS -m 25 -N -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $TKKEY" --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' \
     "$GW/v1/chat/completions" 2>/dev/null | grep -q '^200$'; then
  echo "      [OK] 无需重启：额度即时生效（记进台账：本部署 quota 校验走 DB 直读）"
else
  echo "      [i] 仍非 200 ⇒ rollout restart 清进程内缓存后重试"
  kubectl -n $NS rollout restart deploy/new-api-perf >/dev/null 2>&1
  kubectl -n $NS rollout status deploy/new-api-perf --timeout=300s 2>&1 | tail -2 | sed 's/^/      /'
  sleep 8; echo "      重启后重试："; one
fi

echo "=== T3 收尾回读（额度余额 + 网关 Ready + 邻居无恙）"
Q "select '余额: quota='||quota::text||' (可支撑约 '|| (quota/2422)::text ||' 条) ' from users order by id" | sed 's/^/      /'
kubectl -n $NS get deploy new-api-perf -o jsonpath='      网关 ready={.status.readyReplicas}/{.status.replicas}{"\n"}' 2>/dev/null
kubectl -n newapi-dev get deploy -o custom-columns=N:.metadata.name,R:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      dev邻居 /'
kubectl -n $NS delete pod t2p-q --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- T0–T3 结束"
exit 0
