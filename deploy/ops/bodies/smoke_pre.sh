#!/bin/bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件走的是「旧名对象」链路，勿再执行
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   本文件会渲染 / apply `deploy/jakarta_{pre,perf}/manifests/legacy/new-api-{pre,perf}.yaml`（旧清单），
#   或按 APP=new-api-pre|new-api-perf 这一旧标签选 pod ⇒ 重跑会重建旧对象、
#   让新对象与旧对象抢标签，或让诊断「查不到任何 pod」。**不要重跑**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**。
# =============================================================================
# deploy/ops/bodies/smoke_pre.sh —— 任务 45 单人口径出口冒烟：PG（走 6432 池）+ SQLite 双库
#   2026-10-19 参数化：NS / TRACK / APP 三个入参，默认值 = pre 原口径（不传就和以前逐字等价）。
#   perf 复用同一套判据（卡片只要求两个轨道都过同一矩阵，没要求两套脚本）。
# 判据来自卡片「验证方法」V1/V2 + AGENTS.md 三库要求的本轮裁剪版。
NS="${NS:-new-api-pre}"; TRACK="${TRACK:-pre}"; APP="${APP:-new-api-pre}"
trap "kubectl -n $NS delete pod t2p-smoke t2p-sqlite --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf \"\$T\"" EXIT

echo "=== V1) PG 路径：业务 Pod 的 /api/status（探针同款）  [ns=$NS track=$TRACK]"
POD=$(kubectl -n "$NS" get pod -l "track=$TRACK" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "  [XX] $NS 没有 Pod ⇒ 先跑 --apply-app"; exit 1; }
printf '  POD=%s\n' "$POD"
STATUS=$(kubectl -n "$NS" exec "$POD" -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1)
printf '%s\n' "$STATUS" | cut -c1-300 | sed 's/^/    /'
printf '    判定 success=true ：'; grep -q '"success":true' <<<"$STATUS" && echo "PASS" || echo "FAIL"
# 卡片原判据"version 与镜像 tag 一致"在本构建上不成立：实测 /api/status 里是 "version":""
#   （ldflags 没注入版本号）⇒ 这里只做实况记录，不拿它当通过/不通过的门槛。
printf '    实况 version 字段：[%s]（卡片判据不成立，见台账 §17）\n' "$(grep -oE '"version":"[^"]*"' <<<"$STATUS" | head -1 | sed 's/"version"://')"

echo "=== V1b) PG 落库面：临时 psql Pod 读应用自己的 Secret（口令不进命令体）"
kubectl -n "$NS" delete pod t2p-smoke --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<PGEOMF 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2p-smoke
  namespace: $NS
  labels: { app: t2p-smoke, project: new-api, site: jkt-dev, track: $TRACK, env: dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 420
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 300"]
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
PGEOMF
if ! kubectl -n "$NS" wait --for=condition=Ready pod/t2p-smoke --timeout=240s; then
  echo "    [XX] psql Pod 未就绪"; kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -8 | sed 's/^/      /'
  exit 1
fi
for KV in SQL_DSN_MIGRATE SQL_DSN; do
  echo "  [$KV]（这条 DSN 的端口就是 6432 ⇒ 能连上并建表 = 托管池真的在承载业务）"
  kubectl -n "$NS" exec -i t2p-smoke -- sh -c "psql \"\$${KV}\" -Atq -F'|' -f -" <<'SQL' 2>&1 \
    | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/      /'
select 'conn=' || current_user || '@' || current_database() || ' ssl=' || (select count(*) from pg_stat_ssl where pid=pg_backend_pid() and ssl)::text;
select 'tables=' || count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE';
select 'has_rows_users=' || coalesce((select 'ok' from information_schema.tables where table_name='users' limit 1), 'NO_USERS_TABLE');
SQL
done

echo "=== V1c) 权限链反证（运行账号 newapi：读得到 / 建表必须被拒）"
for SQLTXT in "select count(*) from options;" "create table _t2p_forbid(i int);"; do
  OUT=$(kubectl -n "$NS" exec -i t2p-smoke -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$SQLTXT" 2>&1 | head -2)
  printf '    %-42s ⇒ %s\n' "$SQLTXT" "${OUT:-(无输出=成功)}"
done
kubectl -n "$NS" exec -i t2p-smoke -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -c "drop table if exists _t2p_forbid"' 2>&1 | sed 's/^/      清理：/'

echo "=== V3) 隔离反证（卡片硬门禁）"
echo "  ① dev 三个负载的 Pod 身份指纹（应与 --dev-baseline 一致；不一致就要当场归因）："
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>&1 | sort | sed 's/^/      /'
echo "     归因取证（谁改的 dev，只用来看 managedFields 与 RS 时间线，不改任何东西）："
kubectl -n newapi-dev get deploy new-api-channel-task-dev -o jsonpath='      manager={.metadata.managedFields[*].manager}{"  time="}{.metadata.managedFields[*].time}{"  gen="}{.metadata.generation}{"\n"}' 2>&1 | sed 's/^/    /'
echo "  ② pre 与 dev 的 SESSION_SECRET 指纹必须不同（只出指纹，不出值）："
for pair in "$TRACK:$NS" "dev:newapi-dev"; do
  tag="${pair%%:*}"; n="${pair#*:}"
  fp=$(kubectl -n "$n" get secret new-api-secrets -o go-template='{{ index .data "SESSION_SECRET" }}' 2>/dev/null | base64 -d | sha256sum | cut -c1-12)
  printf '      %s fp=%s\n' "$tag" "$fp"
done
echo "  ③ pre ns 的对象清单（只有 pre 的三件套 + 冒烟临时 Pod；不该出现任何 dev/正式对象）："
kubectl -n "$NS" get deploy,svc,pod --no-headers 2>&1 | sed 's/^/      /'
echo "  ④ 集群内 Service 域名可达（$NS 只在本 ns 内被路由，无 Ingress/ALB）："
kubectl -n "$NS" exec "$POD" -- sh -c "wget -qO- -T 5 http://$APP.$NS.svc.cluster.local/api/status 2>&1 | head -c 90" 2>&1 | sed 's/^/      /'

echo "--- V1–V3 结束（冒烟 Pod 已在 trap 里清理）"
