#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回写安全组 CLI 口径纠错（幂等 + 备份）
—— 2026-09-29 实跑踩到：AuthorizeSecurityGroup 只加**入向**规则，
   出向必须用 AuthorizeSecurityGroupEgress，且 flat 参数已 Deprecated。

用法：
  python3 deploy/patch_sg_cli.py --check      # 只报告
  python3 deploy/patch_sg_cli.py --apply      # 写入（自动 .bak-sgcli-<ts>）
"""
import argparse
import datetime
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGETS = [
    ROOT / "deploy" / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md",
    ROOT / "deploy" / "阿里云国际站菲律宾部署_详细操作指南.md",
    ROOT / "deploy" / "阿里云国际站菲律宾部署_详细操作指南-ch.md",
    ROOT / "deploy" / "wf2" / "part3a.md",
    ROOT / "deploy" / "aliyun" / "ph" / "security-groups.md",
]

MARK = "AuthorizeSecurityGroupEgress"


def build_deprecated_block(nl: str) -> str:
    return nl.join([
        "aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \\",
        "  --IpProtocol tcp --PortRange 3000/3000 --SourceGroupId ${SG_MNL_ALB} \\",
        '  --Policy accept --Priority 1 --Description "from-alb-only"',
    ])


NEW_BLOCK_TMPL = nl_placeholder = None


def new_block(nl: str) -> str:
    lines = [
        "# 入向：只有入向用 AuthorizeSecurityGroup",
        "aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \\",
        "  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 3000/3000 \\",
        "  --Permissions.1.SourceGroupId ${SG_MNL_ALB} --Permissions.1.NicType intranet \\",
        '  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "from-alb-only"',
        "",
        "# 出向：必须换 Egress API（AuthorizeSecurityGroup 只加**入向**规则，用它建出向会静默失败）",
        "aliyun ecs AuthorizeSecurityGroupEgress --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \\",
        "  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 5432/5432 \\",
        "  --Permissions.1.DestCidrIp 10.0.64.0/20 --Permissions.1.NicType intranet \\",
        '  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "to-rds-pg-primary"',
    ]
    return nl.join(lines)


INTRO_FIX = [
    (
        "按下表逐条 `AuthorizeSecurityGroup`（**用组引用而不是 IP 段**，可维护性最高）：",
        "按下表逐条建规则（**入向用 `AuthorizeSecurityGroup`、出向用 `AuthorizeSecurityGroupEgress`**；"
        "组引用只在**同 VPC** 内可用）：",
    ),
    (
        "CLI 示例（**用组引用而不是 IP 段**，可维护性最高）：",
        "CLI 示例（**入向 / 出向是两个 API**，组引用只在同 VPC 内可用）：",
    ),
    (
        "  --Policy accept --Priority 1 --Description \"from-alb-only\"\n\n# 反例自查",
        "  --Policy accept --Priority 1 --Description \"from-alb-only\"\n\n# 反例自查",
    ),
]


def patch(path: pathlib.Path, apply: bool) -> str:
    if not path.exists():
        return f"[跳过] 不存在：{path}"
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"

    if MARK in raw:
        return f"[已是最新] {path.name}"

    new_raw = raw
    changes = []

    dep = build_deprecated_block(nl)
    if dep in new_raw:
        new_raw = new_raw.replace(dep, new_block(nl), 1)
        changes.append("替换 CLI 示例（入向/出向分 API + Permissions.N.*）")
    else:
        # 行尾可能带多余空格，退回逐行正则
        pat = re.compile(
            r"( *)aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 --SecurityGroupId \$\{SG_MNL_APP\} \\"
            r"\n\s*--IpProtocol tcp --PortRange 3000/3000 --SourceGroupId \$\{SG_MNL_ALB\} \\"
            r"\n\s*--Policy accept --Priority 1 --Description \"from-alb-only\""
        )
        new_raw, n = pat.subn(lambda m: new_block(nl), new_raw, count=1)
        if n:
            changes.append("替换 CLI 示例（正则命中）")

    for old, new in INTRO_FIX:
        o = old.replace("\n", nl)
        n2 = new.replace("\n", nl)
        if o in new_raw and o != n2:
            new_raw = new_raw.replace(o, n2, 1)
            changes.append("修正引导语")

    # DescribeSecurityGroupAttribute 漏 RegionId
    bad = "aliyun ecs DescribeSecurityGroupAttribute --SecurityGroupId ${SG_MNL_APP} \\"
    good = "aliyun ecs DescribeSecurityGroupAttribute --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \\"
    if bad in new_raw:
        new_raw = new_raw.replace(bad, good)
        changes.append("补 DescribeSecurityGroupAttribute 的 --RegionId")

    if not changes:
        return f"[未匹配] {path.name}：没找到可替换的片段，需人工看"

    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".bak-sgcli-{ts}"))
        path.write_text(new_raw, encoding="utf-8", newline="")
    return f"[{'已写入' if apply else '待改'}] {path.name}：" + "；".join(changes)


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    for p in TARGETS:
        print(patch(p, apply=args.apply))
    return 0


if __name__ == "__main__":
    sys.exit(main())
