#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
回写任务 10（ACK 马尼拉集群）落地结果 + 更正 ACK 控制面 SLA 口径
—— 2026-09-29 实测发现的两处实质错误：
   ① 指南称「选 regional 多可用区控制面可得 99.95%，否则 8.2 推导链从根上错」——
      但 ACK SLA(2023-04-01) §1.4/1.5 的 regional/zonal 判定依据是【地域 AZ 数】(≥3 / ≤2)，
      马尼拉仅 2 AZ → 永远是 zonal、承诺 99.50%，【选不了】；且 ACK 控制面【不在】
      §8.2 的五项串联链(0.9999^5)内 → 该表述双重错误。
   ② CreateCluster body 漏 resource_group_id → 集群静默落到 default 组，
      且 ACK 不支持资源组迁移（MoveResources → UnsupportedOperation）→ 只能删除重建。

用法：
  python3 deploy/patch_ack_task10.py --check    # 只报告
  python3 deploy/patch_ack_task10.py --apply    # 写入（自动 .bak-ackt10-<ts>）
"""
import argparse
import datetime
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
D = ROOT / "deploy"

GUIDES = [
    D / "docs" / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md",
    D / "docs" / "阿里云国际站菲律宾部署_详细操作指南.md",
    D / "docs" / "阿里云国际站菲律宾部署_详细操作指南-ch.md",
]
PARTS = [D / "wf2" / "part2a.md"]

CLUSTER_ID = "cd57e40ce9a634c1698c2f5c5e09bd93c"
MARK = CLUSTER_ID                              # 主幂等标记（完整 cluster_id）
MARK_SLA = "SLA 口径更正（2026-09-29 实测 + SLA 原文）"   # 次幂等标记（SLA 段标题，不会因省略写法失配）

# ---------- ① SLA 口径更正（前置/状态 行，v2.0 + part2a 同文） ----------
SLA_OLD = (
    "专有版（Dedicated）已停售，只建 ACK 托管版 Pro（`ack.pro.small`，"
    "**多可用区 regional 控制面**，否则 SLA 只有 99.50% 而非 99.95%，方案 8.2 推导链从根上错）。"
)

SLA_NEW = """专有版（Dedicated）已停售，只建 ACK 托管版 Pro（`ack.pro.small`）。

