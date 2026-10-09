#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_g9i_and_sec34.py —— 一次性回写两类修正（幂等：已改则 0 匹配，不重复写）

A. 机型修正：g8i → g9i
   依据 `deploy/docs/控制台核实四问_结论.md` §3（2026-09-25 API 实测：g8i 全系未在马尼拉上架；
   g9i 全系 12 档 6a/6b 均有库存，g9i.2xlarge = 8C32G 与 g8i.2xlarge 同核数同内存比）
   范围：指南（英/中文界面两版）、impl_deploy.md、impl_tech.md、方案 xlsx（仅 v2.1 修订版）

B. 指南 §3.4 认知修正（4 处 + 补实测结论）
   依据 `deploy/docs/资源配额申请_执行报告.md` §1.2 / §2.2
   general-purpose 族不存在 / --DesireValue（无 d）无 --Version / 地域用 --Dimensions / 状态是 Agree

用法：cd <repo> && python3 deploy/patch_g9i_and_sec34.py
备份：.workbuddy/backup/docfix_<ts>/
"""
import os
import re
import shutil
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS = time.strftime("%Y%m%d_%H%M%S")
BK = os.path.join(ROOT, ".workbuddy", "backup", f"docfix_{TS}")

GUIDE_A = "deploy/docs/阿里云国际站菲律宾部署_详细操作指南.md"
GUIDE_B = "deploy/docs/阿里云国际站菲律宾部署_详细操作指南-ch.md"
IMPL_D = "impl_deploy.md"
IMPL_T = "impl_tech.md"
XLSX = "deploy/docs/菲律宾部署方案-v2.1-修订版.xlsx"

# ---------------------------------------------------------------- 机型修正
MACHINE = [
    # impl_deploy.md
    (IMPL_D,
     "| 计算 | ECS 节点池 | `g8i.2xlarge`(8C32G) |",
     "| 计算 | ECS 节点池 | `g9i.2xlarge`(8C32G)（**g8i 全系未在马尼拉上架**，2026-09-25 实测；备选 `g8ine.2xlarge`） |", 1),
    (IMPL_D,
     "马尼拉 / 曼谷各常态 4×`g8i.2xlarge`（自动伸缩至 8",
     "马尼拉 / 曼谷各常态 4×`g9i.2xlarge`（自动伸缩至 8", 1),
    # impl_tech.md
    (IMPL_T,
     "（同 VPC 内 `i2`/`g8i` 实例）",
     "（同 VPC 内 `i2`/`g9i` 实例）", 1),
    (IMPL_T,
     "| 计算 | ECS 节点池 | `g8i.2xlarge`(8C32G) |",
     "| 计算 | ECS 节点池 | `g9i.2xlarge`(8C32G) |", 1),
    (IMPL_T,
     "| 计算 | 每区域 4×`g8i.2xlarge`（可扩至 16）",
     "| 计算 | 每区域 4×`g9i.2xlarge`（可扩至 16）", 1),
]

# ------------------------------------------------- 指南独有（两版共用的字符串）
GUIDE_SHARED = [
    # P0 差异清单机型行
    ("**g8i 在马尼拉无公开可用性承诺**，马尼拉机型目录明显小于新加坡",
     "**g8i 全系未在马尼拉上架**（2026-09-25 API 实测，详见 `控制台核实四问_结论.md`）",
     1),
    # 机型可用性验证 for 循环
    ("for t in ecs.g8i.2xlarge ecs.g8a.2xlarge ecs.g7.2xlarge ecs.g6.2xlarge ecs.g8y.2xlarge ecs.c8i.2xlarge; do",
     "for t in ecs.g9i.2xlarge ecs.g8ine.2xlarge ecs.g9ae.2xlarge ecs.u2i.2xlarge ecs.g8i.2xlarge ecs.g8a.2xlarge; do",
     1),
    # 坑 1
    ("- **坑 1｜把 `g8i.2xlarge` 当既定事实**（方案 R28/R15 全表都基于它，但马尼拉无公开可用性承诺）。",
     "- **坑 1｜把 `g8i.2xlarge` 当既定事实**（方案 R28/R15 全表都基于它；**2026-09-25 实测已确认 g8i 全系未在马尼拉上架** —— 不是「承诺不足」，是「根本没上架」）。",
     1),
    # 新加坡节点池 json
    ('"scaling_group":{"instance_types":["ecs.g8i.2xlarge","ecs.g8a.2xlarge","ecs.g7.2xlarge"],',
     '"scaling_group":{"instance_types":["ecs.g9i.2xlarge","ecs.g8ine.2xlarge","ecs.g9ae.2xlarge"],',
     1),
    # 可用机型过滤
    ('  | grep -E "g8i|g8a|g7|c8i" | sort',
     '  | grep -E "g9i|g8ine|g9ae|u2i|c9i" | sort',
     1),
    # 选型说明
    ("**若 `g8i.2xlarge` 不在列表里，不要坚持改配置单**，直接换机型并把 §2.1 request/limit 按实际 vCPU 重算。",
     "**已实测 `g8i.2xlarge` 不在列表里（g8i 全系未上架）**，不要坚持改配置单，直接换机型并把 §2.1 request/limit 按实际 vCPU 重算。首选 `g9i.2xlarge`（8C32G，与 g8i.2xlarge 同核数同内存比）。",
     1),
    # perf 节点池
    ("4. perf 环境用 2×`g8i.xlarge` 独立节点池",
     "4. perf 环境用 2×`g9i.xlarge` 独立节点池",
     1),
    # 配额台账行
    ("| ECS 马尼拉 | g8i.2xlarge | 4–8 | 【核实】 | | 高（HPA 直接放大） |",
     "| ECS 马尼拉 | g9i.2xlarge（g8i 全系未上架，实测） | 4–8 | ✅ 已核实 | 已批 64 vCPU | 高（HPA 直接放大） |",
     1),
    # P0 差异清单第 1 列机型名
    ("| 3 | 节点规格 `g8i.2xlarge（8C32G）` |",
     "| 3 | 节点规格 `g9i.2xlarge（8C32G）`（原 `g8i.2xlarge`） |",
     1),
    # 节点池创建页「实例规格」行
    ("| 实例规格 | **多机型**：`g8i.2xlarge` 可用则首位，否则 `g7.2xlarge` / `g8a.2xlarge` / `g6.2xlarge`（**至少 2–3 个**） |",
     "| 实例规格 | **多机型**：`g9i.2xlarge` 首位 + `g8ine.2xlarge` / `g9ae.2xlarge`（**至少 2–3 个**；`g8i.2xlarge` 已实测未上架，勿再列入） |",
     1),
    # 配额/门禁台账新加坡行
    ("| ECS 新加坡 | g8i.2xlarge | 2–12 | | | **极高**（接管时 6×） |",
     "| ECS 新加坡 | g9i.2xlarge（机型以 D2 实测为准） | 2–12 | 已批 96 vCPU | | **极高**（接管时 6×） |",
     1),
]

# ------------------------------------------------- 指南 §3.4（两版共有）
SEC34_SHARED = [
    ("### 3.4 G2 / G10 · 资源配额申请（2–3 工作日，关键路径）",
     "### 3.4 G2 / G10 · 资源配额申请（国际站该类配额自动审批、**分钟级生效** —— 2026-09-26 实测）",
     1),
    # 步骤 1 CLI：必须带地域维度
    ("""aliyun quotas ListProductQuotas --ProductCode ecs --RegionId $REGION
