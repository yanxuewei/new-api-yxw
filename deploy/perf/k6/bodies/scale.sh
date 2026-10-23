# bodies/scale.sh —— 仅调整 Deployment 副本数并等就绪（不带压测），用于压测后恢复现场
# 依赖 header 注入：REQ_REPLICAS（目标副本数）、REQ_DEPLOY（默认 perf-new-api-slave）
NS=new-api-perf
DEPLOY="${REQ_DEPLOY:-perf-new-api-slave}"
WANT="${REQ_REPLICAS:?需要 REQ_REPLICAS=<副本数>}"

echo "=== scale deploy/$DEPLOY -> $WANT"
BEFORE=$(kubectl -n $NS get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
echo "  当前 spec.replicas=${BEFORE:-?}"
kubectl -n $NS scale deploy "$DEPLOY" --replicas="$WANT" 2>&1 | sed 's/^/  /'
kubectl -n $NS rollout status deploy/"$DEPLOY" --timeout=240s 2>&1 | sed 's/^/  /'

READY=$(kubectl -n $NS get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
echo "  ready=${READY:-0}/$WANT"
echo "  pods:"
kubectl -n $NS get pod -l app="$DEPLOY" -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,CPU:.spec.containers[0].resources.limits.cpu --no-headers 2>/dev/null | sed 's/^/    /'
[ "${READY:-0}" -ge "$WANT" ] || { echo "  [XX] 副本未就绪"; exit 2; }
echo "=== scale 完成"
