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
    out["dropped_iterations"] = sum(int(n) for n in re.findall(r"dropped_iterations\.+:\s*(\d+)\s", text))
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
    for key, metric in (("checks", "checks"), ("complete", "sse_complete")):
        counts = [(int(p), int(n)) for p, n in re.findall(
            re.escape(metric) + r"\.+:\s*[\d.]+%\s+(\d+) out of (\d+)", text)]
        out[key + "_counts"] = counts
        total = sum(n for _, n in counts)
        if total:
            out[key + "_pct"] = sum(p for p, _ in counts) / total * 100.0
    m = re.search(pats["data_recv"], text)
    if m:
        out["data_mb"] = float(m.group(1))
    rates = re.findall(pats["data_rate"], text)
    if rates:
        # k6 数据单位按十进制换算（1 MB = 1000 kB），各摘要相加后转 Mbps
        kbps = sum(float(v) * (1000 if u == "M" else 1) for v, u in rates)
        out["data_mbps"] = kbps * 8 / 1000.0
    m = re.search(pats["vus_max"], text)
    if m:
        out["vus_max"] = int(m.group(1))
    out["request_counts"] = [int(n) for n, _ in reqs]
    out["error_counts"] = [(int(row[1]), int(row[2])) for row in fails]
    trends = {}
    current = None
    for line in text.splitlines():
        named = re.search(r"\b(http_req_[a-z_]+)(?:\s*\{([^}]+)\})?\.+:\s*(.*)", line)
        if named:
            current = named.group(1)
            tag, values = named.group(2), named.group(3)
        else:
            tagged = re.search(r"\{\s*([^}]+)\s*\}\.+:\s*(.*)", line)
            if not tagged or current is None:
                current = None
                continue
            tag, values = tagged.groups()
        p95 = re.search(r"p\(95\)=(\S+)", values)
        if p95:
            key = current + ("{" + tag.replace(" ", "") + "}" if tag else "")
            try:
                value = _num(p95.group(1))
            except ValueError:
                continue
            if math.isfinite(value) and value >= 0:
                trends.setdefault(key, []).append(value)
    out["p95_values"] = trends
    admin = trends.get("http_req_duration{type:admin}")
    if admin:
        out["admin_p95"] = max(admin)
    return out


STEADY_MODES = {"clusterip", "clusterip-dual", "clusterip-shard", "public-url",
                "clusterip-arrival", "public-arrival"}
# 开环档的横轴是「目标 rps」而不是 VU ⇒ 不参与按 VU 的容量拟合，但沿用同一套 SLO 判定
ARRIVAL_MODES = {"clusterip-arrival", "public-arrival"}
CAPACITY_MODES = STEADY_MODES - {"public-url"} - ARRIVAL_MODES


