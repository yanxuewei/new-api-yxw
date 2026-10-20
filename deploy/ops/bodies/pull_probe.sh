#!/bin/bash
# deploy/ops/bodies/pull_probe.sh —— 在目标 ns 里用一个临时探针 Pod 实测免密拉取（只建/只删自己的对象）
#   NS=new-api-pre|new-api-perf
set -uo pipefail
TNS="${NS:-}"
POD=acr-pull-probe
case "$TNS" in new-api-pre|new-api-perf) : ;; *) echo "  [XX] NS 只能是 new-api-pre/new-api-perf"; exit 2 ;; esac

echo "=== Q0 取镜像参照（复用 dev 现网正在用的镜像，不新造 tag）"
IMG=$(kubectl -n newapi-dev get deploy new-api-dev -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[ -n "$IMG" ] || { echo "  [XX] 取不到 dev 镜像，探针无法构造"; exit 2; }
printf '  探针镜像=%s\n' "$IMG"
printf '  仓库命名空间检查：%s\n' "$(case "$IMG" in */newapi-dev/*) echo "ok（dev 仓库）" ;; *) echo "[XX] 不是 newapi-dev 仓库 ⇒ 违反本卡红线（禁引 newapi-prod/*）"; exit 2 ;; esac)"

echo "=== Q1 建探针前的三要素"
printf '  目标 ns=%s  SA=new-api-app  pullSecrets=%s\n' "$TNS" "$(kubectl -n $TNS get sa new-api-app -o jsonpath='{.imagePullSecrets[*].name}' 2>&1)"
printf '  Secret 在否=%s\n' "$(kubectl -n $TNS get secret acr-credential-secret-aggregation -o jsonpath='{.metadata.name}' 2>&1 | head -1)"

echo "=== Q2 建探针 Pod（restartPolicy=Never，只读拉取，不监听端口、不接任何 DSN）"
kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $TNS
  labels: {site: jkt-dev, track: dev, env: dev, project: new-api, probe: acr-pull}
spec:
  serviceAccountName: new-api-app
  restartPolicy: Never
  activeDeadlineSeconds: 180
  containers:
  - name: probe
    image: $IMG
    command: ["/bin/sh", "-c", "echo PULL_OK; sleep 1"]
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {cpu: 200m, memory: 256Mi}
MANIFEST
printf '  apply_rc=%s\n' "$?"
if ! kubectl -n $TNS get pod $POD >/dev/null 2>&1; then
  echo "  [XX] 探针 Pod 没建出来（多为本 ns 的 ResourceQuota 拦下：容器必须同时给 requests/limits）⇒ 不再空等"
  exit 1
fi

echo "=== Q3 观察至多 150s（每 10s 一次，只打印相位与等待原因）"
RES="unknown"
for i in $(seq 1 15); do
  ST=$(kubectl -n $TNS get pod $POD -o jsonpath='{.status.phase}{"|"}{range .status.containerStatuses[*]}{.state.waiting.reason}{.state.terminated.exitCode}{end}' 2>/dev/null)
  printf '  t+%02ds %s\n' "$((i*10))" "${ST:-<空>}"
  case "$ST" in
    Succeeded*|Running*|*"PULL_OK"*) RES=ok; break ;;
    *ImagePullBackOff*|*ErrImagePull*) RES=pull-fail; break ;;
    *CreateContainerConfigError*) RES=config-fail; break ;;
  esac
  sleep 10
done
printf '  结论=%s\n' "$RES"
printf '  waiting/message=%s\n' "$(kubectl -n $TNS get pod $POD -o jsonpath='{range .status.containerStatuses[*]}{.state.waiting.message}{end}' 2>/dev/null | head -c 300)"
printf '  imageID=%s\n' "$(kubectl -n $TNS get pod $POD -o jsonpath='{range .status.containerStatuses[*]}{.imageID}{end}' 2>/dev/null)"
kubectl -n $TNS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei "pull|authoriz|denied|manifest|unauthorized" | tail -8 | sed 's/^/    /'

echo "=== Q4 清理自建探针（只删这一个对象）"
kubectl -n $TNS delete pod $POD --wait=false 2>&1 | sed 's/^/  /'
echo "--- Q1–Q4 结束（结论=ok 才说明免密作用域对新 ns 真的生效）"
[ "$RES" = ok ]
