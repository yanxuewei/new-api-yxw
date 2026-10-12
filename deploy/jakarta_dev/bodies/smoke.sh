#!/bin/bash
# bodies/smoke.sh —— 三库冒烟 + 权限链自证（任务 2d 出口条件）
trap 'rm -rf "$T"' EXIT
POD=$(kubectl -n newapi-dev get pod -l app=new-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "  [XX] 没有 new-api Pod ⇒ 先跑 --apply-app"; exit 1; }
echo "POD=$POD"

echo "--- S1) /api/status（容器内 3000，生产同款探针）"
kubectl -n newapi-dev exec "$POD" -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1 \
  | cut -c1-320 | sed 's/^/  /'
echo "--- S2) 首页 / 的 HTTP 码"
kubectl -n newapi-dev exec "$POD" -- sh -c 'wget -S -qO /dev/null -T 8 http://127.0.0.1:3000/ 2>&1 | head -4' 2>&1 | sed 's/^/  /'
echo "--- S3) 集群内 Service 域名可达"
SVC_EP=$(kubectl -n newapi-dev get svc new-api-dev -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>&1)
echo "  svc new-api-dev = $SVC_EP"
kubectl -n newapi-dev exec "$POD" -- sh -c 'wget -qO- -T 5 http://new-api-dev.newapi-dev.svc.cluster.local/api/status 2>&1 | head -c 80' 2>&1 | sed 's/^/  /'

echo "--- S4) 落库面：临时 psql Pod 读应用自己的 Secret（口令不进命令体）"
kubectl -n newapi-dev delete pod t2d-smoke --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PGEOMF' 2>&1 | sed 's/^/  /'
apiVersion: v1
kind: Pod
metadata:
  name: t2d-smoke
  namespace: newapi-dev
  labels: { app: t2d-smoke, project: new-api, site: jkt-dev }
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
if ! kubectl -n newapi-dev wait --for=condition=Ready pod/t2d-smoke --timeout=240s; then
  echo "  [XX] psql Pod 未就绪"; kubectl -n newapi-dev get events --sort-by=.lastTimestamp | tail -8 | sed 's/^/    /'
  kubectl -n newapi-dev delete pod t2d-smoke --ignore-not-found --wait=false >/dev/null 2>&1
  exit 1
fi
for KV in SQL_DSN_MIGRATE SQL_DSN LOG_SQL_DSN; do
  echo "  [$KV]"
  kubectl -n newapi-dev exec -i t2d-smoke -- sh -c "psql \"\$${KV}\" -Atq -F'|' -f -" <<'SQL' 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/      /'
select 'conn=' || current_user || '@' || current_database() || ':' || inet_server_port()::text;
select 'tables=' || count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE';
SQL
done

echo "--- S5) 权限链自证（运行账号 newapi：读得到 / 改得动 / 建表必须被拒）"
for SQLTXT in "select count(*) from users;" "update users set status=status where id=0;" "select relname from pg_class where relname='users';" "create table _t2d_forbid(i int);"; do
  OUT=$(kubectl -n newapi-dev exec -i t2d-smoke -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$SQLTXT" 2>&1 | head -2)
  printf '    %-46s ⇒ %s\n' "$SQLTXT" "${OUT:-(无输出=成功且 0 行)}"
done
echo "    （建表那条若返回 permission denied for schema public ⇒ 与生产同构的最小化生效；若成功 ⇒ 授权没收紧，必须记台账）"
echo "--- S6) 越界清理（防残留）"
kubectl -n newapi-dev exec -i t2d-smoke -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -f -' <<'SQL' 2>&1 | sed 's/^/    /'
drop table if exists _t2d_forbid;
select 'public_tables_left=' || count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE';
SQL
kubectl -n newapi-dev delete pod t2d-smoke --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- S7) 应用日志里的迁移痕迹（DDL 计数，口令打码）"
DDL=$(kubectl -n newapi-dev logs "$POD" 2>&1 | grep -ciE 'CREATE TABLE|ALTER TABLE|auto.*migrat')
echo "    DDL/迁移日志行数: $DDL"
echo "  冒烟结束"
