# bodies/sharded.sh —— 多 Job 分片并行压同一个 Service（单客户端进程不够用时使用）
# 依赖 header 注入：K6JS_GZ / VUS（总并发）/ DUR / SHARDS（分片数）
#
# 设计：
#   - 每个分片是一个独立 Job（独立进程、独立连接池），VU 按总并发均分；
#   - 所有分片打同一个 ClusterIP ⇒ kube-proxy 仍按连接分摊到后端副本；
#   - 分片 tag 通过 env SHARD 注入脚本（tags={{type:'sse',shard:'i'}}），便于按分片看指标；
#   - 结束后把各分片摘要拼接输出，report.py 会按"一个日志多条摘要"聚合（RPS 求和、延迟取差）。
NS=new-api-perf
CM=k6-sse
SHARDS="${SHARDS:-4}"
TOTAL="${VUS:-1500}"
DUR="${DUR:-120s}"

[ "$SHARDS" -ge 1 ] || { echo "  [XX] SHARDS 必须 ≥1"; exit 2; }
IP=$(kubectl -n $NS get svc perf-new-api-slave -o jsonpath='{.spec.clusterIP}')
[ -n "$IP" ] || { echo "  [XX] 取不到 svc/perf-new-api-slave"; exit 2; }
REPL=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}')
echo "=== 分片压测：total=$TOTAL VU  shards=$SHARDS  dur=$DUR  base=http://$IP  后端副本=$REPL"

echo "$K6JS_GZ" | base64 -d | gzip -d > /tmp/sse.js
kubectl -n $NS create configmap $CM --from-file=sse.js=/tmp/sse.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/sse.js

# 清理旧分片 Job
for i in $(seq 0 $((SHARDS - 1))); do kubectl -n $NS delete job k6-shard-$i --ignore-not-found >/dev/null 2>&1; done

BASE_VU=$((TOTAL / SHARDS))
REM=$((TOTAL % SHARDS))
echo "=== 下发分片 Job"
for i in $(seq 0 $((SHARDS - 1))); do
  V=$BASE_VU
  [ "$i" -lt "$REM" ] && V=$((V + 1))
  kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: k6-shard-$i, namespace: $NS, labels: {app: k6, purpose: perf, shard: "$i"}}
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
            - {name: VUS, value: "$V"}
            - {name: DUR, value: "$DUR"}
            - {name: BASE, value: "http://$IP"}
            - {name: SHARD, value: "$i"}
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes: [{name: scripts, configMap: {name: $CM}}]
YAML
  echo "  shard-$i -> $V VU"
done

# 资源采样：逐 Pod 时间序列，结束后按同刻汇总（header 中的 sampler_*）
MOCK_BEFORE=$(mock_fingerprint "$NS")
sampler_start perf-new-api-slave

echo "=== 等待所有分片"
DONE=0
for round in $(seq 1 90); do
  DONE=1
  for i in $(seq 0 $((SHARDS - 1))); do
    S=$(kubectl -n $NS get job k6-shard-$i -o jsonpath='{.status.succeeded}' 2>/dev/null)
    F=$(kubectl -n $NS get job k6-shard-$i -o jsonpath='{.status.failed}' 2>/dev/null)
    [ "$S" = "1" ] || { [ -n "$F" ] && [ "$F" != "0" ]; } || { DONE=0; break; }
  done
  [ "$DONE" = "1" ] && break
  sleep 10
done
sampler_stop
MOCK_AFTER=$(mock_fingerprint "$NS")
if [ "$MOCK_BEFORE" = "$MOCK_AFTER" ]; then MOCK_CFG="$MOCK_AFTER"; else MOCK_CFG="changed"; fi
CP="$CPU_PEAK_M"
MP="$MEM_PEAK_MI"
IMG=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{","}{end}' 2>/dev/null | tr ',' '\n' | grep -E "perf-new-api|mock-upstream" | sed '/^$/d' | sort | tr '\n' ';')

echo "  all_done=$DONE cpu_peak_sum=${CP:-?}m cpu_peak_pod=${CPU_MAX_POD_M:-?}m mem_peak_sum=${MP:-?}Mi pods=${PODS_PEAK:-?} samples=${SAMPLE_ROWS:-?}"
echo "===RUN_META==="
echo "target=perf-new-api-slave x${REPL}"
echo "base=http://$IP"
echo "mode=clusterip-shard"
echo "vus=$TOTAL"
echo "dur=$DUR"
echo "cpu_peak_m=${CP:-0}"
echo "cpu_max_pod_m=${CPU_MAX_POD_M:-0}"
echo "mem_peak_mi=${MP:-0}"
echo "mem_max_pod_mi=${MEM_MAX_POD_MI:-0}"
echo "pods_peak=${PODS_PEAK:-0}"
echo "sample_rows=${SAMPLE_ROWS:-0}"
echo "load_config=k6-0.54.0:${SCRIPT_ID}:const-vus:model=${MODEL:-mock-gpt}:shards=${SHARDS}"
echo "mock_config=${MOCK_CFG}"
echo "replicas=${REPL:-1}"
echo "job=k6-shard-0..$((SHARDS - 1))"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images=$IMG"
echo "summary_schema=2"
echo "shards=$SHARDS"
EXIT_CODES=""
for i in $(seq 0 $((SHARDS - 1))); do
  CODE=$(kubectl -n "$NS" get pods -l job-name="k6-shard-$i" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')
  EXIT_CODES+="${EXIT_CODES:+,}${CODE:-unknown}"
done
echo "k6_exit_codes=$EXIT_CODES"
echo "===END_META==="

for i in $(seq 0 $((SHARDS - 1))); do
  echo "----- shard-$i"
  kubectl -n $NS logs job/k6-shard-$i 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|\{ type:sse \}|checks|sse_complete|vus_max|✗"
done
sampler_dump
