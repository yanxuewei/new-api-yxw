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
REPL_BEFORE=""
if [ -n "${REQ_REPLICAS:-}" ] && [ "$MODE" = "clusterip" ]; then
  REPL_BEFORE=$(kubectl -n $NS get deploy "$TARGET_SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  echo "=== 目标副本数=$REQ_REPLICAS（压测前 ready=${REPL_BEFORE:-?}），先 scale deploy/$TARGET_SVC"
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

# 资源采样：逐 Pod 记录时间序列（header 中的 sampler_*），结束后按同一时刻汇总。
# 公网入口 perf.likha.hk 当前只路由到 svc/perf-new-api-slave；内网模式按目标 Service 采样。
if [ "$MODE" = "public-url" ]; then LABELS="perf-new-api-slave"; else LABELS="$TARGET_SVC"; fi
MOCK_BEFORE=$(mock_fingerprint "$NS")
sampler_start "$LABELS"
for i in $(seq 1 90); do
  S=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.succeeded}' 2>/dev/null)
  JFAIL=$(kubectl -n $NS get job $JOB -o jsonpath='{.status.failed}' 2>/dev/null)
  [ "$S" = "1" ] && break
  [ -n "$JFAIL" ] && [ "$JFAIL" != "0" ] && { echo "  [!!] k6 job failed（阈值破线，k6 退出码非 0）⇒ 仍采集结果"; break; }
  sleep 10
done
sampler_stop
MOCK_AFTER=$(mock_fingerprint "$NS")
# mock 配置中途变化时不得按同一条件比较不同档位
if [ "$MOCK_BEFORE" = "$MOCK_AFTER" ]; then MOCK_CFG="$MOCK_AFTER"; else MOCK_CFG="changed"; fi
CPUM="$CPU_PEAK_M"
MEMM="$MEM_PEAK_MI"
REPL=$(kubectl -n $NS get deploy "$TARGET_SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$REPL" ] && [ "$REPL" != "0" ] || REPL=$(kubectl -n $NS get deploy perf-new-api-slave -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ -n "$REPL" ] || REPL=$(echo $LABELS | wc -w)
# 实际副本数 >1 时口径必须是 clusterip-dual，否则报告会把多副本档混进单副本容量曲线
case "$REPL" in ''|*[!0-9]*) : ;; *) [ "$REPL" -gt 1 ] && [ "$MODE" = "clusterip" ] && MODE="clusterip-dual" ;; esac
IMG=$(kubectl -n $NS get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{","}{end}' 2>/dev/null | tr ',' '\n' | grep -E "perf-new-api|mock-upstream" | sed '/^$/d' | sort | tr '\n' ';')
echo "--- job_succeeded=${S:-?} cpu_peak_sum=${CPUM:-?}m cpu_peak_pod=${CPU_MAX_POD_M:-?}m mem_peak_sum=${MEMM:-?}Mi pods=${PODS_PEAK:-?} samples=${SAMPLE_ROWS:-?}"
echo "===RUN_META==="
echo "target=$TARGET_SVC"
echo "base=$BASE"
echo "mode=$MODE"
echo "vus=$VUS"
echo "dur=$DUR"
echo "cpu_peak_m=${CPUM:-0}"
echo "cpu_max_pod_m=${CPU_MAX_POD_M:-0}"
echo "mem_peak_mi=${MEMM:-0}"
echo "mem_max_pod_mi=${MEM_MAX_POD_MI:-0}"
echo "pods_peak=${PODS_PEAK:-0}"
echo "sample_rows=${SAMPLE_ROWS:-0}"
echo "load_config=k6-0.54.0:${SCRIPT_ID}:const-vus:model=${MODEL:-mock-gpt}"
echo "mock_config=${MOCK_CFG}"
echo "replicas_before=${REPL_BEFORE:-}"
echo "replicas=$REPL"
echo "job=$JOB"
echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "images=$IMG"
echo "summary_schema=2"
echo "shards=1"
echo "k6_exit_codes=$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="k6")]}{.state.terminated.exitCode}{","}{end}' 2>/dev/null | sed 's/,$//')"
echo "===END_META==="
kubectl -n $NS logs job/$JOB 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|\{ type:sse \}|checks|sse_complete|iterations\.\.\.|data_received|vus_max|http_req_duration|http_req_connecting|http_req_tls_handshaking|http_req_sending|http_req_receiving|✗"
sampler_dump
