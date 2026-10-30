#!/bin/bash
# bodies/qps_ladder.sh —— 开环阶梯：从 START 起按 STEP 递增，找「仍满足 SLO 的最高 QPS」
# 依赖 header 注入：TARGET_SVC / START / STEP / MAX / DUR / SHARDS / 可选 REQ_REPLICAS
# 与 arrival.sh 的区别：arrival 只打一档并判 PASS/FAIL；本 body 在同一云助手会话内连续升档，
#   首个 FAIL 即停，并输出整条阶梯表 —— 一次调用即可得到 QPS 上限，避免每档一次远程往返。
#
# 判定（任一不满足即 FAIL）：错误率 < SLO_ERR、P95 TTFB < SLO_P95、dropped==0、实得 ≥ 98% 目标
set -uo pipefail
NS=new-api-perf
CM="${K6JS_CM:?缺少 K6JS_CM}"
SHARDS="${SHARDS:-8}"
START="${START:-200}"
STEP="${STEP:-200}"
MAX="${MAX:-4000}"
DUR="${DUR:-60s}"
SLO_ERR="${SLO_ERR:-0.05}"     # 百分比
SLO_P95="${SLO_P95:-800}"      # 毫秒
TOL="${TOL:-0.98}"

case "$TARGET_SVC" in
  *://*) BASE="$TARGET_SVC"; MODE="public-arrival" ;;
  *)
    IP=$(kubectl -n $NS get svc "$TARGET_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [ -n "$IP" ] || { echo "  [XX] 取不到 svc/$TARGET_SVC"; exit 2; }
    BASE="http://$IP"; MODE="clusterip-arrival" ;;
esac
echo "=== 阶梯：target=$TARGET_SVC ($MODE) ${START}→${MAX} 步长 ${STEP}  每档 ${DUR}  ${SHARDS} 分片"
echo "=== SLO：错误率<${SLO_ERR}%  P95<${SLO_P95}ms  dropped=0  实得≥$TOL×目标"

REPL_BEFORE=""
if [ -n "${REQ_REPLICAS:-}" ]; then
  D=perf-new-api-slave
  [ "$MODE" = "clusterip-arrival" ] && D="$TARGET_SVC"
  REPL_BEFORE=$(kubectl -n $NS get deploy "$D" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  kubectl -n $NS scale deploy "$D" --replicas="$REQ_REPLICAS" >/dev/null 2>&1
  kubectl -n $NS rollout status deploy/"$D" --timeout=240s >/dev/null 2>&1
fi
REPL=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

kubectl -n $NS get configmap "$CM" >/dev/null 2>&1 || { echo "  [XX] 缺少脚本 ConfigMap：$CM"; exit 2; }

# 单档：起 SHARDS 个 Job → 等完成 → 聚合
run_rate() {
  local rate=$1 i r pre mx
  local base_rate=$((rate / SHARDS)) rem=$((rate % SHARDS))
  for i in $(seq 0 $((SHARDS - 1))); do kubectl -n $NS delete job "k6-qps-$i" --ignore-not-found >/dev/null 2>&1; done
  for i in $(seq 0 $((SHARDS - 1))); do
    r=$base_rate; [ "$i" -lt "$rem" ] && r=$((r + 1))
    pre=$((r * 3)); mx=$((r * 5))
    kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: k6-qps-$i, namespace: $NS, labels: {app: k6, purpose: perf}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          imagePullPolicy: IfNotPresent
          args: ["run", "/scripts/sse.js"]
          env:
            - {name: RATE, value: "$r"}
            - {name: DUR, value: "$DUR"}
            - {name: BASE, value: "$BASE"}
            - {name: SHARD, value: "$i"}
            - {name: PRE_VUS, value: "$pre"}
            - {name: MAX_VUS, value: "$mx"}
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
            - name: TOKENS
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: tokens, optional: true}}
            - name: ADMIN_USER
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: admin_username, optional: true}}
            - name: ADMIN_PASS
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: admin_password, optional: true}}
            - {name: STREAM, value: "${STREAM:-false}"}
            - {name: MAX_TOKENS, value: "${MAX_TOKENS:-128}"}
            - {name: MODEL, value: "${MODEL:-mock-gpt}"}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      nodeSelector: {perf-role: load}
      volumes: [{name: scripts, configMap: {name: $CM}}]
