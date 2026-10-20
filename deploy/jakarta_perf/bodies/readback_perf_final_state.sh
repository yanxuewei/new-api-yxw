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
# bodies/readback_perf_final_state.sh —— S2 降档压测的**终态回读**（只读；台账 §21 的数据就从这里出）
# 为什么要单独一支：本轮的结论要能脱离聊天记录复算——令牌已轮换、额度已补、副本被 console 缩过，
#   这些状态"当时看到了"不够，必须有一条**可重跑的只读回读**留档。
# 输出纪律（§18.7）：凭据只出 **长度 + 连字符计数 + md5 前 10 位**，绝不取明文子串；DSN 打码。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
fp() { if [ $# -ge 1 ] && [ -n "${1:-}" ]; then printf '%s' "$1"; else cat; fi | md5sum | cut -c1-10; }
shape() {  # $1=值  → "len=… dash=… sk=… fp=…"
  local v="$1"
  printf 'len=%s 连字符=%s sk-前缀=%s 指纹=%s' "${#v}" \
    "$(printf '%s' "$v" | tr -cd '-' | wc -c)" \
    "$(printf '%s' "$v" | grep -c '^sk-')" "$(fp "$v")"
}

echo "=== W1 Secret 里的夹具身份（只出形态）"
AK=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d)
TK=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' 2>/dev/null | base64 -d)
printf '      admin=%s %s\n' "$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_username}' 2>/dev/null | base64 -d)" "$(shape "$AK")"
printf '      token=%s（id=%s）%s\n' "perf-load" \
  "$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_id}' 2>/dev/null | base64 -d)" "$(shape "$TK")"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-w, namespace: new-api-perf, labels: {app: t2p-w, track: perf, env: dev}}
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
kubectl -n $NS wait --for=condition=Ready pod/t2p-w --timeout=240s >/dev/null 2>&1
Q() { kubectl -n $NS exec -i t2p-w -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== W2 库与夹具（防串库 + 对象计数）"
Q "select 'current_database='||current_database()||' 版本='||split_part(version(),' ',2)" | sed 's/^/      /'
Q "select 'channels='||count(*)||' tokens='||(select count(*) from tokens)||' users='||(select count(*) from users)||' logs='||(select count(*) from logs) from channels" | sed 's/^/      /'
Q "select '渠道: '||id||' '||name||' status='||status||' base_url='||coalesce(base_url,'-') from channels order by id" | sed 's/^/      /'
Q "select '令牌: id='||id||' name='||name||' status='||status||' unlimited='||unlimited_quota::text||' key形态len='||length(key)::text from tokens order by id" | sed 's/^/      /'

echo '=== W3 额度账（单条消耗 = used/request，判「补多少才够」就靠这个比值）'
Q "select 'users: quota='||quota::text||' used='||used_quota::text||' req='||request_count::text||' 单条消耗≈'||(used_quota/nullif(request_count,0))::text from users order by id" | sed 's/^/      /'
Q "select '额度可支撑条数≈'|| (quota/nullif(used_quota/nullif(request_count,0),0))::text from users order by id" | sed 's/^/      /'

echo "=== W4 网关与上游形态（副本数是容量判读的分母，必须留档）"
kubectl -n $NS get deploy -o custom-columns=N:.metadata.name,REP:.status.replicas,READY:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      /'
kubectl -n $NS get deploy new-api-perf -o jsonpath='{range .spec.template.spec.containers[*]}      limits={.resources.limits} requests={.resources.requests}{"\n"}{end}' 2>/dev/null
kubectl -n $NS get pod -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].restartCount,P:.status.phase --no-headers 2>&1 | sed 's/^/      /'
echo "      —— 网关最近一次被谁动的（managedFields manager）——"
kubectl -n $NS get deploy new-api-perf -o jsonpath='{range .metadata.managedFields[*]}      mgr={.manager} op={.operation} time={.time}{"\n"}{end}' 2>/dev/null
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'scal|new-api-perf' | tail -4 | sed 's/^/      /'
echo "=== W5 共池邻居（压测有没有把别人带走）"
kubectl -n newapi-dev get deploy -o custom-columns=N:.metadata.name,R:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      dev /'
kubectl -n new-api-pre get deploy -o custom-columns=N:.metadata.name,R:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      pre /'
kubectl top nodes 2>/dev/null | sed 's/^/      /'
kubectl -n $NS delete pod t2p-w --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- W1–W5 结束（只读）"
exit 0
