#!/usr/bin/env bash
# =============================================================================
# 任务 53 追加取证（只读）：429 来源归因 + 探针节拍实测
#
# 已确认的云侧事实（本机 aliyun CLI 只读查询，2026-10-06 16:3x）：
#   mnl alb-1riqckb1h8ezm0y7s9：仅 HTTP:80 一个 listener，默认动作 → kube-system-fake-svc
#         rule pri=1 host=ph-verify.internal.likha.hk → sgp-tqgwt413t19mum8oa9
#         该组 HealthCheckEnabled=true path=/api/status method=GET interval=6s timeout=3s
#                    healthy/unhealthy=2/3 Host=$SERVER_IP，ServerCount=4，**type=Eni :3000**
#         组内 4 个 ENI 目标 = Pod ENI 直连（Terway），ALB 探针不经 NodePort
#   sg  alb-amdwm60xmznh7s1nae：仅 HTTP:80；rule pri=1 host=sg-standby.internal.likha.hk
#         → sgp-rlxs1mqishcxcfkx7u（Eni :3000 ×2，HC 同上）
#         rule pri=2 path=/*（**无 host 条件**）→ sgp-8m8eknlyw0z1busl6r（Eni :3000 ×2，HC 同上）
#   ALB -zone IntranetAddress：mnl 10.0.0.136 / 10.0.1.96；sg 10.1.0.250 / 10.1.1.248
#     ⇒ 日志里出现的 10.0.0.137 / 10.0.1.97 / 10.1.1.249 紧邻这些地址，即 ALB 数据面/探针源
#
# 本脚本要回答的唯一问题：这些源 IP 打 /api/status 的**实际节拍与速率**是多少，
#   与 360 次/180 秒（=2.00 rps，Redis 启用时按客户端 IP **跨全部副本共享**）相比如何。
#   理论推算：interval=6s ⇒ 每副本 0.167 rps，两地分别 0.67 / 0.67 rps，**远低于预算**；
#   若实测高出一个量级，说明还有别的来源（拨测/双监听/双 server group），必须看清再写文档。
#
# 不做的事：不 curl 业务端点（我不再消耗配额）、不写 DB、不改任何云/K8s 对象。
# =============================================================================
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"
NS=new-api
TMP=/tmp/t53-04-$$.txt
trap 'rm -f "$TMP"' EXIT

echo "== SITE=$SITE 探针节拍实测 UTC=$(date -u '+%F %T') =="
PODS=$(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,P:.status.phase 2>/dev/null | awk '$2=="Running" && $1 ~ /^new-api-/{print $1}')
[ -n "$PODS" ] || { echo "  [XX] 无 Running 副本"; exit 1; }
: > "$TMP"
for p in $PODS; do
  kubectl -n $NS logs "$p" --timestamps --tail=8000 2>/dev/null | sed "s|^|$p\t|" >> "$TMP"
done
echo "-- 副本: $(echo "$PODS" | tr '\n' ' ')｜原始行: $(wc -l < "$TMP" | tr -d ' ')"

python3 - "$SITE" "$TMP" <<'PY'
import collections, datetime, re, statistics, sys

site, path = sys.argv[1], sys.argv[2]
# GIN 行（实测格式，µs 是 UTF-8 微符号；IP 在耗时**之后**）：
#   [GIN] 2026/10/06 - 16:37:52 | api | <reqid> | 200 | 73.46µs | 10.1.1.249 | GET /api/status
row = re.compile(r"\|\s*(\d{3})\s*\|\s*[0-9.]+\S*\s*\|\s*([\d.]+)\s*\|\s*(\w+) (\S+)")
BUDGET = 360 / 180.0          # 2.00 rps，按 client IP 跨全部副本共享

