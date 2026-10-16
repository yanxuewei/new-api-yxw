#!/bin/bash
# bodies/pg_port_probe.sh —— RDS 托管 PgBouncer 端口预检（只读，零凭据）
# 用节点已缓存的 postgres:17-alpine 跑 pg_isready：5432 直连 与 6432 经池 两格都测。
# 零凭据：pg_isready 不做认证，不投递任何口令（§13.6 纪律）。
NS=newapi-dev
PGHOST="${PGHOST:-}"
APPLY="${APPLY:-0}"
echo "=== G0 闸门"
[ -n "$PGHOST" ] || { echo "  [XX] 未传 PGHOST"; exit 2; }
echo "  目标: $PGHOST  (5432 直连 / 6432 经池)"
if [ "$APPLY" != "1" ]; then
  echo "=== APPLY=0 ⇒ 只出计划（APPLY=1 才建 Pod）"
  exit 0
fi
echo "=== G1 建临时探针 Pod"
cat <<EOF | kubectl apply -f - 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: pg-port-probe
  namespace: $NS
  labels: {app: pg-port-probe, track: temp}
spec:
  restartPolicy: Never
  containers:
    - name: pg-isready
      image: postgres:17-alpine
      command: ["sh","-c"]
      args:
        - |
          echo "[probe] 5432 直连:"; pg_isready -h "$PGHOST" -p 5432 -t 5
          echo "[probe] 6432 经池:"; pg_isready -h "$PGHOST" -p 6432 -t 5
          echo "[probe] 6432 二次（池侧连接建立后再测）:"; sleep 2; pg_isready -h "$PGHOST" -p 6432 -t 5
      # ns 有 ResourceQuota ⇒ 必须显式 requests/limits
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {cpu: 200m, memory: 128Mi}
EOF
RC=$?
[ $RC -eq 0 ] || { echo "  [XX] Pod 创建失败"; exit $RC; }
echo "=== G2 等待完成（镜像节点已缓存，60s 足够）"
for i in $(seq 1 12); do
  PH=$(kubectl -n $NS get pod pg-port-probe -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Succeeded" ] && break
  [ "$PH" = "Failed" ] && break
  sleep 5
done
echo "  phase=$PH (wait ${i}x5s)"
echo "=== G3 取日志"
kubectl -n $NS logs pg-port-probe 2>&1 | sed 's/^/    /'
echo "=== G4 清理临时 Pod"
kubectl -n $NS delete pod pg-port-probe --wait=false 2>&1 | sed 's/^/    /'
echo "--- G0–G4 结束（写入面只有临时 Pod pg-port-probe，已删）"
exit 0
