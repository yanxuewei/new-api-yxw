#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
inline_svg_into_md.py —— 把《用户设置指南.md》里的 SVG 图片变成**内联**，产出单文件自包含 md

两种模式（可混用）：

  A) 标签模式（推荐，首次运行会自动写入标签）
     <!-- svg:10-七类角色映射.svg -->
     <svg …>…</svg>
     按标签精确定位替换 —— 源图改了重跑一次即可，与文档顺序无关。

  B) 引用模式（旧写法）
     ![alt](user-guide-images/xx.svg)
     首次内联时用；转换后原地替换为「标签 + 内联 svg」。

为什么用标签：单靠标题文字无法区分同标题的图（03/04/05 都叫「创建用户」，
06/09 都叫「用户」），靠出现顺序又太脆弱。

渲染兼容性：
  ✅ Typora / Obsidian / VS Code Markdown Preview / Pandoc 导 PDF
  ❌ GitHub 网页版（会 sanitize 掉内联 SVG）→ 备用 `user-guide-images/index.html` 画廊

用法：
  python3 inline_svg_into_md.py            # 预览（打印将要替换的位置，不改文件）
  python3 inline_svg_into_md.py --apply    # 备份后写入
"""
import io
import os
import re
import sys
import shutil
import time

MD = "用户设置指南.md"
IMG_RE = re.compile(r"^!\[([^\]]*)\]\((user-guide-images/[^)]+\.svg)\)\s*$")
TAG_RE = re.compile(r"^<!--\s*svg:(.+?\.svg)\s*-->\s*$")
SIZE_RE = re.compile(r'\swidth="(\d+)"\s+height="(\d+)"')

# 首次内联时的顺序映射：md 中第 N 个 ![alt](…) 引用 → 源文件
# （仅在还没打标签的老文档上用到；打完标签后此表不再参与）
# 2026-09-26 15:38 起 §5「给用户组授权」整节已删 → 08-用户组-新增授权.svg 不再出现在正文
FIRST_PASS_ORDER = [
    "10-七类角色映射.svg",
    "01-权限策略列表.svg",
    "02-用户组列表.svg",
    "03-创建用户-步骤1-用户信息.svg",
    "04-创建用户-步骤2-访问方式.svg",
    "05-创建用户-步骤3-保存AK.svg",
    "07-用户组-添加用户.svg",
    "06-用户列表.svg",
    "01-权限策略列表.svg",
    "09-移除与删除用户.svg",
]


def load_svg(rel: str) -> str:
    """读 SVG → 自适应宽度（否则内联后在窄容器里横向溢出）。"""
    s = io.open(rel, encoding="utf-8").read().strip()
    if SIZE_RE.search(s):
        s = SIZE_RE.sub(' width="100%" style="max-width:1120px"', s, count=1)
    else:
        s = s.replace("<svg ", '<svg width="100%" style="max-width:1120px" ', 1)
    return s


def main() -> int:
    apply = "--apply" in sys.argv
    if not os.path.exists(MD):
        print("[FAIL] 找不到 %s" % MD)
        return 1

    src = io.open(MD, encoding="utf-8").read()
    lines = src.split("\n")
    out, log = [], []
    pending_tag = None      # 上一个标签声明的文件名
    seq = 0                 # 引用模式下的序号
    in_fence = False        # 代码围栏状态

    for ln in lines:
        # ⚠️ 代码围栏内的内容一律原样保留 —— 文档正文里有「标签 + <svg>」的示例代码，
        #    不跳过会把它当成真图替换掉（踩过：统计出 12 块 ≠ 11 块）
        if ln.strip().startswith("```"):
            in_fence = not in_fence
            out.append(ln)
            continue
        if in_fence:
            out.append(ln)
            continue

        # ── 标签行：原样保留，记住它声明的文件 ──
        m = TAG_RE.match(ln)
        if m:
            pending_tag = m.group(1)
            out.append(ln)
            continue

        # ── 内联 svg 行 ──
        if ln.lstrip().startswith("<svg"):
            rel = pending_tag
            if rel is None:
                log.append(("WARN", "-", "第 %d 行的 <svg> 上方没有标签，跳过" % (len(out) + 1)))
                out.append(ln)
                continue
            pending_tag = None
            path = os.path.join("user-guide-images", os.path.basename(rel))
            if not os.path.exists(path):
                log.append(("FAIL", rel, "源文件不存在"))
                out.append(ln)
                continue
            old_len, new_svg = len(ln), load_svg(path)
            act = "更新" if old_len != len(new_svg) else "不变"
            log.append((act, rel, "%d → %d 字节" % (old_len, len(new_svg))))
            out.append(new_svg)
            continue

        pending_tag = None if ln.strip() else pending_tag

        # ── 图片引用行（首次内联）──
        m = IMG_RE.match(ln)
        if m:
            rel = FIRST_PASS_ORDER[seq] if seq < len(FIRST_PASS_ORDER) else m.group(2)
            seq += 1
            path = os.path.join("user-guide-images", os.path.basename(rel))
            if not os.path.exists(path):
                log.append(("FAIL", rel, "源文件不存在"))
                out.append(ln)
                continue
            log.append(("内联", rel, "首次转换"))
            out.append("<!-- svg:%s -->" % rel)
            out.append(load_svg(path))
            continue

        out.append(ln)

    dst = "\n".join(out)
    for act, rel, note in log:
        print("  [%-4s] %-40s %s" % (act, rel, note))

    # 统计只算围栏外的真实内容（文档正文有「标签 + <svg>」示例代码）
    n_tag = n_svg = n_link = 0
    in_fence = False
    for l in out:
        if l.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if re.match(r"^<!--\s*svg:", l):
            n_tag += 1
        if l.lstrip().startswith("<svg"):
            n_svg += 1
        if re.search(r"!\[[^\]]*\]\(user-guide-images/", l):
            n_link += 1
    print("标签数 %d · 内联 <svg> %d · 残留外链 %d（均不含代码块）" % (n_tag, n_svg, n_link))
    print("md 体积：%d → %d 字节" % (len(src.encode("utf-8")), len(dst.encode("utf-8"))))

    if not apply:
        print("\n（预览模式，未写入。加 --apply 生效）")
        return 0

    bak_dir = ".workbuddy/backup"
    os.makedirs(bak_dir, exist_ok=True)
    bak = os.path.join(bak_dir, "用户设置指南.md.bak_%s" % time.strftime("%Y%m%d_%H%M%S"))
    shutil.copy2(MD, bak)
    io.open(MD, "w", encoding="utf-8").write(dst)
    print("\n[OK] 已写入 %s\n     备份 → %s" % (MD, bak))
    return 0


if __name__ == "__main__":
    sys.exit(main())
