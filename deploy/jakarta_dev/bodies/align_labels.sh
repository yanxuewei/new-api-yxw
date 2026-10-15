#!/bin/bash
# bodies/align_labels.sh —— 对齐 TARGET 的标签（键与范围都显式传入，不再为每个键抄一个 body）
#   KV=site=jkt-dev,track=dev        要设置的键值对（必填，逗号分隔）
#   SCOPE=both|meta|template         改哪一层：顶层 metadata.labels / Pod 模板 / 两层（默认 both）
# 只有 template 层会触发滚动重建；meta 层是纯元数据。
NS=newapi-dev
T="${TARGET:-}"
KVS="${KV:-}"
SCOPE="${SCOPE:-both}"
echo "=== L0 参数与不可变门（过不了就一个字不写）"
[ -n "$T" ] || { echo "  [XX] 未传 TARGET"; exit 2; }
[ -n "$KVS" ] || { echo "  [XX] 未传 KV（刻意不给默认键值，避免误改别人的负载）"; exit 2; }
case "$SCOPE" in both|meta|template) : ;; *) echo "  [XX] SCOPE 只能是 both/meta/template"; exit 2 ;; esac
# 键白名单：只允许这四个归集标签。app 一律禁改 —— Service selector 与成本归集都吃它。
IFS=',' read -ra PAIRS <<<"$KVS"
JQ_META=; JQ_TPL=
for p in "${PAIRS[@]}"; do
  k="${p%%=*}"; v="${p#*=}"
  case "$k" in app) echo "  [XX] 禁改 app（Service selector 依赖它）"; exit 1 ;; esac
  case "$k" in site|track|env|project) : ;; *) echo "  [XX] 键 $k 不在白名单 site/track/env/project"; exit 1 ;; esac
  [[ "$v" =~ ^[a-z0-9-]+$ ]] || { echo "  [XX] 值 $k=$v 不合规范（只允许小写字母数字与连字符）"; exit 1; }
  JQ_META="$JQ_META\"$k\":\"$v\","; JQ_TPL="$JQ_TPL\"$k\":\"$v\","
done
JQ_META="${JQ_META%,}"; JQ_TPL="${JQ_TPL%,}"
case "$SCOPE" in
  both)     PATCH="{\"metadata\":{\"labels\":{$JQ_META}},\"spec\":{\"template\":{\"metadata\":{\"labels\":{$JQ_TPL}}}}}" ;;
  meta)     PATCH="{\"metadata\":{\"labels\":{$JQ_META}}}" ;;
  template) PATCH="{\"spec\":{\"template\":{\"metadata\":{\"labels\":{$JQ_TPL}}}}}" ;;
esac
printf '  目标=%s  SCOPE=%s  KV=%s\n' "$T" "$SCOPE" "$KVS"
case "$SCOPE" in
  meta) printf '  判定：SCOPE=meta ⇒ 只碰顶层元数据，不该有任何 Pod 重建（L4 会反证）\n' ;;
  template) printf '  判定：SCOPE=template ⇒ 只碰 Pod 模板，会滚动重建一次\n' ;;
  both) printf '  判定：SCOPE=both ⇒ 含模板层，会滚动重建一次\n' ;;
esac
SEL=$(kubectl -n $NS get deploy "$T" -o jsonpath='{.spec.selector.matchLabels}' 2>&1)
printf '  selector.matchLabels=%s\n' "$SEL"
if [ "$SCOPE" != meta ]; then
  for p in "${PAIRS[@]}"; do k="${p%%=*}"
    grep -qE "\"$k\"" <<<"$SEL" && { echo "  [XX] selector 含 $k（不可变字段）⇒ 改模板标签会造孤儿 Pod，必须走删重建；本次拒绝"; exit 1; }
  done
  echo "  判定：待改键均不在 selector 内 ⇒ 改模板标签安全"
