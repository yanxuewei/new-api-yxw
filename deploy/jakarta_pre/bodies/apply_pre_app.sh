#!/bin/bash
# bodies/apply_pre_app.sh —— new-api-pre / new-api-perf 的 ConfigMap + Deployment + Service
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

echo "=== A1b 节点池门禁：$APP 必须落在 dedicated=perf 池（若无此标签的 PodSpec 说明 taint 未配）"
sel=$(grep -A3 -m1 "nodeSelector:" "$T/payload/doc_Deployment.yaml" 2>/dev/null | tr '\n' ' ')
printf '    nodeSelector: %s\n' "${sel:-（无 ⇒ 只可能是 pre 的共机口径，perf 必须有）}"
grep -q "effect: NoSchedule" "$T/payload/doc_Deployment.yaml" 2>/dev/null \
  && echo "    tolerations 含 NoSchedule ⇒ 专用池口径成立" || echo "    无 NoSchedule toleration（pre 预期如此）"

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
echo "=== A7 反证：配额账目（pre 与 dev 共机，用量必须落在本 ns 配额内）"
kubectl -n "$NS" get quota 2>&1 | sed 's/^/    /'
