#!/bin/bash
# bodies/check_perf_load_inputs.sh —— 压测可驱性检查：**只读** newapi_perf 里的渠道/令牌配置
# 为什么要它：网关路由在（P5 实测 401），但 S2 降档压测要真跑通 `网关 → 渠道 → mock`，
#   必须有 ① 一个指向 mock-upstream 的渠道 ② 一个可用的令牌。perf 库是新迁移的空库，
#   但 mock-upstream 是别人今天建的（台账 §20.4）⇒ 不能假设"肯定没有"，也不能假设"肯定有"，实测。
# 合规：临时 Pod 只在 new-api-perf，trap 删除；SQL 全为 SELECT；**令牌密钥一律不外显**（只出计数与指纹前缀）。
set -uo pipefail
NS=new-api-perf
trap 'kubectl -n $NS delete pod t2p-loadchk --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

echo "=== L0 起临时只读 Pod（复用已在节点上的 postgres:17-alpine，不新拉镜像）"
kubectl -n $NS apply -f - <<OMF 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2p-loadchk
  namespace: new-api-perf
  labels: { app: t2p-loadchk, project: new-api, site: jkt-dev, track: perf, env: dev }
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
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
OMF
if ! kubectl -n $NS wait --for=condition=Ready pod/t2p-loadchk --timeout=240s; then
  echo "    [XX] Pod 未就绪"; kubectl -n $NS get events --sort-by=.lastTimestamp 2>&1 | tail -6 | sed 's/^/      /'
  exit 0
fi

echo "=== L1 断言压测打的是 perf 库（坑 3：先证明不是生产库）"
kubectl -n $NS exec -i t2p-loadchk -- sh -c 'psql "$SQL_DSN" -Atq -F"|" -c "select current_database(), current_user, version()"' 2>&1 \
  | sed -E 's/(password=)[^ ]*/\1***/g' | sed 's/^/      /'

echo "=== L2 渠道表：有没有指向 mock 的渠道（base_url 不是凭据，可原样出）"
kubectl -n $NS exec -i t2p-loadchk -- sh -c 'psql "$SQL_DSN" -Atq -F" | " -f -' <<'SQL' 2>&1 | sed 's/^/      /'
select 'channels_total=' || count(*)::text from channels;
select 'ch#' || id::text || ' name=' || coalesce(name,'-') || ' type=' || coalesce(type::text,'-')
  || ' status=' || coalesce(status::text,'-') || ' base=' || coalesce(base_url,'(空)')
  || ' models=' || left(coalesce(models,'-'),48) || ' group=' || coalesce("group",'-') from channels order by id limit 12;
SQL

echo "=== L3 令牌表：只出计数/状态/**key 的 md5 指纹前 10 位**（按 §18.7 纪律：绝不外显密钥本身或其可逆前缀）"
kubectl -n $NS exec -i t2p-loadchk -- sh -c 'psql "$SQL_DSN" -Atq -F" | " -f -' <<'SQL' 2>&1 | sed 's/^/      /'
select 'tokens_total=' || count(*)::text from tokens;
select 'tk#' || id::text || ' name=' || coalesce(name,'-') || ' status=' || coalesce(status::text,'-')
  || ' unlimited=' || coalesce(unlimited_quota::text,'-') || ' quota=' || coalesce(quota::text,'-')
  || ' expired=' || coalesce(expired_time::text,'-') || ' group=' || coalesce("group",'-')
  || ' models=' || left(coalesce(models,'-'),32) || ' keyfp=' || left(md5(coalesce(key,'x')),10)
  from tokens order by id limit 12;
SQL

echo "=== L4 用户与计费前置（压测会扣额度：额度不足 ⇒ 403，判读时别当成容量问题）"
kubectl -n $NS exec -i t2p-loadchk -- sh -c 'psql "$SQL_DSN" -Atq -F" | " -f -' <<'SQL' 2>&1 | sed 's/^/      /'
select 'users_total=' || count(*)::text from users;
select 'u#' || id::text || ' role=' || role::text || ' status=' || status::text
  || ' quota=' || quota::text || ' used=' || used::text from users order by id limit 6;
select 'logs_rows=' || count(*)::text from logs;
select 'options_rows=' || count(*)::text from options;
SQL

echo "=== L5 反证：本卡只读，perf/dev 的负载与副本数不应变化"
kubectl -n $NS get deploy -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      /'
kubectl -n newapi-dev get deploy -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas --no-headers 2>&1 | sed 's/^/      /'
kubectl -n $NS delete pod t2p-loadchk --ignore-not-found --wait=false 2>&1 | sed 's/^/      清理：/'
echo "--- L0–L5 结束"
exit 0