> ⚠️ **SLA 口径更正（2026-09-29 实测 + SLA 原文）**：ACK SLA（版本生效日期 **2023-04-01**）§1.4/§1.5 把
> 「**区域级集群 regional**」定义为*地域 AZ 数 **≥3***，「**可用区级集群 zonal**」定义为*AZ 数 **≤2*** ——
> **这是地域属性，不是建簇时可选的形态**。马尼拉 `ap-southeast-6` 只有 **6a / 6b 两个 AZ**，
> 故本集群在 SLA 定义上**就是 zonal**，控制面承诺 **99.50%**（月不可用上限 ≈3.6 h），
> **无法通过任何创建选项提升到 99.95%**。
> 另：ACK 控制面**不在** §8.2 的五项串联链（`0.9999^5 ≈ 0.99950`）之内，8.2 推导链**不受影响** ——
> 原「选错形态会让 8.2 从根上错」的说法系**双重误判，已作废**。
> 影响与对冲：控制面不可用**不影响已运行 Pod**（数据面继续服务），但**部署 / 扩缩容 / HPA 扩节点会停摆**；
> 对冲 = 冻结期内不依赖临时扩缩容 + 常态已含 4+2 节点弹性余量。"""

# ---------- ② 坑 4 更正（两套措辞） ----------
K4_OLD_V2 = "- 坑 4｜控制面形态选成 zonal：SLA 只有 99.50% → 后果：SLA 推导链从根上错 → 改进：确认 regional 多可用区控制面。"

K4_OLD_V1 = (
    '- **坑 4｜"控制面 SLA 99.95%" 的前提**：Pro **regional** 集群 99.95%，**zonal** 只有 99.50%。'
    "**后果**：选了跨区形态不对，SLA 推导链（方案 8.2）从根上就错。**改进**：确认选的是**多可用区（regional）**控制面。"
)

K4_NEW = """- 坑 4｜**误信「选 regional 就能拿 99.95%」**：ACK SLA（2023-04-01）§1.4/§1.5 判 regional/zonal 的依据是**地域 AZ 数**（≥3 / ≤2），**马尼拉只有 2 个 AZ → 永远 zonal、承诺 99.50%**，**没有可选的「regional 形态」**。→ 后果：以为能拿到 99.95% 而放松控制面可观测与应急处置。→ 改进：① 接受 **99.50%** 为控制面基线并**书面记录**（业务 SLO 99.95% 由三源外部拨测度量，**不含**控制面）；② 控制面停摆不影响已跑 Pod，但**部署/扩缩容/HPA 会停**，冻结期内不得依赖临时扩缩容；③ 落实自动升级通道 + 维护窗口（本卡步骤 5 已配 `stable` / 周二 03:00–06:00）。
- 坑 5｜**漏写 `resource_group_id` → 集群静默落到 default 组，且 ACK 集群不支持资源组迁移**（`MoveResources` → `UnsupportedOperation.MoveResources`，`Service=cs|ack` × `ResourceType=cluster|Cluster` 四组合全拒），唯一解法是关删除保护后**删除重建**。→ 现象：**无任何报错**，`resource_group_id=rg-acfnssmgwnsb5oa`；→ 后果：违反铁律「默认组禁放 new-api 资源」；→ 改进：body 显式写 `resource_group_id` + **终验加资源组断言**（本次实测已踩中：`ca9dc…` 落 default → 删除 → `cd57e40c…` 带 RG 重建）。
- 坑 6｜**删集群 ≠ 清干净；带对 RG 重建才会连带继承**：ACK 自动建的**内网 SLB**（名 `ManagedK8SSlbIntranet-<cluster_id>`，**是 SLB 不是 ALB**，`aliyun slb DescribeLoadBalancers` 才查得到）、**集群安全组**、**SLS 审计项目** 都是独立资源。带对 RG 重建时三者**自动继承集群 RG**（实测三项全落 `rg-ph-mnl` ✅）；而 `DeleteCluster` **不会**删除 SLS 项目 `k8s-log-<old-cid>`，会残留在 default，须手工 `aliyun sls DeleteProject --project <name> --region <region>`。"""

# ---------- ③ ✅ 已落地 块 ----------
DONE_ANCHOR_V2 = (
    "**⛔ 2026-09-28 状态**：该调用被账号风控拦截（`RISK.RISK_CONTROL_REJECTION`），"
    "任务 10/11 暂停，待充值/客服解禁。参见下方命令块的偏差说明。"
)

DONE_ANCHOR_V1 = "### 5.3 任务 10｜ACK Pro 集群（人员A，2 人时，S4）"

DONE_BLOCK = """**✅ 已落地（2026-09-29 11:57，任务 10 完成）** — 集群 `cd57e40ce9a634c1698c2f5c5e09bd93c`，`state=running`，创建耗时 **3 分 39 秒**

| 项 | 实测值 |
|---|---|
| cluster_id | `cd57e40ce9a634c1698c2f5c5e09bd93c` |
| 规格 / 版本 | `ack.pro.small` / `1.35.7-aliyun.1` |
| 资源组 | `rg-aek4nyivmmsb6iy`（rg-ph-mnl）✅ |
| CNI / ProxyMode | `terway-eniip` v1.17.7 / `ipvs` |
| 私网端点 | `https://10.0.22.182:6443`（**公网端点未开**，`PublicSLB=false`） |
| RRSA | `enabled=true`；`oidc_arn=acs:ram::5108890064395960:oidc-provider/ack-rrsa-cd57e40ce9a634c1698c2f5c5e09bd93c` |
| 自动升级 / 维护窗口 | `stable` 通道已开 / 周二 `03:00–06:00`（Asia/Manila） |
| vSwitch 基线 | app-a free=**4090** · app-b free=**4091**（Terway 每 Pod 占真实 IP） |