```""",
     """# 注意：ecs-spec 必须显式传地域维度；只传 --RegionId 会返回 cn-hangzhou 的假数据
aliyun quotas ListProductQuotas --ProductCode ecs-spec \\
  --Dimensions.1.Key regionId --Dimensions.1.Value $REGION --MaxResults 100
```""",
     1),
    # 步骤 4 CLI
    ("""aliyun quotas CreateQuotaApplication \\
  --ProductCode ecs --Version 2014-05-26 \\
  --QuotaActionCode <上一步读到的 code> \\
  --DesiredValue 96 \\
  --Reason "new-api AI gateway prod launch, standby region takeover capacity >= 1.5x peak" \\
  --DomainRegions.1.RegionId ap-southeast-1

aliyun quotas ListQuotaApplications            # 轮询审批状态
```""",
     """aliyun quotas CreateQuotaApplication \\
  --ProductCode ecs-spec \\
  --QuotaActionCode q_ecs_enterprise_postpay_c \\
  --DesireValue 96 \\
  --Reason "standby takeover capacity >= 1.5x peak: 16 pods x 1.5 = 24 pods x 4 vCPU = 96" \\
  --Dimensions.1.Key regionId --Dimensions.1.Value ap-southeast-1 \\
  --NoticeType 3 --QuotaCategory CommonQuota

aliyun quotas ListQuotaApplications --ProductCode ecs-spec   # 轮询审批状态
```



