#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
# deploy/sls/alb_pv_report.sh —— ALB 访问日志的 PV/UV 与流量结构查询
#
# 为什么不用云监控：ALB 的 CloudMonitor 指标只有 QPS / 连接数 / 状态码 /
# 流量 / 响应时间，没有页面语义，也无从去重。PV 的唯一可靠来源是访问日志。
#
# 数据源：sls-newapi-mnl/alb_access（AlbConfig 已开启 accessLog）
#   可用字段：host / request_uri / request_method / client_ip /
#             http_user_agent / http_referer / status / upstream_status /
#             slb_pool_name / request_time / upstream_response_time ...
#
# 口径（默认，可用参数改）：
#   PV = GET 请求，排除 /api/* 与静态资源后缀
#   UV = approx_distinct(client_ip)   ← 近似值，NAT 会低估、移动网会高估
#   注意：ALB 日志不含健康检查；SPA 路由切换不产生新请求
#
# 用法：
#   bash deploy/sls/alb_pv_report.sh [pv|hosts|status|top] [选项]
#
#   pv       PV/UV（默认按小时分桶）
#   hosts    host 分布（先用它确认业务域名，再去 pv 加 --host）
#   status   HTTP 状态码分布
#   top      URI Top N
#
# 选项：
#   --host <域名>    只统计该 host（强烈建议；不过滤会把扫描器算进来）
#   --uri <正则>     只看匹配的 URI（页面白名单，例如 '^/$' 或 '^/(index|pricing|docs)/?$'）
#   --hours <N>      时间窗口，默认 24
#   --by <粒度>      pv 用：hour（默认）| day | total
#   --top <N>        条数，默认 10
#
# 环境变量：SLS_PROJECT / SLS_LOGSTORE / SLS_REGION / ALIYUN_BIN
# ════════════════════════════════════════════════════════════════════════
set -uo pipefail

CMD="pv"
HOST=""
URI_RE=""
HOURS=24
BY="hour"
TOP=10

while [ $# -gt 0 ]; do
  case "$1" in
    pv|hosts|status|top) CMD="$1"; shift ;;
    --host)  HOST="${2:-}"; shift 2 ;;
    --host=*) HOST="${1#*=}"; shift ;;
    --uri)   URI_RE="${2:-}"; shift 2 ;;
    --uri=*) URI_RE="${1#*=}"; shift ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --hours=*) HOURS="${1#*=}"; shift ;;
    --by)    BY="${2:-hour}"; shift 2 ;;
    --by=*)  BY="${1#*=}"; shift ;;
    --top)   TOP="${2:-10}"; shift 2 ;;
    --top=*) TOP="${1#*=}"; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) printf '未知参数: %s（-h 查看用法）\n' "$1" >&2; exit 1 ;;
  esac
done

case "$BY" in hour|day|total) : ;; *) printf '--by 只支持 hour|day|total\n' >&2; exit 1 ;; esac

CMD="$CMD" HOST="$HOST" URI_RE="$URI_RE" HOURS="$HOURS" BY="$BY" TOP="$TOP" \
SLS_PROJECT="${SLS_PROJECT:-sls-newapi-mnl}" \
SLS_LOGSTORE="${SLS_LOGSTORE:-alb_access}" \
SLS_REGION="${SLS_REGION:-ap-southeast-6}" \
ALIYUN_BIN="${ALIYUN_BIN:-aliyun}" \
python3 - <<'PY'
import json
import os
import subprocess
import sys
import time
import unicodedata

env = os.environ
cmd_name = env["CMD"]
host = env["HOST"]
uri_re = env["URI_RE"]
hours = int(env["HOURS"])
by = env["BY"]
top = int(env["TOP"])
project = env["SLS_PROJECT"]
logstore = env["SLS_LOGSTORE"]
region = env["SLS_REGION"]
aliyun = env["ALIYUN_BIN"]

now = int(time.time())
start = now - hours * 3600


def lit(value: str) -> str:
    """SQL 字符串字面量：单引号翻倍。"""
    return "'" + value.replace("'", "''") + "'"