def evaluate_run(run: dict, text: str) -> None:
    """缺失证据不等于 SLO 失败；每个分片必须独立满足相同脚本阈值。"""
    run["pass"] = False
    run["verdict"] = "INCOMPLETE"
    run["failure_reasons"] = []
    run["evidence_complete"] = False
    mode = run.get("mode", "")
    if not run.get("metadata_valid", True):
        run["verdict_reason"] = "元数据缺失或格式错误"
        return
    if any(int(rc) != 0 for rc in re.findall(r"(?:remote_rc|runner_rc)=(-?\d+)", text)):
        run["verdict_reason"] = "执行失败，不能用作容量边界"
        return
    if mode not in STEADY_MODES | {"burst", "admin"}:
        run["verdict"] = "UNASSESSED"
        run["verdict_reason"] = "该场景未定义验收标准，仅展示观测值"
        return
    requests = run["request_counts"]
    errors = run["error_counts"]
    count = len(requests)
    expected = run.get("shards", "")
    if mode == "clusterip-shard" and not expected:
        jobs = re.fullmatch(r"k6-shard-0\.\.(\d+)", run.get("job", ""))
        expected = str(int(jobs.group(1)) + 1) if jobs else "unknown"
    if expected and (not expected.isdigit() or int(expected) != count):
        run["verdict_reason"] = "分片摘要数量不完整"
        return
    if (not requests or any(n <= 0 for n in requests) or len(errors) != count
            or any(n != requests[i] or not 0 <= e <= n for i, (e, n) in enumerate(errors))):
        run["verdict_reason"] = "请求数或失败计数缺失/不一致"
        return
    exit_codes = []
    if run.get("summary_schema") == "2":
        exit_codes = run.get("k6_exit_codes", "").split(",")
        if len(exit_codes) != count or any(code not in {"0", "99"} for code in exit_codes):
            run["verdict_reason"] = "k6 未正常结束或退出状态缺失"
            return
    is_admin = mode == "admin"
    error_limit = 0.01 if mode in {"burst", "admin"} else SLO_ERR_RATE
    latency_limit = 1000.0 if is_admin else (1500.0 if mode == "burst" else SLO_TTFB_P95)
    trends = run["p95_values"]
    metric = "http_req_duration{type:admin}" if is_admin else "http_req_waiting{type:sse}"
    latencies = trends.get(metric)
    if latencies is None and not is_admin:
        latencies = trends.get("http_req_waiting", [])
    if not latencies or len(latencies) != count:
        run["verdict_reason"] = "场景 P95 指标缺失或分片不完整"
        return
    if not is_admin:
        run["ttfb_p95"] = max(latencies)
    reasons = run["failure_reasons"]
    if any(e / n >= error_limit for e, n in errors):
        reasons.append("error_rate")
    if any(v >= latency_limit for v in latencies):
        reasons.append("latency")
    if (is_admin or mode in ARRIVAL_MODES) and run["dropped_iterations"] > 0:
        # 开环档的 dropped 表示客户端发不出目标 rps，≠ 服务端失败；仍单列原因便于区分
        reasons.append("dropped_iterations")
    integrity = run["checks_counts"] if is_admin else run["complete_counts"]
    integrity_valid = (len(integrity) == count
                       and all(n > 0 and 0 <= p <= n for p, n in integrity)
                       and (is_admin or all(n == requests[i] for i, (_, n) in enumerate(integrity))))
    if integrity_valid and any((n - p) / n >= error_limit for p, n in integrity):
        reasons.append("checks" if is_admin else "integrity")
    # 旧日志（无 summary_schema）：旧脚本每请求 2 个 checks（status 200 + body 含 [DONE]）。
    # 计数能逐请求核对时给出“旧口径”判定，但证据等级低于新版，不参与容量拟合。
    legacy = (not is_admin and not run["complete_counts"]
              and run.get("summary_schema") != "2"
              and len(run["checks_counts"]) == count
              and all(n > 0 and 0 <= p <= n for p, n in run["checks_counts"])
              and all(n == requests[i] * 2 for i, (_, n) in enumerate(run["checks_counts"])))
    if legacy and any((n - p) / n >= error_limit for p, n in run["checks_counts"]):
        reasons.append("integrity")
    run["evidence_complete"] = integrity_valid and run.get("summary_schema") == "2" and not legacy
    run["evidence"] = "legacy" if legacy else ("exact" if run["evidence_complete"] else "insufficient")
    if legacy:
        run["verdict"] = "FAIL" if reasons else "PASS"
        run["pass"] = not reasons
        run["verdict_reason"] = (", ".join(reasons) if reasons else
                                 "旧口径通过：checks 证明 HTTP 200 且响应含 [DONE]；无 finish_reason/退出码证据")
        return
    if not run["evidence_complete"]:
        run["verdict_reason"] = "缺少新版完整流/业务成功计数或执行状态，旧 checks 不能证明完整性"
        if reasons:
            run["verdict"] = "FAIL"
            run["verdict_reason"] = ", ".join(reasons) + "；" + run["verdict_reason"]
        return
    if not reasons and "99" in exit_codes:
        run["evidence_complete"] = False
        run["verdict_reason"] = "k6 阈值退出与摘要不一致，需核对完整日志"
        return
    if mode == "clusterip-shard":
        run["evidence_complete"] = False
        if not reasons:
            run["verdict"] = "UNASSESSED"
            run["verdict_reason"] = "各分片阈值通过，但缺少共同运行窗口证据，不能验证总并发"
            return
    run["verdict"] = "FAIL" if reasons else "PASS"
    run["pass"] = not reasons
    run["verdict_reason"] = ", ".join(reasons) if reasons else "脚本阈值通过"


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
            with open(p, encoding="utf-8", errors="replace") as source:
                text = source.read()
        except OSError:
            continue
        meta = parse_meta(text)
        if not meta:
            continue
        run = dict(meta)
        run.update(parse_summary(text))
        run.setdefault("rps", 0.0)
        required = ("job", "ts", "mode", "target", "base", "vus", "replicas", "dur")
        run["metadata_valid"] = all(meta.get(key) for key in required)
        for key in required:
            run.setdefault(key, "")
        for source_key, key, default in (("vus", "vus_i", "0"), ("replicas", "replicas_i", "0"),
                                         ("cpu_peak_m", "cpu_cores", "0"), ("mem_peak_mi", "mem_mi", "0")):
            try:
                value = float(meta.get(source_key, default))
                if not math.isfinite(value) or value < 0:
                    raise ValueError("invalid numeric metadata")
                if key in {"vus_i", "replicas_i"}:
                    # 开环（constant-arrival-rate）没有 VU 轴 ⇒ 允许 vus=0；其它场景仍必须 >0
                    arrival = str(meta.get("method", "")).startswith("constant-arrival")
                    if not value.is_integer() or value < 0 or (value == 0 and not (key == "vus_i" and arrival)):
                        raise ValueError("invalid topology metadata")
                    value = int(value)
                run[key] = value / 1000 if key == "cpu_cores" else value
            except ValueError:
                run["metadata_valid"] = False
                run[key] = 1 if key == "replicas_i" else 0
        duration = meta.get("dur", "")
        if re.fullmatch(r"(?:\d+(?:\.\d+)?(?:ms|s|m|h))+", duration):
            run["dur_s"] = sum(float(n) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[unit]
                               for n, unit in re.findall(r"(\d+(?:\.\d+)?)(ms|s|m|h)", duration))
        else:
            run["dur_s"] = 0
        if not math.isfinite(run["dur_s"]) or run["dur_s"] <= 0:
            run["metadata_valid"] = False
        run["source"] = os.path.basename(p)
        for k, metric in PHASE_KEYS.items():
            v = parse_phase_p90(text, metric)
            if v is not None:
                run[k] = v
        evaluate_run(run, text)
        # 派生量
        if run["rps"] > 0:
            run["cpu_per_rps"] = run["cpu_cores"] / run["rps"]
            run["cpu_h_per_mreq"] = run["cpu_per_rps"] * 1e6 / 3600.0
            run["reqs_per_core_h"] = (run["rps"] * 3600.0) / run["cpu_cores"] if run["cpu_cores"] > 0 else 0
            run["rps_per_replica"] = run["rps"] / run["replicas_i"]
            run["vus_per_replica"] = run["vus_i"] / run["replicas_i"]
        if run.get("dur_avg"):
            run["little_vus"] = run["rps"] * run["dur_avg"] / 1000.0
        # 只有真正经过 EIP 的公网路径才谈 EIP 利用率；ClusterIP 内网流量不计入。
        if eip_mbps and run.get("data_mbps") and run.get("mode") == "public-url":
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
    # 开环档没有 VU 轴，不能参与「最优通过档 / 容量」这类按 VU 读的卡片与图表
    sse = [r for r in passing if r.get("mode") in STEADY_MODES and r.get("mode") not in ARRIVAL_MODES]
    adm = [r for r in passing if r.get("mode") == "admin"]
    a["best"] = max(sse, key=lambda r: r["rps"]) if sse else None
    a["best_admin"] = max(adm, key=lambda r: r["rps"]) if adm else None
    # 优先取有完整阶段数据（phase_receiving）的最优通过档用于 waterfall；
    # 若无 phase_receiving 则退而用有任意阶段数据的，再退而用 best。
    phased = [r for r in sse if r.get("phase_receiving")]
    if not phased:
        phased = [r for r in sse if any(r.get(k) for k in ("phase_waiting", "phase_duration", "phase_sending"))]
    a["best_phase"] = max(phased, key=lambda r: r["rps"]) if phased else a["best"]
    a["worst"] = max(runs, key=lambda r: r["vus_i"])
    cap_runs = [r for r in runs if r.get("mode") in CAPACITY_MODES]
    config_fields = ("mode", "target", "base", "images", "dur", "load_config", "mock_config", "token_mode")
    grouped = {}
    for r in cap_runs:
        key = tuple(r.get(k, "") for k in config_fields) + (r["replicas_i"], r.get("shards", "1"))
        grouped.setdefault(key, []).append(r)
    groups = []
    for group_runs in grouped.values():
        first = group_runs[0]
        # “读不到 / 中途变化 / 各副本不一致”都等于没有同一条件证据，不可当成分组键。
        unknown_cfg = {"", "unavailable", "mixed", "changed"}
        complete = all(first.get(k) and first.get(k) not in unknown_cfg for k in config_fields)
        accepted = [r for r in group_runs if r["pass"]]
        rejected = [r for r in group_runs if r.get("verdict") == "FAIL"]
        best = max(accepted, key=lambda r: r["vus_i"]) if accepted else None
        fail = min(rejected, key=lambda r: r["vus_i"]) if rejected else None
        contradictory = bool(best and fail and fail["vus_i"] <= best["vus_i"])
        missing = any(not r.get("evidence_complete") for r in group_runs)
        target_verified = any(r["vus_i"] == TARGET_VUS for r in accepted) and not contradictory and not missing
        group = {
            "runs": group_runs, "config_complete": complete, "best": best, "first_fail": fail,
            "target_verified": target_verified, "knee_vus": None, "knee_rps": None,
            "note": "仅有实测通过下限；无有效失败档，不外推",
        }
        if not complete:
            group["note"] = "配置证据缺失（镜像/负载/mock/时长等），禁止拟合"
        elif missing:
            group["note"] = "存在不完整运行，补齐数据后再估计边界"
        elif contradictory:
            group["note"] = "低档失败或同档结果冲突，需复测，不拟合"
        elif not best:
            group["note"] = "无通过档，不能估计合格容量"
        elif fail:
            # 重复实验取通过侧和失败侧较差的延迟，避免挑选有利样本。
            lower = max((r for r in accepted if r["vus_i"] == best["vus_i"]), key=lambda r: r["ttfb_p95"])
            upper_runs = [r for r in rejected if r["vus_i"] == fail["vus_i"]]
            upper = max(upper_runs, key=lambda r: r["ttfb_p95"])
            y1, y2 = lower["ttfb_p95"], upper["ttfb_p95"]
            if (all(r["failure_reasons"] == ["latency"] for r in upper_runs)
                    and y1 < SLO_TTFB_P95 <= y2):
                ratio = (SLO_TTFB_P95 - y1) / (y2 - y1)
                group["knee_vus"] = lower["vus_i"] + ratio * (upper["vus_i"] - lower["vus_i"])
                group["knee_rps"] = lower["rps"] + ratio * (upper["rps"] - lower["rps"])
                group["note"] = "同配置延迟边界插值，仅为估计，不是实测通过容量"
            else:
                group["note"] = "失败涉及错误率或流完整性，不以延迟插值代替容量判定"
        groups.append(group)
    a["capacity_groups"] = groups
    a["verified_replicas"] = sorted({g["runs"][0]["replicas_i"] for g in groups if g["target_verified"]})
    a["replicas_seen"] = sorted({r["replicas_i"] for r in runs})
    a["methods"] = sorted({r.get("method") for r in runs if r.get("method")})
    # 目标档未实测时给出“推测副本数”，明确标注依据与“未实测”。
    a["target_estimate"] = None
    if not a["verified_replicas"]:
        best_per_rep = {}
        for r in runs:
            if r["pass"] and r.get("evidence") == "exact" and r["vus_i"] > 0:
                per = r["vus_i"] / max(1, r["replicas_i"])
                best_per_rep[r["replicas_i"]] = max(best_per_rep.get(r["replicas_i"], 0), per)
        if best_per_rep:
            base_rep, per = max(best_per_rep.items(), key=lambda kv: kv[1])
            a["target_estimate"] = {
                "replicas": math.ceil(TARGET_VUS / per),
                "per_replica": per,
                "basis_replicas": base_rep,
                "basis_vus": int(per * base_rep),
            }
    # 2 副本卡片：优先用**实测**的 2 副本通过档；只有 1 副本数据时按 ×2 折算并明确标注
    a["two_rep"] = None
    two = [r for r in sse if r["replicas_i"] == 2 and r["vus_i"] > 0]
    one = [r for r in sse if r["replicas_i"] == 1 and r["vus_i"] > 0]
    if two:
        b = max(two, key=lambda r: r["rps"])
        a["two_rep"] = {"measured": True, "rps": b["rps"], "vus": b["vus_i"],
                        "p95": b.get("ttfb_p95"), "cpu": b.get("cpu_cores") or 0,
                        "mem": b.get("mem_mi") or 0, "base_vus": b["vus_i"], "base_rep": 2}
    elif one:
        b = max(one, key=lambda r: r["rps"])
        a["two_rep"] = {"measured": False, "rps": b["rps"] * 2, "vus": b["vus_i"] * 2,
                        "p95": b.get("ttfb_p95"), "cpu": (b.get("cpu_cores") or 0) * 2,
                        "mem": (b.get("mem_mi") or 0) * 2, "base_vus": b["vus_i"], "base_rep": 1}
    facts, guesses = [], []
    for i, group in enumerate(groups, 1):
        if group["best"]:
            facts.append(f"容量组 {i}：实测通过最高 VU={group['best']['vus_i']}（不代表容量上限）")
        if group["first_fail"]:
            f = group["first_fail"]
            facts.append(f"容量组 {i}：VU={f['vus_i']} 未通过，原因：{f['verdict_reason']}")
    internal = [r for r in runs if r.get("mode") != "public-url" and r.get("data_mbps")]
    if internal:
        a["internal_bw_peak"] = max(r["data_mbps"] for r in internal)
    public = [r for r in runs if r.get("mode") == "public-url" and r.get("data_mbps")]
    if eip_mbps and public:
        peak = max(r["data_mbps"] for r in public)
        a["eip_mbps"] = eip_mbps
        a["bw_peak"] = peak
        a["bw_util"] = peak / eip_mbps
        facts.append(f"公网路径下行峰值 {peak:.2f} Mbps（EIP 标称 {eip_mbps:.0f} Mbps，利用率 {peak / eip_mbps * 100:.0f}%）")
        if peak >= 0.85 * eip_mbps:
            guesses.append(f"公网下行利用率 ≥85% ⇒ 可能先撞 NAT→EIP {eip_mbps:.0f}Mbps；"
                           "需结合 EIP 实际监控确认，内网档位不受该限制")
    elif eip_mbps:
        a["bw_note"] = "本报告无公网路径运行，未计算 EIP 利用率"
    if a["best"]:
        b = a["best"]
        facts.append(f"最优通过档 VU={b['vus_i']}：RPS={b['rps']:.1f}、P95={b.get('ttfb_p95', 0):.0f}ms、错误率={b.get('err_pct', 0):.3f}%")
        if b.get("cpu_cores"):
            facts.append(f"该档 CPU 峰值 {b['cpu_cores']:.2f} 核，折合每千 RPS {b['cpu_per_rps'] * 1000:.3f} 核·千RPS⁻¹")
        if b.get("mem_mi"):
            facts.append(f"该档内存峰值 {b['mem_mi']:.0f} MiB（全副本合计），"
                         f"折合每千 RPS {b['mem_mi'] / b['rps'] * 1000:.1f} MiB·千RPS⁻¹")
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