YAML
  done

  local round done=0
  for round in $(seq 1 60); do
    done=1
    for i in $(seq 0 $((SHARDS - 1))); do
      local s f
      s=$(kubectl -n $NS get job "k6-qps-$i" -o jsonpath='{.status.succeeded}' 2>/dev/null)
      f=$(kubectl -n $NS get job "k6-qps-$i" -o jsonpath='{.status.failed}' 2>/dev/null)
      [ "$s" = "1" ] && continue
      [ -n "$f" ] && [ "$f" != "0" ] && continue
      done=0; break
    done
    [ "$done" = "1" ] && break
    sleep 5
  done

  # 聚合：http_reqs 的 /s、http_req_failed 的 %、waiting 的 p95、dropped 数
  local tot_rate=0 tot_req=0 tot_fail=0 tot_drop=0 p95=0 i line txt v
  for i in $(seq 0 $((SHARDS - 1))); do
    txt=$(kubectl -n $NS logs "job/k6-qps-$i" 2>/dev/null)
    [ -n "$txt" ] || continue

    line=$(printf '%s\n' "$txt" | grep -E '^ *http_reqs' | tail -1)
    v=$(printf '%s\n' "$line" | awk '{x=$3; sub("/s","",x); print x+0}')
    tot_rate=$(awk -v a="$tot_rate" -v b="$v" 'BEGIN{printf "%.3f", a+b}')

    line=$(printf '%s\n' "$txt" | grep -E '^ *http_req_failed' | tail -1)
    v=$(printf '%s\n' "$line" | awk '{print $3+0}')
    tot_fail=$(awk -v a="$tot_fail" -v b="$v" 'BEGIN{printf "%.0f", a+b}')
    v=$(printf '%s\n' "$line" | awk '{print $6+0}')
    tot_req=$(awk -v a="$tot_req" -v b="$v" 'BEGIN{printf "%.0f", a+b}')

    line=$(printf '%s\n' "$txt" | grep -E '^ *dropped_iterations' | tail -1)
    v=$(printf '%s\n' "$line" | awk '{print $3+0}')
    tot_drop=$(awk -v a="$tot_drop" -v b="$v" 'BEGIN{printf "%.0f", a+b}')

    line=$(printf '%s\n' "$txt" | grep -E '^ *http_req_waiting' | tail -1)
    v=$(printf '%s\n' "$line" | awk '{m=0; for(i=1;i<=NF;i++){if($i ~ /^p\(95\)=/){x=$i; sub("p\\(95\\)=","",x); sub("ms","",x); if(x+0>m) m=x+0}}; print m}')
    p95=$(awk -v a="$p95" -v b="$v" 'BEGIN{print (b+0>a+0)?b:a}')
  done

  local err achieved verdict
  err=$(awk -v f="$tot_fail" -v r="$tot_req" 'BEGIN{if(r>0) printf "%.3f", f*100/r; else print "0"}')
  achieved=$(awk -v r="$tot_rate" 'BEGIN{printf "%.0f", r}')
  verdict=FAIL
  awk -v e="$err" -v p="$p95" -v d="$tot_drop" -v a="$achieved" -v t="$rate" -v se="$SLO_ERR" -v sp="$SLO_P95" -v tol="$TOL" \
    'BEGIN{exit !(e+0<se+0 && p+0<sp+0 && d+0==0 && a+0>=t*tol)}' && verdict=PASS
  LAST_ACH="$achieved"; LAST_P95="$p95"; LAST_ERR="$err"; LAST_DROP="$tot_drop"
  printf '  [QPS] rate=%-6s achieved=%-6s p95=%-6s err=%-7s dropped=%-5s %s\n' "$rate" "$achieved" "${p95}ms" "${err}%" "$tot_drop" "$verdict"
  echo "QPSROW	$rate	$achieved	$p95	$err	$tot_drop	$verdict"
  [ "$verdict" = PASS ]
}

BEST=0; BEST_ACH=0; BEST_P95=0; BEST_ERR=0
R=$START
while [ "$R" -le "$MAX" ]; do
  if run_rate "$R"; then
    BEST=$R; BEST_ACH=$LAST_ACH; BEST_P95=$LAST_P95; BEST_ERR=$LAST_ERR
  else
    echo "=== 首个失败档 = $R，停止上探"
    break
  fi
  R=$((R + STEP))
done

echo "===RUN_META==="
echo "target=$TARGET_SVC x${REPL}"
echo "base=$BASE"
echo "mode=$MODE"
echo "vus=0"
echo "rate=$START-$MAX/$STEP"
echo "dur=$DUR"
echo "replicas=${REPL:-1}"
echo "job=k6-qps-0..$((SHARDS - 1))"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "method=constant-arrival-rate-ladder"
echo "summary_schema=2"
echo "shards=$SHARDS"
echo "===END_META==="
echo "=== 结论：最高通过 QPS 档 = $BEST（实得 ${BEST_ACH}、P95 ${BEST_P95}ms、err ${BEST_ERR}%）"
