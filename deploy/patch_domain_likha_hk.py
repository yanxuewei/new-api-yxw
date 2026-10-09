#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2026-09-30 fanyan 裁定：likha.com 域名被占用 → 正式环境域名改为 www.likha.hk。
范围：deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md（用户指定仅此 + xlsx v2.3）
规则（按序应用，幂等）：
  R1  api.likha.com  -> www.likha.hk        （生产域名换 host + 换域）
  R2  likha.com      -> likha.hk             （其余全域家族：ops/static/internal/media/通配证书/裸域）
  R3  DNS 记录名语义修正：主机记录 api -> www（R1/R2 是纯字符串替换，盖不到这些）
  R4  G4 历史实测值标注（NS=GoDaddy 是对旧域 likha.com 测的，likha.hk 须重测）
用法：python3 patch_domain_likha_hk.py [--check|--apply]
"""
import sys, shutil, re
from pathlib import Path

REPO = Path(r"E:\git_code\new-api-yxw")
TARGET = REPO / "deploy" / "docs" / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md"

PAIRS = [
    # tag, old, new
    ("R1 生产域名", "api.likha.com", "www.likha.hk"),
    ("R2 域名家族", "likha.com", "likha.hk"),
    # R3：DNS 主机记录名（必须在 R1/R2 之后按替换后的文本匹配）
    ("R3 GTM记录行", "--RR api --Type CNAME", "--RR www --Type CNAME"),
    ("R3 预建记录表", "| `api` | CNAME | GTM", "| `www` | CNAME | GTM"),
    ("R3 排障行dig", "`dig +short api` 为空", "`dig +short www.likha.hk` 为空"),
    ("R3 排障行应为", "主机记录写成 `www.likha.hk`（应为 `api`）", "主机记录写成 `www.likha.hk`（应为 `www`）"),
    ("R3 坑TTL600", "`api` 记录 TTL=600", "`www` 记录 TTL=600"),
    ("R3 坑TTL60", "`api` 记录 **TTL 60**", "`www` 记录 **TTL 60**"),
    ("R3 终验清单", "api/ops/static 三条记录已预建，api TTL=60", "www/ops/static 三条记录已预建，www TTL=60"),
    # R4：G4 历史实测值标注（防误导）。措辞刻意避开旧域字面量，防幂等复跑时被 R2 误替换
    ("R4 G4标注", "`dig NS likha.hk @8.8.8.8` → **ns21/ns22.domaincontrol.com（GoDaddy；⚠ 2026-09-30 换域后未重测，此为旧域 likha.com 实测值）**",
                  "`dig NS likha.hk @8.8.8.8` → **ns21/ns22.domaincontrol.com（GoDaddy；⚠ 2026-09-30 换域后未重测，NS 结论沿用旧域实测值，likha.hk 须重新实测）**"),
]

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    text = TARGET.read_text(encoding="utf-8")
    # CRLF 归一保护：文件可能 LF，Read/Write 保持原样即可
    changes, missing = [], []
    new = text
    for tag, old, r in PAIRS:
        # 注意：不能用 "r not in new" 做幂等守卫——R1 结果 www.likha.hk 含子串 likha.hk，
        # 会把 R2 短路成 "已是目标状态"。replace 本身幂等（old 被消费后不再命中），直接判 old。
        if old in new:
            n = new.count(old)
            new = new.replace(old, r)
            changes.append(f"{tag}: {n} 处")

    # 残留核查：不应再有任何 likha.com（R4 标注里的"旧域 likha.com 实测值"属刻意保留）
    leftover = [ln for ln in new.splitlines() if "likha.com" in ln and "旧域 likha.com" not in ln]

    print(f"目标: {TARGET.name}")
    if mode == "--apply":
        bak = TARGET.with_suffix(".md.bak-domain-20260930")
        if not bak.exists():
            shutil.copy2(TARGET, bak)
            print(f"备份: {bak.name}")
        TARGET.write_text(new, encoding="utf-8")
        print(f"[APPLY] 修改 {len(changes)} 类:")
        for c in changes:
            print(f"  - {c}")
    else:
        print(f"[CHECK] 待修改 {len(changes)} 类:")
        for c in changes:
            print(f"  - {c}")

    if missing:
        print(f"[!!] 锚点未命中（可能口径变化，人工核对）: {missing}")
    if leftover:
        print(f"[!!] 残留 likha.com {len(leftover)} 行:")
        for ln in leftover[:10]:
            print(f"    {ln[:120]}")
    else:
        print("[OK] 无 likha.com 残留")
    # 新域计数
    print(f"[OK] www.likha.hk: {new.count('www.likha.hk')} 处 · likha.hk 总计: {new.count('likha.hk')} 处")

if __name__ == "__main__":
    main()
