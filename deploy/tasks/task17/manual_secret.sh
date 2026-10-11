#!/usr/bin/env bash
# ==============================================================================
# task17/manual_secret.sh — 任务 17（2026-09-30 裁定版）：手工 Secret 注入
#
# 背景：KMS/凭据管家/ExternalSecret 链路因成本被整体弃用（太贵：凭据管家需购
#   软件密钥管理实例），改为操作员**手工**在集群内创建/更新 Secret。
#   裁定与补偿控制全文：`deploy/docs/KMS弃用_手工Secret注入_裁定_2026-09-30.md`
#
# 交付物：在目标集群 `new-api` 命名空间创建/更新 generic Secret `new-api-secret`，
#   7 个键（与原 RRSA 策略 ARN 的键名严格一致，Pod 侧 secretKeyRef 无需改）：
#     SQL_DSN  SQL_DSN_MIGRATE  REDIS_CONN_STRING  SESSION_SECRET
#     SESSION_SECRET_OLD  PAYMENT_PRIVATE_KEY  TLS_WILDCARD
#
# 值来源（二选一，值**绝不**进 Git / shell 历史 / 命令行参数）：
#   1) VALUES_FILE=<0600 的 key=value 文件>   # 推荐；读入临时文件后走 --from-file
#   2) 交互逐键输入（read -s 不回显）
#
# 用法：
#   bash deploy/tasks/task17/manual_secret.sh --check            # 只读：核对键齐全性（mnl）
#   VALUES_FILE=./newapi.values bash deploy/tasks/task17/manual_secret.sh --apply mnl
#   bash deploy/tasks/task17/manual_secret.sh --apply mnl        # 交互输入
#   # sg 集群待跨区通道建立后：--apply sg（当前会被拒绝并提示）
#
# 集群通道：mnl = 跳板机 `ssh root@8.212.176.207` + `newapi-kube`（EXEC_REMOTE=1 默认）；
#   sg 集群 API Server 私网不可达（任务 46 跨区限制）。
#
# 纪律（卡片坑 2/坑 7/坑 8 + §密钥纪律）：
#   - SESSION_SECRET / SESSION_SECRET_OLD / PAYMENT_PRIVATE_KEY / TLS_WILDCARD **双集群同值**；
#     SQL_DSN / SQL_DSN_MIGRATE / REDIS_CONN_STRING 按站点取值（备站 SQL_DSN = 马尼拉公网串+verify-full）。
#   - 更新 Secret 后必须 `kubectl -n new-api rollout restart deploy/...`（env 只在启动时读）。
#   - VALUES_FILE 用完 `shred -u`；本脚本已内置（含交互模式使用的临时文件）。
# ==============================================================================
set -uo pipefail

SECRETS=(SQL_DSN SQL_DSN_MIGRATE REDIS_CONN_STRING SESSION_SECRET SESSION_SECRET_OLD PAYMENT_PRIVATE_KEY TLS_WILDCARD)
NS=new-api
MODE="${1:---check}"
TARGET="${2:-mnl}"
VALUES_FILE="${VALUES_FILE:-}"

notice() { echo "[task17-manual] $*" >&2; }

if [ "$TARGET" = "sg" ]; then
  notice "⛔ 新加坡集群 API Server 私网不可达（跨区通道未建，见任务 46 限制）。待通道建立后在可达入口执行：--apply sg"
  exit 3
fi

kc() {  # kubectl 通道：mnl 默认走跳板机
  if [ "${EXEC_REMOTE:-1}" = "1" ]; then
    ssh -o StrictHostKeyChecking=accept-new root@8.212.176.207 \
      "export ALIBABA_CLOUD_REGION_ID=ap-southeast-6; /usr/local/bin/newapi-kube >/dev/null 2>&1; kubectl -n $NS $*; rc=\$?; rm -f /root/.kube/config; exit \$rc"
  else
    kubectl -n "$NS" "$@"
  fi
}

check() {  # 只读：核对 7 键齐全性
  local missing=0 keys
  keys=$(kc get secret new-api-secret -o json 2>/dev/null | jq -r '.data // {} | keys[]' || true)
  for k in "${SECRETS[@]}"; do
    if echo "$keys" | grep -qx "$k"; then echo "  [ok] $k"; else echo "  [MISS] $k"; missing=$((missing+1)); fi
  done
  echo "缺失 $missing / ${#SECRETS[@]}"
  [ "$missing" -eq 0 ] || exit 1
}

apply() {
  local tmpdir; tmpdir=$(mktemp -d); chmod 700 "$tmpdir"
  trap 'shred -u "$tmpdir"/* 2>/dev/null; rm -rf "$tmpdir"' EXIT

  if [ -n "$VALUES_FILE" ]; then
    [ -f "$VALUES_FILE" ] || { notice "VALUES_FILE 不存在：$VALUES_FILE"; exit 2; }
    while IFS='=' read -r k v; do
      [ -z "$k" ] && continue; case "$k" in \#*) continue;; esac
      printf '%s' "$v" > "$tmpdir/$k"
    done < "$VALUES_FILE"
  else
    for k in "${SECRETS[@]}"; do
      read -r -p "输入 $k（输入不回显）: " -s v; echo
      printf '%s' "$v" > "$tmpdir/$k"
    done
  fi

  local args=()
  for k in "${SECRETS[@]}"; do
    [ -s "$tmpdir/$k" ] || { notice "键 $k 为空/缺失，中止（不建半个 Secret）"; exit 2; }
    args+=(--from-file="$k=$tmpdir/$k")
  done

  notice "在 mnl 集群写入 $NS/new-api-secret（7 键）…"
  if kc get secret new-api-secret >/dev/null 2>&1; then
    kc delete secret new-api-secret >/dev/null || exit 2
  fi
  kc create secret generic new-api-secret "${args[@]}" || { notice "创建失败"; exit 2; }
  notice "完成。⚠️ 若 Deployment 已在运行：kubectl -n $NS rollout restart deploy/new-api-stable deploy/new-api-master"
  notice "复核：bash deploy/tasks/task17/manual_secret.sh --check"
}

case "$MODE" in
  --check) check ;;
  --apply) apply ;;
  *) notice "用法：$0 --check | --apply mnl|sg（VALUES_FILE=... 可选）"; exit 2 ;;
esac