def badge(verdict: str, legacy: bool = False) -> str:
    cls = {"PASS": "ok", "FAIL": "bad"}.get(verdict, "pending")
    label = {"INCOMPLETE": "数据不完整", "UNASSESSED": "待评估"}.get(verdict, verdict)
    if legacy and verdict == "PASS":
        label = "PASS·旧口径"
    return f'<span class="badge {cls}">{esc(label)}</span>'


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


def mock_timing(run: dict) -> tuple[float, float] | None:
    """从采集到的 mock 配置取首字延迟与流式吐字总时长；旧日志/不可信值返回 None。"""
    cfg = run.get("mock_config") or ""
    if cfg in ("", "unavailable", "mixed", "changed"):
        return None
    parts = dict(p.split("=", 1) for p in cfg.split(",") if "=" in p)
    try:
        return (float(parts["first_token_delay_ms"]),
                float(parts["tokens_per_response"]) * float(parts["token_interval_ms"]))
    except (KeyError, ValueError):
        return None


def svg_stages(best: dict | None) -> str:
    """k6 客户端阶段 P90 参考图。

    这些 P90 来自不同请求分布（连接复用、TLS 复用、流式接收各不相同），相加并不等于“一次请求的完整链路”；
    网关内部耗时也无法仅凭汇总值分离，需要 trace/SLS。因此这里只并列展示，不求和、不算占比。
    """
    if not best:
        return ""
    stages = [
        ("TCP 连接", best.get("phase_connecting"), "http_req_connecting p90（含建连阻塞；DNS 未单独采集）"),
        ("TLS 握手", best.get("phase_tls"), "http_req_tls_handshaking p90（复用连接时为 0）"),
        ("请求发送", best.get("phase_sending"), "http_req_sending p90"),
        ("等待首字节", best.get("phase_waiting"), "http_req_waiting p90（含网关处理与上游首 token）"),
        ("接收响应", best.get("phase_receiving"), "http_req_receiving p90（含流式吐字与传输）"),
        ("总时长", best.get("phase_duration") or best.get("dur_p90"), "http_req_duration p90"),
    ]
    timing = mock_timing(best)
    if timing:
        first, stream = timing
        wait = best.get("phase_waiting") or 0.0
        stages += [
            ("mock 首字（配置）", first, "mock_config.first_token_delay_ms"),
            ("mock 流式吐字（配置）", stream, "tokens_per_response × token_interval_ms"),
            ("网关等其余环节（估算）", max(0.0, wait - first), "差值：waiting p90 − mock 首字"),
        ]
    rows = [(name, float(v), src) for name, v, src in stages if isinstance(v, (int, float))]
    if not rows:
        return '<div class="note">本档没有可用于阶段分解的客户端指标。</div>'
    peak = max(v for _, v, _ in rows) or 1.0
    W, L, R, gap = 760, 16, 16, 10
    bar_h, label_w, bar_max = 16, 210, 400
    H = gap + len(rows) * (bar_h + gap)
    bars = ""
    y = gap
    for name, value, _ in rows:
        width = max(2.0, value / peak * bar_max)
        bars += (f'<text x="{L}" y="{y + bar_h - 4}" font-size="10.5" fill="#20463a">{esc(name)}</text>'
                 f'<rect x="{L + label_w}" y="{y}" width="{width:.1f}" height="{bar_h}" fill="#12b76a" rx="2"/>'
                 f'<text x="{L + label_w + width + 6:.1f}" y="{y + bar_h - 4}" font-size="10.5" fill="#20463a">{value:.1f} ms</text>')
        y += bar_h + gap
    mode = best.get("mode", "")
    tgt = best.get("target", "") or best.get("base", "") or ""
    if "public" in mode or "http" in tgt:
        path_note = "公网路径（k6→NAT→EIP→ALB→Ingress→Pod）"
    elif "clusterip" in mode or (tgt and not tgt.startswith("http")):
        path_note = "内网直连路径（k6 Pod→kube-proxy→Pod）"
    else:
        path_note = mode
    table = "".join(f'<tr><td>{esc(n)}</td><td>{v:.1f} ms</td><td class="src">{esc(s)}</td></tr>'
                    for n, v, s in rows)
    timing_note = "" if timing else "本档未采集到可信的 mock 配置，因此不给出 mock 首字/吐字参考，也不做差值推算。"
    return f'''<figure class="chart"><figcaption>阶段耗时参考（{esc(short_label(best))}）：k6 客户端各指标 P90，来自不同请求分布，<b>不可相加</b></figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="k6 客户端阶段耗时参考">
{bars}
</svg></figure>
<div class="note" style="margin-top:6px">链路路径：<b>{esc(path_note)}</b>（{esc(tgt)}）· VU={best.get("vus_i","")} · {esc(best.get("ts","")[:16])}</div>
<table class="mini" style="margin-top:10px"><thead><tr><th>指标</th><th>P90</th><th>数据来源</th></tr></thead><tbody>{table}</tbody></table>
<div class="note" style="margin-top:8px">{timing_note}
「网关等其余环节」只在 mock 配置可信时按 waiting−首字估算，仍包含 NAT/ALB/Ingress/鉴权/连接池等；要真正拆分需接 trace/SLS（未做，不填假数据）。</div>'''


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
<td>{fmt(r.get("ttfb_med"), 0)}</td>
<td><b>{fmt(r.get("ttfb_p95"), 0)}</b></td>
<td>{fmt(r.get("ttfb_p99"), 0)}</td>
<td>{fmt(r.get("admin_p95") if r["mode"] == "admin" else r.get("dur_p95"), 0)}</td>
<td>{fmt(r.get("err_pct"), 3)}%</td>
<td>{fmt(r.get("complete_pct") if r["mode"] != "admin" else r.get("checks_pct"), 3)}%</td>
<td>{fmt(r["cpu_cores"], 2)}</td>
<td>{fmt(r["mem_mi"], 0)}</td>
<td>{fmt(r.get("data_mbps"), 2)}</td>
<td>{badge(r["verdict"], r.get("evidence") == "legacy")}<div class="sub">{esc(r["verdict_reason"])}</div></td>
</tr>'''
    best = a.get("best")
    replicas_seen = " / ".join(str(n) for n in a.get("replicas_seen", [])) or "—"
    methods = "、".join(a.get("methods", [])) or "—"
    tr = a.get("two_rep")
    if tr:
        tag = "实测" if tr["measured"] else "推测"
        sub = (f"VU={tr['vus']} · P95={fmt(tr['p95'], 0)}ms · CPU {fmt(tr['cpu'], 2)} 核 · "
               f"内存 {fmt(tr['mem'], 0)} MiB")
        if not tr["measured"]:
            sub += f"（按 1 副本 VU={tr['base_vus']} ×2 折算）"
        card_two = (f'<div class="card"><div class="k">2 副本最优通过档（{tag}）</div>'
                    f'<div class="v">{fmt(tr["rps"], 1)}<small> req/s</small></div>'
                    f'<div class="s">{sub}</div></div>')
    else:
        card_two = ('<div class="card"><div class="k">2 副本最优通过档</div><div class="v">无通过档</div>'
                    '<div class="s">没有可用于折算的通过记录</div></div>')
    best_res = (f"CPU {best['cpu_cores']:.2f} 核 · 内存 {best['mem_mi']:.0f} MiB") if best else ""
    cards = f'''
