# bodies/summary.sh —— 打印 k6 Job 摘要（JOBS 为空=最近 3 个 job）
# 依赖 header 注入：JOBS（空格分隔的 job 名，可为空）
NS=new-api-perf

if [ -n "${JOBS:-}" ]; then
  LIST="$JOBS"
else
  LIST=$(kubectl -n $NS get job -l app=k6 --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | tail -3)
fi
[ -n "$LIST" ] || { echo "  （没有 k6 Job）"; exit 0; }

for J in $LIST; do
  echo "===== $J"
  kubectl -n $NS get job $J -o jsonpath='  status: succeeded={.status.succeeded} failed={.status.failed} start={.status.startTime}{"\n"}' 2>&1
  kubectl -n $NS logs job/$J 2>&1 | grep -E "http_reqs|http_req_failed|http_req_waiting|\{ type:sse \}|checks|iterations\.\.\.|✗" | head -8
done
