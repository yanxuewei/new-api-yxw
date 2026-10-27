#!/usr/bin/env bash
# add-repo-secret.sh —— 把 ops 仓的只读 deploy key 注入 ArgoCD（**本地执行**，不是节点内 body）
#
# 为什么是本地脚本：私钥不能进仓库，也不该出现在静态 body 文件里。
# 本脚本在本地读取私钥 → 拼成一次性 body（mktemp，trap 清理）→ 走云助手通道投递。
#
# usage: bash deploy/gitops/bootstrap/add-repo-secret.sh [/root/.ssh/ops_newapi_yxw]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
KEY="${1:-/root/.ssh/ops_newapi_yxw}"
REPO_URL="git@github.com:yanxuewei/new-api-yxw-ops.git"
SECRET_NAME="repo-new-api-yxw-ops"

[ -f "$KEY" ] || { echo "[!] 私钥不存在：$KEY" >&2; exit 1; }
case "$KEY" in
  /root/*) [ "$(id -u)" -eq 0 ] || { echo "[!] 读 $KEY 需要 root：sudo 或 wsl -u root" >&2; exit 1; } ;;
esac

TMP="$(mktemp /tmp/add-repo-secret.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

{
  echo 'set -uo pipefail'
  echo "cat <<'__KEY_EOF__' | kubectl apply -f -"
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL}
  sshPrivateKey: |
$(sed 's/^/    /' "$KEY")
YAML
  echo '__KEY_EOF__'
  echo "echo '--- 结果'"
  echo "kubectl -n argocd get secret ${SECRET_NAME} -o jsonpath='{.metadata.name} type={.data.type}' | base64 -d 2>/dev/null || kubectl -n argocd get secret ${SECRET_NAME} -o name"
  echo "echo"
  echo "echo '--- repo-server 侧连通性（是否能拉到仓库）'"
  echo "kubectl -n argocd exec deploy/argocd-repo-server -- sh -c 'GIT_SSH_COMMAND=\"ssh -o StrictHostKeyChecking=no -i /dev/null\" true' 2>/dev/null || true"
} > "$TMP"

echo "[i] 投递 repo secret（私钥来自 $KEY，不进仓库）"
bash "${REPO_ROOT}/deploy/lib/ack_remote_jkt_dev.sh" "$TMP"