<div class="card"><div class="k">本次运行数</div><div class="v">{a["n"]}</div><div class="s">由所选日志聚合</div></div>
<div class="card"><div class="k">副本数量</div><div class="v">{replicas_seen}</div><div class="s">本报告内出现的副本配置</div></div>
<div class="card"><div class="k">压测方法</div><div class="v" style="font-size:20px">{esc(methods)}</div><div class="s">k6 executor / 场景类型</div></div>
<div class="card"><div class="k">SSE 最优通过档</div><div class="v">{fmt(best["rps"], 1) if best else "无通过档"}<small>{" req/s" if best else ""}</small></div><div class="s">VU={best["vus_i"] if best else "—"} · P95={fmt(best.get("ttfb_p95"), 0) if best else "—"}ms{f" · {best_res}" if best_res else ""}</div></div>
{f'<div class="card"><div class="k">管理面最优通过档（读接口）</div><div class="v">{fmt(a["best_admin"]["rps"],1)}<small> req/s</small></div><div class="s">管理面 P95 {fmt(a["best_admin"].get("admin_p95"),1)}ms</div></div>' if a.get("best_admin") else ''}
<div class="card"><div class="k">可比容量分组</div><div class="v">{len(a.get("capacity_groups", []))}</div><div class="s">固定路径、副本及配置；分别展示实测与估计</div></div>
{card_two}'''
    capacity_rows = ""
    for i, group in enumerate(a.get("capacity_groups", []), 1):
        first = group["runs"][0]
        config = " · ".join(f"{k}={first.get(k) or '缺失'}" for k in ("images", "dur", "load_config", "mock_config"))
        capacity_rows += f'''<tr><td>{i} · {esc(first.get("mode", ""))}<div class="sub">{esc(first.get("target", ""))} · {first["replicas_i"]} 副本<br>{esc(config)}</div></td>
