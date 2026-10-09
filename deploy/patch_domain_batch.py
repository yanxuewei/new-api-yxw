#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2026-09-30 域名批量同步：likha.com → likha.hk（口径已获用户确认）
范围：deploy/ 下全部活文档（排除备份/日志/历史会话/本脚本自身/memory）
规则（幂等）：
  R1  api.likha.com -> www.likha.hk
  R2  likha.com     -> likha.hk
  R3  语义联动不做批量猜测——apply 后输出可疑记录名模式清单，人工逐个核对
用法：python3 patch_domain_batch.py [--check|--apply]
"""
import sys, shutil
from pathlib import Path

REPO = Path(r"E:\git_code\new-api-yxw")

# 活文档清单：deploy/ + .ch-parts/（旧版 -ch.md 的源件），逐目录枚举
TARGETS = []
for pat in [
    "deploy/wf2/*.md", "deploy/aliyun/ph/*.md", "deploy/aliyun/ph/*.yaml",
    "deploy/docs/*.md", "deploy/*.sh", ".ch-parts/*.md",
]:
    for p in REPO.glob(pat):
        if p.name == "patch_domain_likha_hk.py":
            continue
        if ".bak-" in p.name:
            continue
        TARGETS.append(p)

# 排除：纯历史评审/答疑记录不改（内容为当时评审事实，改了反而失真）
HISTORICAL = {
    "菲律宾部署方案-评审意见.md", "部署方案评审-2026-09-23.md",
    "部署方案修订记录-v2.1.md", "部署答疑_连接数预算与通配符证书_2026-09-27.md",
}
PAIRS = [
    ("R1", "api.likha.com", "www.likha.hk"),
    ("R2", "likha.com", "likha.hk"),
    # R3：DNS 主机记录名语义修正（R1/R2 是纯字符串替换盖不到；幂等，命不中即跳过）
    ("R3", "--RR api --Type CNAME", "--RR www --Type CNAME"),
    ("R3", "| `api` | CNAME | GTM", "| `www` | CNAME | GTM"),
    ("R3", "`dig +short api` 为空", "`dig +short www.likha.hk` 为空"),
    ("R3", "主机记录写成 `www.likha.hk`（应为 `api`）", "主机记录写成 `www.likha.hk`（应为 `www`）"),
    ("R3", "`api` 记录 TTL=600", "`www` 记录 TTL=600"),
    ("R3", "`api` 记录 **TTL 60**", "`www` 记录 **TTL 60**"),
    ("R3", "api/ops/static 三条记录已预建，api TTL=60", "www/ops/static 三条记录已预建，www TTL=60"),
]

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    changed, totals = [], {}
    for p in sorted(set(TARGETS)):
        if p.name in HISTORICAL:
            continue
        text = p.read_text(encoding="utf-8")
        new = text
        counts = {}
        for tag, old, r in PAIRS:
            if old in new:
                n = new.count(old)
                new = new.replace(old, r)
                counts[tag] = counts.get(tag, 0) + n
        if counts:
            changed.append((p, counts))
            for tag, n in counts.items():
                totals[tag] = totals.get(tag, 0) + n
            if mode == "--apply":
                bak = p.with_name(p.name + ".bak-domain-20260930")
                if not bak.exists():
                    shutil.copy2(p, bak)
                p.write_text(new, encoding="utf-8")

    print(f"[{mode.upper()}] 待改文件 {len(changed)} 个：")
    for p, counts in changed:
        rel = p.relative_to(REPO)
        print(f"  {rel}: " + " ".join(f"{t}={n}" for t, n in counts.items()))
    print("合计:", " ".join(f"{t}={n}" for t, n in sorted(totals.items())))

    if mode == "--apply":
        # R3 候选扫描：记录名/主机记录类可疑残留（R1/R2 盖不到的语义位）
        print("\n=== R3 候选扫描（人工核对记录名语义）===")
        pats = ["--RR api", "RR=api", "主机记录", "api/ops", "`api` 记录", "record: api", "name: api", "host: api\b"]
        import re
        for p, _ in changed:
            t = p.read_text(encoding="utf-8")
            for line_no, line in enumerate(t.splitlines(), 1):
                if "likha" not in line and not any(x in line for x in ["--RR", "主机记录", "RR="]):
                    continue
                for pat in ["--RR api", "RR=api", "主机记录", "api/ops", "`api` 记录", "record: api", "- api\b"]:
                    if re.search(pat, line):
                        print(f"  {p.relative_to(REPO)}:{line_no}: {line.strip()[:140]}")
                        break
        print("（历史评审/答疑记录按口径未动：", ", ".join(sorted(HISTORICAL)), "）")

if __name__ == "__main__":
    main()
