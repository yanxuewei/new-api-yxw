#!/usr/bin/env bash
# expose-ui.sh —— 用既有 dev ALB 暴露 ArgoCD UI（argocd.likha.hk）
#
# 口径：
#   - 复用 dev 的 AlbConfig `jkt-alb`（不新建 ALB，不新建证书）
#   - 443 默认证书 `606823-ap-southeast-1`（DV 通配符 *.likha.hk）自动覆盖 argocd.likha.hk
#   - order=60，避开 dev 现有 1/2/3/4/50/51/52/53
#   - 后端 svc/argocd-server:80 → 8080（server 已加 --insecure，TLS 由 ALB 终止）
#
# usage: bash deploy/gitops/bootstrap/expose-ui.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

TMP="$(mktemp /tmp/expose-argocd.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

cat > "$TMP" <<'BODY'
set -uo pipefail
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    app: argocd
    purpose: ui
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/order: "60"
spec:
  ingressClassName: alb
  rules:
    - host: argocd.likha.hk
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
YAML
echo '--- Ingress 状态'
kubectl -n argocd get ingress argocd-server 2>&1 | sed 's/^/  /'
kubectl -n argocd get ingress argocd-server -o jsonpath='  addr={.status.loadBalancer.ingress[0].hostname}{"\n"}' 2>&1
echo '--- 本机回环自测（443，走内网 Service）'
curl -sS -m 8 -o /dev/null -w '  argocd-server:80/api/version -> %{http_code}\n' http://argocd-server.argocd.svc.cluster.local/api/version 2>&1 || true
BODY

echo "[i] 创建 ArgoCD UI Ingress"
bash "${REPO_ROOT}/deploy/lib/ack_remote_jkt_dev.sh" "$TMP"
