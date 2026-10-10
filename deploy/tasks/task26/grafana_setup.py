#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Day3 · 任务26 · Grafana 工作区配置（幂等 · 正式资产）

用途：在 ARMS 控制台创建 Grafana 工作区后，一键把「数据源 + 4 张最小面板」配置到位。
      走 `aliyun arms GrafanaWorkspaceHttpApiProxy`（Grafana HTTP API 代理），
      无需 Grafana 本地账号/API Key —— 前提是调用者已被加入工作区（见 ensure-account）。

BodyStr 结构（权威）: {"method","path","headers","body"}
  - method: GET/POST/PUT/PATCH/DELETE
  - path:   必须以 /api/ 开头；**受代理路径白名单限制**（/api/ds/query、/api/health 不在白名单）
  - headers: 仅少数透传；POST 必须显式带 Content-Type: application/json
  - body:   必须是**转义后的 JSON 字符串**，不是嵌套对象

用法：
  python3 grafana_setup.py account   # 把当前 RAM 子账号加入工作区(Admin)
  python3 grafana_setup.py ds        # 建/更新 Prometheus 数据源
  python3 grafana_setup.py dash      # 建/更新 4 面板看板
  python3 grafana_setup.py verify    # 数据源健康 + 看板面板清单
  python3 grafana_setup.py all       # account + ds + dash + verify
