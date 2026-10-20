#!/bin/bash
# =============================================================================
# ⚠ DEPRECATED（2026-10-20 起）—— 本文件走的是「旧名对象」链路，勿再执行
#   pre / perf 的负载已按 pod 名重建（fanyan 2026-10-20 裁定）：
#     new-api-pre         → pre-new-api-master      （无 Service，不接流量）
#     new-api-pre-slave   → pre-new-api-slave       （唯一 Service，Ingress 后端）
#     new-api-perf        → perf-new-api-master     （无 Service，不接流量）
#     new-api-perf-slave  → perf-new-api-slave      （唯一 Service，Ingress 后端）
#   本文件会渲染 / apply `deploy/jakarta_{pre,perf}/manifests/legacy/new-api-{pre,perf}.yaml`（旧清单），
#   或按 APP=new-api-pre|new-api-perf 这一旧标签选 pod ⇒ 重跑会重建旧对象、
#   让新对象与旧对象抢标签，或让诊断「查不到任何 pod」。**不要重跑**。
#   权威 IaC：deploy/jakarta_pre/manifests/pre-master-slave.yaml
#              deploy/jakarta_perf/manifests/perf-master-slave.yaml
#   弃用说明与新旧对照：deploy/jakarta_pre/DEPRECATED.md
#   注意：命名空间 new-api-pre / new-api-perf 本身**未改名**。
# =============================================================================
# deploy/ops/bodies/apply_pre_app.sh —— new-api-pre / new-api-perf 的 ConfigMap + Deployment + Service
#   （2026-10-16 参数化：NS/APP/TRACK 由 header 注入，默认 pre，与首跑口径逐字一致）
# 前置：Secret 必须已建（--apply-secret）。载荷 $DOCS_B64 = tar.gz（doc_ConfigMap/doc_Deployment/doc_Service）
NS="${NS:-new-api-pre}"; APP="${APP:-new-api-pre}"; TRACK="${TRACK:-pre}"
trap 'rm -rf "$T"' EXIT
printf '%s' "$DOCS_B64" | base64 -d | tar xz -C "$T/payload" || { echo "  [XX] docs 解包失败"; exit 1; }

echo "=== A0 前置校验：Secret 必须存在且 3 键齐全"
KEYS=$(kubectl -n "$NS" get secret new-api-secrets -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>&1)
need_ok=1
for need in SQL_DSN SQL_DSN_MIGRATE SESSION_SECRET; do
  if printf '%s\n' "$KEYS" | grep -qw -- "$need"; then :; else echo "    [XX] Secret 缺键 $need"; need_ok=0; fi
done
[ "$need_ok" = 1 ] || { echo "    ⇒ 先跑 --apply-secret"; exit 1; }
echo "    Secret 键: $KEYS"

echo "=== A1 作用域自检（清单只允许写 $NS；出现别的 ns 直接拒）"
for k in doc_ConfigMap doc_Deployment doc_Service; do
  f="$T/payload/$k.yaml"; [ -s "$f" ] || { echo "    [MISS] $k"; continue; }
  ns=$(grep -m1 -E "^  namespace: " "$f" | awk '{print $2}')
  [ "$ns" = "$NS" ] || { echo "    [XX] $k 的 namespace=$ns ⇒ 越界，终止"; exit 1; }
  img=$(grep -m1 -E "^[[:space:]]+image: " "$f" | awk '{print $2}')
  if [ -n "$img" ]; then
    case "$img" in
      */newapi-dev/*) : ;;
      *) echo "    [XX] $k 引用了非 newapi-dev 仓库（$img）⇒ 禁止碰正式环境镜像"; exit 1 ;;
    esac
    case "$img" in *latest*) echo "    [XX] $k 镜像 tag 用了 latest"; exit 1 ;; esac
  fi
  printf '    %-16s ns=%s image=%s\n' "$k" "$ns" "${img:-n/a}"
done

echo "=== A1b 共池门禁（裁定 2026-10-19：pre 与 perf 都复用 dev 站新池，谁都不许钉机器）"
if grep -qE '^[[:space:]]*(nodeSelector|tolerations):' "$T/payload/doc_Deployment.yaml" 2>/dev/null; then
  echo "    [XX] 载荷里仍有 nodeSelector/tolerations ⇒ 换池前的旧设计，拒绝 apply（台账 §19）"
  exit 1
fi
echo "    载荷无 nodeSelector/toleration（符合共池）"
printf '    节点实况：%s\n' "$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" taints="}{.spec.taints}{" | "}{end}' 2>&1)"
printf '    池标签实况：%s\n' "$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.ack\.alibabacloud\.com/nodepool-id}{" track="}{.items[0].metadata.labels.track}' 2>&1)"

for k in doc_ConfigMap doc_Deployment doc_Service; do
  f="$T/payload/$k.yaml"; [ -s "$f" ] || continue
  echo "=== A2 apply $k"
  kubectl apply -f "$f" 2>&1 | sed 's/^/    /'
done

echo "=== A3 rollout restart（任务 17 已证：Secret 变更不会自动重启 Pod）"
kubectl -n "$NS" rollout restart deploy/"$APP" 2>&1 | sed 's/^/    /'

echo "=== A4 rollout status（startupProbe 150s + 缓冲；必须明显短于云助手 Timeout）"
kubectl -n "$NS" rollout status deploy/"$APP" --timeout=240s 2>&1 | sed 's/^/    /'
rc=$?
printf '    rollout_rc=%s\n' "$rc"

echo "=== A5 Pod 快照 + 镜像与 SA（免密拉取面）"
kubectl -n "$NS" get pod -l track="$TRACK" -o wide 2>&1 | sed 's/^/    /'
kubectl -n "$NS" get pod -l track="$TRACK" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  node="}{.spec.nodeName}{"  sa="}{.spec.serviceAccountName}{"  img="}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/    /'
if [ "$rc" != 0 ]; then
  echo "=== A5b 失败时事件与日志（DSN 打码）"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -14 | sed 's/^/    /'
  kubectl -n "$NS" logs deploy/"$APP" --tail=25 2>&1 \
    | sed -E 's/(password=)[^ ]*/\1***/g; s#://([^:/]+):[^@]*@#://\1:***@#g' | sed 's/^/    /'
fi

echo "=== A6 反证：newapi-dev 的三个负载身份指纹必须与 --dev-baseline 一致（pre 上线不该动 dev）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>&1 | sort | sed 's/^/    /'
echo "=== A7 反证：配额账目（实况优先，不粉饰）"
Q=$(kubectl -n "$NS" get resourcequota -o custom-columns='NAME:.metadata.name,HARD:.spec.hard,USED:.status.used' --no-headers 2>&1)
if grep -qi "No resources found" <<<"$Q"; then
  # 2026-10-19 实测：换池后 dev/pre/perf 三个 ns 的 ResourceQuota 都已不存在（操作者删的）。
  # 我不擅自重建（覆盖别人有意的动作风险更高），但共池又没了上限 ⇒ 如实标成缺口，进台账待裁定。
  echo "    [缺口] $NS 没有 ResourceQuota ⇒ 共池下本 ns 用量无上限，与卡片步骤 1 的配额总账不符（待负责人定）"
else
  printf '%s\n' "$Q" | sed 's/^/    /'
fi
