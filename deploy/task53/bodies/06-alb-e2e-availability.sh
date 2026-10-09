#!/usr/bin/env bash
# =============================================================================
# 任务 53 追加取证 06（只读请求）：429 是否已经变成「ALB 侧真摘除 = 客户端 5xx」
#
# 05 实测两地每台接入 ALB 的副本都有 **7 个连续 6 秒桶（42 s）拿不到任何 2xx**，
#   远超 UnhealthyThreshold=3 × interval=6 s = 18 s ⇒ 按判据 ALB 应当已把这些后端
#   标记为不健康。若所有后端同时不健康，客户端就会看到 503（真 outage，不只是日志噪声）。
#
# 本脚本只做一件事：从 VPC 内以 **0.5 rps**（远低于 360/180 s 预算）向 ALB 发 GET，
#   采样 ≥300 s（跨过至少一个完整的 180 s 限流窗口），统计返回码分布与最长非 2xx 连续串。
#   每条都带正确 Host 以命中 pri=1 规则；mnl 另发一组「无 Host（直连 DNS/IP）」以对照
#   pri=2（mnl=FixedResponse 404，sg=转发到第二个 standby 组）。
#
# 只读：不写 DB、不改 K8s/云对象。请求本身是 GET /api/status（幂等、无副作用）。
# =============================================================================
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?}"
SECS="${SECS:-300}"
case "$SITE" in
  mnl) DNS=alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com; HOST=ph-verify.internal.likha.hk ;;
  sg)  DNS=alb-amdwm60xmznh7s1nae.ap-southeast-1.alb.aliyuncsslbintl.com;  HOST=sg-standby.internal.likha.hk ;;
  *) echo "SITE 必须 mnl|sg"; exit 2 ;;
esac
TMP=/tmp/t53-06-$$.txt
trap 'rm -f "$TMP"' EXIT

echo "== SITE=$SITE ALB 端到端可用性采样 ${SECS}s（0.5 rps）UTC=$(date -u '+%F %T') =="
echo "   DNS=$DNS  Host=$HOST"
command -v curl >/dev/null 2>&1 || { echo "  [XX] 节点缺 curl"; exit 1; }
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  for MODE in host nohost; do
    if [ "$MODE" = host ]; then HDR=(-H "Host: $HOST"); else HDR=(); fi
    CODE=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' "${HDR[@]}" "http://$DNS/api/status" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$(date -u '+%H:%M:%S')" "$MODE" "${CODE:-000}" >> "$TMP"
  done
  sleep 2
done
N=$(wc -l < "$TMP" | tr -d ' ')
echo "-- 采样 $N 条（host / nohost 各半）--"

python3 - "$SITE" "$TMP" <<'PY'
import collections, sys
site, path = sys.argv[1], sys.argv[2]
rows = [ln.rstrip("\n").split("\t") for ln in open(path, encoding="utf-8", errors="replace") if "\t" in ln]
per = collections.defaultdict(collections.Counter)
seq = collections.defaultdict(list)
for t, mode, code in rows:
    per[mode][code] += 1
    seq[mode].append((t, code))
for mode in sorted(per):
    tot = sum(per[mode].values())
    print("-- %s：n=%d 返回码分布 %s" % (mode, tot, dict(per[mode].most_common())))
    # 最长「非 2xx」连续串（同 mode 内按时间序，间隔约 2 s）
    run = best = 0
    for _, c in seq[mode]:
        if c != "200":
            run += 1
        else:
            run = 0
        best = max(best, run)
    print("   最长连续非 2xx = %d 条 ≈ %d s（每 2 s 一条）" % (best, best * 2))
    bad = [(t, c) for t, c in seq[mode] if c not in ("200",)][-8:]
    if bad:
        print("   最近 8 条非 200: %s" % ", ".join("%s=%s" % (t, c) for t, c in bad))
if site == "mnl":
    print("   （mnl 的 nohost 命中 pri=2 = FixedResponse 404，属预期，不是后端故障）")
else:
    print("   （sg 的 nohost 命中 pri=2 = 转发到第二个 standby 组，返回码反映后端健康）")
PY
echo "== DONE SITE=$SITE =="
