# lib/sampling.sh —— 节点侧共享能力：逐 Pod 资源采样与 mock 状态快照/恢复
# 由 run.sh 压缩后随每个动作投递，body 里直接调用这些函数。

SAMPLER_TSV=""

# 逐 Pod 记录时间序列：时刻 / Pod / CPU / 内存
sampler_start() {
  local label="$1"
  SAMPLER_TSV="/tmp/perf_samples.$$.tsv"
  : > "$SAMPLER_TSV"
  (
    while :; do
      ts=$(date -u +%H:%M:%S)
      kubectl -n "${SAMPLER_NS:-new-api-perf}" top pod -l "app=$label" --no-headers 2>/dev/null \
        | awk -v ts="$ts" 'NF>=3 {print ts "\t" $1 "\t" $2 "\t" $3}' >> "$SAMPLER_TSV"
      sleep "${SAMPLER_INTERVAL:-5}"
    done
  ) >/dev/null 2>&1 &
  SAMPLER_PID=$!
}

# 按同一时刻去重后汇总：既保留单 Pod 峰值，也得到全副本同刻合计
sampler_stop() {
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
  [ -n "${SAMPLER_PID:-}" ] && wait "$SAMPLER_PID" 2>/dev/null
  SAMPLE_ROWS=0; PODS_PEAK=0; CPU_PEAK_M=0; MEM_PEAK_MI=0; CPU_MAX_POD_M=0; MEM_MAX_POD_MI=0
  [ -n "$SAMPLER_TSV" ] && [ -f "$SAMPLER_TSV" ] || return 0
  SAMPLE_ROWS=$(wc -l < "$SAMPLER_TSV" | tr -d ' ')
  CPU_PEAK_M=$(awk -F'\t' '{v[$1 SUBSEP $2]=($3 ~ /m$/)?$3+0:($3+0)*1000} END{for(k in v){split(k,a,SUBSEP); s[a[1]]+=v[k]} m=0; for(t in s) if(s[t]>m) m=s[t]; printf "%.0f", m+0}' "$SAMPLER_TSV")
  MEM_PEAK_MI=$(awk -F'\t' '{v[$1 SUBSEP $2]=($4 ~ /Gi$/)?($4+0)*1024:$4+0} END{for(k in v){split(k,a,SUBSEP); s[a[1]]+=v[k]} m=0; for(t in s) if(s[t]>m) m=s[t]; printf "%.0f", m+0}' "$SAMPLER_TSV")
  CPU_MAX_POD_M=$(awk -F'\t' '{c=($3 ~ /m$/)?$3+0:($3+0)*1000; if(c>m) m=c} END{printf "%.0f", m+0}' "$SAMPLER_TSV")
  MEM_MAX_POD_MI=$(awk -F'\t' '{m=($4 ~ /Gi$/)?($4+0)*1024:$4+0; if(m>p) p=m} END{printf "%.0f", p+0}' "$SAMPLER_TSV")
  PODS_PEAK=$(awk -F'\t' '{seen[$1 SUBSEP $2]=1} END{for(k in seen){split(k,a,SUBSEP); c[a[1]]++} m=0; for(t in c) if(c[t]>m) m=c[t]; print m+0}' "$SAMPLER_TSV")
}

# 输出原始采样序列供 run.sh 落盘为 .samples.tsv
sampler_dump() {
  [ -n "$SAMPLER_TSV" ] && [ -f "$SAMPLER_TSV" ] || return 0
  echo "===SAMPLES==="
  cat "$SAMPLER_TSV"
  rm -f "$SAMPLER_TSV"
}

mock_pods() {
  kubectl -n "$1" get pod -l app=mock-upstream -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null
}

mock_state_json() {
  local ns="$1" ip out
  for ip in $(mock_pods "$ns"); do
    out=$(curl -sS -m 3 "http://$ip:8080/__state" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  done
  return 1
}

mock_apply() {
  local ns="$1" json="$2" ip
  for ip in $(mock_pods "$ns"); do
    curl -sS -m 5 -X POST -H 'Content-Type: application/json' -d "$json" "http://$ip:8080/__ctrl" >/dev/null 2>&1
  done
}

# 各副本配置一致才返回可比较的指纹；否则 unavailable / mixed
mock_fingerprint() {
  local ns="$1" ip out first="" mixed=0 n=0
  for ip in $(mock_pods "$ns"); do
    out=$(curl -sS -m 3 "http://$ip:8080/__state" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
keys = ("first_token_delay_ms", "token_interval_ms", "tokens_per_response",
        "token_text_bytes", "error_rate", "error_status", "extra_latency_ms")
print(",".join("%s=%s" % (k, d.get(k)) for k in keys))
' 2>/dev/null) || continue
    n=$((n + 1))
    [ -z "$first" ] && first="$out"
    [ "$out" != "$first" ] && mixed=1
  done
  if [ "$n" -eq 0 ]; then echo unavailable
  elif [ "$mixed" = 1 ]; then echo mixed
  else printf '%s' "$first"; fi
}
