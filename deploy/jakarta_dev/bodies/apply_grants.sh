#!/bin/bash
# bodies/apply_grants.sh —— 权限 SQL 落地（任务 13 第 2 步的 dev 同构版）
# 载荷 $SEC_B64 = tar.gz：DSN_OPS_MAIN / DSN_OPS_LOGS / grants.sql / （4 个应用键，本 body 不用）
# 执行位：集群内临时 psql Pod（镜像 postgres:17-alpine，节点侧已实测可拉）
#   ⇒ 口令不写进 Pod spec 命令行，只经临时 Secret t2d-dba 挂载，跑完即删。
trap 'shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }
[ -s "$T/sec/grants.sql" ] || { echo "  [XX] 缺 grants.sql"; exit 1; }

echo "--- 1) 临时 DBA Secret（只授权用，本 body 末尾必删）"
kubectl -n newapi-dev create secret generic t2d-dba \
  --from-file=DSN_OPS_MAIN="$T/sec/DSN_OPS_MAIN" --from-file=DSN_OPS_LOGS="$T/sec/DSN_OPS_LOGS" \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'

echo "--- 2) 临时 psql Pod（清单形态与任务 27 同构：ns 有 ResourceQuota ⇒ 必须声明 requests/limits）"
kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PGEOMF' 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2d-pgcli
  namespace: newapi-dev
  labels: { app: t2d-pgcli, project: new-api, site: jkt-dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 600"]
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      env:
        - name: DSN_OPS_MAIN
          valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_MAIN } }
        - name: DSN_OPS_LOGS
          valueFrom: { secretKeyRef: { name: t2d-dba, key: DSN_OPS_LOGS } }
PGEOMF
if ! kubectl -n newapi-dev wait --for=condition=Ready pod/t2d-pgcli --timeout=240s; then
  echo "    [XX] pgcli 未就绪 ⇒ 事件尾部："
  kubectl -n newapi-dev get events --sort-by=.lastTimestamp 2>&1 | tail -10 | sed 's/^/    /'
  kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n newapi-dev delete secret t2d-dba --ignore-not-found >/dev/null 2>&1
  exit 1
fi

echo "--- 3) 取数面自证（谁在跑 / 连的哪个库 / 端口 / PG 版本）"
for pair in "main:DSN_OPS_MAIN" "logs:DSN_OPS_LOGS"; do
  dsn="${pair#*:}"
  kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -F'|' -c 'select current_user, current_database(), inet_server_port(), version()'" 2>&1 \
    | cut -c1-160 | sed "s/^/    [$pair] /"
done

echo "--- 4) 逐条执行权限 SQL（一条一次 psql -c：一条失败不连带吞掉后面的判断）"
grep -E '^(main|logs)\|' "$T/sec/grants.sql" | while IFS='|' read -r scope sql; do
  dsn=DSN_OPS_MAIN; [ "$scope" = logs ] && dsn=DSN_OPS_LOGS
  out=$(kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$${dsn}\" -v ON_ERROR_STOP=0 -Atq -c \"\$1\"" sh "$sql" 2>&1)
  printf '    [%-4s] %-58s ⇒ %s\n' "$scope" "$(printf '%s' "$sql" | cut -c1-58)" "${out:-OK（无输出即成功）}"
done

echo "--- 5) 生效判据回读（坑 14 的教训：命令成功 ≠ 权限落地）"
for pair in "main:DSN_OPS_MAIN" "logs:DSN_OPS_LOGS"; do
  scope="${pair%%:*}"; dsn="${pair#*:}"
  echo "  [$scope]"
  grep '^check|' "$T/sec/grants.sql" | sed 's/^check|//' | while IFS= read -r sql; do
    kubectl -n newapi-dev exec t2d-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -c \"\$1\"" sh "$sql" 2>&1 \
      | sed "s/^/      /"
  done
done

echo "--- 6) 清理临时 Pod / DBA Secret（口令不留集群）"
kubectl -n newapi-dev delete pod t2d-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n newapi-dev delete secret t2d-dba --ignore-not-found >/dev/null 2>&1
sleep 3
echo "    残留：pod=$(kubectl -n newapi-dev get pod t2d-pgcli --no-headers 2>&1 | head -1) secret=$(kubectl -n newapi-dev get secret t2d-dba --no-headers 2>&1 | head -1)"
echo "    ns 现有对象："; kubectl -n newapi-dev get secret,cm,deploy,svc 2>&1 | sed 's/^/      /'
