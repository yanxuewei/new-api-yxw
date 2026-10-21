#!/usr/bin/env python3
"""report.py —— 把 k6 压测日志渲染成单文件 HTML 报告（任务 33）

输入：deploy/perf/k6/bodies/stage.sh 产出的日志（含 ===RUN_META=== 块 + k6 文本摘要）
      —— run.sh 每次执行后会把远端输出落盘到 deploy/logs/perf_reports/*.log
输出：单文件 HTML（内联 CSS + 内联 SVG，无外部依赖、可离线打开）

用法：
  python3 report.py --log-dir deploy/logs/perf_reports --out deploy/logs/perf_reports/index.html
  python3 report.py --logs a.log b.log --out /tmp/r.html

口径与公式全部在报告的「公式与口径」章节展开；脚本只做算术，不臆造数据：
  - 首字延迟用 k6 的 http_req_waiting（TTFB 代理），不是应用层首 token
  - CPU 取压测期间 kubectl top 峰值，replicas 为本次经过的副本数
"""
from __future__ import annotations

import argparse
import glob
import html
import json
import math
import os
import re
from datetime import datetime, timezone

SLO_TTFB_P95 = 800.0     # ms
SLO_ERR_RATE = 0.0005    # 0.05%
TARGET_VUS = 1500        # 任务 33 的 S2 目标并发


# ---------- 解析 ----------
def parse_meta(text: str) -> dict:
    m = re.search(r"===RUN_META===(.*?)===END_META===", text, re.S)
    if not m:
        return {}
    meta = {}
    for line in m.group(1).strip().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            meta[k.strip()] = v.strip()
    return meta


def _num(s: str, unit: str = "") -> float:
    s = s.strip()
    if unit and s.endswith(unit):
        s = s[: -len(unit)]
    if s.endswith("ms"):
        return float(s[:-2])
    if s.endswith("s"):
        return float(s[:-1]) * 1000.0
    return float(s)


def parse_summary(text: str) -> dict:
    """从 k6 文本摘要里取关键指标（不依赖 JSON，避免云助手输出上限）"""
    out = {}
    pats = {
        "reqs": r"http_reqs\.+:\s*(\d+)\s+([\d.]+)/s",
        "failed": r"http_req_failed\.+:\s*([\d.]+)%\s+(\d+) out of (\d+)",
        "waiting": r"http_req_waiting\.+:\s*(.+)",
        "duration": r"http_req_duration\.+:\s*avg=([^\s]+)\s+min=([^\s]+)\s+med=([^\s]+)\s+p\(90\)=([^\s]+)\s+p\(95\)=([^\s]+)\s+p\(99\)=([^\s]+)\s+max=([^\s]+)",
        "checks": r"checks\.+:\s*([\d.]+)%\s+(\d+) out of (\d+)",
        "data_recv": r"data_received\.+:\s*([\d.]+)\s*(\wB)",
        "data_rate": r"data_received\.+:\s*[\d.]+\s*\wB\s+([\d.]+)\s*(k|M)B/s",
        "vus_max": r"vus_max\.+:\s*(\d+)",
    }
    # 一个日志可能包含多条摘要（dual1500 = 两个 Job 并行）⇒ 聚合成一次运行：
    # 吞吐/请求数求和，延迟类取最差（保守）。
    reqs = re.findall(pats["reqs"], text)
    if reqs:
        out["reqs"] = sum(int(a) for a, _ in reqs)
        out["rps"] = sum(float(b) for _, b in reqs)
        out["streams"] = len(reqs)
    fails = re.findall(pats["failed"], text)
    if fails:
        err_n = sum(int(a[1]) for a in fails)
        total = sum(int(a[2]) for a in fails)
        out["err_n"] = err_n
        out["reqs_total"] = total
        out["err_pct"] = (err_n / total * 100.0) if total else 0.0
    waits = re.findall(pats["waiting"], text)
    if waits:
        for k, pat in (("ttfb_avg", r"avg=([^\s]+)"), ("ttfb_med", r"med=([^\s]+)"),
                       ("ttfb_p90", r"p\(90\)=([^\s]+)"), ("ttfb_p95", r"p\(95\)=([^\s]+)"),
                       ("ttfb_p99", r"p\(99\)=([^\s]+)"), ("ttfb_max", r"max=([^\s]+)")):
            vals = []
            for w in waits:
                mm = re.search(pat, w)
                if mm:
                    try:
                        vals.append(_num(mm.group(1)))
                    except ValueError:
                        pass
            if vals:
                out[k] = max(vals)
    durs = re.findall(pats["duration"], text)
    if durs:
        out["dur_avg"] = max(_num(d[0]) for d in durs)
        out["dur_med"] = max(_num(d[2]) for d in durs)
        out["dur_p95"] = max(_num(d[4]) for d in durs)
        out["dur_p99"] = max(_num(d[5]) for d in durs)
    m = re.search(pats["checks"], text)
    if m:
        out["checks_pct"] = float(m.group(1))
    m = re.search(pats["data_recv"], text)
    if m:
        out["data_mb"] = float(m.group(1))
    rates = re.findall(pats["data_rate"], text)
    if rates:
        # 取各摘要之和（dual 模式两条），kB/s → Mbps（十进制）
        kbps = sum(float(v) * (1024 if u == "M" else 1) for v, u in rates)
        out["data_mbps"] = kbps * 8 / 1000.0
    m = re.search(pats["vus_max"], text)
    if m:
        out["vus_max"] = int(m.group(1))
    return out


