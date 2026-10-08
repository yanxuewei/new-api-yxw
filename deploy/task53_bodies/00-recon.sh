#!/usr/bin/env bash
# 任务 53 · 前置侦察（只读）：两地副本的同步参数实况 + 同步循环日志证据
# 纪律：REDIS_CONN_STRING 只报 set/unset 与长度，绝不回显值；CM 只取白名单键
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
NS=new-api

echo "== HOST $(hostname) | UTC $(date -u '+%F %T') | local $(date '+%F %T %Z') =="

echo "-- deployments --"
kubectl -n "$NS" get deploy -o wide --no-headers 2>/dev/null | awk '{print "  deploy="$1" desired/ready="$2" age="$5}'

echo "-- pods (app=new-api) --"
kubectl -n "$NS" get pods -l app=new-api -o wide --no-headers 2>/dev/null | \
  awk '{print "  pod="$1" ready="$2" restarts="$3" node="$7" ip="$6}'

PODS="$(kubectl -n "$NS" get pods -l app=new-api -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' 2>/dev/null)"
if [ -z "$PODS" ]; then echo "  (无 app=new-api Pod)"; exit 0; fi

echo "-- ConfigMap 白名单键 --"
kubectl -n "$NS" get cm new-api-config -o json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin).get("data", {})
for k in sorted(d):
    if k in ("SYNC_FREQUENCY","MEMORY_CACHE_ENABLED","NODE_TYPE","TZ","SESSION_MAX_AGE",
             "SQL_MAX_OPEN_CONNS","SQL_MAX_IDLE_CONNS","LOG_SQL_MAX_OPEN_CONNS","BATCH_UPDATE_ENABLED"):
        print("  cm.%s=%s" % (k, d[k]))
print("  cm key count = %d" % len(d))
' || echo "  (无 new-api-config)"

echo "-- Secret 键名（只取键，不取值） --"
kubectl -n "$NS" get secret new-api-secrets -o json 2>/dev/null | python3 -c '
import sys, json
print("  secret keys:", sorted(json.load(sys.stdin).get("data", {})))
' || echo "  (无 new-api-secrets)"

while read -r p ip; do
  [ -n "$p" ] || continue
  echo "=== POD $p ($ip) ==="
  kubectl -n "$NS" get "$p" -o json 2>/dev/null | python3 -c '
import sys, json
o = json.load(sys.stdin)
spec, st = o["spec"], o.get("status", {})
c = spec["containers"][0]
print("  image      =", c["image"])
print("  startedAt  =", st.get("startTime"))
print("  nodeName   =", spec.get("nodeName"))
print("  owner      =", [r.get("name") for r in (o.get("metadata", {}).get("ownerReferences") or [])])
'
  echo "  -- 容器内环境变量（Redis 只报长度） --"
  kubectl -n "$NS" exec "$p" -- sh -c '
    echo "  env: SYNC_FREQUENCY=[$SYNC_FREQUENCY] MEMORY_CACHE_ENABLED=[$MEMORY_CACHE_ENABLED] NODE_TYPE=[$NODE_TYPE] TZ=[$TZ]"
    if [ -n "${REDIS_CONN_STRING:-}" ]; then echo "  env: REDIS_CONN_STRING=set len=${#REDIS_CONN_STRING}"; else echo "  env: REDIS_CONN_STRING=unset"; fi
  ' 2>/dev/null || echo "  exec 失败"
  echo "  -- 节点侧 curl /api/status（按 JSON 取字段，避免逗号截断） --"
  curl -s --max-time 6 "http://$ip:3000/api/status" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("    解析失败:", e); raise SystemExit
for k in ("version","start_time","system_name","server_address","footer_html"):
    v = str(d.get(k))
    print("    %s=%s%s" % (k, v[:60], "…" if len(v) > 60 else ""))
' 2>/dev/null || echo "    curl 失败"
  echo "  -- 同步日志（自启动以来关键行，尾部 14 条） --"
  kubectl -n "$NS" logs "$p" --tail=4000 2>/dev/null | \
    grep -E "Redis is enabled|REDIS_CONN_STRING not set|memory cache enabled|sync frequency|syncing options from database|syncing channels from database" | \
    tail -14 | sed 's/^/    /'
  echo "  -- 循环节拍（本窗口内每次同步的时间戳） --"
  kubectl -n "$NS" logs "$p" --tail=4000 2>/dev/null | \
    awk '/syncing options from database/{print "OPT "$2" "$4} /syncing channels from database/{print "CHN "$2" "$4}' | tail -8 | sed 's/^/    /'
done <<< "$PODS"

echo "== DONE =="
