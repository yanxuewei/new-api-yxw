# bodies/stage.sh —— 单副本阶梯：对 TARGET_SVC 起一个 k6 Job（VUS 恒定 × DUR），采 CPU 峰值并打印摘要
# 依赖 header 注入：K6JS_B64 / TARGET_SVC / VUS / DUR
NS=new-api-perf
CM=k6-sse
JOB="k6-stage-${VUS}"

IP=$(kubectl -n $NS get svc "$TARGET_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ -n "$IP" ] || { echo "  [XX] 取不到 svc/$TARGET_SVC"; exit 2; }
echo "=== target=$TARGET_SVC ($IP)  vus=$VUS dur=$DUR"

echo "$K6JS_B64" | base64 -d > /tmp/sse.js
kubectl -n $NS create configmap $CM --from-file=sse.js=/tmp/sse.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/sse.js

kubectl -n $NS delete job "$JOB" --ignore-not-found >/dev/null 2>&1
kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: $JOB, namespace: $NS, labels: {app: k6, purpose: perf}}
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

# CPU 峰值采样（每 5s；Job 结束后停）
: > /tmp/cpu_${VUS}.txt
( for i in $(seq 1 120); do
    T=$(kubectl -n $NS top pod -l app=$TARGET_SVC --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); print $2+0}')
    [ -n "$T" ] && echo "$T" >> /tmp/cpu_${VUS}.txt
    sleep 5
  done ) &
SAMPLER=$!
for i in $(seq 1 90); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  [ "$S" = "1" ] && break
  sleep 10
done
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
PEAK=$(sort -n /tmp/cpu_${VUS}.txt 2>/dev/null | tail -1)
echo "--- job_succeeded=${S:-?} cpu_peak=${PEAK:-?}m"
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|\{ type:sse \}|checks|✗" | head -8
rm -f /tmp/cpu_${VUS}.txt
