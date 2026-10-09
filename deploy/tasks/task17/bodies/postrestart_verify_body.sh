#!/usr/bin/env bash
# task17/bodies/postrestart_verify_body.sh — B 线写操作后的只读复核
#   1) 新 master Pod 的分口径 DDL 计数 + ERROR 计数 + 计数窗口覆盖度
#   2) 主库 schema 指纹与任务 18 基线逐字比对（证明 ConfigMap 改动没碰 schema）
#   3) 临时 psql Pod 用完即删；对数据库只跑 SELECT
NS=new-api
PGPOD=t17-pgcli
MP=$(kubectl -n $NS get pods -l track=master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "Pod = ${MP:-（无）}  启动时间 = $(kubectl -n $NS get pod "$MP" -o jsonpath='{.status.startTime}' 2>/dev/null)"
printf '  spec.image = %s\n' "$(kubectl -n $NS get pod "$MP" -o jsonpath='{.spec.containers[0].image}')"
printf '  imageID    = %s\n' "$(kubectl -n $NS get pod "$MP" -o jsonpath='{.status.containerStatuses[0].imageID}')"

ddl_pg() { kubectl -n $NS logs "$1" --tail=20000 2>/dev/null | grep -Ec 'ALTER TABLE "|CREATE TABLE "|CREATE (UNIQUE )?INDEX .* ON "|DROP (TABLE|COLUMN|INDEX) "'; }
ddl_ck() { kubectl -n $NS logs "$1" --tail=20000 2>/dev/null | grep -Ec 'CREATE TABLE IF NOT EXISTS [a-z_]+ \(|ALTER TABLE [a-z_]+ MODIFY TTL'; }
errs()   { kubectl -n $NS logs "$1" --tail=20000 2>/dev/null | grep -Eci 'level=(error|fatal)|\bFATAL\b|panic'; }

echo "=== 1) 重启后 DDL/ERROR 计数（期望 PG=0 / CK=3 / ERROR=0）==="
sleep 45
printf '  PG=%s  CK=%s  ERROR=%s\n' "$(ddl_pg pod/$MP)" "$(ddl_ck pod/$MP)" "$(errs pod/$MP)"
TOTAL=$(kubectl -n $NS logs pod/$MP 2>/dev/null | wc -l | tr -d ' ')
if [ "${TOTAL:-0}" -le 20000 ]; then
  printf '  日志总行数=%s（≤20000 ⇒ 窗口未截断，PG 计数可信）\n' "$TOTAL"
else
  printf '  [warn] 日志总行数=%s >20000 ⇒ 窗口截断，改查 SLS\n' "$TOTAL"
fi
echo "  CK 口径命中行（期望固定 3 条）："
kubectl -n $NS logs pod/$MP --tail=20000 2>/dev/null | grep -E 'CREATE TABLE IF NOT EXISTS [a-z_]+ \(|ALTER TABLE [a-z_]+ MODIFY TTL' | cut -c1-140 | sed 's/^/    /'

echo "=== 2) schema 指纹比对（基线来自任务 18 §四）==="
kubectl -n $NS delete pod $PGPOD --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'PGEOMF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: t17-pgcli
  namespace: new-api
  labels: { app: t17-pgcli, project: new-api, site: ph-mnl }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 0
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 600"]
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      envFrom:
        - secretRef: { name: new-api-secrets }
PGEOMF
if kubectl -n $NS wait --for=condition=Ready pod/$PGPOD --timeout=240s >/dev/null 2>&1; then
  FP=$(kubectl -n $NS exec -i $PGPOD -- sh -c 'psql "$SQL_DSN_MIGRATE" -Atq -F"|" -f -' <<'SQL'
select
  (select count(*) from information_schema.tables
     where table_schema='public' and table_type='BASE TABLE'),
  (select md5(string_agg(t, chr(10))) from (
     select table_name||'.'||column_name||':'||data_type||':'||coalesce(character_maximum_length::text,'-') as t
       from information_schema.columns where table_schema='public' order by t) c),
  (select md5(string_agg(t, chr(10))) from (
     select indexname||'='||indexdef as t from pg_indexes where schemaname='public' order by t) i);
SQL
)
  BASE="36|e0573c6f2c3aef3bcfd8f9297f6a2948|8a088809e6f2eaa5d3d484efb8a67127"
  printf '  本次 FP = %s\n  基线 FP = %s\n' "$FP" "$BASE"
  [ "$FP" = "$BASE" ] && echo "  [OK] 逐字相同 ⇒ ConfigMap 改动未触及 schema" || echo "  [XX] 指纹不一致，需排查"
else
  echo "  [XX] psql 临时 Pod 未就绪，跳过指纹"
fi
kubectl -n $NS delete pod $PGPOD --ignore-not-found --wait=false >/dev/null 2>&1

echo "=== 3) 两地 ConfigMap 期望态复核 ==="
kubectl -n $NS get cm new-api-config -o jsonpath='{.data.SQL_MAX_OPEN_CONNS} {.data.SQL_MAX_IDLE_CONNS}{"\n"}'
printf '  死配置是否仍在: LOG_SQL_MAX_OPEN_CONNS=[%s] SESSION_MAX_AGE=[%s]\n' \
  "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.LOG_SQL_MAX_OPEN_CONNS}')" \
  "$(kubectl -n $NS get cm new-api-config -o jsonpath='{.data.SESSION_MAX_AGE}')"
printf '  SA role-name 注解 = [%s]\n' "$(kubectl -n $NS get sa new-api-app -o jsonpath='{.metadata.annotations.pod-identity\.alibabacloud\.com/role-name}')"
echo "=== 4) 应用可用性（xlsx 判据：注入后应用可正常启动）==="
kubectl -n $NS logs pod/$MP --tail=6 2>/dev/null | cut -c1-140 | sed 's/^/  /'
echo "DONE-T17-POSTVERIFY"
