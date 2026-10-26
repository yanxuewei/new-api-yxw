# bodies/dual1500.sh —— 双副本 1500 并发：把 perf-new-api-slave 扩到 2 副本，单 Job 打该 Service
# 依赖 header 注入：K6JS_B64 / VUS（总并发，如 1500）/ DUR
# 设计说明：
#   - 不使用 perf-new-api-master（负责人 2026-10-20 裁定：双副本只扩 slave）
#   - 一个 Job 打 Service，kube-proxy 天然按连接分摊到 2 个 Pod ⇒ 与线上多副本入口形态一致
NS=new-api-perf
CM="${K6JS_CM:?缺少 K6JS_CM（脚本 ConfigMap）}"
JOB=k6-1500
REPL_WANT=2

kubectl -n $NS get configmap "$CM" >/dev/null 2>&1 || { echo "  [XX] 缺少脚本 ConfigMap：$CM"; exit 2; }

REPL_BEFORE=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
echo "=== 扩 perf-new-api-slave 到 $REPL_WANT 副本（压测前 ready=${REPL_BEFORE:-?}）"
kubectl -n $NS scale deploy perf-new-api-slave --replicas=$REPL_WANT 2>&1 | sed 's/^/  /'
kubectl -n $NS rollout status deploy/perf-new-api-slave --timeout=180s 2>&1 | sed 's/^/  /'
READY=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}')
echo "  ready=$READY/$REPL_WANT"
[ "${READY:-0}" -ge "$REPL_WANT" ] || { echo "  [XX] 副本未就绪，终止"; exit 2; }

IP=$(kubectl -n $NS get svc perf-new-api-slave -o jsonpath='{.spec.clusterIP}')
echo "=== 起 k6 Job：VUS=$VUS DUR=$DUR -> $IP（2 副本）"
kubectl -n $NS delete job $JOB --ignore-not-found >/dev/null 2>&1
kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB, namespace: $NS, labels: {app: k6, purpose: perf}}
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
            - {name: VUS, value: "$VUS"}
            - {name: DUR, value: "$DUR"}
            - {name: BASE, value: "http://$IP"}
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
            - name: TOKENS
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: tokens, optional: true}}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes:
        - name: scripts
          configMap: {name: $CM}
YAML

echo "=== 等 Job 完成（并行逐 Pod 采样）"
MOCK_BEFORE=$(mock_fingerprint "$NS")
sampler_start perf-new-api-slave
for i in $(seq 1 90); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  F=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$S" = "1" ] && break
  [ -n "$F" ] && [ "$F" != "0" ] && { echo "  [!!] k6 job failed（阈值破线）⇒ 仍采集结果"; break; }
  sleep 10
done
sampler_stop
MOCK_AFTER=$(mock_fingerprint "$NS")
if [ "$MOCK_BEFORE" = "$MOCK_AFTER" ]; then MOCK_CFG="$MOCK_AFTER"; else MOCK_CFG="changed"; fi
CPUM="$CPU_PEAK_M"
MEMM="$MEM_PEAK_MI"
IMG=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{","}{end}' 2>/dev/null | tr ',' '\n' | grep -E "perf-new-api|mock-upstream" | sed '/^$/d' | sort | tr '\n' ';')
echo "  job_succeeded=${S:-?} failed=${F:-0} cpu_peak_sum=${CPUM:-?}m cpu_peak_pod=${CPU_MAX_POD_M:-?}m mem_peak_sum=${MEMM:-?}Mi pods=${PODS_PEAK:-?} samples=${SAMPLE_ROWS:-?}"
echo "===RUN_META==="
echo "target=perf-new-api-slave x$REPL_WANT"
echo "base=http://$IP"
echo "mode=clusterip-dual"
echo "vus=$VUS"
echo "dur=$DUR"
echo "cpu_peak_m=${CPUM:-0}"
echo "cpu_max_pod_m=${CPU_MAX_POD_M:-0}"
echo "mem_peak_mi=${MEMM:-0}"
echo "mem_max_pod_mi=${MEM_MAX_POD_MI:-0}"
echo "pods_peak=${PODS_PEAK:-0}"
echo "sample_rows=${SAMPLE_ROWS:-0}"
TOKEN_MODE=$(kubectl -n $NS get secret perf-load-test-credentials -o jsonpath='{.data.tokens}' 2>/dev/null)
[ -n "$TOKEN_MODE" ] && TOKEN_MODE=multi || TOKEN_MODE=single
echo "token_mode=$TOKEN_MODE"
echo "load_config=k6-0.54.0:${SCRIPT_ID}:const-vus:model=${MODEL:-mock-gpt}"
echo "mock_config=${MOCK_CFG}"
echo "replicas_before=${REPL_BEFORE:-}"
echo "replicas=$REPL_WANT"
echo "job=$JOB"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images=$IMG"
echo "summary_schema=2"
echo "shards=1"
echo "k6_exit_codes=$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')"
echo "===END_META==="
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|\{ type:sse \}|checks|sse_complete|vus_max|✗"
sampler_dump
