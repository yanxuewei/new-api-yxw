#!/usr/bin/env bash
# =============================================================================
# 任务 53 追加取证（只读）：429 的来源归因 + 与 GlobalAPIRateLimit 预算对账
#
# 为什么要跨副本合并：限流键是 rateLimit:v2:ip:GA:<clientIP>（Redis 启用时全集群共享一个
#   计数器），预算 360 次/180 秒 是**按客户端 IP** 计的，而不是按 Pod。ALB 会把探测请求
#   轮询分发到各副本 ⇒ 单副本计数除以时间窗会严重低估该 IP 的真实速率。
#
# 不做的事：不 curl 业务端点（避免我自己再消耗配额）、不写 DB、不改任何对象。
#   只 kubectl logs 读已有访问行 + kubectl get 读注释里那份健康检查参数。
# =============================================================================
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"
NS=new-api
TMP=/tmp/t53-alb429-$$.txt
trap 'rm -f "$TMP"' EXIT

echo "== SITE=$SITE 429 跨副本归因 UTC=$(date -u '+%F %T') =="

# 1) Ingress 上的健康检查注释（ALB 探针的权威参数来源）
for ing in $(kubectl -n $NS get ingress --no-headers -o custom-columns=N:.metadata.name 2>/dev/null); do
  echo "--- INGRESS $ing ---"
  kubectl -n $NS get ingress "$ing" -o json 2>/dev/null | python3 -c '
import sys, json
o = json.load(sys.stdin)
a = (o.get("metadata") or {}).get("annotations") or {}
hc = {k: v for k, v in a.items() if "healthcheck" in k or "listen-ports" in k}
print("    ", json.dumps(hc, ensure_ascii=False) if hc else "(无 healthcheck / listen-ports 注释)")
print("     rules:", json.dumps([{ "host": r.get("host"), "paths": [p.get("path") for p in (r.get("http") or {}).get("paths", [])] } for r in (o.get("spec") or {}).get("rules", [])], ensure_ascii=False)[:220])
'
done

# 2) 汇总各副本访问行
PODS=$(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,P:.status.phase 2>/dev/null | awk '$2=="Running" && $1 ~ /^new-api-/{print $1}')
[ -n "$PODS" ] || { echo "  [XX] 无 Running 副本"; exit 1; }
: > "$TMP"
for p in $PODS; do
  kubectl -n $NS logs "$p" --tail=6000 2>/dev/null | sed "s|^|$p\t|" >> "$TMP"
done
echo "-- 采样副本: $(echo "$PODS" | tr '\n' ' ')"
echo "-- 原始行数: $(wc -l < "$TMP" | tr -d ' ')"

python3 - "$SITE" "$TMP" <<'PY'
import collections, datetime, re, sys

site, path = sys.argv[1], sys.argv[2]
# GIN 行：| 200 | <ip> | 0.5ms | GET /api/status |
row = re.compile(r"\|\s*(\d{3})\s*\|\s*([\d.]+)\s*\|\s*[0-9.]+\S*\s*\|\s*(\w+) (\S+)")
ts = re.compile(r"(\d{4}/\d\d/\d\d - \d\d:\d\d:\d\d)")

per_ip = collections.defaultdict(lambda: collections.Counter())
ip_paths = collections.defaultdict(collections.Counter)
n_lines = n_parse = 0
tmin = tmax = None
for ln in open(path, encoding="utf-8", errors="replace"):
    n_lines += 1
    m = row.search(ln)
    if not m:
        continue
    code, ip, method, p = m.groups()
    n_parse += 1
    tm = ts.search(ln)
    if tm:
        try:
            t = datetime.datetime.strptime(tm.group(1), "%Y/%m/%d - %H:%M:%S")
            tmin = t if tmin is None or t < tmin else tmin
            tmax = t if tmax is None or t > tmax else tmax
        except Exception:
            pass
    per_ip[ip][code] += 1
    ip_paths[ip]["%s %s" % (method, p)] += 1

span = (tmax - tmin).total_seconds() if (tmin and tmax and tmax > tmin) else 0.0
print("-- 解析: 可解析访问行 %d / %d，时间跨度 %s → %s（%.0fs）" %
      (n_parse, n_lines, tmin, tmax, span))
if not n_parse:
    print("   (窗口内无可解析行)"); sys.exit(0)

print("-- 按客户端 IP 跨副本合并（限流预算就是按 IP 算的）--")
print("   %-16s %-7s %-6s %-6s %-9s %-11s %s" %
      ("client IP", "总", "200", "429", "429%", "rps(合并)", "主要路径"))
BUDGET_RPS = 360 / 180.0
for ip, c in sorted(per_ip.items(), key=lambda kv: -sum(kv[1].values())):
    tot = sum(c.values())
    if tot < 5:
        continue
    rps = tot / span if span else 0
    top = ", ".join("%s×%d" % (k, v) for k, v in ip_paths[ip].most_common(2))
    flag = "  ← 超预算" if rps > BUDGET_RPS else ""
    print("   %-16s %-7d %-6d %-6d %-9s %-11.2f %s%s" %
          (ip, tot, c.get("200", 0), c.get("429", 0),
           "%.0f%%" % (100.0 * c.get("429", 0) / tot), rps, top[:60], flag))
print("   参考：GlobalAPIRateLimit 预算 = 360 次/180 秒 = %.2f rps（同 IP 跨全部副本共享）" % BUDGET_RPS)

# 429 究竟落在哪些路径上
c429 = collections.Counter()
for ip, pc in ip_paths.items():
    if per_ip[ip].get("429", 0) == 0:
        continue
    for k, v in pc.items():
        c429[k] += v
print("-- 429 来源 IP 的访问路径分布（含被放行部分）--")
for k, v in c429.most_common(6):
    print("   %-32s %d" % (k, v))
PY

echo "== DONE SITE=$SITE =="
