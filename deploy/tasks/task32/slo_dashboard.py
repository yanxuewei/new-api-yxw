#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Day3 · 任务 32 · SLO / 错误预算看板（Grafana 新加坡工作区，幂等）

口径与缺口（全部来自任务 32 卡，勿自行放宽）：
  · 可用性 SLO 99.95%/月 ⇒ 错误预算 21.6 分钟/月
  · 请求成功率 ≥99.9%（5min 滑窗，排除 4xx/429）
  · 延迟 P95 ≤800ms —— **依赖 /metrics（G8 未落地）⇒ 本看板不呈现，按卡内「探针降级口径」记缺口**
  · 5xx 比率真源在 **SLS `sls-newapi-mnl/alb_access`**（`host`/`status`/`slb_pool_name`），
    不在 Prometheus ⇒ 本看板给的是**资源侧支撑面板**（副本/饱和/重启/节点水位）
    + 一张口径说明面板；5xx/预算燃尽面板由 SLS 仪表盘与 SLS 告警承担（见 burn_alerts.sh）。

用法：
  python3 slo_dashboard.py dash     # 建/更新看板 newapi-slo
  python3 slo_dashboard.py verify   # 回读面板清单
"""
import json
import subprocess
import sys

REGION = "ap-southeast-1"
GWID = "grafana-intl-sg-swy4zuysc01"
DS_UID = "arms-prom-mnl"
DASH_UID = "newapi-slo"
NS = "new-api"
MODE = sys.argv[1] if len(sys.argv) > 1 else "dash"


def proxy(method, path, body=None, show=True):
    req = {"method": method, "path": path,
           "headers": {"Content-Type": "application/json"}}
    if body is not None:
        req["body"] = json.dumps(body, ensure_ascii=False)
    cmd = ["aliyun", "arms", "GrafanaWorkspaceHttpApiProxy",
           "--region", REGION, "--RegionId", REGION,
           "--GrafanaWorkspaceId", GWID, "--OrgId", "1",
           "--BodyStr", json.dumps(req, ensure_ascii=False)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "").strip() or (r.stderr or "").strip()
    if show:
        print(f"──────── {method} {path}\n{out[:1200]}\n")
    return out


def p_text(pid, title, markdown, gp):
    return {"id": pid, "title": title, "type": "text", "gridPos": gp,
            "options": {"mode": "markdown", "content": markdown},
            "transparent": False}


def p_ts(pid, title, targets, gp, unit=None, legend="__auto", desc=""):
    p = {"id": pid, "title": title, "type": "timeseries", "gridPos": gp,
         "datasource": {"type": "prometheus", "uid": DS_UID},
         "description": desc,
         "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l,
                      "datasource": {"type": "prometheus", "uid": DS_UID}}
                     for i, (e, l) in enumerate(targets)],
         "fieldConfig": {"defaults": {}, "overrides": []},
         "options": {"legend": {"displayMode": "table", "placement": "bottom",
                                "calcs": ["lastNotNull", "max"]},
                     "tooltip": {"mode": "multi", "sort": "desc"}}}
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    return p


def p_stat(pid, title, expr, gp, unit=None, desc="", thresholds=None):
    p = {"id": pid, "title": title, "type": "stat", "gridPos": gp,
         "datasource": {"type": "prometheus", "uid": DS_UID},
         "description": desc,
         "targets": [{"refId": "A", "expr": expr, "legendFormat": "__auto",
                      "datasource": {"type": "prometheus", "uid": DS_UID}}],
         "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                       "values": False},
                     "colorMode": "value", "graphMode": "area",
                     "justifyMode": "auto", "textMode": "auto"},
         "fieldConfig": {"defaults": {}, "overrides": []}}
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    if thresholds:
        p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute",
                                                      "steps": thresholds}
    return p


SLO_TEXT = """## SLO / 错误预算口径（任务 32）

| SLO | 指标 | 目标 | 窗口 | 本看板状态 |
|---|---|---|---|---|
| 可用性 | 外部拨测（云监控站点监控 + GTM） | **99.95%** | 月 | 见云监控 `likha-hk-newapi-status`（不在 Grafana） |
| 错误预算 | 99.95% ⇒ **21.6 分钟/月** | — | 月 | SLS 仪表盘 / 告警承担 |
| 请求成功率 | 5xx 比例（排除 4xx/429） | **≥99.9%** | 5min 滑窗 | 真源 = SLS `alb_access`（`host`/`status`） |
| 延迟 | 首字延迟 P95 ≤800ms | — | 5min | **缺口：需 /metrics（G8）** |
| 网关链路 | 上游 5xx（`upstream_status`） | 单独曲线 | 月 | SLS 单独查询，**不计入自身 SLO** |
| DB | 慢查询 >1s | 阈值告警 | 5min | RDS 侧，另见 PG 监控 |