"""
import json
import subprocess
import sys

REGION = "ap-southeast-1"
GWID = "grafana-intl-sg-swy4zuysc01"
RAM_UID = "219901390242410810"          # RAM 子账号 yanxuewei 的 UserId
PROM_URL = ("http://ap-southeast-6.arms.aliyuncs.com:9090/api/v1/prometheus/"
            "d53ceaaa3a927a094abb56714f8/5108890064395960/"
            "cd57e40ce9a634c1698c2f5c5e09bd93c/ap-southeast-6")
DS_NAME = "ARMS-Prometheus-MNL"
DS_UID = "arms-prom-mnl"
DASH_UID = "newapi-min-obs"
NS = "new-api"

MODE = sys.argv[1] if len(sys.argv) > 1 else "all"


def proxy(method, path, body=None, orgid=1, show=True):
    req = {"method": method, "path": path,
           "headers": {"Content-Type": "application/json"}}
    if body is not None:
        req["body"] = json.dumps(body, ensure_ascii=False)
    cmd = ["aliyun", "arms", "GrafanaWorkspaceHttpApiProxy",
           "--region", REGION, "--RegionId", REGION,
           "--GrafanaWorkspaceId", GWID, "--OrgId", str(orgid),
           "--BodyStr", json.dumps(req, ensure_ascii=False)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "").strip() or (r.stderr or "").strip()
    if show:
        print("──────── %s %s" % (method, path))
        print(out[:2500])
        print()
    return out


def body_of(out):
    try:
        data = json.loads(out).get("Data") or {}
        b = data.get("body")
        return json.loads(b) if isinstance(b, str) else None
    except Exception:
        return None


# ── 0. 把调用者加入工作区 ─────────────────────────────────────────────────
def ensure_account():
    print("=== [0] 工作区账号（RAM 子账号 -> Admin）===")
    out = subprocess.run(
        ["aliyun", "arms", "ListGrafanaWorkspaceAccount", "--region", REGION,
         "--GrafanaWorkspaceId", GWID], capture_output=True, text=True).stdout
    for a in (json.loads(out).get("Data") or []):
        if a.get("aliyunUid") == RAM_UID:
            print("  已存在 -> skip（accountId=%s, role=%s）"
                  % (a.get("accountId"),
                     (a.get("orgs") or [{}])[0].get("role")))
            return
    r = subprocess.run(
        ["aliyun", "arms", "CreateGrafanaWorkspaceAccount", "--region", REGION,
         "--RegionId", REGION, "--GrafanaWorkspaceId", GWID, "--OrgId", "1",
         "--AliyunUid", RAM_UID, "--Role", "Admin",
         "--AccountNotes", "fanyan RAM admin"], capture_output=True, text=True)
    print("  " + (r.stdout or r.stderr).strip()[:300])


# ── 1. 数据源 ─────────────────────────────────────────────────────────────
DS = {
    "name": DS_NAME,
    "uid": DS_UID,
    "type": "prometheus",
    "access": "proxy",
    "url": PROM_URL,
    "isDefault": True,
    "jsonData": {"httpMethod": "POST", "timeInterval": "30s"},
}


def apply_ds():
    print("=== [1] 数据源 ===")
    cur = body_of(proxy("GET", "/api/datasources", show=False)) or []
    hit = next((d for d in cur if isinstance(d, dict)
                and d.get("name") == DS_NAME), None)
    if hit:
        print("  已存在 uid=%s -> PUT 更新" % hit.get("uid"))
        proxy("PUT", "/api/datasources/uid/%s" % hit.get("uid"), DS)
    else:
        print("  新建")
        proxy("POST", "/api/datasources", DS)
    cur = body_of(proxy("GET", "/api/datasources", show=False)) or []
    for d in cur:
        if isinstance(d, dict) and d.get("name") == DS_NAME:
            print("  ✅ 数据源在位：uid=%s isDefault=%s" % (d.get("uid"),
                                                           d.get("isDefault")))
            return True
    print("  ⚠️ 复核未找到")
    return False


# ── 2. 看板（4 面板） ─────────────────────────────────────────────────────
def mk(pid, title, ptype, expr, gp, unit=None, legend="__auto"):
    p = {"id": pid, "title": title, "type": ptype,
         "datasource": {"type": "prometheus", "uid": DS_UID},
         "gridPos": gp,
         "targets": [{"refId": "A", "expr": expr, "legendFormat": legend,
                      "datasource": {"type": "prometheus", "uid": DS_UID}}],
         "fieldConfig": {"defaults": {}, "overrides": []}}
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    if ptype == "stat":
        p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "",
                                          "values": False},
                        "colorMode": "value", "graphMode": "none",
                        "justifyMode": "auto", "textMode": "auto"}
    else:
        p["options"] = {"legend": {"displayMode": "table",
                                   "placement": "bottom",
                                   "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}}
    return p


PANELS = [
    mk(1, "就绪容器数 (ready)", "stat",
       'count(kube_pod_container_status_ready{namespace="%s"} == 1)' % NS,
       {"h": 8, "w": 8, "x": 0, "y": 0}, "short", "ready"),
    mk(2, "容器 CPU 使用 (cores)", "timeseries",
       'sum(rate(container_cpu_usage_seconds_total'
       '{namespace="%s",container!="",container!="POD"}[5m])) by (pod)' % NS,
       {"h": 8, "w": 8, "x": 8, "y": 0}, "short"),
    mk(3, "容器内存工作集 (bytes)", "timeseries",
       'sum(container_memory_working_set_bytes'
       '{namespace="%s",container!="",container!="POD"}) by (pod)' % NS,
       {"h": 8, "w": 8, "x": 16, "y": 0}, "bytes"),
    mk(4, "容器重启累计 (次)", "timeseries",
       'sum(kube_pod_container_status_restarts_total{namespace="%s"}) by (pod)' % NS,
       {"h": 8, "w": 24, "x": 0, "y": 8}, "short"),
]

DASH = {"dashboard": {
    "uid": DASH_UID,
    "title": "New API · 最小可观测（4 面板）",
    "tags": ["new-api", "likha", "task26"],
    "timezone": "browser", "schemaVersion": 39, "version": 0,
    "refresh": "30s", "editable": True,
    "time": {"from": "now-3h", "to": "now"},
    "panels": PANELS},
    "overwrite": True, "message": "task26 minimal 4 panels"}


def apply_dash():
    print("=== [2] 看板 ===")
    proxy("POST", "/api/dashboards/db", DASH)
    cur = body_of(proxy("GET", "/api/search", show=False)) or []
    for d in cur:
        if isinstance(d, dict) and d.get("uid") == DASH_UID:
            print("  ✅ 看板在位：%s -> %s" % (d.get("title"), d.get("url")))
            return True
    print("  ⚠️ 复核未找到")
    return False


# ── 3. 验证 ───────────────────────────────────────────────────────────────
def verify():
    print("=== [V1] 数据源健康 ===")
    out = body_of(proxy("GET", "/api/datasources/uid/%s/health" % DS_UID,
                        show=False))
    print("  " + json.dumps(out, ensure_ascii=False) if out else "  ⚠️ 无返回")
    print("=== [V2] 看板面板 ===")
    out = proxy("GET", "/api/dashboards/uid/%s" % DASH_UID, show=False)
    try:
        dash = json.loads(json.loads(out)["Data"]["body"]).get("dashboard", {})
        print("  title=%s uid=%s version=%s"
              % (dash.get("title"), dash.get("uid"), dash.get("version")))
        for p in dash.get("panels", []):
            print("   - [%s] %s" % (p.get("type"), p.get("title")))
    except Exception as e:
        print("  解析失败:", e, out[:300])


if MODE in ("account", "all"):
    ensure_account()
if MODE in ("ds", "all"):
    apply_ds()
if MODE in ("dash", "all"):
    apply_dash()
if MODE in ("verify", "all"):
    verify()
print("=== done (%s) ===" % MODE)