def load_runs(paths: list[str], eip_mbps: float = 0.0) -> list[dict]:
    runs = []
    for p in paths:
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        meta = parse_meta(text)
        if not meta or "vus" not in meta:
            continue
        s = parse_summary(text)
        if "rps" not in s:
            continue
        run = dict(meta)
        run.update(s)
        run["vus_i"] = int(float(meta.get("vus", 0)))
        run["replicas_i"] = max(1, int(float(meta.get("replicas", 1) or 1)))
        run["cpu_cores"] = float(meta.get("cpu_peak_m", 0) or 0) / 1000.0
        run["mem_mi"] = float(meta.get("mem_peak_mi", 0) or 0)
        run["dur_s"] = float(re.sub(r"[^0-9.]", "", meta.get("dur", "0")) or 0)
        run["source"] = os.path.basename(p)
        run["pass"] = (s.get("err_pct", 100) <= SLO_ERR_RATE * 100) and (s.get("ttfb_p95", 1e9) <= SLO_TTFB_P95)
        # 派生量
        if run["rps"] > 0:
            run["cpu_per_rps"] = run["cpu_cores"] / run["rps"]
            run["cpu_h_per_mreq"] = run["cpu_per_rps"] * 1e6 / 3600.0
            run["reqs_per_core_h"] = (run["rps"] * 3600.0) / run["cpu_cores"] if run["cpu_cores"] > 0 else 0
            run["rps_per_replica"] = run["rps"] / run["replicas_i"]
            run["vus_per_replica"] = run["vus_i"] / run["replicas_i"]
        if run.get("dur_avg"):
            run["little_vus"] = run["rps"] * run["dur_avg"] / 1000.0
        if eip_mbps and run.get("data_mbps"):
            run["bw_util"] = run["data_mbps"] / eip_mbps
        runs.append(run)
    runs.sort(key=lambda r: (r["vus_i"], r["ts"]))
    return runs


