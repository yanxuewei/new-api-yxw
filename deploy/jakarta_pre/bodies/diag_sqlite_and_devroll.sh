#!/bin/bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件内的对象名已失效
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   ⇒ 凡出现旧名的 kubectl 操作：只读诊断会 NotFound；apply / patch / scale 类会
#     重新造出旧对象并与新对象抢标签 ⇒ **不要重跑本文件**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**，只读诊断仍可用。
# =============================================================================
# bodies/diag_sqlite_and_devroll.sh —— 三件事一次取数：① SQLite 冒烟为什么没就绪 ② /api/status 里版本字段实况
#   ③ new-api-channel-task-dev 的模板哈希在基线后变了（隔离红线要的反证），必须查清是谁、什么时候、改了什么
set -uo pipefail
echo "=== Z1 channel-task 变更时间线（RS 历史 + 条件 + 观测到的最后一次模板更新）"
kubectl -n newapi-dev get deploy new-api-channel-task-dev \
  -o jsonpath='generation={.metadata.generation}{"\n  resourceVersion="}{.metadata.resourceVersion}{"\n  managedFields.manager="}{.metadata.managedFields[*].manager}{"\n  managedFields.operation="}{.metadata.managedFields[*].operation}{"\n  managedFields.time="}{.metadata.managedFields[*].time}{"\n  conditions="}{.status.conditions}{"\n"}' 2>&1 | cut -c1-900 | sed 's/^/    /'
echo "  --- ReplicaSet 历史（谁在什么时候被建出来）"
kubectl -n newapi-dev get rs -l app=new-api-channel-task -o wide 2>&1 | sed 's/^/    /'
kubectl -n newapi-dev get rs 2>&1 | grep channel | sed 's/^/    /'
echo "  --- 两个 RS 的镜像与创建时间"
for r in $(kubectl -n newapi-dev get rs --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep channel); do
  printf '      %s\n' "$r"
  kubectl -n newapi-dev get rs "$r" -o jsonpath='        created={.metadata.creationTimestamp}{"  img="}{.spec.template.spec.containers[0].image}{"  ann="}{.spec.template.metadata.annotations}{"\n"}' 2>&1 | cut -c1-500 | sed 's/^/      /'
done
echo "  --- 现 Pod 的启动时间与节点"
kubectl -n newapi-dev get pod -o wide 2>&1 | grep -E "NAME|channel" | sed 's/^/    /'

echo "=== Z2 /api/status 的字段实况（版本字段到底叫什么）"
POD=$(kubectl -n new-api-pre get pod -l track=pre -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
S=$(kubectl -n new-api-pre exec "$POD" -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1)
printf '    success 字段：%s\n' "$(grep -oE '"success":[a-z]+' <<<"$S" | head -1)"
printf '    含 version 关键字的片段：%s\n' "$(grep -oE '"[a-zA-Z_]*[Vv]ersion[a-zA-Z_]*":[^,}]*' <<<"$S" | head -3 | tr '\n' ' ')"
printf '    顶层键：%s\n' "$(grep -oE '"[a-zA-Z_]+":' <<<"$S" | tr -d '":' | sort -u | tr '\n' ' ' | cut -c1-600)"
printf '    字节数：%s\n' "${#S}"

echo "=== Z3 SQLite 冒烟 Pod 的下落（上次 240s 没就绪，先复现再定位）"
kubectl -n new-api-pre delete pod t2p-sqlite --ignore-not-found --wait=true >/dev/null 2>&1
IMG=$(kubectl -n new-api-pre get deploy new-api-pre -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1)
kubectl apply -f - <<SQLITEOMF 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2p-sqlite
  namespace: new-api-pre
  labels: { app: t2p-sqlite, project: new-api, site: jkt-dev, track: pre, env: dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: newapi
      image: $IMG
      imagePullPolicy: IfNotPresent
      args: ["-log-dir=/data/logs"]
      workingDir: /data
      env:
        - {name: SESSION_SECRET, value: "smoke-only-not-a-real-secret"}
        - {name: MEMORY_CACHE_ENABLED, value: "false"}
        - {name: SQL_MAX_OPEN_CONNS, value: "5"}
      ports: [{name: http, containerPort: 3000}]
      volumeMounts: [{name: data, mountPath: /data}]
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits:   { cpu: 300m, memory: 512Mi }
  volumes:
    - name: data
      emptyDir: {sizeLimit: 1Gi}
SQLITEOMF
for i in $(seq 1 18); do
  sleep 10
  PH=$(kubectl -n new-api-pre get pod t2p-sqlite -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready} {.status.containerStatuses[0].state}' 2>/dev/null)
  printf '    [%02d] %s\n' "$i" "$PH"
  case "$PH" in *"true "*) echo "    ⇒ 已就绪，停止轮询"; break ;; esac
done
echo "  --- 事件（只挑本 Pod）"
kubectl -n new-api-pre get events --sort-by=.lastTimestamp 2>&1 | grep -E "t2p-sqlite" | tail -10 | sed 's/^/      /'
echo "  --- 日志（DSN 打码；没有 DSN 也应无敏感串）"
kubectl -n new-api-pre logs t2p-sqlite --tail=30 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/      /'
echo "  --- 容器内 /data 与端口实况"
kubectl -n new-api-pre exec t2p-sqlite -- sh -c 'ls -l /data; echo; wget -qO- -T 5 http://127.0.0.1:3000/api/status | head -c 200' 2>&1 | sed 's/^/      /'