fi
# 滚动前后要能对上号：先记 Pod 身份指纹（名字+模板哈希+重启数）
BEFORE=$(kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>/dev/null | grep -F -- "$T" | sort)
kubectl -n $NS get deploy "$T" -o jsonpath='  before 顶层labels={.metadata.labels}{"\n"}' 2>&1
kubectl -n $NS get deploy "$T" -o jsonpath='  before 模板labels={.spec.template.metadata.labels}{"\n"}' 2>&1

echo "=== L1 patch"
OUT=$(kubectl -n $NS patch deploy "$T" --type=merge -p "$PATCH" 2>&1)
printf '  %s\n' "$OUT"
case "$OUT" in *error*|*Error*) echo "  [XX] patch 失败 ⇒ 不重试"; exit 1 ;; esac

echo "=== L2 回读（生效判据只认这里）"
kubectl -n $NS get deploy "$T" -o jsonpath='  after 顶层labels={.metadata.labels}{"\n"}' 2>&1
kubectl -n $NS get deploy "$T" -o jsonpath='  after 模板labels={.spec.template.metadata.labels}{"\n"}' 2>&1
printf '  after selector=%s（应保持不变）\n' "$(kubectl -n $NS get deploy "$T" -o jsonpath='{.spec.selector.matchLabels}' 2>&1)"
echo "  --- 与同 ns 参照负载的标签集做差集（补齐是否真的同形，除 app 外）"
for d in $(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  [ "$d" = "$T" ] && continue
  printf '    参照 %s 顶层=%s\n' "$d" "$(kubectl -n $NS get deploy "$d" -o jsonpath='{.metadata.labels}' 2>&1)"
  M1=$(kubectl -n $NS get deploy "$T" -o go-template='{{range $k,$v := .metadata.labels}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | sort -u)
  M2=$(kubectl -n $NS get deploy "$d" -o go-template='{{range $k,$v := .metadata.labels}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | sort -u)
  printf '      仅目标有的键：%s | 仅参照有的键：%s\n' "$(comm -23 <(echo "$M1") <(echo "$M2") | tr '\n' ' ')" "$(comm -13 <(echo "$M1") <(echo "$M2") | tr '\n' ' ')"
done

echo "=== L3 需要滚动才等，meta 层不等"
RC=0
case "$SCOPE" in
  meta) echo "    SCOPE=meta ⇒ 跳过 rollout 等待" ;;
  *) kubectl -n $NS rollout status deploy/"$T" --timeout=180s 2>&1 | sed 's/^/    /'; RC=$? ;;
esac
printf '  rollout_rc=%s\n' "$RC"

echo "=== L4 反证：SCOPE=meta 时 Pod 身份必须一字不变（没有重建才是对的）"
AFTER=$(kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"\n"}{end}' 2>/dev/null | grep -F -- "$T" | sort)
if [ "$BEFORE" = "$AFTER" ]; then echo "    [ok] Pod 身份指纹（名字|模板哈希|重启数）改前后完全一致 ⇒ 未发生重建"; else
  printf '    [!!] 身份变了：\n      before: %s\n      after : %s\n' "$BEFORE" "$AFTER"
fi
printf '    现状：%s\n' "$(kubectl -n $NS get deploy "$T" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>&1)"
kubectl -n $NS get pod -o wide --no-headers 2>&1 | grep -F -- "$T" | sed 's/^/      /'
PODIP=$(kubectl -n $NS get pod -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null)
for sv in $(kubectl -n $NS get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  for ip in $(kubectl -n $NS get endpoints "$sv" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null); do
    owner=$(awk -v i="$ip" '$2==i {print $1}' <<<"$PODIP"); [ -n "$owner" ] || owner="<查不到>"
    printf '      后端归属：svc/%-20s → %s → pod/%s\n' "$sv" "$ip" "$owner"
  done
done
echo "--- L0–L4 结束（写入面只有 $T 在 $SCOPE 层的 $KVS）"
exit $RC