<td>{fmt(group["best"]["vus_i"], 0) if group["best"] else "无通过档"}</td>
<td>{fmt(group["first_fail"]["vus_i"], 0) if group["first_fail"] else "—"}</td>
<td>{fmt(group["knee_vus"], 0)} VU / {fmt(group["knee_rps"], 1)} req/s</td>
<td>{esc(group["note"])}</td></tr>'''

    stage_run = a.get("best_phase")
    stages_section = ""
    if stage_run:
        stages_section = ('<h2>阶段耗时参考（不是逐请求链路）</h2>' + svg_stages(stage_run)
                          + '<div class="note" style="margin-top:10px">'
                            '各指标均取 <b>p90</b>，但来自不同请求分布：连接可能复用、TLS 可能复用、'
                            '接收阶段覆盖整段流式响应。因此这些数值<b>不能相加</b>成“一次请求的完整耗时”，'
                            '也不据此计算占比。mock 首字/吐字只在本次采集到可信 <code>mock_config</code> 时展示，'
                            '否则不做差值推算。</div>')
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
        "dur_p95": r.get("dur_p95"), "err_pct": r.get("err_pct"),
        "admin_p95": r.get("admin_p95"), "complete_pct": r.get("complete_pct"),
        "checks_pct": r.get("checks_pct"), "cpu": r.get("cpu_cores", 0),
        "mem": r.get("mem_mi", 0), "bw": r.get("data_mbps", 0), "pass": bool(r.get("pass")),
        "verdict": r["verdict"], "verdict_reason": r["verdict_reason"],
        "evidence": r.get("evidence"),
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
<thead><tr><th>Job / 时间</th><th>VU</th><th>路径</th><th>RPS</th><th>P50 首字</th><th>P95 首字</th><th>P99 首字</th><th>P95 端到端（管理面按标签）</th><th>错误率</th><th>完整流成功率 / 管理面 checks</th><th>CPU 峰值(核·全副本合计)</th><th>内存峰值(Mi·全副本合计)</th><th>下行(Mbps)</th><th>判定</th></tr></thead>
<tbody>{rows or "<tr><td colspan=14>无数据</td></tr>"}</tbody>
</table>
<div class="lim">首字使用 k6 <code>http_req_waiting</code>（TTFB 代理）。稳态：P95 &lt; {SLO_TTFB_P95:.0f}ms、请求失败率 &lt; {SLO_ERR_RATE*100:.2f}%、完整流成功率 &gt; 99.95%；突发：P95 &lt; 1500ms、失败率 &lt; 1%、完整流成功率 &gt; 99%；管理面：标签端到端 P95 &lt; 1000ms、失败率 &lt; 1%、业务成功 checks &gt; 99%、丢弃迭代为 0。CPU/内存为采样窗口内同一时刻全副本合计峰值；旧日志只采首个 Pod，数值偏小且不可用于成本换算。旧日志（无 <code>summary_schema</code>）当 checks 计数按每请求 2 项可逐请求核对且全部在错误预算内时，标为 <b>PASS·旧口径</b>：只证明 HTTP 200 且响应含 <code>[DONE]</code>，不证明 <code>finish_reason</code>，也不参与容量拟合；其余缺证据情况仍为“数据不完整”。新日志须有完整流/业务成功计数及 k6 退出状态。故障注入、滚动及长流待定义专属标准；分片缺少共同运行窗口证据时待评估。突发汇总阈值通过不代表已验证恢复时间。</div>

<h2>可比配置容量边界</h2>
<table><thead><tr><th>分组 / 配置</th><th>实测最高通过 VU</th><th>最小失败 VU</th><th>延迟边界估计（总量）</th><th>说明</th></tr></thead>
<tbody>{capacity_rows or '<tr><td colspan="5">无可用于稳态容量分析的内网运行</td></tr>'}</tbody></table>
<div class="lim">镜像、负载或 mock 配置未知时只展示观测结果，不插值、不外推；不同副本不得按每副本并发混合拟合。</div>

<h2>趋势</h2>
{svg_line(runs, "ttfb_p95", "P95 首字延迟 vs 并发", "ms", SLO_TTFB_P95)}
{svg_line(runs, "rps", "吞吐 RPS vs 并发", "req/s")}

{stages_section}

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
{TARGET_VUS} VU 目标只有相同负载下的实际通过运行才能验证，插值不能替代验收，也不能证明最少副本数。
</div>

<h2>公式与口径（完整）</h2>
<div class="note">
<b>VU（Virtual User，虚拟用户）</b>：k6 里一个 VU 就是一条独立执行循环 + 一条（或一组）连接。SSE 场景下每条请求持续到流结束（本次约 1.9s），
所以"VU≈同时在途的 SSE 流数≈并发连接数"，不是"每秒请求数"。吞吐与并发的关系由 Little 定律给出：
<code>RPS ≈ VU ÷ 平均请求时长</code>（例：1500 VU ÷ 2.1s ≈ 714 RPS，与实测 701.6 吻合）。
</div>
<table class="mini" style="margin-top:10px">
<thead><tr><th>Job / 动作</th><th>脚本</th><th>含义</th><th>为什么这么设计（设计目的）</th></tr></thead><tbody>
<tr><td><code>stage</code></td><td>sse.js</td><td>恒定 VU 打 SSE，单档运行（如 1500 VU）</td><td>固定并发观察 P95/CPU/完整流，用于单点验收</td></tr>
<tr><td><code>sweep</code></td><td>sse.js</td><td>先 scale 到指定副本，再从 start（默认 400）每档 +step（默认 100）扫到首个失败</td><td>同一路径/副本下逐档找通过上限；每组结束打印本组最优通过档</td></tr>
<tr><td><code>shard</code></td><td>sse.js</td><td>多个 k6 Job 分摊总 VU（如 2×750）</td><td>排除单客户端 CPU/连接限制，验证是否由客户端先行饱和</td></tr>
<tr><td><code>arrival</code></td><td>sse_arrival.js</td><td>恒定到达率（如 1500 rps），不受单请求耗时反压</td><td>测真实 QPS 能力；需要按 RATE×耗时为并发预留 VU</td></tr>
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

5) 稳态 SLO 余量     margin = 1 − TTFB_p95 / 800ms
6) 同配置延迟边界估计（不是实测通过容量）
   VU_knee = VU_pass + (800 − P95_pass) / (P95_fail − P95_pass) × (VU_fail − VU_pass)
   只使用相同路径、目标、副本、镜像、时长、负载及 mock 配置的观测。
   pass 为最高通过档，fail 为其上方最小失败档，且只能因延迟超标失败。
   配置缺失、低档失败、高低档冲突、证据不足或无破线档时不拟合，不外推。
7) 目标验收
   只记录实际 {TARGET_VUS} VU 通过的副本配置；不得从插值推算最少副本数。

8) 判定口径
   稳态：错误率 &lt; 0.05%、P95 TTFB &lt; 800ms、完整流成功率 &gt; 99.95%。
   突发：错误率 &lt; 1%、P95 TTFB &lt; 1500ms、完整流成功率 &gt; 99%。
   管理面：错误率 &lt; 1%、管理面标签 P95 &lt; 1000ms、业务成功 checks &gt; 99%、丢弃迭代为 0。
   分片逐一判定，不能用加权平均掩盖某分片失败；执行异常/缺数据为 INCOMPLETE。
   旧日志无 summary_schema 时：checks=2×http_reqs 且各项在错误预算内 ⇒ PASS·旧口径
   （仅证明 HTTP 200 + 含 [DONE]，不含 finish_reason/退出码，不参与容量拟合）。
   未定义专属验收标准的场景为 UNASSESSED，不计入通过容量。
   注意：本环境 mock 上游无真实厂商延迟，且部分档位未含 ALB（clusterip 模式）；
   URL 模式（https://perf.likha.hk）含 NAT+ALB 入口开销，两种模式不可直接混比。

9) 链路带宽利用率（仅公网路径）
   U_bw = data_received_rate(Mbps) / EIP_Bandwidth(Mbps)，k6 数据单位按十进制（1 MB = 1000 kB）。
   ClusterIP 内网流量不经过 EIP，只记录集群内下行峰值，不参与 EIP 饱和度判断。
   公网路径先撞带宽时表现为 RPS 塌陷 + 连接级失败（超时/重置）而应用侧无 5xx、CPU 不高；
   该推断仍需 EIP 实际监控确认，不能只凭本报告下结论。

10) 资源口径
   CPU_peak / Mem_peak = 采样窗口内同一时刻全副本合计峰值（逐 Pod 采样后求和，同刻去重）
   单 Pod 峰值另存为 cpu_max_pod_m / mem_max_pod_mi；旧日志只采首个 Pod，数值偏小。
   CPU 上限按部署 limits=2 核记（实际 deployment 以集群为准）。
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
  if (v === null || v === undefined) return '\u2014';
  return Number(v).toFixed(n) + (suf || '');
}
function head(r) {
  const cls = r.verdict === 'PASS' ? 'ok' : (r.verdict === 'FAIL' ? 'bad' : 'pending');
  let label = { INCOMPLETE: '数据不完整', UNASSESSED: '待评估' }[r.verdict] || r.verdict;
  if (r.evidence === 'legacy' && r.verdict === 'PASS') label = 'PASS·旧口径';
  return '<div class="tip-h">' + r.job + ' <span class="badge ' + cls + '">'
    + label + '</span></div>';
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
  return head(r) + '<table class="tip-t">'
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
    ap.add_argument("--json", help="把解析后的结构化运行结果写到该路径，供归档与二次分析")
    ap.add_argument("--eip-mbps", type=float, default=0.0, help="公网路径的 EIP 标称带宽（Mbps），用于带宽利用率判定")
    ap.add_argument("--check", metavar="LOG",
                    help="按场景判定：PASS 退出 0，FAIL 退出 1，数据不完整/待评估退出 2")
    args = ap.parse_args()

    if args.check:
        runs = load_runs([args.check], args.eip_mbps)
        if not runs:
            print(f"[check] INCOMPLETE 无法解析日志：{args.check}")
            sys.exit(2)
        r = runs[0]
        print(f'[check] {r["verdict"]} vu={r["vus_i"]} replicas={r["replicas_i"]} '
              f'rps={fmt(r["rps"], 1)} p95={fmt(r.get("admin_p95") if r["mode"] == "admin" else r.get("ttfb_p95"), 0)}ms '
              f'err={fmt(r.get("err_pct"), 3)}% reason={r["verdict_reason"]}')
        sys.exit({"PASS": 0, "FAIL": 1}.get(r["verdict"], 2))

    if not args.out and not args.json:
        ap.error("--out 或 --json 至少需要一个（--check 除外）")
    paths = []
    if args.logs:
        paths = list(args.logs)
    elif args.log_dir:
        for d in args.log_dir:
            paths += sorted(glob.glob(os.path.join(d, "**", "*.log"), recursive=True))
        paths = sorted(set(paths))
    runs = load_runs(paths, args.eip_mbps)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                       "runs": runs}, fh, ensure_ascii=False, indent=2)
        print(f"[report] json={args.json} runs={len(runs)}")
    if args.out:
        render(runs, analyse(runs, args.eip_mbps), args.out, args.eip_mbps)
        print(f"[report] runs={len(runs)} -> {args.out}")


if __name__ == "__main__":
    main()
