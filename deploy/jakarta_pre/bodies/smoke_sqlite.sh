#!/bin/bash
# bodies/smoke_sqlite.sh —— 任务 45 单人口径矩阵的第二格：SQLite 冒烟
#   2026-10-19 参数化：NS / APP / TRACK（默认 = pre 原口径，不传就和历史逐字等价）⇒ pre 与 perf
#   跑同一套判据，这是卡片"两个轨道都要过矩阵"的要求，不是两套各测各的。
# 为什么单独成 body：云助手命令体有 15000B 硬门禁（`CmdContentExceedLimit` 实测 ~19KB 被拒），
#   通道外层包装就占 ~7.2KB ⇒ 与 PG 冒烟合并后的 body 到 15270B 被拦。拆步不是绕门禁，是适配它。
# 判据：同镜像 + 无 SQL_DSN ⇒ 代码回落 SQLite；/api/status 通；/data 下建出库文件。
set -uo pipefail
NS="${NS:-new-api-pre}"; APP="${APP:-new-api-pre}"; TRACK="${TRACK:-pre}"
trap "kubectl -n $NS delete pod t2p-sqlite --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf \"\$T\"" EXIT

echo "=== V2) SQLite 路径：同镜像、无 SQL_DSN、emptyDir ⇒ 代码回落到 /data/one-api.db  [ns=$NS]"
IMG=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1)
printf '    复用镜像：%s\n' "$IMG"
kubectl apply -f - <<SQLITEOMF 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: Pod
metadata:
  name: t2p-sqlite
  namespace: $NS
  labels: { app: t2p-sqlite, project: new-api, site: jkt-dev, track: $TRACK, env: dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 420
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: newapi
      image: $IMG
      imagePullPolicy: IfNotPresent
      args: ["-log-dir=/data/logs"]
      workingDir: /data
      env:
        - name: SESSION_SECRET
          value: "smoke-only-not-a-real-secret"
        - name: MEMORY_CACHE_ENABLED
          value: "false"
        - name: SQL_MAX_OPEN_CONNS
          value: "5"
      ports: [{name: http, containerPort: 3000}]
      volumeMounts: [{name: data, mountPath: /data}]
      resources:
        # 冒烟 Pod 刻意取小值（100m/256Mi）：换池前那是"贴现网余量"的实测结果（旧池 3×1930m 已请求
        #   1.69–1.80 核，写 200m 直接 Insufficient cpu）。2026-10-19 换新池后余量已到 5.9 核，
        #   但**判据不变**：冒烟只验代码路径，不该为了好看抢占邻居。
        #   （这里不能写反引号：本 heredoc 未加引号，反引号会被当命令替换执行——上一版就是这么炸的。）
        requests: { cpu: 100m, memory: 256Mi }
        limits:   { cpu: 300m, memory: 512Mi }
  volumes:
    - name: data
      emptyDir: {sizeLimit: 1Gi}
SQLITEOMF
READY=0
for i in $(seq 1 24); do
  sleep 10
  S=$(kubectl -n "$NS" get pod t2p-sqlite -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$S" = true ] && { READY=1; break; }
done
printf '    ready=%s（轮询 %s 次）\n' "$READY" "$i"
if [ "$READY" = 1 ]; then
  SQLST=$(kubectl -n "$NS" exec t2p-sqlite -- sh -c 'wget -qO- -T 5 http://127.0.0.1:3000/api/status' 2>&1)
  printf '%s\n' "$SQLST" | cut -c1-300 | sed 's/^/      /'
  printf '    判定 SQLite 下 success=true ：'; grep -q '"success":true' <<<"$SQLST" && echo "PASS" || echo "FAIL"
  kubectl -n "$NS" exec t2p-sqlite -- sh -c 'ls -l /data 2>&1 | head -8' 2>&1 | sed 's/^/      /'
  # 实测文件名是 one-api.db（不是 new-api.db）：SQLite 回落路径由代码常量决定，判据按实况写
  kubectl -n "$NS" exec t2p-sqlite -- sh -c 'ls /data/one-api.db >/dev/null 2>&1 && echo "  判定 SQLite 库文件已建（/data/one-api.db）：PASS" || echo "  判定 SQLite 库文件已建：FAIL"' 2>&1 | sed 's/^/      /'
  kubectl -n "$NS" logs t2p-sqlite --tail=60 2>&1 | grep -iE "SQLite|migration|ready in" | head -5 | sed 's/^/      日志自证：/'
else
  echo "    [XX] SQLite Pod 未就绪 ⇒ 事件与日志尾部："
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | grep -E "t2p-sqlite" | tail -8 | sed 's/^/      /'
  kubectl -n "$NS" logs t2p-sqlite --tail=20 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g' | sed 's/^/      /'
fi
echo "--- V2 结束（冒烟 Pod 已在 trap 里清理）"
