#!/bin/bash
# dev 环境：关闭 / 恢复 Passkey 登录（数据库侧开关，无需重启业务）
#
# 背景：new-api 的 Passkey 开关存在 `options` 表，键为 **`passkey.enabled`**（`setting/config` 按
#   `Register("passkey", …)` + 前缀 `passkey.` 落地）。进程内 OptionMap 由 `model.SyncOptions`
#   **每 60 秒**从库重载（`SYNC_FREQUENCY` 默认 60）⇒ 改库后 **1–2 分钟自动生效，不必重启 Pod**。
#   生效判据：`GET /api/status` 的 `passkey_login` 字段（controller/misc.go:118）。
#
# 用法：
#   bash deploy/ops/dev_disable_passkey.sh status     # 只读：当前开关值 + 相关配置
#   bash deploy/ops/dev_disable_passkey.sh off        # 关闭（passkey.enabled=false）
#   bash deploy/ops/dev_disable_passkey.sh on         # 恢复（true）
#
# 实现：在 newapi-dev 命名空间起一个一次性 psql pod（镜像 postgres:16-alpine，集群已验证可拉），
#   DSN 取自 Secret `new-api-secrets` 的 `SQL_DSN_MIGRATE`（master 用的就是它，见 manifests/newapi-dev.yaml:132）。
#   顺便打印 passkey_credentials 计数——0 表示没有人注册过凭证，关闭后无需额外清理。
set -uo pipefail
NS=newapi-dev
POD=psql-oneshot-passkey
MODE="${1:-status}"
TARGET=false
[ "$MODE" = "on" ] && TARGET=true
case "$MODE" in status|on|off) ;; *) echo "usage: $0 status|on|off"; exit 2 ;; esac

kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1
cat <<YAML | kubectl apply -f - 2>&1 | tail -1
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS, labels: {purpose: db-ops}}
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:16-alpine
    env:
    - name: DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN_MIGRATE}}
    - name: TARGET
      value: "$TARGET"
    - name: MODE
      value: "$MODE"
    command: ["sh","-c"]
    args:
    - |
      if [ "\$MODE" = "status" ]; then
        psql "\$DSN" -c "SELECT key, value FROM options WHERE key LIKE 'passkey%' ORDER BY key;"
      else
        psql "\$DSN" -v ON_ERROR_STOP=1 -c "UPDATE options SET value = '\$TARGET' WHERE key = 'passkey.enabled';"
        psql "\$DSN" -c "SELECT key, value FROM options WHERE key = 'passkey.enabled';"
      fi
      psql "\$DSN" -c "SELECT count(*) AS passkey_credentials FROM passkey_credentials;"
YAML

for i in $(seq 1 20); do
  PH=$(kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Succeeded" ] || [ "$PH" = "Failed" ] && break
  sleep 5
done
kubectl -n $NS logs $POD 2>&1 | head -40
kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1

if [ "$MODE" != "status" ]; then
  echo "--- 等 90s 让 options 自动同步，再查 /api/status ---"
  sleep 90
  curl --noproxy '*' -s -m 15 https://dev.likha.hk/api/status \
    | python3 -c "import sys,json;d=json.load(sys.stdin).get('data') or {};print('  passkey_login =', d.get('passkey_login'))"
fi
