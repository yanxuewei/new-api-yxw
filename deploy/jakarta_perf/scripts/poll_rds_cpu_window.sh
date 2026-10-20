#!/usr/bin/env bash
# poll_rds_cpu_window.sh —— 从云监控取压测窗口的 RDS CPU（PG 主实例），只读、无费用
# 用法：bash new-api-yxw/deploy/jakarta_perf/scripts/poll_rds_cpu_window.sh "<ISO-UTC 起>" "<ISO-UTC 止>"
# 为什么要它：台账里"S2 判读"要证明 **数据库不是拐点**，靠的是云监控实测峰值，
#   而不是"看起来没事"。基线 ≈0.3%，所以任何 >5% 的点都能归因到具体某一档。
# 已知坑：Dimensions 里的双引号必须转义；时间用 UTC ISO（本机 WSL 时区是 UTC+8，别把本地时间当 UTC 传）。
set -uo pipefail
INST=pgm-d9j9p421lzx4gw73
ST=${1:-2026-10-19T08:00:00Z}
ET=${2:-2026-10-19T09:50:00Z}
for M in CpuUsage ConnectionUsage; do
  echo "=== $M  $ST ~ $ET"
  aliyun cms DescribeMetricList --RegionId ap-southeast-5 --Namespace acs_rds_dashboard \
    --MetricName "$M" --Dimensions "[{\"instanceId\":\"$INST\"}]" \
    --Period 60 --StartTime "$ST" --EndTime "$ET" 2>&1 | python3 -c '
import sys, json, datetime
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    pts = json.loads(d.get("Datapoints") or "[]")
except Exception as ex:
    print("      [XX] 解析失败：%s | %s" % (type(ex).__name__, raw[:200])); raise SystemExit(0)
if not pts:
    print("      (窗口内无数据点)"); raise SystemExit(0)
pts.sort(key=lambda p: p["timestamp"])
f = lambda ms: datetime.datetime.utcfromtimestamp(ms/1000.0).strftime("%H:%M")
vals = [p.get("Maximum", p.get("Average", 0)) for p in pts]
top = sorted(pts, key=lambda p: -(p.get("Maximum", p.get("Average", 0))))[:6]
print("      点数=%d 最小=%.3f 中位≈%.3f 峰值=%.3f" % (
    len(pts), min(vals), sorted(vals)[len(vals)//2], max(vals)))
print("      峰值前 6 分钟点(UTC)：" + "  ".join("%s=%.2f" % (f(p["timestamp"]), p.get("Maximum", p.get("Average", 0))) for p in top))
'
done
