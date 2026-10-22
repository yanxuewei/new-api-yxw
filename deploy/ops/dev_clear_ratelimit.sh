#!/bin/bash
# dev 环境：清理登录/接口限流计数（Redis 固定窗口）
#
# 背景（2026-10-22 实证）：new-api 的限流键为
#   `rateLimit:v2:ip:<mark>:<clientIP>` / `rateLimit:v2:user:<mark>:<userID>`
#   mark: GA=全局 API · GW=全局 Web · CT=关键操作（**登录 / 2FA / passkey 走这个**）· UC=<scope>=按用户
#   阈值默认（common/init.go:131-133）：CT = 20 次 / 20 分钟 / IP，超限返回 **429**。
#   Redis 启用时计数落 Tair（dev 用 db /0，连接串来自 Secret `new-api-secrets/REDIS_CONN_STRING`）。
#
# 用法：
#   bash deploy/ops/dev_clear_ratelimit.sh status [IP]     # 只读：列 rateLimit 键（可按 IP 过滤）
#   bash deploy/ops/dev_clear_ratelimit.sh clear <IP>      # 删该 IP 的全部限流键 + 所有 UC 键
#   bash deploy/ops/dev_clear_ratelimit.sh clear-all       # 删全部 rateLimit:v2:*（⚠ 仅 dev 用）
#
# 实现：newapi-dev 起一次性 redis:7-alpine Pod（集群可直接拉取），跑完即删；不回显密码。
set -uo pipefail
NS=newapi-dev
POD=redis-oneshot-ops
MODE="${1:-status}"
ARG="${2:-}"

case "$MODE" in
  status|clear|clear-all) ;;
  *) echo "usage: $0 status [IP] | clear <IP> | clear-all"; exit 2 ;;
esac

kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1
cat <<YAML | kubectl apply -f - 2>&1 | tail -1
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS, labels: {purpose: db-ops}}
spec:
  restartPolicy: Never
  containers:
  - name: redis
    image: redis:7-alpine
    env:
    - name: R
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: REDIS_CONN_STRING}}
    - name: MODE
      value: "$MODE"
    - name: IP_ARG
      value: "$ARG"
    command: ["sh","-c"]
    args:
    - |
      rc() { redis-cli -u "\$R" --no-auth-warning "\$@"; }
      # ⚠ xargs 不能调用 shell 函数（实测 xargs: rc: No such file or directory）⇒ 统一用 while 循环
      del_pat() {
        rc --scan --pattern "\$1" 2>/dev/null | while read -r k; do
          [ -n "\$k" ] && rc DEL "\$k" >/dev/null
        done
      }
      case "\$MODE" in
        status)
          if [ -n "\$IP_ARG" ]; then
            rc --scan --pattern "rateLimit:v2:ip:*:\$IP_ARG" 2>/dev/null | while read -r k; do
              echo "  \$k ttl=\$(rc TTL "\$k")"
            done
          else
            rc --scan --pattern 'rateLimit:v2:*' 2>/dev/null | while read -r k; do
              echo "  \$k ttl=\$(rc TTL "\$k")"
            done
          fi
          ;;
        clear)
          [ -n "\$IP_ARG" ] || { echo '[!] clear 需要 IP 参数'; exit 1; }
          del_pat "rateLimit:v2:ip:*:\$IP_ARG"
          del_pat 'rateLimit:v2:user:UC:*'
          echo '  剩余匹配：'; rc --scan --pattern "rateLimit:v2:ip:*:\$IP_ARG" 2>/dev/null | wc -l
          ;;
        clear-all)
          del_pat 'rateLimit:v2:*'
          echo '  剩余 rateLimit 键：'; rc --scan --pattern 'rateLimit:v2:*' 2>/dev/null | wc -l
          ;;
      esac
YAML

for i in $(seq 1 20); do
  PH=$(kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Succeeded" ] || [ "$PH" = "Failed" ] && break
  sleep 5
done
kubectl -n $NS logs $POD 2>&1 | head -40
kubectl -n $NS delete pod $POD --ignore-not-found >/dev/null 2>&1