# ---------- 分析 ----------
def analyse(runs: list[dict], eip_mbps: float = 0.0) -> dict:
    a = {"n": len(runs)}
    if not runs:
        return a
    passing = [r for r in runs if r["pass"]]
    a["best"] = max(passing, key=lambda r: r["rps"]) if passing else None
    a["worst"] = max(runs, key=lambda r: r["vus_i"])
    a["first_fail"] = next((r for r in runs if not r["pass"]), None)
    # 单副本拐点：最后一个通过点与第一个失败点之间，对 P95 做线性插值到 800ms
    knee_vus = knee_rps = None
    bw_blocked = bool(a["first_fail"] and (a["first_fail"].get("bw_util") or 0) >= 0.85)
    a["knee_blocked"] = bw_blocked
    if passing and a["first_fail"] and not bw_blocked:
        p, f = passing[-1], a["first_fail"]
        if p is not f and f.get("ttfb_p95") and p.get("ttfb_p95") and f["ttfb_p95"] > p["ttfb_p95"]:
            vp, vf = p["vus_per_replica"], f["vus_per_replica"]
            yp, yf = p["ttfb_p95"], f["ttfb_p95"]
            ratio = (SLO_TTFB_P95 - yp) / (yf - yp)
            knee_vus = vp + ratio * (vf - vp)
            knee_rps = (p["rps_per_replica"] + ratio * (f["rps_per_replica"] - p["rps_per_replica"]))
    a["knee_vus_per_replica"] = knee_vus
    a["knee_rps_per_replica"] = knee_rps
    if bw_blocked:
        a["knee_note"] = "首个破线档带宽利用率 ≥85%（链路先饱和）⇒ 该拐点不能当容量结论，改用内网直连档位"
    if knee_vus and knee_vus > 0:
        a["replicas_for_target"] = math.ceil(TARGET_VUS / knee_vus)
    # 瓶颈判定（事实 + 推测分开写）
    facts, guesses = [], []
    if a["first_fail"]:
        f = a["first_fail"]
        facts.append(f"VU={f['vus_i']} 时 P95={f.get('ttfb_p95', 0):.0f}ms、错误率={f.get('err_pct', 0):.3f}%，超出 SLO")
        if f.get("err_pct", 0) > SLO_ERR_RATE * 100 and (f.get("bw_util") or 0) < 0.85:
            guesses.append("错误率抬升先于延迟劣化 ⇒ 优先怀疑连接/上游/DB 连接池，而非 CPU")
        elif f["cpu_cores"] >= 0.8 * 2.0:
            guesses.append("CPU 峰值已 ≥ 80% 上限（2 核）且延迟同步劣化 ⇒ 主要瓶颈在网关 CPU")
        else:
            guesses.append("CPU 未触顶但延迟劣化 ⇒ 更可能是排队（连接数/DB 池/上游 mock 调度），需下钻进程指标")
    if eip_mbps and runs:
        peak = max((r.get("data_mbps") or 0) for r in runs)
        a["eip_mbps"] = eip_mbps
        a["bw_peak"] = peak
        a["bw_util"] = peak / eip_mbps if eip_mbps else 0
        facts.append(f"下行流量峰值 {peak:.2f} Mbps（EIP 标称 {eip_mbps:.0f} Mbps，利用率 {peak / eip_mbps * 100:.0f}%）")
        if peak >= 0.85 * eip_mbps:
            guesses.append(f"带宽利用率 ≥85% ⇒ 公网路径（NAT→EIP {eip_mbps:.0f}Mbps）先于网关饱和；"
                           "继续加并发只会放大超时/重置，需先抬带宽或改内网路径再测")
    if passing:
        b = a["best"]
        facts.append(f"最优通过档 VU={b['vus_i']}：RPS={b['rps']:.1f}、P95={b.get('ttfb_p95', 0):.0f}ms、错误率={b.get('err_pct', 0):.3f}%")
        if b.get("cpu_cores"):
            facts.append(f"该档 CPU 峰值 {b['cpu_cores']:.2f} 核，折合每千 RPS {b['cpu_per_rps'] * 1000:.3f} 核·千RPS⁻¹")
    a["facts"], a["guesses"] = facts, guesses
    return a


# ---------- 渲染 ----------
def esc(x) -> str:
    return html.escape(str(x))


def fmt(x, n=1, suffix=""):
    try:
        return f"{float(x):,.{n}f}{suffix}"
    except (TypeError, ValueError):
        return "—"


def badge(ok: bool, text_pass="PASS", text_fail="FAIL") -> str:
    cls = "ok" if ok else "bad"
    return f'<span class="badge {cls}">{text_pass if ok else text_fail}</span>'