> **参数名三处坑**：是 `--DesireValue`（**无 d**），**没有** `--Version`，地域必须用
> `--Dimensions.1.Key regionId --Dimensions.1.Value <region>`（不是 `--DomainRegions`）。""",
     1),
    # 验证方法
    ("**验证方法**：`ListQuotaApplications` 返回 `Status: Approved`；再跑一次步骤 1 的 `ListProductQuotas`，`TotalAllowedQuota` ≥ 申请值。",
     "**验证方法**：`ListQuotaApplications` 返回 `Status: Agree`（中间态 `Process`；**不是 `Approved`**，且地域字段是 `Dimension` 单数，不是 `Dimensions`）；再跑一次步骤 1 的 `ListProductQuotas`，`TotalQuota` ≥ 申请值。",
     1),
    # 补实测结论
    ("- **坑｜配额是按 region 独立的**。马尼拉批了 ≠ 新加坡有。**改进**：两批工单分开提，**先马尼拉后新加坡但同日发起**。",
     "- **坑｜配额是按 region 独立的**。马尼拉批了 ≠ 新加坡有。**改进**：两批工单分开提，**先马尼拉后新加坡但同日发起**。\n\n> **2026-09-26 实测闭环**：批次 1/2 的 ECS vCPU 申请（马尼拉 **50 → 64**、新加坡 **50 → 96**）均 **`Agree`**，约 **2 分钟**生效；其余 7 类资源现值已 ≥ 需求、**无需申请**。工单号与原始证据见 `deploy/docs/资源配额申请_执行报告.md`。",
     1),
    # 备站容量式口径澄清（原「192 vCPU Pod 需求」维度不清）
    ("备 region 接管上限 = 主站峰值 16 × 1.5 = **24 副本 = 192 vCPU Pod 需求**（按 request 2 vCPU 时是 48 vCPU，按 limit 4 vCPU 时是 96 vCPU）。",
     "备 region 接管上限 = 主站峰值 16 副本 × 1.5 = **24 副本**；按 **limit 4 vCPU** 口径 = **96 vCPU**（按 request 2 vCPU 口径是 48 vCPU，但配额须按 limit 预留）⇔ 节点池 **12 × 8 vCPU = 96**。",
     1),
]

GUIDE_A_ONLY = [
    ("**general-purpose 族的 vCPU 配额**。",
     "**`ecs-spec` 产品的 `q_ecs_enterprise_postpay_c`** —— 配额中心里**没有** general-purpose 族，该项按「按量付费企业级计算实例（g/c/r/u/hf/sn）」分组；`g9i` 属 g 系列，就是这一条。",
     1),
    ("- 长时间 `Approving` → **另开 Support Ticket 催办**",
     "- 长时间 `Processing`（`Approving`）→ **另开 Support Ticket 催办**",
     1),
]

GUIDE_B_ONLY = [
    ("**通用型（general-purpose）族的 vCPU 配额**。",
     "**`ecs-spec` 产品的 `q_ecs_enterprise_postpay_c`** —— 配额中心里**没有** general-purpose 族，该项按「按量付费企业级计算实例（g/c/r/u/hf/sn）」分组；`g9i` 属 g 系列，就是这一条。",
     1),
    ("- 长时间 `Approving` → **另提交工单催办**",
     "- 长时间 `Processing`（`Approving`）→ **另提交工单催办**",
     1),
]

def machine_subs(rel):
    return [(old, new, exp) for f, old, new, exp in MACHINE if f == rel]


PLAN = [
    (GUIDE_A, GUIDE_SHARED + SEC34_SHARED + GUIDE_A_ONLY),
    (GUIDE_B, GUIDE_SHARED + SEC34_SHARED + GUIDE_B_ONLY),
    (IMPL_D, machine_subs(IMPL_D)),
    (IMPL_T, machine_subs(IMPL_T)),
]

XLSX_SUBS = [("g8i.2xlarge", "g9i.2xlarge"), ("g8i.xlarge", "g9i.xlarge")]


def backup(rel):
    src = os.path.join(ROOT, rel)
    os.makedirs(BK, exist_ok=True)
    dst = os.path.join(BK, rel.replace("/", "__"))
    shutil.copy2(src, dst)
    return dst


def patch_text(rel, subs):
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as f:
        txt = f.read()
    backup(rel)
    done = miss = skip = 0
    for old, new, exp in subs:
        c = txt.count(old)
        if c == exp:
            txt = txt.replace(old, new)
            done += 1
        elif c == 0 and txt.count(new) >= exp:
            skip += 1  # 已应用
        else:
            miss += 1
            print(f"  ! {rel}  期望{exp}处 / 实得{c}处 :: {old[:48]}...")
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    print(f"  {rel}: 新替换 {done} 组，已应用跳过 {skip} 组，未匹配 {miss} 组 / 共 {len(subs)} 组")


def patch_xlsx(rel):
    src = os.path.join(ROOT, rel)
    backup(rel)
    zin = zipfile.ZipFile(src)
    names = zin.namelist()
    total = 0
    out = {}
    for n in names:
        raw = zin.read(n)
        if n.endswith(".xml"):
            s = raw.decode("utf-8")
            for a, b in XLSX_SUBS:
                total += s.count(a)
                s = s.replace(a, b)
            raw = s.encode("utf-8")
        out[n] = raw
    zin.close()
    tmp = src + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for n in names:
            zout.writestr(n, out[n])
    os.replace(tmp, src)
    print(f"  {rel}: 单元格内机型替换 {total} 处")


def main():
    print(f"备份目录：{os.path.relpath(BK, ROOT)}")
    for rel, subs in PLAN:
        patch_text(rel, subs)
    patch_xlsx(XLSX)
    # 校验：残留
    print("\n残留 g8i 检查（应仅剩「未上架」说明性引用）")
    for rel, _ in PLAN:
        p = os.path.join(ROOT, rel)
        with open(p, encoding="utf-8") as f:
            for i, line in enumerate(f, 1):
                if "g8i" in line:
                    print(f"  {rel}:{i}: {line.strip()[:110]}")
    with zipfile.ZipFile(os.path.join(ROOT, XLSX)) as z:
        bad = z.testzip()
    print(f"\nxlsx 完整性：{'OK' if bad is None else '损坏 ' + str(bad)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