recs = []
for ln in open(path, encoding="utf-8", errors="replace"):
    head, _, rest = ln.partition("\t")
    m = row.search(rest)
    if not m:
        continue
    code, ip, method, p = m.groups()
    # 时间戳在 rest 的开头（head 是 sed 前缀的 Pod 名）
    t = None
    tm = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.(\d+)", rest)
    if tm:
        t = datetime.datetime.strptime(tm.group(1), "%Y-%m-%dT%H:%M:%S")
        t = t + datetime.timedelta(microseconds=int(tm.group(2)[:6]))
    else:
        tm = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", rest)
        if tm:
            t = datetime.datetime.strptime(tm.group(1), "%Y-%m-%dT%H:%M:%S")
    recs.append((head, t, head.strip(), code, ip, method, p))
if not recs:
    print("  (无可解析访问行)"); sys.exit(0)
if not [r[1] for r in recs if r[1]]:
    print("  [!] 行已解析但时间戳前缀缺失 ⇒ 放弃节拍统计"); sys.exit(0)

ts = [r[1] for r in recs if r[1]]
span = (max(ts) - min(ts)).total_seconds() if len(ts) > 1 else 0.0
print("-- 解析 %d 行，时间跨度 %s → %s（%.0fs）｜全部路径: %s" %
      (len(recs), min(ts), max(ts), span,
       dict(collections.Counter(r[6] for r in recs).most_common(6))))

# ---- 按 (源 IP) 合并跨副本：限流预算就是这个口径 ----
print("-- 按客户端 IP 跨副本合并（对照预算 %.2f rps）--" % BUDGET)
print("   %-16s %-7s %-6s %-6s %-7s %-9s %s" %
      ("client IP", "总", "200", "429", "429%", "合并 rps", "路径"))
byip = collections.defaultdict(lambda: [0, 0, 0, collections.Counter(), []])
for _, t, _, code, ip, method, p in recs:
    b = byip[ip]
    b[0] += 1
    if code == "200": b[1] += 1
    if code == "429": b[2] += 1
    b[3]["%s %s" % (method, p)] += 1
    if t: b[4].append(t)
for ip, b in sorted(byip.items(), key=lambda kv: -kv[1][0]):
    if b[0] < 5:
        continue
    rps = b[0] / span if span else 0
    mark = "  ← 超预算" if rps > BUDGET else ""
    print("   %-16s %-7d %-6d %-6d %-7s %-9.2f %s%s" %
          (ip, b[0], b[1], b[2], "%.0f%%" % (100.0 * b[2] / b[0]), rps,
           ", ".join("%s×%d" % (k, v) for k, v in b[3].most_common(2))[:52], mark))

# ---- 节拍：相邻间隔分布（判定是否 6s 健康检查）----
print("-- 访问节拍（同 IP 相邻请求间隔，秒）--")
for ip, b in sorted(byip.items(), key=lambda kv: -kv[1][0])[:6]:
    if b[0] < 20 or len(b[4]) < 20:
        continue
    d = sorted((y - x).total_seconds() for x, y in zip(b[4], b[4][1:]))
    med = statistics.median(d)
    print("   %-16s n=%-6d 间隔 p10/中位/p90 = %.1f/%.1f/%.1f s  max=%.0f  %s" %
          (ip, len(d), d[int(.1 * len(d))], med, d[int(.9 * len(d))], max(d),
           "≈6s 单次健康检查节拍" if 4 <= med <= 8 else
           ("≈6s/N 多目标共享源 IP" if med < 4 else "非健康检查节拍")))

# ---- 每副本视角：ALB 源 IP 在该副本上的 429 与节拍 ----
print("-- 每副本 × ALB 源 IP（谁被限流打死）--")
per = collections.defaultdict(lambda: collections.Counter())
for _, _, pod, code, ip, method, p in recs:
    if p == "/api/status":
        per[(pod, ip)][code] += 1
