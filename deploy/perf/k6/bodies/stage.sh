# bodies/stage.sh —— 单副本阶梯：对 TARGET_SVC 起一个 k6 Job（VUS 恒定 × DUR），采 CPU/内存峰值并打印摘要
# 依赖 header 注入：K6JS_B64 / TARGET_SVC / VUS / DUR
# 输出约定：末尾先打 ===RUN_META=== 块（KEY=VALUE，供 report.py 解析），再打 k6 摘要原文
NS=new-api-perf
CM=k6-sse
JOB="k6-stage-${VUS}"

# TARGET_SVC：Service 名（集群内直连 ClusterIP）或完整 URL（走公网 ALB 路径）
case "$TARGET_SVC" in
  *://*) BASE="$TARGET_SVC"; MODE="public-url" ;;
  *)
    IP=$(kubectl -n $NS get svc "$TARGET_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [ -n "$IP" ] || { echo "  [XX] 取不到 svc/$TARGET_SVC"; exit 2; }
    BASE="http://$IP"; MODE="clusterip" ;;
esac
echo "=== target=$TARGET_SVC ($MODE, BASE=$BASE)  vus=$VUS dur=$DUR"

# 可选：REQ_REPLICAS 指定本次压测的副本数。起 Job 前先 scale 到该值并等就绪，
# 保证同一阶梯内副本口径固定（HPA/人工改动不会混进同一档）。
if [ -n "${REQ_REPLICAS:-}" ] && [ "$MODE" = "clusterip" ]; then
  echo "=== 目标副本数=$REQ_REPLICAS，先 scale deploy/$TARGET_SVC"
  kubectl -n $NS scale deploy "$TARGET_SVC" --replicas="$REQ_REPLICAS" 2>&1 | sed 's/^/  /'
  kubectl -n $NS rollout status deploy/"$TARGET_SVC" --timeout=240s 2>&1 | sed 's/^/  /'
  READY=$(kubectl -n $NS get deploy "$TARGET_SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "  ready=${READY:-0}/$REQ_REPLICAS"
  [ "${READY:-0}" -ge "$REQ_REPLICAS" ] || { echo "  [XX] 副本未就绪，终止本档"; exit 2; }
  [ "$REQ_REPLICAS" -gt 1 ] && MODE="clusterip-dual"
fi
echo "=== 生效：mode=$MODE replicas=${REQ_REPLICAS:-auto}"

echo "$K6JS_GZ" | base64 -d | gzip -d > /tmp/sse.js
kubectl -n $NS create configmap $CM --from-file=sse.js=/tmp/sse.js --dry-run=client -o yaml | kubectl apply -f - >/dev/null
rm -f /tmp/sse.js

kubectl -n $NS delete job "$JOB" --ignore-not-found >/dev/null 2>&1
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
            - {name: BASE, value: "$BASE"}
            - name: TOKEN
              valueFrom: {secretKeyRef: {name: perf-load-test-credentials, key: token_key}}
          volumeMounts: [{name: scripts, mountPath: /scripts}]
          resources: {requests: {cpu: 500m, memory: 256Mi}, limits: {cpu: "2", memory: 1Gi}}
      volumes:
        - name: scripts
          configMap: {name: $CM}
YAML

# CPU/内存峰值采样（每 5s；Job 结束即停）。URL 模式会经两个副本 ⇒ 逐副本取各自峰值
# 公网入口 perf.likha.hk 当前只路由到 svc/perf-new-api-slave（1 副本）；内网模式按目标 Service 采样
if [ "$MODE" = "public-url" ]; then LABELS="perf-new-api-slave"; else LABELS="$TARGET_SVC"; fi
: > /tmp/cpu_${VUS}.txt; : > /tmp/mem_${VUS}.txt
( for i in $(seq 1 120); do
    for L in $LABELS; do
      LINE=$(kubectl -n $NS top pod -l app=$L --no-headers 2>/dev/null | head -1)
      C=$(printf '%s' "$LINE" | awk '{gsub(/m/,"",$2); print $2+0}')
      M=$(printf '%s' "$LINE" | awk '{gsub(/Mi/,"",$3); print $3+0}')
      [ -n "$C" ] && [ "$C" -gt 0 ] && echo "$C" >> /tmp/cpu_${VUS}.txt
      [ -n "$M" ] && [ "$M" -gt 0 ] && echo "$M" >> /tmp/mem_${VUS}.txt
    done
    sleep 5
  done ) &
SAMPLER=$!
for i in $(seq 1 90); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  JFAIL=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$S" = "1" ] && break
  [ -n "$JFAIL" ] && [ "$JFAIL" != "0" ] && { echo "  [!!] k6 job failed（阈值破线，k6 退出码非 0）⇒ 仍采集结果"; break; }
  sleep 10
done
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
CPUM=$(sort -n /tmp/cpu_${VUS}.txt 2>/dev/null | tail -1)
MEMM=$(sort -n /tmp/mem_${VUS}.txt 2>/dev/null | tail -1)
REPL=$(kubectl -n $NS get deploy "$TARGET_SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$REPL" ] && [ "$REPL" != "0" ] || REPL=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$REPL" ] || REPL=$(echo $LABELS | wc -w)
# 实际副本数 >1 时口径必须是 clusterip-dual，否则报告会把多副本档混进单副本容量曲线
case "$REPL" in ''|*[!0-9]*) : ;; *) [ "$REPL" -gt 1 ] && [ "$MODE" = "clusterip" ] && MODE="clusterip-dual" ;; esac
IMG=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{","}{end}' 2>/dev/null | tr ',' '\n' | grep -E "perf-new-api" | head -2 | tr '\n' ';')
echo "--- job_succeeded=${S:-?} cpu_peak=${CPUM:-?}m mem_peak=${MEMM:-?}Mi"
echo "===RUN_META==="
echo "target=$TARGET_SVC"
echo "base=$BASE"
echo "mode=$MODE"
echo "vus=$VUS"
echo "dur=$DUR"
echo "cpu_peak_m=${CPUM:-0}"
echo "mem_peak_mi=${MEMM:-0}"
echo "replicas=$REPL"
echo "job=$JOB"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images=$IMG"
echo "===END_META==="
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|\{ type:sse \}|checks|iterations\.\.\.|data_received|vus_max|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|✗" | head -24
rm -f /tmp/cpu_${VUS}.txt /tmp/mem_${VUS}.txt
