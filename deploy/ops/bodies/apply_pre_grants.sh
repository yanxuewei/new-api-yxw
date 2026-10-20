#!/bin/bash
# deploy/ops/bodies/apply_pre_grants.sh —— pre/perf 两库的权限 SQL 落地（任务 45 步骤 4）
# 载荷 $SEC_B64 = tar.gz：DSN_OPS_PRE / DSN_OPS_PERF / grants.sql
# 执行位：集群内临时 psql Pod（postgres:17-alpine，节点侧已实测有缓存），落 new-api-pre ns
#   ⇒ 口令不写进 Pod spec 命令行，只经临时 Secret t2p-dba 以文件挂载，跑完即删。
# 只写这两样：临时 Secret + 临时 Pod；两库外的对象一概不碰（DBA 账号只用 grants.sql 里那几条）。
trap 'shred -u "$T"/sec/* 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/sec"; chmod 700 "$T/sec"
printf '%s' "$SEC_B64" | base64 -d | tar xz -C "$T/sec" || { echo "  [XX] 载荷解包失败"; exit 1; }
[ -s "$T/sec/grants.sql" ] || { echo "  [XX] 缺 grants.sql"; exit 1; }

echo "=== G0 目标自检（打印打码后的 DSN，只留 user/host/db；口令不外泄）"
for f in DSN_OPS_PRE DSN_OPS_PERF; do
  [ -s "$T/sec/$f" ] || { echo "  [XX] 载荷缺 $f"; exit 1; }
  printf '    %s => %s\n' "$f" "$(sed -E 's#://([^:/]+):[^@]*@#://\1:***@#g' "$T/sec/$f")"
done

echo "=== G1 临时 DBA Secret"
kubectl -n new-api-pre create secret generic t2p-dba \
  --from-file=DSN_OPS_PRE="$T/sec/DSN_OPS_PRE" --from-file=DSN_OPS_PERF="$T/sec/DSN_OPS_PERF" \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'

echo "=== G2 临时 psql Pod（ns 有 ResourceQuota ⇒ 必须声明 requests/limits）"
kubectl -n new-api-pre delete pod t2p-pgcli --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PGEOMF' 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2p-pgcli
  namespace: new-api-pre
  labels: { app: t2p-pgcli, project: new-api, site: jkt-dev, env: dev, track: dev }
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
        - name: DSN_OPS_PRE
          valueFrom: { secretKeyRef: { name: t2p-dba, key: DSN_OPS_PRE } }
        - name: DSN_OPS_PERF
          valueFrom: { secretKeyRef: { name: t2p-dba, key: DSN_OPS_PERF } }
PGEOMF
if ! kubectl -n new-api-pre wait --for=condition=Ready pod/t2p-pgcli --timeout=240s; then
  echo "    [XX] pgcli 未就绪 ⇒ 事件尾部："
  kubectl -n new-api-pre get events --sort-by=.lastTimestamp 2>&1 | tail -10 | sed 's/^/    /'
  kubectl -n new-api-pre delete pod t2p-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n new-api-pre delete secret t2p-dba --ignore-not-found >/dev/null 2>&1
  exit 1
fi

echo "=== G3 取数面自证（谁在跑 / 连的哪个库 / 端口 / PG 版本）"
for pair in "pre:DSN_OPS_PRE" "perf:DSN_OPS_PERF"; do
  dsn="${pair#*:}"
  kubectl -n new-api-pre exec t2p-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -F'|' -c 'select current_user, current_database(), inet_server_port(), version()'" 2>&1 \
    | cut -c1-160 | sed "s/^/    [$pair] /"
done

echo "=== G4 逐条执行权限 SQL（一条一次 psql -c：一条失败不连带吞掉后面的判断）"
grep -E '^(pre|perf)\|' "$T/sec/grants.sql" | while IFS='|' read -r scope sql; do
  dsn=DSN_OPS_PRE; [ "$scope" = perf ] && dsn=DSN_OPS_PERF
  out=$(kubectl -n new-api-pre exec t2p-pgcli -- sh -c "psql \"\$${dsn}\" -v ON_ERROR_STOP=0 -Atq -c \"\$1\"" sh "$sql" 2>&1)
  printf '    [%-4s] %-58s ⇒ %s\n' "$scope" "$(printf '%s' "$sql" | cut -c1-58)" "${out:-OK（无输出即成功）}"
done

echo "=== G5 生效判据回读（坑 14：命令成功 ≠ 权限落地）"
for pair in "pre:DSN_OPS_PRE" "perf:DSN_OPS_PERF"; do
  scope="${pair%%:*}"; dsn="${pair#*:}"
  echo "  [$scope]"
  grep '^check|' "$T/sec/grants.sql" | sed 's/^check|//' | while IFS= read -r sql; do
    kubectl -n new-api-pre exec t2p-pgcli -- sh -c "psql \"\$${dsn}\" -Atq -c \"\$1\"" sh "$sql" 2>&1 | sed 's/^/      /'
  done
done

echo "=== G6 清理临时 Pod / DBA Secret（口令不留集群）"
kubectl -n new-api-pre delete pod t2p-pgcli --ignore-not-found --wait=false >/dev/null 2>&1
kubectl -n new-api-pre delete secret t2p-dba --ignore-not-found >/dev/null 2>&1
sleep 3
echo "    残留：pod=$(kubectl -n new-api-pre get pod t2p-pgcli --no-headers 2>&1 | head -1) secret=$(kubectl -n new-api-pre get secret t2p-dba --no-headers 2>&1 | head -1)"
echo "    new-api-pre 现有对象："; kubectl -n new-api-pre get secret,cm,deploy,svc 2>&1 | sed 's/^/      /'
