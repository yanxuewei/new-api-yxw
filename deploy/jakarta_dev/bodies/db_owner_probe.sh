#!/bin/bash
# bodies/db_owner_probe.sh —— 只读探测：谁能当库 owner（不改任何东西）
# 背景：GrantAccountPrivilege DBOwner 曾静默把 dev 两库 owner 改成业务账号（坑 11 禁止的状态）；
#       ALTER DATABASE OWNER TO aurora ⇒ "must be able to SET ROLE aurora"；
#       RevokeAccountPrivilege 回 200 但 owner 不变。⇒ 先只读确定可行的目标角色。
trap 'cleanup_pr; shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
cleanup_pr() {
  kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n newapi-dev delete secret t2d-dba --ignore-not-found >/dev/null 2>&1
}
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }
[ -s "$T/sec/DSN_OPS_MAIN" ] || { echo "  [XX] 缺 DSN_OPS_MAIN"; exit 1; }
kubectl -n newapi-dev create secret generic t2d-dba \
  --from-file=DSN_OPS_MAIN="$T/sec/DSN_OPS_MAIN" --from-file=DSN_OPS_LOGS="$T/sec/DSN_OPS_LOGS" \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/  /'
kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PGEOPF' 2>&1 | sed 's/^/  /'
apiVersion: v1
kind: Pod
metadata: { name: t2d-pgcli, namespace: newapi-dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 420"]
      resources: { requests: { cpu: 100m, memory: 128Mi }, limits: { cpu: 200m, memory: 256Mi } }
      env:
        - { name: DSN_OPS_MAIN, valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_MAIN } } }
        - { name: DSN_OPS_LOGS, valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_LOGS } } }
PGEOPF
kubectl -n newapi-dev wait --for=condition=Ready pod/t2d-pgcli --timeout=240s || { echo "  [XX] Pod 未就绪"; exit 1; }

q() {  # $1=DSN 变量名 $2=SQL（单条）
  kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$$1\" -v ON_ERROR_STOP=0 -Atq -F'|' -c \"\$1\"" sh "$2" 2>&1 | sed 's/^/    /'
}

echo "--- 1) 成员关系（pg_auth_members：roleid=被授予的角色，member=被授予者）"
q DSN_OPS_MAIN "select m.rolname||' MEMBER_OF '||r.rolname||' admin='||ma.admin_option::text from pg_auth_members ma join pg_roles r on r.oid=ma.roleid join pg_roles m on m.oid=ma.member where m.rolname in ('newapi_ops','newapi','newapi_migrate') order by 1"

echo "--- 2) SET ROLE 实测（决定 ALTER ... OWNER TO 的可行目标）"
for r in aurora pg_rds_superuser newapi_ops; do
  OUT=$(kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$DSN_OPS_MAIN\" -v ON_ERROR_STOP=0 -Atq -c \"\$1\"" sh \
    "begin; set role $r; select 'OK current_user='||current_user; rollback" 2>&1)
  echo "    $r ⇒ $(tr '\n' ' ' <<<"$OUT" | sed 's/  */ /g')"
done
q DSN_OPS_MAIN "select 'roles_present: '||string_agg(rolname,',') from pg_roles where rolname in ('aurora','pg_rds_superuser','newapi_ops','newapi','newapi_migrate')"

echo "--- 3) 生效判据：业务账号在当前 owner 状态下到底有没有 CREATE"
for pair in "newapi:DSN_OPS_MAIN" "newapi_logs:DSN_OPS_LOGS"; do
  dsn="${pair#*:}"
  echo "  [${pair%%:*}]"
  q "$dsn" "select 'owner='||pg_get_userbyid(datdba) from pg_database where datname=current_database()"
  q "$dsn" "select 'has_create_newapi='||has_schema_privilege('newapi','public','CREATE')::text||'  has_create_migrate='||has_schema_privilege('newapi_migrate','public','CREATE')::text"
  q "$dsn" "select 'objects='||count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','m','v','S')"
done
echo "--- 探测完成（本 body 全程只读）"
