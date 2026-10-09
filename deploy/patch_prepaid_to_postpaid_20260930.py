#!/usr/bin/env python3
# ==============================================================================
# patch_prepaid_to_postpaid_20260930.py
# 任务 42 后续｜2026-09-30 裁定「ECS 节点池维持按量（PostPaid）」→ 订正 v2.0 指南中
# 所有"节点池 = 包年包月/PrePaid"的不准确描述（共 30 处）。
#
# 范围界定：
#   - 只改 `阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（权威手册；-ch.md / 旧版 .md 不维护）
#   - 不动 RDS / Tair / CK / EIP 的"包年包月"描述（实测正确：Tair 马尼拉 ChargeType=PrePaid；
#     RDS Prepaid 落地；CK 只支持按量；EIP 包年包月为 EIP 自身计费）
#   - 历史决策记录保留（划线 + 日期标注），事实改为 2026-09-30 实测口径
#
# 用法：python3 deploy/patch_prepaid_to_postpaid_20260930.py [--check] / [--apply]
# 幂等：以本脚本头部标记串为幂等标记；复跑 --check 应全部 [已是最新]
# ==============================================================================
import sys, shutil, time

FILE = "deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md"
MARK = "2026-09-30 裁定（ECS 节点池按量）"

# (old, new, 说明)
PAIRS = [
# --- §0.5 修订摘要 L7 ---
("**ECS 节点池与 Tair 实例全面改为包年包月（`PrePaid`，1 年 + 自动续费）**；配额核量口径随之从按量 `q_ecs_enterprise_postpay_c`（马尼拉 64 / 新加坡 96）切换为包年包月 **`q_ecs_enterprise_prepay_c`（马尼拉 100 / 新加坡 100，2026-09-28 API 实测）**",
 "**ECS 节点池 = 按量（2026-09-30 裁定维持 `PostPaid`：实测两池/节点/ESS 伸缩配置均为 PostPaid，\"转包年\"未落地且不再转，见 `nodepool_ledger.md` §11.1）**；**Tair = 包年包月（PrePaid，已落地）**；配额核量口径 = 按量 `q_ecs_enterprise_postpay_c`（马尼拉 64 / 新加坡 96，**顶满 max_size**），`q_ecs_enterprise_prepay_c`（100/100，2026-09-28 实测）降为备查",
 "0.5 摘要"),
("任务 11 坑 7/坑 7b/坑 10（扩容即预付、库存独立、数据盘勿转包月）与任务 52 成本表（单价必须取包年包月价）。",
 "任务 11 坑 7/坑 7b/坑 10（**按量口径下暂不适用**，留作未来转 PrePaid 时启用）与任务 52 成本表（ECS 行取按量价）。",
 "0.5 摘要·连带影响"),
# --- §0.5 F2 ---
("**付费方式全面转包年包月后以 prepay 额度为准** |",
 "**2026-09-30 裁定：节点池维持按量，核量以按量额度为准（64/96 顶满 max_size），prepay 额度降为备查** |",
 "F2"),
# --- G0 配额复核命令注释 L193 ---
("# 期望 q_ecs_enterprise_prepay_c=100（包年包月口径；按量 postpay_c=64 仅作对照）",
 "# 期望：按量 q_ecs_enterprise_postpay_c 马尼拉=64 / 新加坡=96（**裁定口径** " + MARK + "，顶满 max_size）；prepay_c=100/100 备查",
 "G0 命令注释"),
# --- 门禁表 G2 / G10 ---
("| G2 | 马尼拉配额批复 | 工单号 b140e263-…（按量 Agree）；**包年包月 `q_ecs_enterprise_prepay_c`=100 实测可用** |",
 "| G2 | 马尼拉配额批复 | 工单号 b140e263-…（**按量 Agree，64** —— 裁定口径，顶满 8×8）；~~包年包月 `q_ecs_enterprise_prepay_c`=100 实测可用~~（2026-09-30 起备查） |",
 "G2"),
("| G10 | 新加坡 ≥96 vCPU | 工单号 e117bf2b-…（按量 Agree）；**包年包月 `prepay_c`=100（需求 96，仅余 4 vCPU）** |",
 "| G10 | 新加坡 ≥96 vCPU | 工单号 e117bf2b-…（**按量 Agree，96 —— 裁定口径，顶满 12×8**）；~~包年包月 `prepay_c`=100（需求 96，仅余 4 vCPU）~~（2026-09-30 起备查） |",
 "G10"),
# --- §1 差异表 #16 ---
("✅ ECS 已批 Agree（F2/F3）；**包年包月口径 `prepay_c`=100/100（2026-09-28 实测）** |",
 "✅ ECS 已批 Agree（F2/F3，**裁定口径 = 按量**：64/96 顶满 max_size）；`prepay_c`=100/100（2026-09-28 实测）降为备查 |",
 "差异 #16"),
# --- §2.2 基线表节点池行 ---
("| 节点池                  | 马尼拉 4×（上限 8，**包年包月**配额 64/100 vCPU）/ 新加坡 2×（上限 12，**包年包月**配额 96/100 vCPU）",
 "| 节点池                  | 马尼拉 4×（上限 8，**按量**配额 64/64 顶满 vCPU）/ 新加坡 2×（上限 12，**按量**配额 96/96 顶满 vCPU）（2026-09-30 裁定维持按量）",
 "基线表"),
# --- §2.1 付费方式表 ECS 段 ---
("| **付费方式（2026-09-28 修订）** | **ECS 节点池 = 包年包月**（`instance_charge_type: PrePaid`，`period_unit: Month` / `period: 12`，`auto_renew: true`）· **Tair = 包年包月**",
 "| **付费方式（2026-09-28 修订；2026-09-30 裁定 ECS 改按量）** | **ECS 节点池 = 按量 `PostPaid`**（2026-09-30 裁定维持；实测两池/节点/ESS 均为 PostPaid，转包年未落地不再转，见 `nodepool_ledger.md` §11.1）· **Tair = 包年包月**",
 "付费方式表"),
# --- §2.1 配额坑注 ---
("**2026-09-28 付费方式修订后：包年包月走独立额度 `q_ecs_enterprise_prepay_c`（马尼拉 100 / 新加坡 100，属默认值、无需工单）——核量时必须查 prepay 而非 postpay，两者分别计量、互不抵扣。**",
 "**2026-09-30 裁定（ECS 节点池维持按量）后：核量以 `q_ecs_enterprise_postpay_c`（马尼拉 64 / 新加坡 96，顶满 max_size）为准；`q_ecs_enterprise_prepay_c`（100/100，属默认值、无需工单）降为备查——两者分别计量、互不抵扣。**",
 "配额坑注"),
# --- G0 配额复核命令块 ---
("# vCPU 额度看 q_ecs_enterprise_prepay_c（**包年包月**，2026-09-28 实测 ap-southeast-6 = 100、ap-southeast-1 = 100）",
 "# vCPU 额度看 q_ecs_enterprise_postpay_c（**按量，2026-09-30 裁定口径**：马尼拉 64 / 新加坡 96，顶满 max_size）",
 "G0 命令块①"),
("# 按量口径对照：q_ecs_enterprise_postpay_c（马尼拉 64 / 新加坡 96）—— 包年包月**不共享**该额度，两者分别计量",
 "# 备查对照：q_ecs_enterprise_prepay_c（包年包月，100/100，2026-09-28 实测）—— 两者**不共享**额度、分别计量，按量池勿以 prepay 判可建量",
 "G0 命令块②"),
("期望输出：马尼拉 ECS **包年包月** vCPU 配额 `q_ecs_enterprise_prepay_c` 的 `TotalQuota=100`，新加坡同为 `100`（2026-09-28 实测，属默认额度、无需工单）。按量口径（`q_ecs_enterprise_postpay_c`）作对照：马尼拉 64 / 新加坡 96（工单 `b140e263-…` / `e117bf2b-…`，状态 `Agree`）。状态核验：",
 "期望输出：马尼拉 ECS **按量** vCPU 配额 `q_ecs_enterprise_postpay_c` 的 `TotalQuota=64`、新加坡 `=96`（2026-09-30 裁定口径，工单 `b140e263-…` / `e117bf2b-…`，状态 `Agree`，**顶满 max_size**）。备查对照（`q_ecs_enterprise_prepay_c`）：马尼拉 100 / 新加坡 100（2026-09-28 实测，属默认额度、无需工单）。状态核验：",
 "G0 期望输出"),
# --- G0 检查表 ---
("☐ G0 表全部通过（含配额：**包年包月** vCPU 马尼拉=100、新加坡=100（`q_ecs_enterprise_prepay_c`）；按量对照 64/96 工单 `Agree`）；机型统一 ecs.g9i.2xlarge；**付费方式：ECS/Tair/RDS = 包年包月（PrePaid）；ACK 集群管理费走 ACK 资源包；CK 企业版只能按量（可选计算资源包，抵扣因子 1.45）**",
 "☐ G0 表全部通过（含配额：**按量** vCPU 马尼拉=64、新加坡=96（`q_ecs_enterprise_postpay_c` 工单 `Agree`，**顶满 max_size**）；`prepay_c`=100/100 备查）；机型统一 ecs.g9i.2xlarge；**付费方式：ECS 节点池 = 按量（2026-09-30 裁定）；Tair/RDS = 包年包月（PrePaid）；ACK 集群管理费走 ACK 资源包；CK 企业版只能按量（可选计算资源包，抵扣因子 1.45）**",
 "G0 检查表"),
# --- Day 2 风险块 ---
("> **Day 2 付费方式（2026-09-28 修订）**：ECS 节点池（任务 11/24）= **包年包月 1 年**（`instance_charge_type: PrePaid` + `period_unit: Month`/`period: 12` + `auto_renew: true`）；ACK 集群管理费**不支持包年包月**，用 **ACK 资源包**抵扣（任务 10）。**节点池付费类型决定后续扩容实例的计费方式 → HPA 扩容即预付、缩容不退款（任务 11 坑 7）。**",
 "> **Day 2 付费方式（2026-09-30 裁定，改写 09-28 版）**：ECS 节点池（任务 11/24）= **按量 `PostPaid`**（实测两池/节点/ESS 伸缩配置均 PostPaid，裁定不转包年，见 `nodepool_ledger.md` §11.1）；ACK 集群管理费**不支持包年包月**，用 **ACK 资源包**抵扣（任务 10）。~~节点池付费类型决定扩容计费 → 扩容即预付~~ —— 仅当池为 PrePaid 时成立（任务 11 坑 7，当前不适用）；**按量口径下扩缩随起随停、按小时计费，约束只剩配额（马尼拉 64 顶满 / 新加坡 96 顶满）**。",
 "Day2 风险块"),
# --- Day2 付费方式块 ---
("> **付费方式（2026-09-28 修订：全面包年包月口径）**",
 "> **付费方式（2026-09-30 裁定：ECS 节点池按量；Tair/RDS 包年包月）**",
 "Day2 付费块①"),
("> - **节点（ECS）= 包年包月** —— 在任务 11 / 任务 24 的节点池 `instance_charge_type:\"PrePaid\"` 落地（`period_unit:\"Month\", period:12` = 包 1 年，`auto_renew:true` 必开，否则到期释放 = 集群掉节点）。**节点池的付费类型决定后续扩容实例的计费方式**。",
 "> - **节点（ECS）= 按量 PostPaid**（2026-09-30 裁定；任务 11/24 实建即 PostPaid，脚本 `instance_charge_type:\"PostPaid\"`）。~~包年包月落地方式~~ 备查：若未来转 PrePaid 则为 `instance_charge_type:\"PrePaid\", period_unit:\"Month\", period:12, auto_renew:true`（`auto_renew` 必开，否则到期释放 = 集群掉节点）。**节点池的付费类型决定后续扩容实例的计费方式**。",
 "Day2 付费块②"),
# --- 任务 11 机型验证命令 / 注释 ---
("  --InstanceChargeType PrePaid --IoOptimized optimized --NetworkCategory vpc --ResourceType instance \\",
 "  --InstanceChargeType PostPaid --IoOptimized optimized --NetworkCategory vpc --ResourceType instance \\",
 "任务11 机型验证命令"),
("# 期望：q_ecs_enterprise_prepay_c=100（马尼拉包年包月 vCPU 上限，2026-09-28 实测；按量口径 q_ecs_enterprise_postpay_c=64 仅作对照）",
 "# 期望：q_ecs_enterprise_postpay_c 马尼拉=64 / 新加坡=96（**按量裁定口径**，顶满 max_size；prepay_c=100/100 备查）",
 "任务11 配额注释"),
("> **包年包月务必用 `--InstanceChargeType PrePaid` 查库存** —— 包年包月与按量的可售池不共享，用 `PostPaid` 查出来的结果不能证明包年包月有货。",
 "> **包年包月务必用 `--InstanceChargeType PrePaid` 查库存** —— 包年包月与按量的可售池不共享，用 `PostPaid` 查出来的结果不能证明包年包月有货。（⏸ 2026-09-30 裁定按量后：机型/库存验证用 `PostPaid` 即可，本条仅在转包年时适用。）",
 "任务11 库存坑注"),
("2. 创建节点池（差异于新加坡：desired/min 4、max 8、site=ph-mnl、**包年包月 1 年**）：",
 "2. 创建节点池（差异于新加坡：desired/min 4、max 8、site=ph-mnl、**按量 PostPaid，2026-09-30 裁定**）：",
 "任务11 建池标题"),
# --- 任务 11 建池 body（JSON，去掉 period 三行）---
('   "desired_size":4,"min_size":4,"max_size":8,"instance_charge_type":"PrePaid",\n   "period_unit":"Month","period":12,"auto_renew":true,"auto_renew_period":1,',
 '   "desired_size":4,"min_size":4,"max_size":8,"instance_charge_type":"PostPaid",',
 "任务11 建池 body"),
# --- 任务 11 修复段 ---
("- 配额复核不通过（`q_ecs_enterprise_prepay_c` 不足 64）→ 包年包月 vCPU 配额未覆盖 → 用 `--DesireValue` + `--QuotaActionCode q_ecs_enterprise_prepay_c` 提交**包年包月**配额申请，等 `Agree` 后再建池；**严禁用按量配额（`postpay_c`）判断包年包月可建量**。",
 "- 配额复核不通过（`q_ecs_enterprise_postpay_c` 不足 64）→ 按量 vCPU 配额未覆盖 → 用 `--DesireValue` + `--QuotaActionCode q_ecs_enterprise_postpay_c` 提交**按量**配额申请，等 `Agree` 后再建池；（若未来转包年，才需查/申 `q_ecs_enterprise_prepay_c`，**严禁**用按量额度判断包年包月可建量）。",
 "任务11 修复段"),
# --- 任务 11 坑 7 / 7b 状态标记 ---
("- 坑 7｜**包年包月 + 自动伸缩 = 成本刚性**（2026-09-28 新增）：",
 "- 坑 7｜**包年包月 + 自动伸缩 = 成本刚性**（2026-09-28 新增；⏸ **2026-09-30 起暂不适用**：节点池裁定维持按量，本坑留作未来转 PrePaid 时启用）：",
 "坑7 标记"),
("- 坑 7b｜**库存抖动导致扩不出机器**：包年包月比按量更吃库存",
 "- 坑 7b｜**库存抖动导致扩不出机器**（⏸ 同坑 7，按量口径下暂不适用）：包年包月比按量更吃库存",
 "坑7b 标记"),
# --- 任务 24 前置注释 ---
("# instance_charge_type:PrePaid、period_unit:Month、period:12、auto_renew:true、auto_renew_period:1（2026-09-28 付费方式修订）、",
 "# instance_charge_type:PostPaid（2026-09-30 裁定；09-28 曾定 PrePaid——period_unit:Month、period:12、auto_renew:true 仅在转包年时使用）、",
 "任务24 注释"),
# --- 任务 42 前置段 ---
("**付费方式为包年包月 → 每次扩容出的节点都按 12 个月预付且缩容不退款**（任务 11 坑 7）：本卡压测打满 `max_size` 前必须先取得预算确认，压测结束后手动把 `desired_size` 回落到基线。",
 "**付费方式 = 按量（2026-09-30 裁定，实测两池 PostPaid）→ 扩缩随起随停、按小时计费，无预付/退款问题；约束是配额顶满（马尼拉 64/64、新加坡 96/96）**：压测打满 `max_size` 前知会财务即可，结束后节点池自动缩回 `min`。",
 "任务42 前置"),
# --- 机型验证留痕检查项 ---
("- [ ] 机型验证留痕：`DescribeAvailableResource --InstanceChargeType PrePaid` 输出确认 `g9i.2xlarge` 双 AZ **包年包月**可售（或已切换 `g8ine.2xlarge` 并回填方案与容量基线）；配额复核 `q_ecs_enterprise_prepay_c` 马尼拉=100、新加坡=100（按量口径 64/96 工单状态 `Agree` 作对照）。",
 "- [ ] 机型验证留痕：`DescribeAvailableResource --InstanceChargeType PostPaid`（**按量裁定口径**）输出确认 `g9i.2xlarge` 双 AZ 按量可售（或已切换 `g8ine.2xlarge` 并回填方案与容量基线）；配额复核 `q_ecs_enterprise_postpay_c` 马尼拉=64、新加坡=96（顶满 max_size；`prepay_c`=100/100 备查）。",
 "机型验证留痕"),
# --- 任务 52 成本表 ---
("**付费方式（2026-09-28 修订）= ECS/Tair 包年包月，故单价必须取包年包月价而非按量价**。",
 "**付费方式（2026-09-30 裁定）= ECS 节点池按量（单价取按量价）、Tair/RDS 包年包月（取包年价）**。",
 "成本表·口径"),
("（按量同配置约 1.57808 USD/小时×4 台 ⇒ 月约 1136 USD，**包月省 ≈18%**）",
 "（按量同配置约 1.57808 USD/小时×4 台 ⇒ 月约 1136 USD，**包月省 ≈18%**；**2026-09-30 裁定 A：ECS 实际按按量 ≈1136 USD/月 计，包月价留作对照**）",
 "成本表·锚点"),
("清单：ECS 马尼拉 `g9i.2xlarge`×4–8（包年包月配额 64/100）、ECS 新加坡 ×2–12（包年包月配额 96/100，**接管时 6× 弹性极高**——但包年包月**扩容即按 12 个月预付、缩容不退款**，弹性成本须按 12 个月上限而非月费率估算）",
 "清单：ECS 马尼拉 `g9i.2xlarge`×4–8（**按量**配额 64/64 顶满）、ECS 新加坡 ×2–12（**按量**配额 96/96 顶满，**接管时 6× 弹性极高**——按量扩缩随起随停，弹性成本按实际运行小时计）",
 "成本表·清单"),
# --- 附录 命令速查 ---
("#   （包年包月口径 q_ecs_enterprise_prepay_c = 100 / 100，2026-09-28 实测）\n#   （按量口径对照 q_ecs_enterprise_postpay_c = 64 / 96，仅作对照；两者分别计量）",
 "#   （**按量裁定口径** q_ecs_enterprise_postpay_c = 64 / 96，顶满 max_size，2026-09-30）\n#   （备查 q_ecs_enterprise_prepay_c = 100 / 100，包年包月口径，2026-09-28 实测；两者分别计量）",
 "附录·配额期望"),
("# 付费方式为包年包月 → 申请的配额码必须是 prepay（postpay 批了也不够用）",
 "# 付费方式 = 按量（2026-09-30 裁定）→ 核量/申请用 postpay_c；prepay 仅在转包年时才需要",
 "附录·申请注释"),
("  --QuotaActionCode q_ecs_enterprise_prepay_c \\",
 "  --QuotaActionCode q_ecs_enterprise_postpay_c \\",
 "附录·申请命令"),
("# 付费方式 = 包年包月 → 查询也必须用 PrePaid（包年包月与按量可售池不共享）",
 "# 付费方式 = 按量（2026-09-30 裁定）→ 可售查询用 PostPaid（可售池与包年包月不共享；转包年时才需 PrePaid）",
 "附录·机型验证注释"),
("  --DestinationResource InstanceType --InstanceChargeType PrePaid \\",
 "  --DestinationResource InstanceType --InstanceChargeType PostPaid \\",
 "附录·机型验证命令"),
]

def main():
    mode = next((a for a in sys.argv[1:] if a in ("--check", "--apply")), "--check")
    with open(FILE, encoding="utf-8") as f:
        text = f.read()

    if MARK in text and mode == "--apply":
        print("[已是最新] 幂等标记已存在，跳过（如需强制重打请先回滚备份）")
        return

    fails, applied = [], 0
    for i, (old, new, tag) in enumerate(PAIRS, 1):
        n = text.count(old)
        if n == 1:
            if mode == "--apply":
                text = text.replace(old, new)
            applied += 1
        elif n == 0 and new in text:
            print(f"  [{i:>2}] [已是最新] {tag}")
        else:
            fails.append((i, tag, n))
            print(f"  [{i:>2}] [FAIL] {tag}（匹配 {n} 次，应为 1）")

    print(f"\n共 {len(PAIRS)} 处：可应用/已应用 {applied}，异常 {len(fails)}")
    if fails:
        print("存在异常，不写文件（--apply 也不会写）。逐条核对 old 串后重试。")
        sys.exit(1)

    if mode == "--apply":
        bak = FILE + ".bak-prepaid2postpaid-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(FILE, bak)
        with open(FILE, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"已写入：{FILE}\n备份：{bak}")

if __name__ == "__main__":
    main()
