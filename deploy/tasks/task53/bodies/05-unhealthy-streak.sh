#!/usr/bin/env bash
# =============================================================================
# 任务 53 追加取证 05（只读）：ALB 探针的 429 是否会形成「连续失败串」
#
# 为什么还要再测一轮：429 打在 /api/status 上**本身**只是限流命中；真正要命的是
#   ALB 健康检查判据是 http_2xx + UnhealthyThreshold=3 + interval=6 s ⇒ 只有当
#   「连续 18 s 内一次 2xx 都拿不到」时后端才会被判不健康、被摘流量。
#   04 只给了窗口总量（每副本每 IP 每 180 s：放行 360、拒绝 120），没给**时间形状**。
#   本脚本把 (Pod × 源 IP) 按 6 秒桶切开，统计「全 429 桶」及其最长连续串：
#     连续串 ≥3 桶（=18 s）⇒ ALB 有真实概率摘除该副本；
#     连续串 <3 桶        ⇒ 429 只是噪声，健康判定不受影响。
#   这是从「限流命中」跨到「可用性事故」的分界线，必须实测而不是推算。
#
# 只读：kubectl logs + get，不 curl 业务端点、不写 DB、不改对象。
# =============================================================================
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"
NS=new-api
TMP=/tmp/t53-05-$$.txt
trap 'rm -f "$TMP"' EXIT

echo "== SITE=$SITE 连续失败串实测 UTC=$(date -u '+%F %T') =="
PODS=$(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,P:.status.phase 2>/dev/null | awk '$2=="Running" && $1 ~ /^new-api-/{print $1}')
[ -n "$PODS" ] || { echo "  [XX] 无 Running 副本"; exit 1; }
: > "$TMP"
for p in $PODS; do
  kubectl -n $NS logs "$p" --tail=8000 2>/dev/null | sed "s|^|$p\t|" >> "$TMP"
done
echo "-- 副本: $(echo "$PODS" | tr '\n' ' ')｜原始行: $(wc -l < "$TMP" | tr -d ' ')"

python3 - "$SITE" "$TMP" <<'PY'
import collections, datetime, re, sys

site, path = sys.argv[1], sys.argv[2]
row = re.compile(r"\|\s*(\d{3})\s*\|\s*[0-9.]+\S*\s*\|\s*([\d.]+)\s*\|\s*(\w+) (\S+)")
tin = re.compile(r"\[GIN\] (\d{4}[-/]\d\d[-/]\d\d) - (\d\d:\d\d:\d\d)")

recs = []
for ln in open(path, encoding="utf-8", errors="replace"):
    pod, _, rest = ln.partition("\t")
    m = row.search(rest)
    if not m:
        continue
    code, ip, method, p = m.groups()
    if p != "/api/status":
        continue
    tm = tin.search(rest)
    if not tm:
        continue
    try:
        t = datetime.datetime.strptime(tm.group(1).replace("/", "-") + " " + tm.group(2), "%Y-%m-%d %H:%M:%S")
    except ValueError:
        continue
    recs.append((pod.strip(), ip, code, t))
if not recs:
    print("  (无 /api/status 访问行)"); sys.exit(0)

# 与 ALB 无关的来源（kubelet 节点 IP / 外部 IP）不参与「ALB 摘除」判据；
# ALB 源 = 两地 ALB 的 zone IntranetAddress+1（04 已实测确认）
ALB_IPS = {"mnl": {"10.0.0.137", "10.0.1.97"}, "sg": {"10.1.0.251", "10.1.1.249"}}[site]
anchor = min(r[3] for r in recs)

buckets = collections.defaultdict(lambda: [0, 0])   # (pod, ip, 6s-bidx) -> [ok, rej]
for pod, ip, code, t in recs:
    if ip not in ALB_IPS:
        continue
    b = buckets[(pod, ip, int((t - anchor).total_seconds() // 6))]
    if code == "429":
        b[1] += 1
    else:
        b[0] += 1
if not buckets:
    print("  (窗口内无 ALB 源请求)"); sys.exit(0)

print("-- 每 (副本 × ALB 源 IP) 的 6 秒桶形态 --")
print("   %-44s %-13s %-6s %-6s %-9s %s" %
      ("pod", "alb src", "桶数", "全429桶", "最长连续串", "该串时长"))
worst = 0
for pod in sorted({k[0] for k in buckets}):
    for ip in sorted(ALB_IPS):
        idxs = sorted(b for (p, i, b) in buckets if p == pod and i == ip)
        if not idxs:
            continue
        allrej = [b for b in idxs if buckets[(pod, ip, b)][0] == 0 and buckets[(pod, ip, b)][1] > 0]
        # 最长「连续桶号且全无 2xx」串
        run = best = 0
        prev = None
        for b in idxs:
            ok = buckets[(pod, ip, b)][0]
            rej = buckets[(pod, ip, b)][1]
            bad = (ok == 0 and rej > 0)
            if bad and prev is not None and b == prev + 1:
                run += 1
            elif bad:
                run = 1
            else:
                run = 0
            best = max(best, run)
            prev = b
        worst = max(worst, best)
        print("   %-44s %-13s %-6d %-6d %-9s %s" %
              (pod[:44], ip, len(idxs), len(allrej), "%d 桶" % best,
               "%.0f s" % (best * 6)))
print("-- 判定基准：UnhealthyThreshold=3 × interval=6 s = 连续 18 s 无 2xx 才会被判不健康 --")
print("   实测最长连续无 2xx 串 = %d 桶（%d s）⇒ %s" %
      (worst, worst * 6,
       "≥3 桶 ⇒ ALB 有概率摘除副本（严重）" if worst >= 3 else
       "<3 桶 ⇒ 单次失败会被下一次 2xx 覆盖，健康判定未被打破"))
PY
echo "== DONE SITE=$SITE =="
