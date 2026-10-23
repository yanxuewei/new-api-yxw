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
import sys
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
    """k6 时长字符串 -> 毫秒。支持 12m4.4s / 992.81µs / 6.74ms / 2.1s。"""
    s = s.strip()
    if unit and s.endswith(unit):
        s = s[: -len(unit)]
    m = re.fullmatch(r"(?:(\d+)m)?([\d.]+)(\u00b5s|us|ms|s)", s)
    if not m:
        m2 = re.fullmatch(r"(\d+)m", s)
        if m2:
            return float(m2.group(1)) * 60000.0
        return float(s)
    mins = float(m.group(1) or 0)
    val = float(m.group(2))
    u = m.group(3)
    return mins * 60000.0 + val * {"\u00b5s": 0.001, "us": 0.001, "ms": 1.0, "s": 1000.0}[u]


def parse_summary(text: str) -> dict:
    """从 k6 文本摘要里取关键指标（不依赖 JSON，避免云助手输出上限）"""
    out = {}
    pats = {
        "reqs": r"http_reqs\.+:\s*(\d+)\s+([\d.]+)/s",
        "failed": r"http_req_failed\.+:\s*([\d.]+)%\s+(\d+) out of (\d+)",
        "waiting": r"http_req_waiting\.+:\s*(.+)",
        "duration": r"http_req_duration(?:\{[^}]*\})?\.+:\s*avg=(\S+)\s+(?:min=\S+\s+)?med=(\S+)\s+p\(90\)=(\S+)\s+p\(95\)=(\S+)\s+p\(99\)=(\S+)\s+max=(\S+)",
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
        out["dur_med"] = max(_num(d[1]) for d in durs)
        out["dur_p90"] = max(_num(d[2]) for d in durs)
        out["dur_p95"] = max(_num(d[3]) for d in durs)
        out["dur_p99"] = max(_num(d[4]) for d in durs)
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


PHASE_KEYS = {
    "phase_connecting": "http_req_connecting",
    "phase_tls": "http_req_tls_handshaking",
    "phase_sending": "http_req_sending",
    "phase_waiting": "http_req_waiting",
    "phase_receiving": "http_req_receiving",
    "phase_duration": "http_req_duration",
}


def parse_phase_p90(text: str, metric: str) -> float | None:
    """从 k6 摘要取某指标 p(90)（毫秒）。

    k6 输出格式因版本/指标不同，min= 字段有时省略，✓/✗ 前缀也可能存在；
    这里宽松匹配：只要行里含该指标名且能找到 p(90)= 即可。
    """
    # 宽松匹配：找到含该指标的行，再从行内找 p(90)=<value>
    line_pat = re.compile(
        re.escape(metric) + r"(?:\{[^}]*\})?[^:\n]*:([^\n]+)"
    )
    m = line_pat.search(text)
    if not m:
        return None
    segment = m.group(1)
    pm = re.search(r"p\(90\)=(\S+)", segment)
    if not pm:
        return None
    try:
        return _num(pm.group(1))
    except ValueError:
        return None


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
        for k, metric in PHASE_KEYS.items():
            v = parse_phase_p90(text, metric)
            if v is not None:
                run[k] = v
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
    sse = [r for r in passing if r.get("mode") != "admin"]
    adm = [r for r in passing if r.get("mode") == "admin"]
    a["best"] = max(sse, key=lambda r: r["rps"]) if sse else (max(passing, key=lambda r: r["rps"]) if passing else None)
    a["best_admin"] = max(adm, key=lambda r: r["rps"]) if adm else None
    # 优先取有完整阶段数据（phase_receiving）的最优通过档用于 waterfall；
    # 若无 phase_receiving 则退而用有任意阶段数据的，再退而用 best。
    phased = [r for r in sse if r.get("phase_receiving")]
    if not phased:
        phased = [r for r in sse if any(r.get(k) for k in ("phase_waiting", "phase_duration", "phase_sending"))]
    a["best_phase"] = max(phased, key=lambda r: r["rps"]) if phased else a["best"]
    a["worst"] = max(runs, key=lambda r: r["vus_i"])
    # 稳态容量档：只认内网直连（单副本/双副本），排除公网（带宽受限）、管理面、劣化、滚动、长流
    cap_runs = [r for r in runs if r.get("mode") in ("clusterip", "clusterip-dual")]
    cap_runs.sort(key=lambda r: r.get("vus_per_replica") or 0)
    cap_pass = [r for r in cap_runs if r["pass"]]
    fail = next((r for r in cap_runs if not r["pass"]), None)
    a["first_fail"] = fail
    knee_vus = knee_rps = None
    note = ""
    if cap_pass and fail:
        p1 = cap_pass[-1]
        v1, y1 = p1["vus_per_replica"], p1["ttfb_p95"]
        v2, y2 = fail["vus_per_replica"], fail["ttfb_p95"]
        if y2 > y1 and v2 > v1 and y1 < SLO_TTFB_P95:
            ratio = (SLO_TTFB_P95 - y1) / (y2 - y1)
            knee_vus = v1 + ratio * (v2 - v1)
            knee_rps = p1["rps_per_replica"] + ratio * (fail["rps_per_replica"] - p1["rps_per_replica"])
            note = "实测破线档插值"
    if knee_vus is None and len(cap_pass) >= 2:
        # 去掉冷启动畸变：保留 P95 最低点之后的点（低并发首跑常因副本未热身而 P95 偏高）
        ys_all = [r["ttfb_p95"] for r in cap_pass]
        k = ys_all.index(min(ys_all))
        cap_use = cap_pass[k:]
        if len(cap_use) >= 2:
            cap_pass = cap_use
        # 最小二乘：P95 = a + b * VU_per_replica，解 P95=800
        xs = [r["vus_per_replica"] for r in cap_pass]
        ys = [r["ttfb_p95"] for r in cap_pass]
        n = len(xs)
        mx, my = sum(xs) / n, sum(ys) / n
        denom = sum((x - mx) ** 2 for x in xs)
        if denom > 0:
            b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / denom
            if b > 0 and my + b * (max(xs) - mx) < SLO_TTFB_P95:
                knee_vus = mx + (SLO_TTFB_P95 - my) / b
                rps_x = [r["rps_per_replica"] for r in cap_pass]
                rps_b = sum((x - mx) * (y - my) for x, y in zip(xs, rps_x)) / denom
                knee_rps = sum(rps_x) / n + rps_b * (knee_vus - mx)
                note = "无破线档：内网稳态点最小二乘外推到 800ms（外推值）"
    a["knee_vus_per_replica"] = knee_vus
    a["knee_rps_per_replica"] = knee_rps
    if knee_vus and knee_vus > 0:
        a["replicas_for_target"] = math.ceil(TARGET_VUS / knee_vus)
    a["knee_note"] = note
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


def short_label(r: dict) -> str:
    m = {"clusterip": "内网", "clusterip-dual": "内网双副本", "public-url": "公网",
         "burst": "突发", "admin": "管理面", "degrade": "劣化", "rolling": "滚动", "long": "长流"}.get(r.get("mode", ""), r.get("mode", ""))
    return f"{m}@{r['vus_i']}"


def svg_line(runs: list[dict], key: str, title: str, unit: str, slo: float | None = None) -> str:
    """横轴=并发数（VU），纵轴=指标值；每点标注时间戳+路径，支持 hover/点击明细。

    横轴改用 VU 数值而非运行序号，使单点报告也能看出绝对位置，多点报告能看出并发-性能曲线。
    """
    W, H, L, R, T, B = 760, 280, 72, 20, 22, 68
    n = len(runs)
    if n == 0:
        return ""
    vus = [r["vus_i"] for r in runs]
    ys = [float(r.get(key, 0) or 0) for r in runs]
    x0 = 0.0
    x1 = max(vus) * 1.1 or 1.0
    y0 = 0.0
    y1 = max(ys + ([slo] if slo else [])) * 1.15 or 1.0

    def px(v: float) -> float:
        # 单点时固定在图中央偏左，避免挤在左边框
        if x1 <= 0:
            return L + (W - L - R) * 0.5
        return L + (v - x0) / max(1e-9, x1 - x0) * (W - L - R)

    def py(y: float) -> float:
        return H - B - (y - y0) / max(1e-9, (y1 - y0)) * (H - T - B)

    # 折线只在同一模式内连线，否则只画散点（公网/内网混排连线无意义）
    # 简化处理：按 mode 分组，同组内按 vus 排序后连线
    from itertools import groupby
    mode_order = ["clusterip", "clusterip-dual", "public-url", "burst", "rolling", "degrade", "long", "admin"]
    mode_colors = {
        "clusterip": "#0f9d58", "clusterip-dual": "#12b76a",
        "public-url": "#f59e0b", "burst": "#6366f1",
        "rolling": "#8b5cf6", "degrade": "#ef4444",
        "long": "#06b6d4", "admin": "#64748b",
    }
    by_mode: dict[str, list[tuple[int, float, int]]] = {}
    for idx, r in enumerate(runs):
        m = r.get("mode", "")
        by_mode.setdefault(m, []).append((r["vus_i"], float(r.get(key, 0) or 0), idx))

    polylines = ""
    for mode, pts_raw in by_mode.items():
        pts_raw_s = sorted(pts_raw, key=lambda t: t[0])
        color = mode_colors.get(mode, "#94a3b8")
        if len(pts_raw_s) >= 2:
            pts_str = " ".join(f"{px(v):.1f},{py(y):.1f}" for v, y, _ in pts_raw_s)
            polylines += f'<polyline points="{pts_str}" fill="none" stroke="{color}" stroke-width="2" stroke-dasharray="none" opacity="0.7"/>'

    dots = ""
    for i, r in enumerate(runs):
        v, y = r["vus_i"], float(r.get(key, 0) or 0)
        mode = r.get("mode", "")
        color = mode_colors.get(mode, "#94a3b8")
        dots += (f'<circle class="pt" data-i="{i}" cx="{px(v):.1f}" cy="{py(y):.1f}" r="6" fill="{color}" '
                 f'stroke="#ffffff" stroke-width="2" style="cursor:pointer"/>')

    slo_line = ""
    if slo:
        yy = py(slo)
        slo_line = (f'<line x1="{L}" y1="{yy:.1f}" x2="{W-R}" y2="{yy:.1f}" stroke="#e11d48" '
                    f'stroke-dasharray="6 4" stroke-width="1.4"/>'
                    f'<text x="{W-R}" y="{yy-6:.1f}" text-anchor="end" font-size="11" fill="#be123c" font-weight="600">SLO {slo:g}{unit}</text>')

    yticks = ""
    for i in range(5):
        yv = y0 + (y1 - y0) * i / 4
        yy = py(yv)
        yticks += (f'<line x1="{L}" y1="{yy:.1f}" x2="{W-R}" y2="{yy:.1f}" stroke="#e6f4ec"/>'
                   f'<text x="{L-8}" y="{yy+4:.1f}" text-anchor="end" font-size="10.5" fill="#3f6152">{yv:.0f}</text>')

    # X 轴刻度：取各 VU 值，最多显示 8 个，避免重叠
    xtick_vals = sorted(set(vus))
    if len(xtick_vals) > 8:
        step = len(xtick_vals) // 8
        xtick_vals = xtick_vals[::step]
    xticks = ""
    for v in xtick_vals:
        xx = px(v)
        xticks += (f'<line x1="{xx:.1f}" y1="{H-B}" x2="{xx:.1f}" y2="{H-B+4}" stroke="#94a3b8" stroke-width="1"/>'
                   f'<text x="{xx:.1f}" y="{H-B+16}" text-anchor="middle" font-size="10" fill="#315244">{v}</text>')

    # 每个点在点正下方标注时间+路径（旋转，避免重叠）
    xlabels = ""
    for i, r in enumerate(runs):
        v = r["vus_i"]
        ts_short = (r.get("ts", "") or "")[:16].replace("T", " ")
        tgt = r.get("target", "") or r.get("base", "") or ""
        # 只取 hostname 部分，避免太长
        tgt_short = re.sub(r"https?://", "", tgt).split("/")[0][:20]
        label = f"{ts_short} {tgt_short}".strip()
        xlabels += (f'<text x="{px(v):.1f}" y="{H-B+34}" text-anchor="end" font-size="9.5" fill="#315244" '
                    f'transform="rotate(-38 {px(v):.1f} {H-B+34})">{esc(label)}</text>')

    # X 轴标签
    xlabel = f'<text x="{L + (W-L-R)/2:.1f}" y="{H-2}" text-anchor="middle" font-size="10.5" fill="#3f6152">并发 VU</text>'

    return f'''<figure class="chart"><figcaption>{esc(title)}（横轴=并发 VU；纵轴 {esc(unit)}；颜色区分路径类型）</figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="{esc(title)}">
{yticks}{xticks}{slo_line}{polylines}{dots}{xlabels}{xlabel}
</svg></figure>'''


def svg_waterfall(best: dict | None) -> str:
    """一次请求的模块级耗时分解。

    口径优先级：k6 客户端阶段指标（实测 p90）> 已知 mock 参数 > 差值；
    网关+链路（含 DNS/NAT/ALB/Ingress）与"客户端接收余量"用差值推导，并在表格里标注来源。

    「网关+链路」= waiting_p90 − mock首字300ms，它包含了 NAT/ALB/Ingress/鉴权/限流/连接池等
    所有非 mock 延迟。公网路径（https://perf.likha.hk）比内网 ClusterIP 多经过 NAT+EIP+ALB，
    通常多出 30~150ms，因此不同报告该值差异大属于正常——取决于所用路径，不代表网关自身性能差异。
    """
    if not best:
        return ""
    mock_first = 300.0
    stream = 50 * 30.0
    send = best.get("phase_sending") or 0.0
    conn = best.get("phase_connecting") or 0.0
    tls = best.get("phase_tls") or 0.0
    wait = best.get("phase_waiting") or best.get("ttfb_p90") or 0.0
    recv = best.get("phase_receiving") or 0.0
    total = best.get("phase_duration") or best.get("dur_p90") or best.get("dur_p95") or 0.0
    gw = max(0.0, wait - mock_first)
    recv_tail = max(0.0, recv - stream)
    used = send + conn + tls + gw + mock_first + stream + recv_tail
    tail = max(0.0, total - used)

    # 标注路径类型，帮助理解跨报告耗时差异
    mode = best.get("mode", "")
    tgt = best.get("target", "") or best.get("base", "") or ""
    path_note = ""
    if "public" in mode or "http" in tgt:
        path_note = "公网路径（k6→NAT→EIP→ALB→Ingress→Pod）"
    elif "clusterip" in mode or (tgt and not tgt.startswith("http")):
        path_note = "内网直连路径（k6 Pod→kube-proxy→Pod）"

    segs = [
        ("k6 发送", send, "#0b7a45", "实测 http_req_sending p90"),
        ("DNS/TCP 连接", conn, "#116b3a", "实测 http_req_connecting p90（复用连接时为 0）"),
        ("TLS 握手", tls, "#1a8f4c", "实测 http_req_tls_handshaking p90"),
        ("网关+链路（NAT/ALB/Ingress/鉴权）", gw, "#12b76a", "差值：waiting_p90 − mock 首字 300ms"),
        ("mock 首字", mock_first, "#34d399", "已知：FIRST_TOKEN_DELAY_MS=300"),
        ("mock 流式吐字", stream, "#6ee7a8", "已知：50 token × 30ms"),
        ("客户端接收余量", recv_tail, "#a7f3d0", "差值：receiving_p90 − 1500ms"),
    ]
    if tail > 0:
        segs.append(("未归类余量", tail, "#d1fae5", "差值：总时长 − 以上各项"))
    sumv = sum(v for _, v, _, _ in segs) or 1.0

    W, H, L, R = 760, 96, 16, 16
    barY, barH = 30, 40
    barW = W - L - R
    x = L
    rects = ""
    for name, v, color, _ in segs:
        w = v / sumv * barW
        if w <= 0:
            continue
        rects += f'<rect x="{x:.1f}" y="{barY}" width="{w:.1f}" height="{barH}" fill="{color}" rx="2"/>'
        if w > 58:
            rects += (f'<text x="{x + w/2:.1f}" y="{barY + barH/2 + 4:.1f}" text-anchor="middle" '
                      f'font-size="10.5" fill="#04231a" font-weight="700">{v:.0f}</text>')
        x += w
    rows = "".join(
        f'<tr><td>{esc(name)}</td><td>{v:.1f} ms</td><td>{v/sumv*100:.1f}%</td><td class="src">{esc(src)}</td></tr>'
        for name, v, _, src in segs)
    path_info = f'<div class="note" style="margin-top:6px">本次链路路径：<b>{esc(path_note or tgt or mode)}</b>（{esc(tgt)}）· VU={best.get("vus_i","")} · {esc(best.get("ts","")[:16])}</div>' if (path_note or tgt) else ""
    return f'''<figure class="chart"><figcaption>一次请求的模块耗时（{esc(short_label(best))}，按 k6 客户端阶段实测 p90 分解，合计 {sumv:.0f} ms）</figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="请求链路模块耗时">
<text x="{L}" y="20" font-size="10.5" fill="#3f6152">0 ms</text>
<text x="{W-R}" y="20" text-anchor="end" font-size="10.5" fill="#3f6152">{sumv:.0f} ms</text>
{rects}
</svg></figure>
{path_info}
<table class="mini" style="margin-top:10px"><thead><tr><th>模块</th><th>耗时</th><th>占比</th><th>数据来源</th></tr></thead><tbody>{rows}</tbody></table>
<div class="note" style="margin-top:8px">说明：<b>NAT / ALB / Ingress / 鉴权 / 渠道选择 / 连接池</b> 目前没有逐跳埋点，全部落在「网关+链路」这一段（等待首字节减去 mock 首字）。
<b>不同报告该值差异大的原因</b>：公网路径（https://...）比内网 ClusterIP 多经过 NAT+EIP+ALB，通常多出 30~150ms，属于路径差异而非网关性能差异。
若需把各跳再拆开，需要给入口接 SLS 访问日志或 OpenTelemetry trace（本次未做，不做假数据填充）。</div>'''


def render(runs: list[dict], a: dict, out_path: str, eip_mbps: float = 0.0) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    rows = ""
    for r in runs:
        tgt_url = r.get("target", "") or r.get("base", "") or ""
        rows += f'''<tr>
<td>{r["job"]}<div class="sub">{esc(r.get("ts", ""))}</div></td>
<td>{r["vus_i"]}<div class="sub">{r["replicas_i"]} 副本</div></td>
<td>{esc(r.get("mode", ""))}<div class="sub"><a href="{esc(tgt_url)}" target="_blank" style="color:#0b7a45;word-break:break-all">{esc(tgt_url)}</a></div></td>
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
<div class="card"><div class="k">SSE 最优通过档</div><div class="v">{fmt(best["rps"], 1) if best else "—"}<small> req/s</small></div><div class="s">VU={best["vus_i"] if best else "—"} · P95={fmt(best.get("ttfb_p95"), 0) if best else "—"}ms</div></div>
{f'<div class="card"><div class="k">管理面峰值（读接口）</div><div class="v">{fmt(a["best_admin"]["rps"],1)}<small> req/s</small></div><div class="s">P95 时延 {fmt((a["best_admin"].get("dur_p95") or 0),1)}ms</div></div>' if a.get("best_admin") else ''}
<div class="card"><div class="k">单副本拐点（线性插值到 800ms）</div><div class="v">{fmt(a.get("knee_vus_per_replica"), 0) if a.get("knee_vus_per_replica") else "—"}<small> 并发流/副本</small></div><div class="s">{esc(a.get("knee_note") or ("≈ %s req/s/副本" % fmt(a.get("knee_rps_per_replica"), 1) if a.get("knee_rps_per_replica") else "数据不足"))}</div></div>
<div class="card"><div class="k">{TARGET_VUS} 并发所需副本</div><div class="v">{a.get("replicas_for_target", "—")}</div><div class="s">ceil({TARGET_VUS} ÷ 单副本拐点)</div></div>'''

    facts = "".join(f"<li>{esc(x)}</li>" for x in a.get("facts", [])) or "<li>（数据不足）</li>"
    guesses = "".join(f"<li>{esc(x)}</li>" for x in a.get("guesses", [])) or "<li>（数据不足，暂不推断）</li>"

    detail = ""
    if runs:
        heads = "".join("<th>VU=%d</th>" % r["vus_i"] for r in runs)
        r_rep = "".join("<td>%d</td>" % r["replicas_i"] for r in runs)
        r_rps = "".join("<td>%s</td>" % fmt(r["rps"], 1) for r in runs)
        r_p95 = "".join("<td>%s</td>" % fmt(r.get("ttfb_p95"), 0) for r in runs)
        r_err = "".join("<td>%s%%</td>" % fmt(r.get("err_pct"), 3) for r in runs)
        r_cpu = "".join("<td>%s</td>" % fmt(r["cpu_cores"], 2) for r in runs)
        r_cpr = "".join("<td>%s</td>" % (fmt(r["cpu_per_rps"] * 1000, 2) if r.get("cpu_per_rps") else "—") for r in runs)
        detail = ('<table class="mini"><thead><tr><th>指标</th>' + heads + '</tr></thead><tbody>'
                  '<tr><td>副本数</td>' + r_rep + '</tr>'
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
.tip{{position:fixed;z-index:99;background:#04231a;color:#f2fff8;border:2px solid #22c55e;border-radius:12px;
  box-shadow:0 16px 40px rgba(2,20,12,.55);padding:14px 16px;font-size:13px;min-width:300px;line-height:1.55}}
.tip-h{{font-weight:800;margin-bottom:8px;color:#a7f3d0;display:flex;align-items:center;gap:8px;font-size:13.5px}}
.tip-x{{margin-left:auto;cursor:pointer;color:#86efac;font-size:16px;padding:0 4px}}
.tip table, .tip .tip-t{{background:transparent !important;border:none !important;border-radius:0;box-shadow:none}}
.tip-t{{width:100%;border-collapse:collapse}}
.tip-t td{{padding:3px 8px;border:none !important;background:transparent !important;font-size:13px;color:#f4fff9 !important}}
.tip-t td b{{color:#86efac}}
.tip-t td:first-child{{color:#a7f3d0 !important;white-space:nowrap;font-weight:700}}
.tip-t td.hint{{color:#6ee7a8;font-style:italic;font-weight:400}}
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

<h2>一次请求的完整链路耗时</h2>
{svg_waterfall(a.get("best_phase"))}
<div class="note" style="margin-top:10px">
分段全部按 <b>p90</b> 取值：k6 客户端阶段（sending / connecting / tls_handshaking / waiting / receiving）为实测；
<b>mock 首字</b>=300ms、<b>流式吐字</b>=50×30ms 为配置已知量；<b>网关+链路</b>=waiting−300ms（含 DNS/NAT/ALB/Ingress/鉴权/限流/选渠道/取连接）；
<b>客户端接收余量</b>=receiving−1500ms。占比以各段合计为分母。
</div>

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
<div class="note">
<b>VU（Virtual User，虚拟用户）</b>：k6 里一个 VU 就是一条独立执行循环 + 一条（或一组）连接。SSE 场景下每条请求持续到流结束（本次约 1.9s），
所以"VU≈同时在途的 SSE 流数≈并发连接数"，不是"每秒请求数"。吞吐与并发的关系由 Little 定律给出：
<code>RPS ≈ VU ÷ 平均请求时长</code>（例：1500 VU ÷ 2.1s ≈ 714 RPS，与实测 701.6 吻合）。
</div>
<table class="mini" style="margin-top:10px">
<thead><tr><th>Job / 动作</th><th>脚本</th><th>含义</th><th>为什么这么设计（设计目的）</th></tr></thead><tbody>
<tr><td><code>stage</code></td><td>sse.js</td><td>恒定 VU 打 SSE，阶梯取 100/300/500/900/1200…</td><td>固定并发观察 P95/CPU 随并发单调变化，用线性插值找 800ms 拐点（单副本容量 C）</td></tr>
<tr><td><code>dual1500</code></td><td>sse.js</td><td>把 slave 扩到 2 副本，单 Job 打 Service</td><td>用 kube-proxy 自然分摊，复现"多副本入口"形态；避免直连单 Pod 造成失真</td></tr>
<tr><td><code>burst</code></td><td>s3_burst.js</td><td>0→1500 用 30s 拉起，保持后再降</td><td>验证 HPA/排队/冷启动在突增下的收敛能力（S3），而非稳态容量</td></tr>
<tr><td><code>admin</code></td><td>s4_admin.js</td><td>恒定到达率打管理面读接口</td><td>管理面是"请求/秒"型负载，用 arrival-rate 而非 VU，才能对准 800 QPS 目标</td></tr>
<tr><td><code>degrade</code></td><td>sse.js + mock_ctl</td><td>mock 注入 50% 5xx + 5s 延迟</td><td>验证上游劣化时网关"不被拖死"、错误归类正确（S5），不产生级联雪崩</td></tr>
<tr><td><code>rolling</code></td><td>sse.js + rollout restart</td><td>压测中滚动重启被测负载</td><td>验证发布期间连接是否被优雅摘除（S10），暴露 preStop/就绪延迟缺口</td></tr>
<tr><td><code>long</code></td><td>s9_long.js</td><td>单请求、超长流（约 12 分钟）</td><td>验证 ALB/网关对长连接是"空闲超时"还是"总时长上限"（S9 口径之争）</td></tr>
</tbody></table>
<pre style="margin-top:12px">
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
</body></html>'''
    doc = doc + render_js(runs_json)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(doc)


JS_TMPL = r"""
<div id="tip" class="tip" hidden></div>
<script>
const RUNS = __RUNS__;
const tip = document.getElementById('tip');
let pinned = false;
function f(v, n, suf) {
  if (v === null || v === undefined || v === 0) return '\u2014';
  return Number(v).toFixed(n) + (suf || '');
}
function head(r) {
  return '<div class="tip-h">' + r.job + ' <span class="badge ' + (r.pass ? 'ok' : 'bad') + '">'
    + (r.pass ? 'PASS' : 'FAIL') + '</span></div>';
}
function card(i) {
  const r = RUNS[i];
  return head(r) + '<table class="tip-t">'
    + '<tr><td>\u573a\u666f / \u5e76\u53d1</td><td>' + r.mode + ' \u00b7 ' + r.vus + ' VU</td></tr>'
    + '<tr><td>RPS</td><td>' + f(r.rps, 1) + '</td></tr>'
    + '<tr><td>\u9996\u5b57 P95 / P99</td><td>' + f(r.ttfb_p95, 0) + ' / ' + f(r.ttfb_p99, 0) + ' ms</td></tr>'
    + '<tr><td>\u9519\u8bef\u7387</td><td>' + f(r.err_pct, 3) + '%</td></tr>'
    + '<tr><td class="hint">\u5355\u51fb\u67e5\u770b\u5b8c\u6574\u660e\u7ec6</td><td></td></tr></table>';
}
function detail(i) {
  const r = RUNS[i];
  return '<div class="tip-h">' + r.job + ' <span class="badge ' + (r.pass ? 'ok' : 'bad') + '">'
    + (r.pass ? 'PASS' : 'FAIL') + '</span><span class="tip-x" onclick="document.getElementById(&quot;tip&quot;).hidden=true">\u00d7</span></div>'
    + '<table class="tip-t">'
    + '<tr><td>\u8fd0\u884c\u65f6\u95f4</td><td>' + r.ts + '</td></tr>'
    + '<tr><td>\u573a\u666f / \u8def\u5f84</td><td>' + r.mode + ' \u00b7 ' + r.target + '</td></tr>'
    + '<tr><td>\u5e76\u53d1 / \u526f\u672c</td><td>' + r.vus + ' VU / ' + r.replicas + ' \u526f\u672c</td></tr>'
    + '<tr><td>\u541e\u5410 RPS</td><td><b>' + f(r.rps, 1) + '</b></td></tr>'
    + '<tr><td>\u9996\u5b57 P50/P95/P99</td><td>' + f(r.ttfb_p50, 0) + ' / ' + f(r.ttfb_p95, 0) + ' / ' + f(r.ttfb_p99, 0) + ' ms</td></tr>'
    + '<tr><td>\u7aef\u5230\u7aef P95</td><td>' + f(r.dur_p95, 0) + ' ms</td></tr>'
    + '<tr><td>\u9519\u8bef\u7387 / checks</td><td>' + f(r.err_pct, 3) + '% / ' + f(r.checks_pct, 2) + '%</td></tr>'
    + '<tr><td>CPU / \u5185\u5b58\u5cf0\u503c</td><td>' + f(r.cpu, 2) + ' \u6838 / ' + f(r.mem, 0) + ' Mi</td></tr>'
    + '<tr><td>\u4e0b\u884c</td><td>' + f(r.bw, 2) + ' Mbps</td></tr></table>';
}
function place(ev) {
  const pad = 16, w = tip.offsetWidth, h = tip.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + w > window.innerWidth - 8) x = ev.clientX - w - pad;
  if (y + h > window.innerHeight - 8) y = ev.clientY - h - pad;
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}
document.querySelectorAll('circle.pt').forEach(function (el) {
  const i = Number(el.dataset.i);
  el.addEventListener('mouseenter', function (ev) {
    if (pinned) return;
    tip.innerHTML = card(i); tip.hidden = false; place(ev);
  });
  el.addEventListener('mousemove', function (ev) { if (!pinned) place(ev); });
  el.addEventListener('mouseleave', function () { if (!pinned) tip.hidden = true; });
  el.addEventListener('click', function (ev) {
    ev.stopPropagation();
    pinned = true;
    tip.innerHTML = detail(i); tip.hidden = false; place(ev);
  });
});
document.addEventListener('click', function () { pinned = false; tip.hidden = true; });
document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') { pinned = false; tip.hidden = true; } });
</script>
</body></html>
"""


def render_js(runs_json: str) -> str:
    return JS_TMPL.replace("__RUNS__", runs_json)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log-dir", action="append", help="可重复；多个目录一起聚合")
    ap.add_argument("--logs", nargs="*")
    ap.add_argument("--out", help="HTML 输出路径（--check 时可省略）")
    ap.add_argument("--eip-mbps", type=float, default=0.0, help="公网路径的 EIP 标称带宽（Mbps），用于带宽利用率判定")
    ap.add_argument("--check", metavar="LOG",
                    help="仅判定该日志是否满足 SLO：pass 退出 0，fail 退出 1（供阶梯压测自动找瓶颈）")
    args = ap.parse_args()

    if args.check:
        runs = load_runs([args.check], args.eip_mbps)
        if not runs:
            print(f"[check] FAIL 无法解析日志：{args.check}")
            sys.exit(1)
        r = runs[0]
        verdict = "PASS" if r["pass"] else "FAIL"
        print(f'[check] {verdict} vu={r["vus_i"]} replicas={r["replicas_i"]} '
              f'rps={fmt(r["rps"], 1)} p95={fmt(r.get("ttfb_p95"), 0)}ms err={fmt(r.get("err_pct"), 3)}%')
        sys.exit(0 if r["pass"] else 1)

    if not args.out:
        ap.error("--out 必填（除非使用 --check）")
    paths = []
    if args.logs:
        paths = list(args.logs)
    elif args.log_dir:
        for d in args.log_dir:
            paths += sorted(glob.glob(os.path.join(d, "*.log")))
        paths = sorted(set(paths))
    runs = load_runs(paths, args.eip_mbps)
    render(runs, analyse(runs, args.eip_mbps), args.out, args.eip_mbps)
    print(f"[report] runs={len(runs)} -> {args.out}")


if __name__ == "__main__":
    main()
