#!/usr/bin/env bash
# apply-app.sh —— 把 ops 仓里的 AppProject + Application 应用到集群（**本地执行**）
#
# 清单真源在 ops 仓：argocd/project-newapi.yaml + argocd/application-jkt-dev.yaml
# 本脚本只负责把它们投递进集群（云助手通道），不做任何改写。
#
# usage: bash deploy/gitops/bootstrap/apply-app.sh [ops仓库本地路径]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OPS="${1:-/mnt/e/git_code/new-api-yxw-ops}"

[ -d "$OPS" ] || { echo "[!] ops 仓库目录不存在：$OPS" >&2; exit 1; }
for f in argocd/project-newapi.yaml argocd/application-jkt-dev.yaml; do
  [ -f "$OPS/$f" ] || { echo "[!] 缺清单：$OPS/$f" >&2; exit 1; }
done

TMP="$(mktemp /tmp/apply-app.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

{
  echo 'set -uo pipefail'
  echo "cat <<'__YAML_EOF__' | kubectl apply -f -"
  cat "$OPS/argocd/project-newapi.yaml"
  echo '---'
  cat "$OPS/argocd/application-jkt-dev.yaml"
  echo '__YAML_EOF__'
  echo "echo '--- app 状态（首次会短暂 Unknown/OutOfSync，属正常）'"
  echo "kubectl -n argocd get app jkt-dev -o wide 2>&1 | head -3"
  echo "kubectl -n argocd get app jkt-dev -o jsonpath='  sync={.status.sync.status} health={.status.health.status}{\"\\n\"}' 2>&1"
  echo "echo '--- 最近事件（仓库拉取失败会在这里）'"
  echo "kubectl -n argocd get events --sort-by=.lastTimestamp 2>/dev/null | tail -8"
} > "$TMP"

echo "[i] 投递 AppProject + Application（来源 $OPS）"
bash "${REPO_ROOT}/deploy/lib/ack_remote_jkt_dev.sh" "$TMP"
