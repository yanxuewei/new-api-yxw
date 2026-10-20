#!/bin/bash
# 只读：查 new-api-perf 库的 users 表现状（不打印任何凭据）
set -u
NS=new-api-perf
POD=perf-dbprobe

cleanup() { kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1

cat <<'OMF' | kubectl apply -f - >/dev/null 2>&1 || { echo "  [XX] 建探针 Pod 失败"; exit 1; }
apiVersion: v1
kind: Pod
metadata:
  name: perf-dbprobe
  namespace: new-api-perf
  labels: {app: perf-dbprobe, purpose: readonly-diag}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  terminationGracePeriodSeconds: 0
  containers:
  - name: psql
    image: postgres:17-alpine
    command: ["sh","-c","sleep 300"]
    env:
    - name: SQL_DSN
      valueFrom:
        secretKeyRef:
          name: new-api-secrets
          key: SQL_DSN
    resources:
      requests: {cpu: 10m, memory: 32Mi}
      limits: {cpu: 200m, memory: 128Mi}
OMF

ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  ph=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$ph" = "Running" ]; then ok=1; break; fi
  if [ "$ph" = "Failed" ]; then break; fi
  sleep 3
done
if [ "$ok" != "1" ]; then
  echo "  [XX] 探针未就绪（phase=$ph），事件："
  kubectl -n "$NS" describe pod "$POD" 2>&1 | sed -n '/^Events:/,$p' | tail -6 | sed 's/^/      /'
  exit 1
fi

q() { kubectl -n "$NS" exec "$POD" -- sh -c "psql \"\$SQL_DSN\" -At -F '|' -c \"$1\"" 2>&1 | sed 's/^/  /'; }

echo "=== D1 连接目标（不打印凭据）"
q 'select current_database(), current_user, split_part(version(),'"'"' '"'"',2)'

echo
echo "=== D2 关键表是否存在"
q "select to_regclass('public.users') as users, to_regclass('public.setups') as setups, to_regclass('public.channels') as channels, to_regclass('public.tokens') as tokens, to_regclass('public.logs') as logs"

echo
echo "=== D3 users 全量（id|username|role|status|deleted|pwd前缀|pwd长度|display）"
q "select id, username, role, status, (deleted_at is not null) as del, left(password,7) as pfx, length(password) as plen, coalesce(display_name,'-') from users order by id"

echo
echo "=== D4 计数"
q "select (select count(*) from users) as users, (select count(*) from channels) as channels, (select count(*) from tokens) as tokens"

echo
echo "=== D5 最近一次登录相关时间戳（若有 last_login_at / created_at）"
q "select id, username, created_at, updated_at from users order by id limit 5"
