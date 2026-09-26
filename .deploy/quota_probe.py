#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quota_probe.py —— 阿里云国际站配额实时读取（§3.4 步骤 1）

用途：把「配额中心 + ECS 账号属性」的实时值落盘，作为配额申请的依据与留痕证据。
不要凭印象报数字 —— 默认配额不公开，只能实测。

用法：
  python3 quota_probe.py                 # 读全部目标产品 × 双 region
  python3 quota_probe.py --region ap-southeast-6
  python3 quota_probe.py --product ecs-spec

产物：
  .workbuddy/quota/<ProductCode>_<region>.json     原始返回
  .workbuddy/quota/配额实时读取_<时间戳>.md         汇总表
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import time

ALIYUN = os.environ.get("ALIYUN_BIN") or os.path.expanduser(
    "~/.workbuddy/binaries/aliyun-cli/aliyun")
OUT = ".workbuddy/quota"

REGIONS = ["ap-southeast-6", "ap-southeast-1"]

# 关注的产品（配额中心里实际存在的商品码，2026-09-26 实测 ListProducts 结果）
PRODUCTS = ["ecs-spec", "ecs", "slb", "eip", "nat", "vpc", "kvstore", "csk", "mysql"]

# 每产品的关键字过滤：只保留与本次部署相关的配额行（None = 全留）
FOCUS = {
    "ecs-spec": ("vCPU", ["enterprise", "share", "local_storage", "high_mem", "restrict", "xpec"]),
    "ecs": ("", ["vcpu", "instance-count", "network-interfaces", "security-group",
                 "elastic-network-interfaces"]),
    "slb": ("", ["instance"]),
    "eip": ("", ["eip", "instance", "count"]),
    "nat": ("", ["nat", "gateway", "count"]),
    "vpc": ("", ["vpc", "switch", "route"]),
    "kvstore": ("", ["instance", "count"]),
    "csk": ("", ["cluster", "instance"]),
    "mysql": ("", ["instance", "count"]),
}


def call(args):
    p = subprocess.run([ALIYUN] + args, capture_output=True, text=True)
    raw = (p.stdout or "") + (p.stderr or "")
    i = raw.find("{")
    if i < 0:
        return None, raw.strip()[:300]
    try:
        return json.loads(raw[i:]), None
    except Exception as e:
        return None, "JSON 解析失败: %s | %s" % (e, raw[:200])


def fetch_quotas(product, region):
    d, err = call(["quotas", "ListProductQuotas", "--ProductCode", product,
                   "--Dimensions.1.Key", "regionId", "--Dimensions.1.Value", region,
                   "--MaxResults", "100"])
    if err:
        return None, err
    return d.get("Quotas") or [], None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", action="append", default=[])
    ap.add_argument("--product", action="append", default=[])
    a = ap.parse_args()
    regions = a.region or REGIONS
    products = a.product or PRODUCTS

    if not os.path.exists(os.path.join(os.path.dirname(ALIYUN), "aliyun")):
        print("[WARN] 未找到 aliyun CLI：%s" % ALIYUN)
    os.makedirs(OUT, exist_ok=True)

    ver, _ = call(["version"])
    md = ["# 配额实时读取（§3.4 步骤 1）", "",
          "读取时间：%s" % time.strftime("%Y-%m-%d %H:%M:%S"),
          "账号：5108890064395960 · region：%s · CLI：`aliyun %s`" % (", ".join(regions), ver), ""]
    md.append("| 产品 | 配额 code | 名称 | %s |" % " | ".join(regions))
    md.append("| --- | --- | --- |" + " --- |" * len(regions))

    for prod in products:
        per_region = {}
        for r in regions:
            qs, err = fetch_quotas(prod, r)
            if err:
                print("[WARN] %s@%s: %s" % (prod, r, err))
                per_region[r] = None
                continue
            per_region[r] = qs
            with io.open(os.path.join(OUT, "%s_%s.json" % (prod, r)), "w",
                         encoding="utf-8") as f:
                json.dump(qs, f, ensure_ascii=False, indent=1)
        keys = {}
        for r, qs in per_region.items():
            for q in (qs or []):
                keys.setdefault(q["QuotaActionCode"], {})[r] = q
        wanted = FOCUS.get(prod, ("", None))[1]
        for code in sorted(keys):
            sample = next(iter(keys[code].values()))
            if wanted and not any(w.lower() in code.lower() for w in wanted):
                continue
            row = ["`%s`" % prod, "`%s`" % code, sample.get("QuotaName", "")[:44]]
            for r in regions:
                q = keys[code].get(r)
                if not q:
                    row.append("—")
                else:
                    adj = "可调" if q.get("Adjustable") else "**不可调**"
                    row.append("**%s** / 已用 %s · %s" % (q.get("TotalQuota"),
                                                        q.get("TotalUsage"), adj))
            md.append("| " + " | ".join(row) + " |")
        md.append("")

    txt = "\n".join(md)
    path = os.path.join(OUT, "配额实时读取_%s.md" % time.strftime("%Y%m%d_%H%M%S"))
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(txt + "\n")
    print(txt)
    print("\n[OK] 明细 JSON + 汇总表 → %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
