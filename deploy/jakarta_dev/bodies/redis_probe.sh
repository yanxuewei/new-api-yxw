#!/bin/bash
# bodies/redis_probe.sh —— Redis 连通性探针（只读）
# 结构性不取值（§13.6 纪律）：临时 Pod 经 secretKeyRef 挂 REDIS_CONN_STRING，
# 口令既不进命令体、也不进节点 shell，Pod 退出即随之销毁。
# 闸门：Secret 里必须已有 REDIS_CONN_STRING 键；APPLY=1 才建 Pod，默认只出计划。
NS=newapi-dev
SEC=new-api-secrets
APPLY="${APPLY:-0}"
echo "=== P0 前置闸门（零凭据）"
kubectl -n $NS get secret $SEC -o go-template='{{range $k, $v := .data}}{{if eq $k "REDIS_CONN_STRING"}}    [ok] Secret 键 REDIS_CONN_STRING 存在（b64len={{len $v}}）{{"\n"}}{{end}}{{end}}' 2>&1 \
  | grep -q "\[ok\]" || { echo "  [XX] Secret $SEC 无 REDIS_CONN_STRING 键 ⇒ 先跑 --secret"; exit 2; }
echo "  [ok] 前置通过"
if [ "$APPLY" != "1" ]; then
  echo "=== APPLY=0 ⇒ 只出计划，不建 Pod（APPLY=1 才真做）"
  exit 0
fi
echo "=== P1 建临时探针 Pod（redis:7-alpine，值经 secretKeyRef 注入）"
cat <<'EOF' | kubectl apply -f - 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: tair-probe
  namespace: newapi-dev
  labels: {app: tair-probe, track: temp}
spec:
  restartPolicy: Never
  containers:
    - name: redis-cli
      image: redis:7-alpine
      command: ["sh","-c"]
      args:
        - |
          set -e
          echo "[probe] PING:";        redis-cli -u "$REDIS_CONN_STRING" PING
          echo "[probe] DBSIZE:";      redis-cli -u "$REDIS_CONN_STRING" DBSIZE
          echo "[probe] INFO memory(maxmemory-policy 侧):"; redis-cli -u "$REDIS_CONN_STRING" CONFIG GET maxmemory-policy
          echo "[probe] 禁用命令复核（期望报错，绝不允许成功）:"; redis-cli -u "$REDIS_CONN_STRING" FLUSHALL || echo "  [ok] FLUSHALL 被拒"
          echo "[probe] rateLimit 键样例:"; redis-cli -u "$REDIS_CONN_STRING" --scan --pattern 'rateLimit:*' | head -5
          echo "[probe] INFO stats:"; redis-cli -u "$REDIS_CONN_STRING" INFO stats | grep -E '^(instantaneous_ops_per_sec|total_commands_processed)'
      env:
        - name: REDIS_CONN_STRING
          valueFrom:
            secretKeyRef: {name: new-api-secrets, key: REDIS_CONN_STRING}
      # ns 有 ResourceQuota ⇒ 必须显式 requests/limits
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {cpu: 200m, memory: 128Mi}
  tolerations: []
EOF
RC=$?
[ $RC -eq 0 ] || { echo "  [XX] Pod 创建失败"; exit $RC; }
echo "=== P2 等待完成（镜像跨区公网拉取可能偏慢，180s < 云助手 900s）"
for i in $(seq 1 36); do
  PH=$(kubectl -n $NS get pod tair-probe -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Succeeded" ] && break
  [ "$PH" = "Failed" ] && break
  sleep 5
done
echo "  phase=$PH (wait ${i}x5s)"
echo "=== P3 取日志（值通道：只有 redis-cli 输出，无明文口令）"
kubectl -n $NS logs tair-probe 2>&1 | sed 's/^/    /'
echo "=== P4 清理临时 Pod"
kubectl -n $NS delete pod tair-probe --wait=false 2>&1 | sed 's/^/    /'
echo "--- P0–P4 结束（写入面只有临时 Pod tair-probe，已删）"
exit 0
