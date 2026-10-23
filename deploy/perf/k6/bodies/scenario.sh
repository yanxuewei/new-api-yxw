# bodies/scenario.sh —— 场景执行器（burst/admin/degrade/rolling/long），单 Job 模板
# 依赖 header 注入：K6JS_GZ / MODE / VUS / DUR / RATE / BASE_URL
NS=new-api-perf; CM=k6-scenario; JOB="k6-$MODE"
ctl() { local J="$1" IP; for IP in $(kubectl -n $NS get pod -l app=mock-upstream -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}'); do curl -sS -m 5 -X POST -H 'Content-Type: application/json' -d "$J" "http://$IP:8080/__ctrl" >/dev/null 2>&1; done; }
NORMAL='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":50,"token_text_bytes":12,"error_rate":0,"error_status":500,"extra_latency_ms":0}'
S5='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":50,"token_text_bytes":12,"error_rate":0.5,"error_status":500,"extra_latency_ms":5000}'
LONG='{"first_token_delay_ms":300,"token_interval_ms":30,"tokens_per_response":24000,"token_text_bytes":12,"error_rate":0,"error_status":500,"extra_latency_ms":0}'

echo "$K6JS_GZ" | base64 -d | gzip -d > /tmp/scen.js
kubectl -n $NS create configmap $CM --from-file=scen.js=/tmp/scen.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/scen.js
IP=$(kubectl -n $NS get svc perf-new-api-slave -o jsonpath='{.spec.clusterIP}')
if [ "$MODE" = "long" ]; then BASE="${BASE_URL:-https://perf.likha.hk}"; TGT="$BASE"; else BASE="http://$IP"; TGT="perf-new-api-slave"; fi
echo "=== mode=$MODE base=$BASE vus=${VUS:-} dur=${DUR:-} rate=${RATE:-}"
[ "$MODE" = degrade ] && { echo "  mock -> S5"; ctl "$S5"; }
[ "$MODE" = long ] && { echo "  mock -> 长流(24000 token)"; ctl "$LONG"; }

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
          args: ["run", "/scripts/scen.js"]
          env:
            - {name: VUS, value: "${VUS:-1}"}
            - {name: DUR, value: "${DUR:-60s}"}
            - {name: RATE, value: "${RATE:-100}"}
            - {name: BASE, value: "$BASE"}
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
            - name: ADMIN_USER
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: admin_username}}
            - name: ADMIN_PASS
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: admin_password}}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes: [{name: scripts, configMap: {name: $CM}}]
YAML

[ "$MODE" = rolling ] && ( sleep 30; kubectl -n $NS rollout restart deploy/perf-new-api-slave >/dev/null 2>&1; echo "  [rolling] 已触发 rollout restart" ) &
: > /tmp/c_$MODE; : > /tmp/m_$MODE
( for i in $(seq 1 180); do
    kubectl -n $NS top pod -l app=perf-new-api-slave --no-headers 2>/dev/null | while read -r N C M REST; do
      c=${C%m}; m=${M%Mi}; [ -n "$c" ] && [ "$c" -gt 0 ] && echo "$c" >> /tmp/c_$MODE; [ -n "$m" ] && [ "$m" -gt 0 ] && echo "$m" >> /tmp/m_$MODE; done
    sleep 5; done ) &
SP=$!
for i in $(seq 1 80); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  F=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$S" = "1" ] && break
  [ -n "$F" ] && [ "$F" != "0" ] && { echo "  [!!] k6 job failed（阈值破线），仍采集"; break; }
  sleep 10
done
kill $SP 2>/dev/null; wait $SP 2>/dev/null
CP=$(sort -n /tmp/c_$MODE 2>/dev/null | tail -1); MP=$(sort -n /tmp/m_$MODE 2>/dev/null | tail -1)
[ "$MODE" = degrade ] && { echo "  mock -> normal"; ctl "$NORMAL"; }
[ "$MODE" = long ] && { echo "  mock -> normal"; ctl "$NORMAL"; }
echo "  job_succeeded=${S:-?} failed=${F:-0} cpu_peak=${CP:-?}m mem_peak=${MP:-?}Mi"
echo "===RUN_META==="
echo "target=$TGT"; echo "base=$BASE"; echo "mode=$MODE"; echo "vus=${VUS:-1}"; echo "dur=${DUR:-}"
echo "cpu_peak_m=${CP:-0}"; echo "mem_peak_mi=${MP:-0}"
echo "replicas=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 1)"
echo "job=$JOB"; echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "images="
echo "summary_schema=2"
echo "shards=1"
echo "k6_exit_codes=$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')"
echo "===END_META==="
rm -f /tmp/c_$MODE /tmp/m_$MODE
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|\{ type:|checks|sse_complete|dropped_iterations|vus_max|✗|data_received"
