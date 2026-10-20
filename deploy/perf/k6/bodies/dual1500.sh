# bodies/dual1500.sh —— 双副本并行：master/slave 各 VUS_EACH（默认 750）× DUR ⇒ 合计 1500 并发
# 依赖 header 注入：K6JS_B64 / VUS_EACH / DUR
NS=new-api-perf
CM=k6-sse

echo "$K6JS_B64" | base64 -d > /tmp/sse.js
kubectl -n $NS create configmap $CM --from-file=sse.js=/tmp/sse.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/sse.js

for pair in "perf-new-api-master:k6-1500-m" "perf-new-api-slave:k6-1500-s"; do
  SVC="${pair%%:*}"; JOB="${pair##*:}"
  IP=$(kubectl -n $NS get svc "$SVC" -o jsonpath='{.spec.clusterIP}')
  [ -n "$IP" ] || { echo "  [XX] 取不到 svc/$SVC"; exit 2; }
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
            - {name: VUS, value: "$VUS_EACH"}
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
  echo "  queued $JOB -> $SVC ($IP) x $VUS_EACH VU x $DUR"
done

echo "=== 等两个 Job 完成"
for i in $(seq 1 60); do
  A=$(kubectl -n $NS get job k6-1500-m -o jsonpath='{.status.succeeded}' 2>/dev/null)
  B=$(kubectl -n $NS get job k6-1500-s -o jsonpath='{.status.succeeded}' 2>/dev/null)
  [ "$A" = "1" ] && [ "$B" = "1" ] && break
  sleep 10
done
echo "  master_succeeded=${A:-running} slave_succeeded=${B:-running}"
for J in k6-1500-m k6-1500-s; do
  echo "===== $J"
  kubectl -n $NS logs job/$J 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|\{ type:sse \}|checks|✗" | head -6
done
echo "--- 两副本 CPU 现值（跑完瞬间，仅参考）"
kubectl -n $NS top pod -l app=perf-new-api-master --no-headers 2>/dev/null
kubectl -n $NS top pod -l app=perf-new-api-slave --no-headers 2>/dev/null