**本看板定位**：资源侧支撑（副本数/饱和度/重启/节点水位）。5xx 与预算燃尽在 SLS 侧，
避免跨源口径打架；三者对不上时以 SLS `alb_access` 为 5xx 唯一真源。
"""


PANELS = [
    p_text(1, "SLO 口径与缺口", SLO_TEXT, {"h": 9, "w": 24, "x": 0, "y": 0}),
    p_stat(2, "就绪容器数", f'count(kube_pod_container_status_ready{{namespace="{NS}"}} == 1)',
           {"h": 6, "w": 6, "x": 0, "y": 9}, "short", "SLO 支撑：至少 2 个就绪才有冗余",
           [{"color": "red", "value": None}, {"color": "orange", "value": 1},
            {"color": "green", "value": 2}]),
    p_stat(3, "期望副本（HPA）",
           f'max(kube_horizontalpodautoscaler_status_desired_replicas{{namespace="{NS}"}})',
           {"h": 6, "w": 6, "x": 6, "y": 9}, "short", "HPA 期望值；打满 max 即 P2"),
    p_stat(4, "CPU 饱和率（使用/requests）",
           f'sum(rate(container_cpu_usage_seconds_total{{namespace="{NS}",container!="",container!="POD"}}[5m]))'
           f' / sum(kube_pod_container_resource_requests{{namespace="{NS}",resource="cpu"}})',
           {"h": 6, "w": 6, "x": 12, "y": 9}, "percentunit",
           "接近 1 表示无扩容余量，与 HPA 联动看",
           [{"color": "green", "value": None}, {"color": "orange", "value": 0.7},
            {"color": "red", "value": 0.9}]),
    p_stat(5, "内存饱和率（工作集/requests）",
           f'sum(container_memory_working_set_bytes{{namespace="{NS}",container!="",container!="POD"}})'
           f' / sum(kube_pod_container_resource_requests{{namespace="{NS}",resource="memory"}})',
           {"h": 6, "w": 6, "x": 18, "y": 9}, "percentunit",
           "超 1 有 OOMKill 风险",
           [{"color": "green", "value": None}, {"color": "orange", "value": 0.8},
            {"color": "red", "value": 1}]),
    p_ts(6, "副本数趋势（就绪 vs 期望）",
         [(f'count(kube_pod_status_ready{{namespace="{NS}",condition="true"}})', "就绪"),
          (f'max(kube_horizontalpodautoscaler_status_desired_replicas{{namespace="{NS}"}})', "期望")],
         {"h": 8, "w": 12, "x": 0, "y": 15}, "short"),
    p_ts(7, "容器重启速率（次/分钟）",
         [(f'sum(rate(kube_pod_container_status_restarts_total{{namespace="{NS}"}}[15m])) * 60', "重启/分")],
         {"h": 8, "w": 12, "x": 12, "y": 15}, "short",
         desc="单副本反复重启 ⇒ P3；整批重启 ⇒ 升级 P2"),
    p_ts(8, "节点 CPU 水位", [
        ('1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)', "{{instance}}"),
    ], {"h": 8, "w": 12, "x": 0, "y": 23}, "percentunit",
        desc="节点级：>0.8 影响调度余量（dev 集群尤其紧）"),
    p_ts(9, "节点内存水位", [
        ('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes', "{{instance}}"),
    ], {"h": 8, "w": 12, "x": 12, "y": 23}, "percentunit"),
]

DASH = {"dashboard": {
    "uid": DASH_UID,
    "title": "New API · SLO 与错误预算（资源侧 + 口径）",
    "tags": ["new-api", "likha", "task32", "slo"],
    "timezone": "browser", "schemaVersion": 39, "version": 0,
    "refresh": "1m", "editable": True,
    "time": {"from": "now-6h", "to": "now"},
    "panels": PANELS},
    "overwrite": True, "message": "task32 SLO dashboard"}


def main():
    if MODE in ("dash", "all"):
        print("=== [1] 建/更新看板 newapi-slo ===")
        proxy("POST", "/api/dashboards/db", DASH)
    if MODE in ("verify", "all", "dash"):
        print("=== [2] 回读 ===")
        out = proxy("GET", f"/api/dashboards/uid/{DASH_UID}", show=False)
        try:
            dash = json.loads(json.loads(out)["Data"]["body"]).get("dashboard", {})
            print(f"  title={dash.get('title')} uid={dash.get('uid')} version={dash.get('version')}")
            for p in dash.get("panels", []):
                print(f"   - [{p.get('type')}] {p.get('title')}")
        except Exception as e:
            print("  解析失败:", e, out[:300])
    print("=== done ===")


main()
