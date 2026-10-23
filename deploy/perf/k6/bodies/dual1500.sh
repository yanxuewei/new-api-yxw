# bodies/dual1500.sh —— 双副本 1500 并发：把 perf-new-api-slave 扩到 2 副本，单 Job 打该 Service
# 依赖 header 注入：K6JS_B64 / VUS（总并发，如 1500）/ DUR
# 设计说明：
#   - 不使用 perf-new-api-master（负责人 2026-10-20 裁定：双副本只扩 slave）
#   - 一个 Job 打 Service，kube-proxy 天然按连接分摊到 2 个 Pod ⇒ 与线上多副本入口形态一致
NS=new-api-perf
CM=k6-sse
JOB=k6-1500
REPL_WANT=2

echo "$K6JS_GZ" | base64 -d | gzip -d > /tmp/sse.js
kubectl -n $NS create configmap $CM --from-file=sse.js=/tmp/sse.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/sse.js

echo "=== 扩 perf-new-api-slave 到 $REPL_WANT 副本"
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
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes:
        - name: scripts
          configMap: {name: $CM}
YAML

echo "=== 等 Job 完成（并行采样 CPU/内存峰值）"
: > /tmp/cpu_1500.txt; : > /tmp/mem_1500.txt
( for i in $(seq 1 120); do
    for L in perf-new-api-slave; do
      kubectl -n $NS top pod -l app=$L --no-headers 2>/dev/null | while read -r NAME C M REST; do
        c=${C%m}; m=${M%Mi}
        [ -n "$c" ] && [ "$c" -gt 0 ] && echo "$c" >> /tmp/cpu_1500.txt
        [ -n "$m" ] && [ "$m" -gt 0 ] && echo "$m" >> /tmp/mem_1500.txt
      done
    done
    sleep 5
  done ) &
SAMPLER=$!
for i in $(seq 1 90); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  F=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$S" = "1" ] && break
  [ -n "$F" ] && [ "$F" != "0" ] && { echo "  [!!] k6 job failed（阈值破线）⇒ 仍采集结果"; break; }
  sleep 10
done
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
CPUM=$(sort -n /tmp/cpu_1500.txt 2>/dev/null | tail -1)
MEMM=$(sort -n /tmp/mem_1500.txt 2>/dev/null | tail -1)
echo "  job_succeeded=${S:-?} failed=${F:-0} cpu_peak=${CPUM:-?}m mem_peak=${MEMM:-?}Mi"
echo "===RUN_META==="
echo "target=perf-new-api-slave x$REPL_WANT"
echo "base=http://$IP"
echo "mode=clusterip-dual"
echo "vus=$VUS"
echo "dur=$DUR"
echo "cpu_peak_m=${CPUM:-0}"
echo "mem_peak_mi=${MEMM:-0}"
echo "replicas=$REPL_WANT"
echo "job=$JOB"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images="
echo "summary_schema=2"
echo "shards=1"
echo "k6_exit_codes=$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')"
echo "===END_META==="
rm -f /tmp/cpu_1500.txt /tmp/mem_1500.txt
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|\{ type:sse \}|checks|sse_complete|vus_max|✗"
