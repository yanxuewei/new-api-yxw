#!/bin/bash
# install-argocd.sh —— 在 jkt dev 集群装 ArgoCD（非 HA，dev 专用）
#
# 口径（与方案 §7.1 一致）：
#   - 版本钉死 v3.5.6，禁 latest
#   - 关掉 dex（不用 SSO）/ notifications（走既有告警）/ applicationset（单环境不需要）
#   - 压 requests：集群两节点 CPU requests 已 80%/67%，剩余约 2 核
#   - argo-server 加 --insecure：TLS 由 ALB 终止（argocd.likha.hk），
#     否则 server 会在 8080 上做 307 跳转到自签 8083，ALB 健康检查全红
#
# 幂等：可重复执行（kubectl apply）
set -uo pipefail

ARGOCD_VERSION=v3.5.6
NS=argocd

echo "===1. namespace"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "===2. install.yaml ($ARGOCD_VERSION)"
# 必须 --server-side：CRD（applicationsets.argoproj.io）的内嵌 schema 让 client-side apply 的
# last-applied-configuration 注解超过 262144 字节上限，会直接报
# `metadata.annotations: Too long` 并中止整批 apply。
# --force-conflicts：清掉上一次 client-side apply 留下的 managedFields 冲突。
kubectl apply --server-side=true --force-conflicts -n "$NS" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" 2>&1 | tail -6

echo "===3. 关闭 dev 不用的组件"
for d in argocd-dex-server argocd-notifications-controller argocd-applicationset-controller; do
  kubectl -n "$NS" scale "deploy/$d" --replicas=0 2>/dev/null && echo "  scaled $d=0" || echo "  skip $d（不存在）"
done

echo "===4. argo-server 走明文（TLS 交给 ALB）"
# ★ 不能只写 ["--insecure"]：v3.5 的 argocd-server 没有 command，args 的第一项就是可执行文件
#   （/usr/local/bin/argocd-server）。整体替换 args 会让 tini 去 exec `--insecure`
#   → CrashLoopBackOff，日志 `[FATAL tini] exec --insecure failed`（2026-10-26 实测踩过）。
kubectl -n "$NS" patch deploy argocd-server --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["/usr/local/bin/argocd-server","--insecure"]}]' 2>&1 \
  | grep -v 'no change' | head -2

echo "===5. 压 requests（剩余预算 ~2 核）"
set_req() {  # <kind/name> <ctr> <cpu/mem>
  local target="$1"
  local ctr="$2"
  local r="$3"
  local cpu="${r%/*}"
  local mem="${r#*/}"
  kubectl -n "$NS" set resources "$target" -c "$ctr" \
    --requests="cpu=${cpu},memory=${mem}" 2>&1 | head -1
}
# application-controller 在 v3 是 **StatefulSet**（pod 名带 -0），不是 Deployment
set_req sts/argocd-application-controller argocd-application-controller 200m/512Mi
set_req deploy/argocd-repo-server         argocd-repo-server            150m/256Mi
set_req deploy/argocd-server              argocd-server                 100m/128Mi
set_req deploy/argocd-redis               redis                         50m/128Mi

kubectl -n "$NS" set resources sts/argocd-application-controller -c argocd-application-controller \
  --limits=cpu=1,memory=2Gi >/dev/null 2>&1
kubectl -n "$NS" set resources deploy/argocd-repo-server -c argocd-repo-server \
  --limits=cpu=1,memory=1Gi >/dev/null 2>&1

echo "===6. 等待就绪（最多 180s）"
kubectl -n "$NS" rollout status deploy/argocd-repo-server --timeout=180s 2>&1 | tail -2
kubectl -n "$NS" rollout status deploy/argocd-server --timeout=120s 2>&1 | tail -2

echo "===7. 状态"
kubectl -n "$NS" get pods -o wide 2>&1 | sed 's/^/  /'
echo "--- requests 汇总"
for d in $(kubectl -n "$NS" get deploy -o name 2>/dev/null) $(kubectl -n "$NS" get sts -o name 2>/dev/null); do
  echo -n "  $d: "
  kubectl -n "$NS" get "$d" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}={.resources.requests.cpu}/{.resources.requests.memory} {end}' 2>/dev/null
  echo
done
echo "--- 节点已分配（Requests）"
kubectl describe node 2>/dev/null | grep -E "^  (cpu|memory) " | sed 's/^/  /'
