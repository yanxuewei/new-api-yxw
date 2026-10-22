#!/bin/bash
# dev 环境：查询渠道 API Key（默认打码，--show 才输出完整值）
#
# 结论（代码依据）：new-api 的渠道密钥存在 **`channels.key`** 列（`model/channel.go:26`
#   `Key string \`json:"key" gorm:"not null"\``），**明文、无加密**；页面上的
#   「隐藏 - 验证以显示」只是前端掩码（配合 /api/channel/:id/key 的二次验证接口），库里不加密。
#   多 Key 模式下该列是**换行分隔**的多个 Key（`is_multi_key=true`）。
#
# 用法：
#   bash deploy/ops/dev_query_channel_key.sh list                 # 只读：列出渠道（名称/类型/状态/Key 长度）
#   bash deploy/ops/dev_query_channel_key.sh get <渠道名或ID>      # 只读：打码查看（前6+后4）
#   bash deploy/ops/dev_query_channel_key.sh show <渠道名或ID>     # ⚠ 输出完整 Key（敏感，勿贴聊天/截图）
set -uo pipefail
NS=newapi-dev
POD=psql-oneshot-chkey
MODE="${1:-list}"
ARG="${2:-}"
SHOW=0; [ "$MODE" = "show" ] && SHOW=1

case "$MODE" in list|get|show) ;; *) echo "usage: $0 list | get <name|id> | show <name|id>"; exit 2 ;; esac
[ "$MODE" = "list" ] || [ -n "$ARG" ] || { echo "[!] 需要渠道名或 id"; exit 2; }

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
    - name: MODE
      value: "$MODE"
    - name: ARG
      value: "$ARG"
    - name: SHOW
      value: "$SHOW"
    command: ["sh","-c"]
    args:
    - |
      if [ "\$MODE" = "list" ]; then
        psql "\$DSN" -c "SELECT id, name, type, status, length(key) AS key_len, channel_info->>'is_multi_key' AS multi FROM channels ORDER BY id;"
      elif [ "\$SHOW" = "1" ]; then
        psql "\$DSN" -c "SELECT id, name, channel_info->>'is_multi_key' AS multi, key FROM channels WHERE name ILIKE '%\$ARG%' OR id::text = '\$ARG';"
      else
        psql "\$DSN" -c "SELECT id, name, length(key) AS key_len, channel_info->>'is_multi_key' AS multi, left(key,6) || '****' || right(key,4) AS key_masked FROM channels WHERE name ILIKE '%\$ARG%' OR id::text = '\$ARG';"
      fi
YAML
for i in $(seq 1 20); do
  PH=$(kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Succeeded" ] || [ "$PH" = "Failed" ] && break
  sleep 5
done
kubectl -n $NS logs $POD 2>&1 | head -40
kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1