for (pod, ip), c in sorted(per.items(), key=lambda kv: -sum(kv[1].values()))[:14]:
    tot = sum(c.values())
    if tot < 5:
        continue
    print("   %-44s %-14s 总=%-5d 200=%-5d 429=%-5d %s" %
          (pod[:44], ip, tot, c.get("200", 0), c.get("429", 0),
           "%.0f%%" % (100.0 * c.get("429", 0) / tot)))

# ---- 429 的分钟直方图：突发还是持续 ----
print("-- 429 每分钟计数（跨副本合并）--")
mk = collections.Counter()
for _, t, _, code, ip, method, p in recs:
    if code == "429" and t:
        mk[t.strftime("%H:%M")] += 1
for k in sorted(mk)[-25:]:
    print("   %s %s (%d)" % (k, "#" * min(mk[k], 60), mk[k]))

# ---- 突发形状：每秒请求数 + 180 秒定长窗口的放行/拒绝 ----
print("-- 每秒请求数分布（判定 6s 健康检查 vs 突发洪泛）--")
for ip, b in sorted(byip.items(), key=lambda kv: -kv[1][0])[:4]:
    if len(b[4]) < 50:
        continue
    sec = collections.Counter(x.strftime("%H:%M:%S") for x in b[4])
    v = sorted(sec.values())
    busiest = sorted(sec.items(), key=lambda kv: -kv[1])[:6]
    print("   %-16s 覆盖秒数=%-6d 每秒 p50/p90/max = %d/%d/%d ｜ 最忙: %s" %
          (ip, len(sec), v[len(v) // 2], v[int(.9 * len(v))], v[-1],
           ", ".join("%s×%d" % (k, n) for k, n in busiest)))
print("-- 180 秒定长窗口对账（固定窗口，额度 360 次/窗口/IP）--")
print("   口径说明：mnl RedisEnabled ⇒ 计数器在 Redis，**同 IP 跨全部副本共享一份 360**；")
print("            sg 无 Redis ⇒ 每副本各有一份内存计数器，360 是**每副本每 IP** 的额度。")
print("   下面两表都给：合并=按 IP 跨副本（mnl 口径），分副本=按 (Pod,IP)（sg 口径）。")
allt = [r[1] for r in recs if r[1]]
anchor = min(allt)
merged = collections.defaultdict(collections.Counter)
perpod = collections.defaultdict(collections.Counter)
for _, t, pod, code, ip, method, p in recs:
    if not t:
        continue
    w = int((t - anchor).total_seconds() // 180)
    merged[(ip, w)][code] += 1
    perpod[(pod, ip, w)][code] += 1
print("   [合并] %-16s %-9s %-7s %-6s %-6s %s" % ("client IP", "窗口起点", "总", "200", "429", "对 360 额度"))
rows = [(k, sum(c.values()), c.get("200", 0), c.get("429", 0)) for k, c in merged.items()]
for (ip, w), tot, ok, rl in sorted(rows, key=lambda r: -r[1])[:10]:
    print("   %-22s %-9s %-7d %-6d %-6d %s" %
          (ip, (anchor + datetime.timedelta(seconds=180 * w)).strftime("%H:%M:%S"), tot, ok, rl,
           "总请求已超额度 %d 次" % (tot - 360) if tot > 360 else "未超"))
print("   [分副本] %-44s %-14s %-9s %-7s %-6s %-6s %s" %
      ("pod", "client IP", "窗口起点", "总", "200", "429", "对每副本 360"))
rows = [(k, sum(c.values()), c.get("200", 0), c.get("429", 0)) for k, c in perpod.items()]
for (pod, ip, w), tot, ok, rl in sorted(rows, key=lambda r: -r[1])[:12]:
    print("   %-44s %-14s %-9s %-7d %-6d %-6d %s" %
          (pod[:44], ip, (anchor + datetime.timedelta(seconds=180 * w)).strftime("%H:%M:%S"),
           tot, ok, rl, "超额 %d" % (tot - 360) if tot > 360 else "未超"))
PY
echo "== DONE SITE=$SITE =="