def svg_line(runs: list[dict], key: str, title: str, unit: str, slo: float | None = None) -> str:
    W, H, L, R, T, B = 640, 220, 56, 16, 18, 34
    xs = [r["vus_i"] for r in runs]
    ys = [float(r.get(key, 0) or 0) for r in runs]
    if not xs:
        return ""
    x0, x1 = min(xs), max(xs)
    y0, y1 = 0.0, max(ys + ([slo] if slo else [])) * 1.15 or 1.0
    def px(x): return L + (x - x0) / max(1, (x1 - x0)) * (W - L - R)
    def py(y): return H - B - (y - y0) / max(1e-9, (y1 - y0)) * (H - T - B)
    pts = " ".join(f"{px(x):.1f},{py(y):.1f}" for x, y in zip(xs, ys))
    dots = "".join(
        f'<circle class="pt" data-i="{i}" cx="{px(x):.1f}" cy="{py(y):.1f}" r="5" fill="#0f9d58" '
        f'stroke="#ffffff" stroke-width="1.6" style="cursor:pointer"><title>VU={x}</title></circle>'
        for i, (x, y) in enumerate(zip(xs, ys)))
    slo_line = ""
    if slo:
        yy = py(slo)
        slo_line = (f'<line x1="{L}" y1="{yy:.1f}" x2="{W-R}" y2="{yy:.1f}" stroke="#e53e3e" '
                    f'stroke-dasharray="5 4" stroke-width="1"/><text x="{W-R}" y="{yy-5:.1f}" text-anchor="end" '
                    f'font-size="11" fill="#e53e3e">SLO {slo:g}{unit}</text>')
    labels = "".join(f'<text x="{px(x):.1f}" y="{H-12}" text-anchor="middle" font-size="10" fill="#666">{x}</text>' for x in xs)
    yticks = ""
    for i in range(4):
        yv = y0 + (y1 - y0) * i / 3
        yy = py(yv)
        yticks += (f'<line x1="{L}" y1="{yy:.1f}" x2="{W-R}" y2="{yy:.1f}" stroke="#eee"/>'
                   f'<text x="{L-6}" y="{yy+3.5:.1f}" text-anchor="end" font-size="10" fill="#888">{yv:.0f}</text>')
    return f'''<figure class="chart"><figcaption>{esc(title)}（横轴 VU，纵轴 {esc(unit)}）</figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="{esc(title)}">
{yticks}{slo_line}<polyline points="{pts}" fill="none" stroke="#2b6cb0" stroke-width="2"/>{dots}{labels}
</svg></figure>'''