base = [
    "request_method = 'GET'",
    r"NOT regexp_like(request_uri, '^/api/')",
    r"NOT regexp_like(request_uri, '\.(js|css|png|jpg|jpeg|svg|ico|woff2?|map)$')",
]
if host:
    base.insert(0, f"host = {lit(host)}")
if uri_re:
    base.append(f"regexp_like(request_uri, {lit(uri_re)})")
where = " AND ".join(base)
host_only = f" WHERE host = {lit(host)}" if host else ""

if cmd_name == "hosts":
    sql = f"* | SELECT host, count(*) AS c FROM log{host_only} GROUP BY host ORDER BY c DESC LIMIT {top}"
elif cmd_name == "status":
    sql = f"* | SELECT status, count(*) AS c FROM log{host_only} GROUP BY status ORDER BY c DESC LIMIT 20"
elif cmd_name == "top":
    sql = f"* | SELECT request_uri, count(*) AS c FROM log WHERE {where} GROUP BY request_uri ORDER BY c DESC LIMIT {top}"
elif by == "total":
    sql = f"* | SELECT count(*) AS pv, approx_distinct(client_ip) AS uv FROM log WHERE {where}"
else:
    unit = "hour" if by == "hour" else "day"
    sql = (f"* | SELECT date_trunc('{unit}', __time__) AS t, count(*) AS pv, "
           f"approx_distinct(client_ip) AS uv FROM log WHERE {where} GROUP BY t ORDER BY t DESC")

body = json.dumps({"query": sql, "from": start, "to": now, "line": max(top, 100), "offset": 0})
proc = subprocess.run(
    [aliyun, "sls", "GetLogsV2", "--project", project, "--logstore", logstore,
     "--region", region, "--body", body],
    capture_output=True, text=True)
raw = proc.stdout or proc.stderr
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("查询失败：", raw[:500], file=sys.stderr)
    sys.exit(1)
if "data" not in data:
    print("查询失败：", json.dumps(data, ensure_ascii=False)[:500], file=sys.stderr)
    sys.exit(1)

rows = data["data"]

print(f"# project={project} logstore={logstore} region={region}")
print(f"# 窗口=最近 {hours}h    host={host or '<未过滤，含扫描器>'}    "
      f"uri={uri_re or '<全部>'}    命令={cmd_name}"
      + (f"    粒度={by}" if cmd_name == "pv" else ""))
print(f"# SQL: {sql}")
print()

if not rows:
    print("（窗口内无数据）")
    sys.exit(0)


def dwidth(text):
    """终端显示宽度：中文/全角算 2 列。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def pad(text, width):
    return text + " " * max(0, width - dwidth(text))


def table(headers, keys, rows, pct=False):
    body_rows = []
    total = sum(int(r[keys[-1]]) for r in rows) if pct else 0
    for r in rows:
        cells = [str(r.get(k, "")) for k in keys]
        if pct and total:
            cells.append(f"{int(r[keys[-1]]) * 100 / total:.1f}%")
        body_rows.append(cells)
    heads = headers + (["占比"] if pct else [])
    widths = [max(dwidth(h), *(dwidth(c[i]) for c in body_rows)) for i, h in enumerate(heads)]
    print("  " + "  ".join(pad(h, w) for h, w in zip(heads, widths)))
    print("  " + "  ".join("-" * w for w in widths))
    for cells in body_rows:
        print("  " + "  ".join(pad(c, w) for c, w in zip(cells, widths)))


if cmd_name == "pv":
    if by == "total":
        row = rows[0]
        print(f"  PV: {row['pv']}    UV: {row['uv']}")
    else:
        table(["时间", "PV", "UV"], ["t", "pv", "uv"], rows)
        total_pv = sum(int(r["pv"]) for r in rows)
        print(f"\n  合计 PV {total_pv}；UV 为分桶近似值，跨桶不可直接相加")
elif cmd_name == "hosts":
    table(["host", "请求数"], ["host", "c"], rows, pct=True)
elif cmd_name == "status":
    table(["status", "请求数"], ["status", "c"], rows, pct=True)
else:
    table(["request_uri", "请求数"], ["request_uri", "c"], rows, pct=True)
PY
