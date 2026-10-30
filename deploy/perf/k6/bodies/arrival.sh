#!/bin/bash
# bodies/arrival.sh —— 开环到达率压测：N 个分片 Job 各跑 constant-arrival-rate（脚本必须装 sse_arrival.js）
# 依赖 header 注入：TARGET_SVC / TOTAL_RATE / DUR / SHARDS / 可选 REQ_REPLICAS
#
# 与 sharded.sh 的差别：分片切的是「每秒请求数」而不是「并发 VU」。
# 开环不受单请求耗时反压 ⇒ 判据必须分两层看：
#   · dropped_iterations > 0 或 Job failed ⇒ 客户端发不出去（客户端容量不足，不是服务端问题）
#   · http_req_failed > 0.05% / sse_complete 掉 ⇒ 服务端接不住（这才是容量结论）
set -uo pipefail
NS=new-api-perf
CM="${K6JS_CM:?缺少 K6JS_CM（脚本 ConfigMap）}"
SHARDS="${SHARDS:-3}"
TOTAL="${TOTAL_RATE:?缺少 TOTAL_RATE（总目标 rps）}"
DUR="${DUR:-120s}"

case "$TARGET_SVC" in
  *://*) BASE="$TARGET_SVC"; MODE="public-arrival" ;;
  *)
    IP=$(kubectl -n $NS get svc "$TARGET_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [ -n "$IP" ] || { echo "  [XX] 取不到 svc/$TARGET_SVC"; exit 2; }
    BASE="http://$IP"; MODE="clusterip-arrival" ;;
esac
echo "=== target=$TARGET_SVC ($MODE)  总目标=${TOTAL} rps  shards=$SHARDS  dur=$DUR"

REPL_BEFORE=""
if [ -n "${REQ_REPLICAS:-}" ]; then
  D=perf-new-api-slave
  [ "$MODE" = "clusterip-arrival" ] && D="$TARGET_SVC"
  REPL_BEFORE=$(kubectl -n $NS get deploy "$D" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "=== 目标副本数=$REQ_REPLICAS（压测前 ready=${REPL_BEFORE:-?}）"
  kubectl -n $NS scale deploy "$D" --replicas="$REQ_REPLICAS" 2>&1 | sed 's/^/  /'
  kubectl -n $NS rollout status deploy/"$D" --timeout=240s 2>&1 | sed 's/^/  /'
fi
REPL=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
echo "=== 生效：mode=$MODE replicas=${REPL:-auto}"

kubectl -n $NS get configmap "$CM" >/dev/null 2>&1 || { echo "  [XX] 缺少脚本 ConfigMap：$CM"; exit 2; }

for i in $(seq 0 $((SHARDS - 1))); do
  kubectl -n $NS delete job "k6-arr-$i" --ignore-not-found >/dev/null 2>&1
done

BASE_RATE=$((TOTAL / SHARDS)); REM=$((TOTAL % SHARDS))
echo "=== 下发分片 Job（基础 rate=${BASE_RATE}/s，前 ${REM} 片各 +1）"
for i in $(seq 0 $((SHARDS - 1))); do
  R=$BASE_RATE
  [ "$i" -lt "$REM" ] && R=$((R + 1))
  # 单请求耗时 ≈2.0s（mock 1.8s + 开销）⇒ 需要 rate×2.05 个并发；池子按 3 倍留余量，
  # 否则 k6 会在运行中临时扩容 VU，扩容窗口里的迭代会被计成 dropped（实测 48/分片）。
  PRE=$((R * 3)); MAX=$((R * 5))
  kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: k6-arr-$i, namespace: $NS, labels: {app: k6, purpose: perf, arrival: "$i"}}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 7200
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:0.54.0
          imagePullPolicy: IfNotPresent
          args: ["run", "/scripts/sse.js"]
          env:
            - {name: RATE, value: "$R"}
            - {name: DUR, value: "$DUR"}
            - {name: BASE, value: "$BASE"}
            - {name: SHARD, value: "$i"}
            - {name: PRE_VUS, value: "$PRE"}
            - {name: MAX_VUS, value: "$MAX"}
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
  echo "  shard-$i -> ${R} rps（preAllocated=${PRE} max=${MAX}）"
done

MOCK_BEFORE=$(mock_fingerprint "$NS")
sampler_start perf-new-api-slave

echo "=== 等待所有分片"
DONE=0
for round in $(seq 1 90); do
  DONE=1
  for i in $(seq 0 $((SHARDS - 1))); do
    S=$(kubectl -n $NS get job "k6-arr-$i" -o jsonpath='{.status.succeeded}' 2>/dev/null)
    F=$(kubectl -n $NS get job "k6-arr-$i" -o jsonpath='{.status.failed}' 2>/dev/null)
    [ "$S" = "1" ] || { [ -n "$F" ] && [ "$F" != "0" ]; } || { DONE=0; break; }
  done
  [ "$DONE" = "1" ] && break
  sleep 10
done
sampler_stop
MOCK_AFTER=$(mock_fingerprint "$NS")
if [ "$MOCK_BEFORE" = "$MOCK_AFTER" ]; then MOCK_CFG="$MOCK_AFTER"; else MOCK_CFG="changed"; fi
CP="$CPU_PEAK_M"; MP="$MEM_PEAK_MI"
IMG=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{","}{end}' 2>/dev/null | tr ',' '\n' | grep -E "perf-new-api|mock-upstream" | sed '/^$/d' | sort | tr '\n' ';')

echo "  all_done=$DONE cpu_peak_sum=${CP:-?}m cpu_peak_pod=${CPU_MAX_POD_M:-?}m mem_peak_sum=${MP:-?}Mi pods=${PODS_PEAK:-?} samples=${SAMPLE_ROWS:-?}"
echo "===RUN_META==="
echo "target=$TARGET_SVC x${REPL}"
echo "base=$BASE"
echo "mode=$MODE"
echo "vus=0"
echo "rate=$TOTAL"
echo "dur=$DUR"
echo "cpu_peak_m=${CP:-0}"
echo "cpu_max_pod_m=${CPU_MAX_POD_M:-0}"
echo "mem_peak_mi=${MP:-0}"
echo "mem_max_pod_mi=${MEM_MAX_POD_MI:-0}"
echo "pods_peak=${PODS_PEAK:-0}"
echo "sample_rows=${SAMPLE_ROWS:-0}"
TOKEN_MODE=$(kubectl -n $NS get secret perf-load-test-credentials -o jsonpath='{.data.tokens}' 2>/dev/null)
[ -n "$TOKEN_MODE" ] && TOKEN_MODE=multi || TOKEN_MODE=single
echo "token_mode=$TOKEN_MODE"
echo "method=constant-arrival-rate"
echo "load_config=k6-0.54.0:${SCRIPT_ID}:const-arrival-rate:model=${MODEL:-mock-gpt}:shards=${SHARDS}"
echo "mock_config=${MOCK_CFG}"
echo "replicas_before=${REPL_BEFORE:-}"
echo "replicas=${REPL:-1}"
echo "job=k6-arr-0..$((SHARDS - 1))"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images=$IMG"
echo "summary_schema=2"
echo "shards=$SHARDS"
EXIT_CODES=""
for i in $(seq 0 $((SHARDS - 1))); do
  CODE=$(kubectl -n "$NS" get pods -l job-name="k6-arr-$i" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')
  EXIT_CODES+="${EXIT_CODES:+,}${CODE:-unknown}"
done
echo "k6_exit_codes=$EXIT_CODES"
echo "===END_META==="

for i in $(seq 0 $((SHARDS - 1))); do
  echo "----- shard-$i"
  kubectl -n $NS logs "job/k6-arr-$i" 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|\{ type:sse \}|checks|sse_complete|dropped_iterations|vus_max|✗"
done
sampler_dump