def render(runs: list[dict], a: dict, out_path: str, eip_mbps: float = 0.0) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows = ""
    for r in runs:
        rows += f'''<tr>
<td>{r["job"]}<div class="sub">{esc(r.get("ts", ""))}</div></td>
<td>{r["vus_i"]}<div class="sub">{r["replicas_i"]} 副本</div></td>
<td>{esc(r.get("mode", ""))}<div class="sub">{esc(r.get("target", ""))}</div></td>
<td>{fmt(r["rps"], 1)}</td>
<td>{fmt(r.get("ttfb_med", 0), 0)}</td>
<td><b>{fmt(r.get("ttfb_p95", 0), 0)}</b></td>
<td>{fmt(r.get("ttfb_p99", 0), 0)}</td>
<td>{fmt(r.get("dur_p95", 0), 0)}</td>
<td>{fmt(r.get("err_pct", 0), 3)}%</td>
<td>{fmt(r.get("checks_pct", 0), 2)}%</td>
<td>{fmt(r["cpu_cores"], 2)}</td>
<td>{fmt(r["mem_mi"], 0)}</td>
<td>{fmt(r.get("data_mbps", 0), 2)}</td>
<td>{badge(r["pass"])}</td>
</tr>'''
    best = a.get("best") or (runs[-1] if runs else None)
    first_fail = a.get("first_fail")
    cards = f'''
<div class="card"><div class="k">本次运行数</div><div class="v">{a["n"]}</div><div class="s">由同一目录日志聚合</div></div>
<div class="card"><div class="k">实测最优通过档</div><div class="v">{fmt(best["rps"], 1) if best else "—"}<small> req/s</small></div><div class="s">VU={best["vus_i"] if best else "—"} · P95={fmt(best.get("ttfb_p95"), 0) if best else "—"}ms</div></div>
<div class="card"><div class="k">单副本拐点（线性插值到 800ms）</div><div class="v">{fmt(a.get("knee_vus_per_replica"), 0) if a.get("knee_vus_per_replica") else "—"}<small> 并发流/副本</small></div><div class="s">{esc(a.get("knee_note") or ("≈ %s req/s/副本" % fmt(a.get("knee_rps_per_replica"), 1) if a.get("knee_rps_per_replica") else "数据不足"))}</div></div>
<div class="card"><div class="k">{TARGET_VUS} 并发所需副本</div><div class="v">{a.get("replicas_for_target", "—")}</div><div class="s">ceil({TARGET_VUS} ÷ 单副本拐点)</div></div>'''

    facts = "".join(f"<li>{esc(x)}</li>" for x in a.get("facts", [])) or "<li>（数据不足）</li>"
    guesses = "".join(f"<li>{esc(x)}</li>" for x in a.get("guesses", [])) or "<li>（数据不足，暂不推断）</li>"

    detail = ""
    if runs:
        heads = "".join("<th>VU=%d</th>" % r["vus_i"] for r in runs)
        r_rps = "".join("<td>%s</td>" % fmt(r["rps"], 1) for r in runs)
        r_p95 = "".join("<td>%s</td>" % fmt(r.get("ttfb_p95"), 0) for r in runs)
        r_err = "".join("<td>%s%%</td>" % fmt(r.get("err_pct"), 3) for r in runs)
        r_cpu = "".join("<td>%s</td>" % fmt(r["cpu_cores"], 2) for r in runs)
        r_cpr = "".join("<td>%s</td>" % (fmt(r["cpu_per_rps"] * 1000, 2) if r.get("cpu_per_rps") else "—") for r in runs)
        detail = ('<table class="mini"><thead><tr><th>指标</th>' + heads + '</tr></thead><tbody>'
                  '<tr><td>RPS</td>' + r_rps + '</tr>'
                  '<tr><td>P95 首字 (ms)</td>' + r_p95 + '</tr>'
                  '<tr><td>错误率</td>' + r_err + '</tr>'
                  '<tr><td>CPU 峰值 (核)</td>' + r_cpu + '</tr>'
                  '<tr><td>每千 RPS 用核</td>' + r_cpr + '</tr></tbody></table>')

    runs_json = json.dumps([{
        "job": r.get("job", ""), "ts": r.get("ts", ""), "vus": r["vus_i"],
        "replicas": r["replicas_i"], "mode": r.get("mode", ""), "target": r.get("target", ""),
        "rps": r.get("rps", 0), "ttfb_p50": r.get("ttfb_med", 0),
        "ttfb_p95": r.get("ttfb_p95", 0), "ttfb_p99": r.get("ttfb_p99", 0),
        "dur_p95": r.get("dur_p95", 0), "err_pct": r.get("err_pct", 0),
        "checks_pct": r.get("checks_pct", 0), "cpu": r.get("cpu_cores", 0),
        "mem": r.get("mem_mi", 0), "bw": r.get("data_mbps", 0), "pass": bool(r.get("pass")),
    } for r in runs], ensure_ascii=False).replace("</", "<\\/")

    doc = f'''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>new-api · SSE 容量压测报告 · {now}</title>
<style>
:root{{--fg:#0b1f16;--mut:#4b6a5c;--line:#cde8d8;--bg:#f2fbf6;--brand:#0f9d58;--accent:#12b76a;--deep:#052e1b;--ok:#0b7a45;--bad:#b42318}}
*{{box-sizing:border-box}}
body{{margin:0;color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans SC",sans-serif;
  background:radial-gradient(1200px 500px at 15% -10%,rgba(18,183,106,.18),transparent 60%),
             radial-gradient(900px 420px at 100% 0%,rgba(5,46,27,.10),transparent 55%),var(--bg)}}
header{{background:linear-gradient(120deg,#052e1b 0%,#0b5d34 55%,#0f9d58 100%);color:#eafff3;padding:30px 34px;border-bottom:3px solid #12b76a;box-shadow:0 8px 24px rgba(5,46,27,.18)}}
header h1{{margin:0 0 6px;font-size:22px;font-weight:650}}
header .meta{{opacity:.85;font-size:12.5px}}
main{{max-width:1180px;margin:0 auto;padding:24px 20px 64px}}
h2{{font-size:16px;margin:30px 0 12px;padding-left:10px;border-left:4px solid var(--accent);letter-spacing:.3px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}}
.card{{background:#fff;border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:10px;padding:14px 16px;box-shadow:0 2px 10px rgba(5,46,27,.05)}}
.card .k{{font-size:12px;color:var(--mut)}}
.card .v{{font-size:24px;font-weight:700;color:#0b7a45;font-variant-numeric:tabular-nums}}
.card .v small{{font-size:12px;color:var(--mut);font-weight:400}}
.card .s{{font-size:11.5px;color:var(--mut);margin-top:4px}}
table{{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}}
th,td{{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;font-variant-numeric:tabular-nums;font-size:12.5px;vertical-align:top}}
th{{background:#e6f7ee;font-weight:600;font-size:12px;color:#0b3d27}}
tr:last-child td{{border-bottom:none}}
.sub{{color:var(--mut);font-size:10.5px}}
.badge{{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;font-weight:600}}
.badge.ok{{background:#d1fadf;color:var(--ok)}}
.badge.bad{{background:#fee4e2;color:var(--bad)}}
ul{{margin:6px 0 0 20px;padding:0}} li{{margin:3px 0}}
.note{{background:#fff;border:1px dashed var(--line);border-radius:10px;padding:12px 14px;font-size:12.5px;color:#4a5568}}
code{{background:#e2f8ec;color:#064e2b;border:1px solid #b7e4c9;padding:1px 6px;border-radius:5px;font-size:12.5px;font-weight:600;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
pre{{background:#06281a;color:#d9ffe9;border:1px solid #14532d;padding:14px 16px;border-radius:10px;overflow:auto;font-size:12.5px;line-height:1.6}}
.chart{{margin:10px 0 0;background:#fff;border:1px solid var(--line);border-radius:10px;padding:10px 12px}}
.chart figcaption{{font-size:12px;color:var(--mut);margin-bottom:4px}}
.lim{{color:#315244;font-size:12.5px;line-height:1.7}}
.tip{{position:fixed;z-index:99;background:#06281a;color:#e9fff2;border:1px solid #16a34a;border-radius:10px;
  box-shadow:0 12px 32px rgba(5,46,27,.35);padding:12px 14px;font-size:12.5px;min-width:260px}}
.tip-h{{font-weight:700;margin-bottom:6px;color:#7ef0b0;display:flex;align-items:center;gap:8px}}
.tip-t{{width:100%;border-collapse:collapse}}
.tip-t td{{padding:2px 6px;border:none;font-size:12px;color:#cdeedd}}
.tip-t td:first-child{{color:#8fbfa9;white-space:nowrap}}
</style></head><body>
<header>
  <h1>new-api · SSE 容量压测报告</h1>
  <div class="meta">生成于 {now} · 数据源：k6 文本摘要 + 运行时采样 · 集群 new-api-perf（雅加达 ap-southeast-5）</div>
</header>
<main>
<h2>摘要</h2>
<div class="cards">{cards}</div>

<h2>每次运行明细</h2>
<table>
<thead><tr><th>Job / 时间</th><th>VU</th><th>路径</th><th>RPS</th><th>P50 首字</th><th>P95 首字</th><th>P99 首字</th><th>P95 端到端</th><th>错误率</th><th>checks</th><th>CPU 峰值(核)</th><th>内存峰值(Mi)</th><th>下行(Mbps)</th><th>判定</th></tr></thead>
<tbody>{rows or "<tr><td colspan=13>无数据</td></tr>"}</tbody>
</table>
<div class="lim">首字用 k6 <code>http_req_waiting</code>（TTFB 代理）；端到端为 <code>http_req_duration</code>；CPU 为压测期间 <code>kubectl top pod</code> 峰值（URL 模式取各副本最大值）。SLO：P95 首字 ≤ {SLO_TTFB_P95:.0f}ms 且错误率 ≤ {SLO_ERR_RATE*100:.2f}%。</div>

<h2>趋势</h2>
{svg_line(runs, "ttfb_p95", "P95 首字延迟 vs 并发", "ms", SLO_TTFB_P95)}
{svg_line(runs, "rps", "吞吐 RPS vs 并发", "req/s")}

<h2>瓶颈判定</h2>
<div class="note"><b>事实</b><ul>{facts}</ul></div>
<div class="note" style="margin-top:10px"><b>推断（需下钻验证）</b><ul>{guesses}</ul></div>

<h2>理想 QPS 与资源</h2>
{detail}
<div class="note" style="margin-top:10px">
当前实测「理想 QPS」= 在 SLO 内可稳定达到的最高吞吐：<b>{fmt(best["rps"],1) if best else "—"} req/s</b>
（{("单副本" if best and best["replicas_i"]==1 else (str(best["replicas_i"])+" 副本") if best else "")}，VU={best["vus_i"] if best else "—"}）。
单副本资源效率：<b>{fmt(best["cpu_per_rps"]*1000,2) if best and best.get("cpu_per_rps") else "—"} 核 / 千 RPS</b>，
即约 <b>{fmt(best["reqs_per_core_h"],0) if best and best.get("reqs_per_core_h") else "—"} 请求 / 核·小时</b>。
按 {TARGET_VUS} 并发目标，需 <b>{a.get("replicas_for_target","—")} 个副本</b>（公式见下）。
</div>

<h2>公式与口径（完整）</h2>
<pre>
1) 首字延迟（代理）   TTFB_p95 = k6 http_req_waiting 的 p(95)
   说明：SSE 场景下响应头与首块几乎同时到达；若需真实 token 级首字，需改用自定义流式客户端。

2) 吞吐              RPS = http_reqs / duration
   实测值直接取 k6 的 http_reqs 速率行（如 "220  10.72/s"）。

3) 并发与驻留（Little 定律）
   N ≈ RPS × T_avg        N=VU（并发流数），T_avg=http_req_duration 平均（秒）
   一致性校验：N 计算值应与 vus_max 同量级；若明显偏小，说明大量请求在客户端排队。

4) 每次请求 CPU       C_req = CPU_peak_cores / RPS        （核·秒/请求）
   每千 RPS 用核       C_k = C_req × 1000
   每核小时可服务请求    Q_coreh = RPS × 3600 / CPU_peak_cores
   每百万请求 CPU 小时   H_1M = C_req × 1,000,000 / 3600

5) SLO 余量          margin = 1 − TTFB_p95 / 800ms
6) 单副本拐点（线性插值）
   VU_knee = VU_pass + (800 − P95_pass) / (P95_fail − P95_pass) × (VU_fail − VU_pass)
   其中 pass 为最后一个满足 SLO 的档，fail 为第一个破线的档；RPS_knee 同法按 RPS 插值。
7) 目标副本数        Replicas = ceil(Target_VU / VU_knee_per_replica)
   本项目 Target_VU = 1500（S2）；未额外乘 1.5 余量，若要求峰值×1.5 则再乘 1.5 后向上取整。

8) 判定口径
   PASS ⇔ 错误率 ≤ 0.05% 且 P95 首字 ≤ 800ms
   注意：本环境 mock 上游无真实厂商延迟，且部分档位未含 ALB（clusterip 模式）；
   URL 模式（https://perf.likha.hk）含 NAT+ALB 入口开销，两种模式不可直接混比。

9) 链路带宽利用率
   U_bw = data_received_rate(Mbps) / EIP_Bandwidth(Mbps)
   公网路径（k6→NAT→EIP→ALB）先撞带宽时，表现为 RPS 塌陷 + 大量连接级失败（超时/重置），
   而此时应用侧无 5xx、CPU 不高 ⇒ 必须换内网直连或抬带宽后再压。

10) 资源口径
   CPU_peak = 压测窗口内 kubectl top 的峰值（URL 模式逐副本采样后取最大）
   Mem_peak = 同上（MiB）
   CPU 上限按部署 limits=2 核记（deploy/perf/... 实际 deployment 以集群为准）。
</pre>

<h2>复现</h2>
<pre>bash deploy/perf/k6/run.sh stage https://perf.likha.hk 300 120s
bash deploy/perf/k6/run.sh stage perf-new-api-slave 900 120s
bash deploy/perf/k6/run.sh summary</pre>

<p class="lim">本报告由 deploy/perf/k6/report.py 自动生成；点击趋势图上的绿色数据点可查看该次运行明细。</p>
</main>
<div id="tip" class="tip" hidden></div>
<script>
const RUNS = {runs_json};
const tip = document.getElementById('tip');
function showTip(ev, i) {{
  const r = RUNS[i]; if (!r) return;
  const f = (v, n, suf) => (v === null || v === undefined || v === 0 ? '—' : Number(v).toFixed(n) + (suf || ''));
  tip.innerHTML = `<div class="tip-h">${{r.job}} <span class="badge ${{r.pass ? 'ok' : 'bad'}}">${{r.pass ? 'PASS' : 'FAIL'}}</span></div>`
    + `<table class="tip-t"><tr><td>时间</td><td>${{r.ts}}</td></tr>`
    + `<tr><td>并发 / 副本</td><td>${{r.vus}} / ${{r.replicas}}</td></tr>`
    + `<tr><td>路径</td><td>${{r.mode}} · ${{r.target}}</td></tr>`
    + `<tr><td>RPS</td><td>${{f(r.rps,1)}}</td></tr>`
    + `<tr><td>首字 P50/P95/P99</td><td>${{f(r.ttfb_p50,0)}} / ${{f(r.ttfb_p95,0)}} / ${{f(r.ttfb_p99,0)}} ms</td></tr>`
    + `<tr><td>端到端 P95</td><td>${{f(r.dur_p95,0)}} ms</td></tr>`
    + `<tr><td>错误率 / checks</td><td>${{f(r.err_pct,3)}}% / ${{f(r.checks_pct,2)}}%</td></tr>`
    + `<tr><td>CPU / 内存峰值</td><td>${{f(r.cpu,2)}} 核 / ${{f(r.mem,0)}} Mi</td></tr>`
    + `<tr><td>下行</td><td>${{f(r.bw,2)}} Mbps</td></tr></table>`;
  tip.hidden = false;
  const pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + w > window.innerWidth - 8) x = ev.clientX - w - pad;
  if (y + h > window.innerHeight - 8) y = ev.clientY - h - pad;
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}}
document.querySelectorAll('circle.pt').forEach(el => {{
  el.addEventListener('click', ev => {{ ev.stopPropagation(); showTip(ev, Number(el.dataset.i)); }});
}});
document.addEventListener('click', () => {{ tip.hidden = true; }});
document.addEventListener('keydown', ev => {{ if (ev.key === 'Escape') tip.hidden = true; }});
</script>
</body></html>'''
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(doc)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log-dir")
    ap.add_argument("--logs", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--eip-mbps", type=float, default=0.0, help="公网路径的 EIP 标称带宽（Mbps），用于带宽利用率判定")
    args = ap.parse_args()

    paths = []
    if args.logs:
        paths = list(args.logs)
    elif args.log_dir:
        paths = sorted(glob.glob(os.path.join(args.log_dir, "*.log")))
    runs = load_runs(paths, args.eip_mbps)
    render(runs, analyse(runs, args.eip_mbps), args.out, args.eip_mbps)
    print(f"[report] runs={len(runs)} -> {args.out}")


if __name__ == "__main__":
    main()