终验 **28/28 PASS**；完整字段、RRSA 参数、依赖资源清单 → **`deploy/ack_ledger.md`**；原始证据 `deploy/logs/task10_20260929-115336/`。
账号级前置 `OpenAckService --type propayasgo` 幂等重跑返回 **`ORDER.OPEND`**（服务已开通态）—— **2026-09-28 的账号风控已解除**。
**仍未完成**：`kubectl get ns` / Terway CRD 校验 / kubeconfig 拉取需 **VPC 内**执行 → 等任务 46（堡垒机）；8 EIP 出口复验与 Tair 连通性需节点池 → 等任务 11。

"""


def fix_guide(path: pathlib.Path, apply: bool) -> str:
    if not path.exists():
        return f"[跳过] 不存在：{path}"
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    if MARK in raw:
        return f"[已是最新] {path.name}"
    new = raw
    changes = []

    def rep(old: str, new_s: str, tag: str) -> None:
        nonlocal new
        o = old.replace("\n", nl)
        s = new_s.replace("\n", nl)
        if o in new and s not in new:
            new = new.replace(o, s, 1)
            changes.append(tag)

    rep(SLA_OLD, SLA_NEW, "更正 SLA 口径（regional/zonal 是地域属性）")
    rep(K4_OLD_V2, K4_NEW, "重写坑 4 + 新增坑 5/坑 6")
    rep(K4_OLD_V1, K4_NEW, "重写坑 4 + 新增坑 5/坑 6")

    # 插入 ✅ 已落地 块（插在锚点之后）
    for anchor, tag in ((DONE_ANCHOR_V2, "v2.0"), (DONE_ANCHOR_V1, "v1/ch")):
        a = anchor.replace("\n", nl)
        if a in new:
            block = DONE_BLOCK.replace("\n", nl)
            new = new.replace(a, a + nl + nl + block.rstrip(nl), 1)
            changes.append(f"插入「✅ 已落地」块（锚点 {tag}）")
            break

    if not changes:
        return f"[未匹配] {path.name}：无可用替换片段，需人工看"

    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".bak-ackt10-{ts}"))
        path.write_text(new, encoding="utf-8", newline="")
    return f"[{'已写入' if apply else '待改'}] {path.name}：" + "；".join(changes)


def fix_part(path: pathlib.Path, apply: bool) -> str:
    """源部件 wf2/part2a.md：只更正 SLA 口径与坑 4（正文体已另有六处实测修订，不在此脚本范围）"""
    if not path.exists():
        return f"[跳过] 不存在：{path}"
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    if MARK in raw or MARK_SLA in raw:
        return f"[已是最新] {path.name}"
    new = raw
    changes = []
    for old, new_s, tag in (
        (SLA_OLD, SLA_NEW, "更正 SLA 口径"),
        (K4_OLD_V2, K4_NEW, "重写坑 4 + 新增坑 5/坑 6"),
    ):
        o = old.replace("\n", nl)
        s = new_s.replace("\n", nl)
        if o in new and s not in new:
            new = new.replace(o, s, 1)
            changes.append(tag)
    if not changes:
        return f"[未匹配] {path.name}：无可用替换片段"
    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".bak-ackt10-{ts}"))
        path.write_text(new, encoding="utf-8", newline="")
    return f"[{'已写入' if apply else '待改'}] {path.name}：" + "；".join(changes)


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    for p in GUIDES:
        print(fix_guide(p, apply=args.apply))
    for p in PARTS:
        print(fix_part(p, apply=args.apply))
    return 0


if __name__ == "__main__":
    sys.exit(main())
