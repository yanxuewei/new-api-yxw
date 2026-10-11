#!/usr/bin/env bash
# =============================================================================
# 任务 53 收尾复核 07（只读）：生产状态复原取证
#
# 报告里要写"已复原"，就必须有**当前**证据，而不是引用 20 分钟前的日志。
# 本脚本一次读回四项：
#   ① options 行数与键集合（哨兵实验的目标键 Footer 必须不存在 ⇒ 回到 precheck 的 3 行基线）
#   ② 两地是否残留探针 Pod t53-pg
#   ③ 副本 Ready 与重启计数（我自伤导致的 llxr9 重启是否已停止增长）
#   ④ SYNC_FREQUENCY / Redis 开关现值（卡片"前置"那一条的最终确认）
# 不写任何东西。
# =============================================================================
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"
NS=new-api
PROBE=t53-pg

echo "== SITE=$SITE 收尾复核 UTC=$(date -u '+%F %T') =="

kubectl -n $NS delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
cat <<'YAML' | kubectl -n $NS apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: t53-pg, labels: {app: t53-probe, run: task53}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: p
    image: postgres:17
    imagePullPolicy: IfNotPresent
    command: ["sleep","600"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    volumeMounts:
    - {name: ca, mountPath: /etc/ssl/rds, readOnly: true}
    resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
  volumes:
  - name: ca
    secret: {secretName: rds-ca-apse6, optional: true}
YAML
if ! kubectl -n $NS wait --for=condition=Ready pod/$PROBE --timeout=150s; then
  echo "  [XX] 探针 Pod 未就绪"
  kubectl -n $NS delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
  exit 1
fi
printf '%s\n' "SELECT count(*) FROM options" | kubectl -n $NS exec -i $PROBE -- sh -c 'psql "$SQL_DSN" -qAt' 2>/dev/null | sed 's/^/    options 总行数: /'
printf '%s\n' "SELECT key, length(value) FROM options ORDER BY key" | kubectl -n $NS exec -i $PROBE -- sh -c 'psql "$SQL_DSN" -qAt -F"|"' 2>/dev/null | sed 's/^/      /'
printf '%s\n' "SELECT count(*) FROM options WHERE key='Footer'" | kubectl -n $NS exec -i $PROBE -- sh -c 'psql "$SQL_DSN" -qAt' 2>/dev/null | sed 's/^/    目标键 Footer 行数（期望 0）: /'
printf '%s\n' "SELECT count(*) FROM options WHERE value LIKE 'T53PROBE%'" | kubectl -n $NS exec -i $PROBE -- sh -c 'psql "$SQL_DSN" -qAt' 2>/dev/null | sed 's/^/    哨兵残留行数（期望 0）: /'
kubectl -n $NS delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1

echo "-- 探针 Pod 残留（应为空）--"
kubectl -n $NS get pod $PROBE --no-headers 2>/dev/null | sed 's/^/    /'; echo "    (以上为空即已清)"

echo "-- 副本 Ready / 重启计数 / 关键 env --"
kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].restartCount,\
READY:.status.containerStatuses[0].ready,IP:.status.podIP,ST:.status.startTime 2>/dev/null | \
  awk '$1 ~ /^new-api-/{printf "    %-42s restarts=%-4s ready=%-6s ip=%-14s start=%s\n", $1, $2, $3, $4, $5}'
for p in $(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,P:.status.phase 2>/dev/null | awk '$2=="Running" && $1 ~ /^new-api-/{print $1}'); do
  kubectl -n $NS exec "$p" -- sh -c 'echo "    '"$p"' SYNC_FREQUENCY=[$SYNC_FREQUENCY] MEMORY_CACHE_ENABLED=[$MEMORY_CACHE_ENABLED] NODE_TYPE=[$NODE_TYPE] redis=$([ -n "${REDIS_CONN_STRING:-}" ] && echo set || echo unset)"' 2>/dev/null
done
echo "== DONE SITE=$SITE =="
