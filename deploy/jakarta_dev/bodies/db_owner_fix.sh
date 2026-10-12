#!/bin/bash
# bodies/db_owner_fix.sh —— 诊断并尝试把 dev 两库的 owner 交回 RDS 内部账号（非破坏）
# 背景：本轮曾试错 `GrantAccountPrivilege --AccountPrivilege DBOwner`（坑 11 明令禁止的路径），
#       API 回 200 但 DescribeAccounts 不回显 ⇒ 静默把 owner 改成了业务账号。
#       空库（tables=0）里唯一受害者是"权限模型不可信"，所以先试 ALTER DATABASE OWNER，
#       不行再谈重建（重建属破坏性，需负责人核准）。
cleanup_mf() {
  kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n newapi-dev delete secret t2d-dba --ignore-not-found >/dev/null 2>&1
}
trap 'cleanup_mf; shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }
[ -s "$T/sec/DSN_OPS_MAIN" ] || { echo "  [XX] 缺 DSN_OPS_MAIN"; exit 1; }
kubectl -n newapi-dev create secret generic t2d-dba \
  --from-file=DSN_OPS_MAIN="$T/sec/DSN_OPS_MAIN" --from-file=DSN_OPS_LOGS="$T/sec/DSN_OPS_LOGS" \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/  /'
kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PGEOMF' 2>&1 | sed 's/^/  /'
apiVersion: v1
kind: Pod
metadata: { name: t2d-pgcli, namespace: newapi-dev, labels: { app: t2d-pgcli } }
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
        - name: DSN_OPS_MAIN
          valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_MAIN } }
        - name: DSN_OPS_LOGS
          valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_LOGS } }
PGEOMF
kubectl -n newapi-dev wait --for=condition=Ready pod/t2d-pgcli --timeout=240s || { echo "  [XX] Pod 未就绪"; exit 1; }

DIAG="select 'db='||current_database()||' owner='||pg_get_userbyid(datdba) from pg_database where datname=current_database();
select 'schema_public_owner='||pg_get_userbyid(nspowner)||' acl='||coalesce(array_to_string(nspacl,','),'(null)') from pg_namespace where nspname='public';
select 'has_create_newapi='||has_schema_privilege('newapi','public','CREATE')::text||' has_create_migrate='||has_schema_privilege('newapi_migrate','public','CREATE')::text;
select 'memberships='||coalesce(string_agg(m.rolname||'->'||r.rolname||'(admin='||ma.admin_option::text||')',','),'(none)') from pg_auth_members ma join pg_roles r on r.oid=ma.roleid join pg_roles m on m.oid=ma.member where m.rolname=current_user;"

for pair in "main:DSN_OPS_MAIN" "logs:DSN_OPS_LOGS"; do
  dsn="${pair#*:}"
  echo "--- [$pair] 诊断（改前）"
  kubectl -n newapi-dev exec -i t2d-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -f -" <<<"$DIAG" 2>&1 | sed 's/^/    /'
done

echo "--- 尝试 ALTER DATABASE OWNER TO newapi_ops（由 newapi_ops 执行；库里 objects=0，无数据面风险）"
# 目标角色为什么不是 aurora —— 2026-10-12 实测（bodies/db_owner_probe.sh）：
#   · newapi_ops 只属于 pg_rds_superuser（admin=false）；SET ROLE aurora ⇒ permission denied
#   · ALTER DATABASE ... OWNER TO aurora ⇒ "must be able to SET ROLE \"aurora\""（owner 校验已过，卡在目标角色）
#   · RevokeAccountPrivilege 回 200 但 owner 不变 ⇒ RDS 侧没有"还原内部账号 owner"的通路
#   ⇒ 可行目标只有 newapi_ops（应用绝不使用的高权限账号；控制台"授权账号"本来就支持这种形状）。
#     pg_rds_superuser 是保留组角色，拿它当库 owner 属未验证用法，不用。
#   安全性质达成即可：业务运行账号 newapi 不再是 owner ⇒ schema ACL 真正生效（坑 11 最小化）。
#   若负责人要求 owner 必须回到 aurora，唯一路径是删库重建（两库 objects=0，无数据损失，但属破坏性 API）。
for pair in "newapi:DSN_OPS_MAIN" "newapi_logs:DSN_OPS_LOGS"; do
  db="${pair%%:*}"; dsn="${pair#*:}"
  RES=$(kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$${dsn}\" -v ON_ERROR_STOP=0 -Atq -c \"\$1\"" sh "ALTER DATABASE \"$db\" OWNER TO newapi_ops" 2>&1)
  echo "    ALTER $db ⇒ ${RES:-成功(无输出)}"
done

echo "--- 诊断（改后）"
for pair in "main:DSN_OPS_MAIN" "logs:DSN_OPS_LOGS"; do
  dsn="${pair#*:}"
  echo "  [$pair]"
  kubectl -n newapi-dev exec -i t2d-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -f -" <<<"$DIAG" 2>&1 | sed 's/^/    /'
done

kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n newapi-dev delete secret t2d-dba --ignore-not-found >/dev/null 2>&1
echo "--- 临时 Pod/DBA Secret 已删"
