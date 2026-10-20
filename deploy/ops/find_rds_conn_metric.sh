#!/usr/bin/env bash
# find_rds_conn_metric.sh —— 摸清 cms 里 RDS 的连接数指标到底叫什么
# 背景：猜 ActiveConnections ⇒ 400 SDK.ServerError（body 不是 JSON，会把解析器带崩）。
#   所以这一步先看 DescribeMetricMetaList 的**原始结构**，再挑名字，不要凭记忆报指标名。
set -uo pipefail
echo "=== 原始响应前 600 字（确认字段名与是否报错）"
aliyun cms DescribeMetricMetaList --Namespace acs_rds_dashboard --PageSize 100 2>&1 | head -c 600
printf '\n'
echo "=== 从原始 JSON 里提取指标名（大小写不敏感匹配 conn）"
aliyun cms DescribeMetricMetaList --Namespace acs_rds_dashboard --PageSize 100 2>&1 | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("      [!] 非 JSON，头部：%s" % raw[:200]); raise SystemExit(0)
res = (d.get("Resources") or {})
lst = res.get("Resource") or d.get("Datapoints") or []
names = []
for it in lst:
    if isinstance(it, dict):
        n = it.get("MetricName") or it.get("metricName") or ""
        if n: names.append(n)
print("      条目=%d" % len(names))
for n in sorted(set(names)):
    if any(k in n.lower() for k in ("conn", "cpu", "mem", "active")):
        print("      ", n)
'
