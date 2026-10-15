#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 impl_deploy.md / impl_tech.md 的 §7.10 成本结构 —— **线上实测口径**。

与上一版（2026-09-27「规划口径」）的区别：
  旧版按《菲律宾部署方案》资源清单的**计划规格**（g9i.2xlarge 包月、RDS 16C64G、
  CK 双副本 8C32G 包月、WAF 企业版 $1400…）估算；
  本版按 **线上实际部署的资源实况 + 真实账单** 重算，单价取：
    · CLI   —— `aliyun ecs|rds DescribePrice`（2026-10-14 实测）
    · 账单  —— `aliyun bssopenapi DescribeInstanceBill`（2026-10 账期）反推的官方日率
    · 官网  —— 官方定价页公开价

折月口径：ECS/磁盘等按量项按 **730 h/月**；账单反推的「日率」项按 **30.4167 天/月**（=730/24）。

用法：
    python3 deploy/ops/gen_cost_table.py            # 打印 markdown
    python3 deploy/ops/gen_cost_table.py --apply    # 回写两份方案文档（自动备份）
"""

import argparse
import datetime
import os
import re
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
H = 730                 # 按量项月小时数
D = H / 24.0            # 30.4167 天/月

# ------------------------------------------------------------------ 实测单价
# --- CLI 实测（aliyun DescribePrice，2026-10-14，USD）
EC_H = {                                  # ECS 按量 USD/小时（节点 = 实例 + 100G 系统盘）
    "mnl_g9ae_2xl": 0.44252,              # ap-southeast-6 ecs.g9ae.2xlarge
    "sg_g9ae_2xl":  0.49732,              # ap-southeast-1 ecs.g9ae.2xlarge
    "sg_g8ine_2xl": 0.53832,              # ap-southeast-1 ecs.g8ine.2xlarge
    "jkt_g9ae_l":   0.124328,             # ap-southeast-5 ecs.g9ae.large
    "jkt_g9i_l":    0.112728,             # ap-southeast-5 ecs.g9i.large
}
DISK300_H = 0.07596                       # ESSD PL1 300G 数据盘 USD/小时（含税档同价两地）
DISK100_H = 0.02532                       # ESSD PL1 100G 数据盘 USD/小时（= 300G × 1/3；线性计价，两地同价）
OPS_MONTH = 48.25                         # ecs.c9i.large(2C4G)+40G ESSD PL1，包月
RDS_MONTH = 168.26                        # pg.n4.2c.2m(2C8G, HA 1主1备)+100G ESSD PL1，包月

# --- 账单反推（aliyun bssopenapi DescribeInstanceBill，2026-10 账期 USD/天）
R = {
    "ack":  2.160,      # ACK Pro 控制面 /集群/天（= $0.09/h × 24）
    "clb":  0.429,      # ACK 自动创建内网 CLB /天
    "alb":  0.437,      # ALB 标准版（实例费 + LCU）/天
    "nat":  0.880,      # NAT 增强型（实例费 + CU）/天
    "nat_sg": 0.881,
    "nat_jkt": 0.878,
    "eip":  0.120,      # EIP 保有费 /IP/天
    "eip_jkt": 0.144,
    "ck":   35.587,     # ClickHouse 企业版（2 server 节点 / OSS / Serverless）/天
    "kms":  0.346,      # KMS 3.0 凭据管家 /天
    "gtm":  0.221,      # GTM 3.0（1 接入域名 / 1 池 / 1 地址 / 3 节点 / 60s）/天
    "sls":  5.00 / 13.33,   # SLS 实测合计 5.00 USD / 13.33 天
    "cms":  0.678 / 13.33,  # 云监控 + 拨测 实测合计 0.678 USD / 13.33 天
    "oss":  0.013 / 13.33,  # OSS 实测合计 0.013 USD / 13.33 天
}
ACR_MONTH = 157.00        # ACR 企业版（基础版）订阅，2026-09 实付
TAIR_MNL_MONTH = 64.63    # Tair 企业版 主备（1g.2db.0rodb.6proxy），2026-09 实付
TAIR_SG_MONTH = 88.02     # Tair 集群版（tair.rdb.with.proxy.1g ×2 shard，ESSD PL1 5G），2026-10 实付
RDS_DEV_MONTH = 43.38     # 雅加达 dev RDS pg.n2.2c.1m(2C4G,20G,基础版) 包月
RDS_DEV_PAYG = 2.194 * D  # 雅加达 dev RDS 后付（存储/备份）实测日率

# ------------------------------------------------------------------ 流量类单价
# --- 阿里云国际站官网公开定价页（2026-10-14 查证）
EIP_TRAFFIC_GB = {"mnl": 0.081, "sg": 0.081, "jkt": 0.090}   # BGP(多线) EIP 出方向 USD/GB
NAT_CU_RATE    = {"mnl": 0.043, "sg": 0.043, "jkt": 0.043}   # 增强型 CU USD/CU（跨 AZ 档）
#   1 CU = 处理流量 1 GB（入 + 出均计）；单 AZ 档为 0.034（0~100 万 CU）
# --- 「上量后」出口流量估算口径（项目负责人 2026-10-14 给定：100 MB/天）
TRAFFIC_MB_DAY = 100
TRAFFIC_GB_MONTH = TRAFFIC_MB_DAY / 1024.0 * D              # ≈ 2.97 GB/月
TRAFFIC_MNL_MONTH = TRAFFIC_GB_MONTH * (EIP_TRAFFIC_GB["mnl"] + NAT_CU_RATE["mnl"])   # ≈ $0.37/月


def m(v):
    return f"{v:,.2f}"


def rows_mnl():
    r = []
    r.append(("计算", "ECS 节点池 ×4", "ecs.g9ae.2xlarge（8C32G）+ 100G ESSD PL1 系统盘", "按量",
              f"$0.44252/h → ${m(EC_H['mnl_g9ae_2xl']*H)}/台·月 × 4", EC_H["mnl_g9ae_2xl"] * H * 4, "CLI"))
    r.append(("计算", "ECS 数据盘 ×4", "300G ESSD PL1（独立云盘）", "按量",
              f"$0.07596/h → ${m(DISK300_H*H)}/台·月 × 4", DISK300_H * H * 4, "CLI"))
    r.append(("计算", "运维跳板节点 ×1", "ecs.c9i.large（2C4G）+ 40G ESSD PL1", "包月",
              "$48.25/台·月 × 1", OPS_MONTH, "CLI"))
    r.append(("计算", "ACK Pro 托管版 ×1", "ack-newapi-mnl（cd57e40c…）控制面 99.95%", "按量",
              f"$0.09/集群·h → ${m(R['ack']*D)}/月", R["ack"] * D, "账单"))
    r.append(("计算", "ACK 内网 CLB ×1", "ManagedK8SSlbIntranet-cd57e40c…（ACK 自动创建）", "按量",
              f"$0.429/天 → ${m(R['clb']*D)}/月", R["clb"] * D, "账单"))
    r.append(("计算", "ACR 企业版 ×1", "cri-avfqy9xkqi5bj8ee（基础版实例，两地共用）", "订阅",
              "$157.00/月（2026-09 实付）", ACR_MONTH, "账单"))
    r.append(("接入", "ALB ×1", "alb-1riqckb1h8ezm0y7s9（标准版 / Internet / Fixed / 2 AZ）", "按量",
              f"$0.437/天（实例费+LCU） → ${m(R['alb']*D)}/月", R["alb"] * D, "账单"))
    r.append(("网络", "NAT 网关 ×1", "ngw-5tss1ii3…（增强型 / 跨 AZ）", "按量",
              f"$0.880/天（实例费+CU） → ${m(R['nat']*D)}/月", R["nat"] * D, "账单"))
    r.append(("网络", "EIP 保有费 ×6", "4 个上游白名单 EIP + 2 个 ALB 自带 EIP（PayByTraffic）", "按量",
              f"$0.120/天·IP → ${m(R['eip']*D)}/IP·月 × 6", R["eip"] * D * 6, "账单"))
    r.append(("数据", "RDS PostgreSQL 高可用 ×1", "pg.n4.2c.2m（2C8G，1 主 1 备）+ 100G ESSD PL1", "包月",
              "$168.26/月（CLI 实测 = 2026-09 实付）", RDS_MONTH, "CLI"))
    r.append(("数据", "Tair（兼容 Redis）×1", "企业版 主备 / redis.amber…1g.2db.0rodb.6proxy", "包月",
              "$64.63/月（2026-09 实付）", TAIR_MNL_MONTH, "账单"))
    r.append(("日志", "ClickHouse 企业版 ×1", "cc-5tsv2o51s1360b0pr（单 AZ / 2 server 节点 / OSS 存储 / Serverless 4–32CU）", "按量",
              f"$35.587/天 → ${m(R['ck']*D)}/月", R["ck"] * D, "账单"))
    r.append(("观测", "SLS 日志服务", "7 个项目（sls-newapi-mnl + k8s-log-cd57… + ARMS/CMS 托管）", "按量",
              f"实测 $5.00 / 13.33 天 → ${m(R['sls']*D)}/月", R["sls"] * D, "账单"))
    r.append(("观测", "云监控 + 拨测", "1 个站点拨测任务（www.likha.hk/api/status，5 min，PC 组）", "按量",
              f"实测 $0.678 / 13.33 天 → ${m(R['cms']*D)}/月", R["cms"] * D, "账单"))
    r.append(("接入", "GTM 3.0", "gtm-post-2109945017262880768（postpay_standard，www.likha.hk）", "按量",
              f"$0.221/天 → ${m(R['gtm']*D)}/月", R["gtm"] * D, "账单"))
    r.append(("安全", "KMS 3.0 凭据管家", "kst-php6abb88e21s0imvefj", "按量",
              f"$0.346/天 → ${m(R['kms']*D)}/月", R["kms"] * D, "账单"))
    r.append(("存储", "OSS ×3", "oss-newapi-mnl + img-likha + cri-…-registry（标准 LRS）", "按量",
              f"实测 $0.013 / 13.33 天 → ${m(R['oss']*D)}/月", R["oss"] * D, "账单"))
    r.append(("网络", f"出口流量（上量后估算 {TRAFFIC_MB_DAY} MB/天）",
              f"EIP 出方向 ${EIP_TRAFFIC_GB['mnl']}/GB + NAT CU ${NAT_CU_RATE['mnl']}/CU（1 CU = 1 GB）", "按量",
              f"{TRAFFIC_GB_MONTH:.2f} GB/月 × ${EIP_TRAFFIC_GB['mnl']+NAT_CU_RATE['mnl']:.3f}/GB → 估算",
              TRAFFIC_MNL_MONTH, "官网"))
    r.append(("网络", "VPC / vSwitch / 安全组 / ActionTrail", "——", "免费", "免费", 0.0, "官网"))
    return r


def rows_sg():
    r = []
    r.append(("计算", "ECS 节点池 ×2", "1×ecs.g8ine.2xlarge + 1×ecs.g9ae.2xlarge（8C32G）+ 100G ESSD PL1 系统盘", "按量",
              f"($0.53832 + $0.49732)/h → ${m((EC_H['sg_g8ine_2xl']+EC_H['sg_g9ae_2xl'])*H)}/月", (EC_H["sg_g8ine_2xl"] + EC_H["sg_g9ae_2xl"]) * H, "CLI"))
    r.append(("计算", "ECS 数据盘 ×2", "300G ESSD PL1（独立云盘）", "按量",
              f"$0.07596/h → ${m(DISK300_H*H)}/台·月 × 2", DISK300_H * H * 2, "CLI"))
    r.append(("计算", "ACK Pro 托管版 ×1", "ack-newapi-sg（ca75829e…）控制面 99.95%", "按量",
              f"$0.09/集群·h → ${m(R['ack']*D)}/月", R["ack"] * D, "账单"))
    r.append(("计算", "ACK 内网 CLB ×1", "ManagedK8SSlbIntranet-ca75829e…（ACK 自动创建）", "按量",
              f"$0.429/天 → ${m(R['clb']*D)}/月", R["clb"] * D, "账单"))
    r.append(("接入", "ALB ×1", "alb-amdwm60xmznh7s1nae（标准版 / Internet / Fixed / 2 AZ）", "按量",
              f"$0.437/天 → ${m(R['alb']*D)}/月", R["alb"] * D, "账单"))
    r.append(("网络", "NAT 网关 ×1", "ngw-t4n7gdnoh…（增强型 / 跨 AZ）", "按量",
              f"$0.881/天 → ${m(R['nat_sg']*D)}/月", R["nat_sg"] * D, "账单"))
    r.append(("网络", "EIP 保有费 ×6", "4 个上游白名单 EIP + 2 个 ALB 自带 EIP", "按量",
              f"$0.120/天·IP → ${m(R['eip']*D)}/IP·月 × 6", R["eip"] * D * 6, "账单"))
    r.append(("数据", "Tair 集群版 ×1", "tair.rdb.cluster.sharding.common（tair.rdb.with.proxy.1g ×2 shard / ESSD PL1 5G / 双 AZ）", "包月",
              "$88.02/月（2026-10 实付）", TAIR_SG_MONTH, "账单"))
    r.append(("存储", "OSS ×1", "oss-newapi-backup-sgp（标准 LRS，CRR 目标）", "按量",
              f"实测 → ${m(R['oss']*D)}/月", R["oss"] * D, "账单"))
    r.append(("网络", "VPC / vSwitch / 安全组", "——", "免费", "免费", 0.0, "官网"))
    return r


def rows_jkt():
    r = []
    r.append(("计算", "ECS 节点池 ×2", "1×ecs.g9ae.large（2C8G）+ 1×ecs.g9i.large（2C8G）+ 40G ESSD PL1", "按量",
              f"($0.124328 + $0.112728)/h → ${m((EC_H['jkt_g9ae_l']+EC_H['jkt_g9i_l'])*H)}/月", (EC_H["jkt_g9ae_l"] + EC_H["jkt_g9i_l"]) * H, "CLI"))
    r.append(("计算", "ACK 内网 CLB ×1", "ManagedK8SSlbIntranet-cb0abf5b…", "按量",
              f"$0.429/天 → ${m(R['clb']*D)}/月", R["clb"] * D, "账单"))
    r.append(("网络", "NAT 网关 ×1", "ngw-k1aij9gq…（增强型）", "按量",
              f"$0.878/天 → ${m(R['nat_jkt']*D)}/月", R["nat_jkt"] * D, "账单"))
    r.append(("网络", "EIP 保有费 ×1", "eip-k1ans4dq…", "按量",
              f"$0.144/天 → ${m(R['eip_jkt']*D)}/月", R["eip_jkt"] * D, "账单"))
    r.append(("数据", "RDS PG dev ×1", "pgm-d9j9p421lzx4gw73（pg.n2.2c.1m，2C4G，20G ESSD PL1，基础版）", "包月+后付",
              f"$43.38/月 + 后付 ${m(RDS_DEV_PAYG)}/月", RDS_DEV_MONTH + RDS_DEV_PAYG, "账单"))
    r.append(("计算", "ACK Pro 控制面", "ack-newapi-jkt-dev（cb0abf5b…）", "按量",
              "⚠ 账单未见计费（疑似账号首集群免费额度）", 0.0, "账单"))
    return r


def table(rows, subtotal_label="小计"):
    out = ["| # | 资源 | 实际规格（线上实测） | 计费方式 | 单价与算式 | USD/月 | 来源 |",
           "| --- | --- | --- | --- | --- | --- | --- |"]
    n, sub = 0, 0.0
    # ★ 按 USD/月 从高到低排序（2026-10-14 要求）；0 值（免费行）自然落到末尾
    for _, name, spec, billing, rate, amt, src in sorted(rows, key=lambda x: -x[5]):
        n += 1
        tag = {"CLI": "`CLI`", "账单": "`账单`", "官网": "`官网`"}[src]
        out.append(f"| {n} | {name} | {spec} | {billing} | {rate} | {m(amt) if amt else '0.00'} | {tag} |")
        sub += amt
    out.append(f"| | **{subtotal_label}** | | | | **{m(sub)}** | |")
    return "\n".join(out), sub


def markdown():
    mnl, sub_mnl = table(rows_mnl())
    sg, sub_sg = table(rows_sg())
    jkt, sub_jkt = table(rows_jkt())
    total = sub_mnl + sub_sg + sub_jkt
    prod = sub_mnl + sub_sg

    # ---- 目标态：按 2026-10-14 新伸缩下限（mnl min 2 / sg min 1）测算 ----
    per_mnl = EC_H["mnl_g9ae_2xl"] * H + DISK300_H * H            # 单台：实例 + 300G 数据盘
    per_sg_g9ae = EC_H["sg_g9ae_2xl"] * H + DISK300_H * H
    per_sg_g8ine = EC_H["sg_g8ine_2xl"] * H + DISK300_H * H
    tgt_mnl = sub_mnl - per_mnl * 2                               # 4 台 → 2 台
    tgt_sg = sub_sg - per_sg_g8ine                                # 2 台 → 1 台（保留较便宜的 g9ae 口径）
    tgt_prod = tgt_mnl + tgt_sg
    tgt_total = tgt_prod + sub_jkt

    return f"""### 7.10 成本结构（线上实测口径：官方单价 × 实际部署与用量，2026-10-14）

**口径**：全部 USD。本版**以线上实际部署的资源与真实账单为准重算**，与 2026-09-27 的「规划口径」（按《菲律宾部署方案》资源清单的计划规格估算）不同，差异逐项见 7.10.7。

**排列**：7.10.1 / 7.10.2 / 7.10.3 三表均按 **USD/月 从高到低**排序（免费项自然落末），便于一眼看出成本大头。
**「上量后」口径**：出口流量按 **100 MB/天**估算（2026-10-14 项目负责人给定），已作为独立行计入 7.10.1；单价取阿里云国际站官网公开价，标度表见 7.10.8。

**数据源**：

| 标记 | 含义 |
| --- | --- |
| `CLI` | `aliyun ecs\\|rds DescribePrice` **2026-10-14 实测**（ECS / 磁盘 / RDS） |
| `账单` | `aliyun bssopenapi DescribeInstanceBill`（**2026-10 账期**，10-01~10-14 实际计费）反推的官方日率；订阅项取**实付金额** |
| `官网` | 阿里云国际站官方定价页公开价 |

**折月口径**：ECS / 磁盘等按量项按 **730 h/月**；账单反推的日率项按 **30.4167 天/月**（= 730 ÷ 24）。
⚠ **无「未公示项」** —— 本版所有单价均已实测或由账单反推，RDS / ACR 不再是估参。

**实测总账**（本版结论）：**生产两站 ≈ {m(prod)} USD/月**（马尼拉 {m(sub_mnl)} + 新加坡 {m(sub_sg)}）；含雅加达 dev ≈ **{m(total)} USD/月**。

#### 7.10.1 马尼拉主站点（ap-southeast-6）—— 实测

{table(rows_mnl())[0]}

**马尼拉常态小计 ≈ {m(sub_mnl)} USD/月**（含 RDS 实测值，不再有未公示项）

> 与规划稿的三处结构性差异：① 节点机型实际开出 **`ecs.g9ae.2xlarge`**（非 `g9i.2xlarge`），且为**按量付费**（`PostPaid`）；② **无 staging/perf 节点**，压测环境实为**雅加达 dev 集群**（见 7.10.3）；③ **WAF / DCDN / 付费 DNS 均未开通**（见 7.10.7）。
>
> ★ **节点池伸缩边界（2026-10-14 13:00 实测）**：`np-mnl-app` = **min 2 / max 8**（`ModifyClusterNodePool`，ActionTrail 实证 `05:00:02Z`，由原 min 4 下调）。**当前实际仍为 4 台** —— 4 台实例与 8 块云盘的 `CreationTime` 均为 **2026-09-29**，无节点替换、无磁盘变更 ⇒ **本表按实际 4 台计**；按新下限跑满缩容的目标态见 7.10.4 / 7.10.8。

#### 7.10.2 新加坡备 region（ap-southeast-1）—— 实测

{table(rows_sg())[0]}

**新加坡常态小计 ≈ {m(sub_sg)} USD/月**

> ⚠️ 两节点**规格不一致**：`i-t4nha3jicbebtvf3tr7v` = `ecs.g8ine.2xlarge`、`i-t4nb4aj0ssltm7jjawuv` = `ecs.g9ae.2xlarge`（节点池 `np-sg-ph-standby` 为多规格池）。备站**无 RDS、无 ClickHouse**（共用马尼拉主库与 CK），亦**无独立 ACR**（共用马尼拉 ACR 实例）。备站**当前未承接业务流量**（GTM 只挂马尼拉）⇒ 出口流量成本计 **$0**；一旦接管，按同口径 **$0.124/GB** 计算。
>
> ★ **节点池伸缩边界（2026-10-14 12:59 实测）**：`np-sg-ph-standby` = **min 1 / max 10**（`ModifyClusterNodePool`，ActionTrail 实证 `04:59:20Z`，由原 min 2 / max 12 调整）。**当前实际仍为 2 台**（两块实例/四块盘 `CreationTime` 均 2026-09-29）⇒ **本表按实际 2 台计**。

#### 7.10.3 雅加达 dev 环境（ap-southeast-5）—— 非生产 SLA 范围，独立列示

{table(rows_jkt())[0]}

**雅加达 dev 小计 ≈ {m(sub_jkt)} USD/月**（该集群承载压测/冒烟，**不计入生产 SLA 成本**；原规划稿的「staging/perf 2 × g9i.xlarge」即此）

#### 7.10.4 汇总（实测）

| 口径 | 马尼拉 | 新加坡 | 雅加达 dev | 合计（USD/月） |
| --- | --- | --- | --- | --- |
| **常态（当前实况）** | {m(sub_mnl)} | {m(sub_sg)} | {m(sub_jkt)} | **{m(total)}** |
| **生产两站（不含 dev）** | {m(sub_mnl)} | {m(sub_sg)} | — | **{m(prod)}** |
| **目标态（按 10-14 新下限：mnl 2 / sg 1，估算）** | {m(tgt_mnl)} | {m(tgt_sg)} | {m(sub_jkt)} | **{m(tgt_total)}** |
| 日烧钱速率（常态） | — | — | — | ≈ **${m(total/30.4167)}/天** |

> ★ **目标态说明**：2026-10-14 两次 `ModifyClusterNodePool` 把节点池下限调至 **mnl 2 / sg 1**（实证见 7.10.1 / 7.10.2）。若两地按新下限跑满缩容（mnl 4→2 台、sg 2→1 台），**生产两站 ≈ {m(tgt_prod)} USD/月**（较常态省 **{m(prod-tgt_prod)}/月**，降幅 **{m((prod-tgt_prod)/prod*100)}%**）。⚠ 目标态是**容量下限估算、非当前实况**；是否真正缩到下限由 ACK 依据负载利用率判定，**不会因改下限而立即执行**。

**对照账号余额**：2026-10-14 **11:0x 最新实测可用余额 374.50 USD**（同日 09:5x 为 380.33、10-12 为 699.00；现金 374.50 / 信用 0.00）⇒ 日内 1.1 h 消耗 ≈ 5.8 USD，折 **≈130 USD/天**，与上表 **{m(total/30.4167)} USD/天** 同量级（差额为一次性项与按量浮动）。✅ **已安排充值（受理中，2026-10-14）** ⇒ 此前「余额仅够约 2.4 天」的告警**解除**（⚠ 截至本次实测**充值尚未到账**）。⚠ 仍建议配置**余额 + 到期双告警**（建议阈值：余额 < 1,000 USD 或日均消耗 > 250 USD），避免再次出现余额见底才补的被动局面。

#### 7.10.5 2026-10 账期实付对照（真实账单）

| 产品 | 2026-09 全账期 | 2026-10（至 10-14，13.3 天） | 说明 |
| --- | --- | --- | --- |
| 云服务器 ECS（按量） | 98.07 | 975.59 | 6 节点 mnl+sg + 2 节点 jkt |
| 云数据库 ClickHouse | 21.20 | 474.49 | 企业版按量，单站 |
| 块存储（数据盘） | 15.78 | 145.41 | 6 × 300G ESSD PL1 |
| 云数据库 Tair | 64.63（订阅）+ 0.63（后付） | 88.02（订阅） | 09 月为 mnl；10 月为 sg |
| 容器服务 ACK | 6.12 | 57.60 | 2 集群（jkt 未计费） |
| 云数据库 RDS | 168.26（订阅）+ 0.54（后付） | 43.38（订阅）+ 25.40（后付） | 09 含 prod 首月；10 为 dev |
| NAT 网关 | 4.17 | 35.07 | 3 个（mnl/sg/jkt） |
| 负载均衡 | 1.35 + 0.10 | 26.22 | ALB ×2 + ACK 内网 CLB ×3 |
| 弹性公网 IP | 2.25 | 19.65 | 13 个保有费 |
| 数字证书 | — | 212.07 | **一次性**（DV 通配符实付；OV $997 已退款，见 7.10.6） |
| 域名注册 | — | 18.00 | **一次性** |
| 日志服务 SLS | 0.37 | 5.00 | — |
| 密钥管理 KMS | 0.00 | 4.50 | — |
| 云监控 + 拨测 | — | 0.68 | 1 个拨测任务 |
| 云解析 DNS（GTM） | — | 0.22 | GTM 3.0 按量 |
| 对象存储 OSS | 0.00 | 0.01 | 4 个 bucket，用量极小 |
| 容器镜像 ACR | 157.00（订阅） | — | 10 月未出账（订阅周期） |
| **合计（含一次性）** | **588.72** | **2,131.31** | 09 月为搭建期（09-24 起） |

> 上表口径为 `DescribeInstanceBill` 按实例汇总（`QueryBillOverview` 口径为 **2,137.82**，差 6.5 为抹零与未归类项）。
> 2026-09 含大量**搭建期临时实例**（短时 ECS / 磁盘，单笔 <$1，合计约 **$48**），已体现在 09 月合计中但未计入 7.10.1~7.10.3 的常态表。

#### 7.10.6 一次性 / 非经常项（不计入月度常态）

| 项 | 金额（USD） | 说明 |
| --- | --- | --- |
| DV 通配符证书 `*.likha.hk`（**生产在用**） | **212.07** | 订单 `cas_intl-sg-4rf4zyk0u00s`：新购 207.00 + 升级/降级 5.07；`CertIdentifier=606823-ap-southeast-1`，`issued`，**有效期至 2027-04-28** |
| ~~OV 通配符证书 `*.likha.hk`~~ | **0.00（已退款）** | 订单 `cas_intl-sg-9lu4zmk9e00m`：新购 997.00 + **退款 −997.00** ⇒ **净额 0** |
| 域名注册 | 18.00 | `ST49XLYWX261QWX` |
| 正式发布期待购 | — | WAF 3.0 企业版 / DCDN / 付费 DNS（若按原规划启用，见 7.10.7） |

> ✅ **证书一次性支出 = 212.07 USD（净额）** —— 2026-10-14 核实：**OV 通配符（$997）已退款**（账单实证 `cas_intl-sg-9lu4zmk9e00m`：新购 +997.00 / 退款 −997.00），**改为 DV 通配符**（`cas_intl-sg-4rf4zyk0u00s`：207.00 + 5.07 = **212.07**）。DV 覆盖 `*.likha.hk` + `likha.hk`、有效期至 **2027-04-28**，**较 OV 方案省 $784.93**。原「997 悬案」**已闭合**。

#### 7.10.7 与 2026-09-27 规划口径的差异（逐项）

| 项 | 规划稿（2026-09-27） | 线上实测（本版） | 差异主因 |
| --- | --- | --- | --- |
| ECS 节点机型 | `g9i.2xlarge` **包月** $232.37/台 | `g9ae.2xlarge` **按量** $323.04/台 | ① `g8i` 全系马尼拉无库存后实际开出 `g9ae`；② **2026-10-06 裁定：ECS 节点池维持按量付费** |
| staging / perf | 2 × `g9i.xlarge` 包月 $247.58 | **无**（改为雅加达 dev 集群，独立列） | 环境隔离改到 ap-southeast-5 |
| ACK Pro | 仅计 1 集群/地域 | 2 集群计费（jkt 未计费） | 集群数实测为 3 |
| ACR 企业版 | $113/月（2020 版 PDF，待复核） | **$157.00/月**（实付） | 旧价作废，已按实付更正 |
| ALB | $15.33 + LCU $27.59 | **$13.29/天·月**（实例费 + LCU 合并实测） | 实测 LCU 远低于假设 5.4 LCU |
| NAT | $31.39 + CU $169.51 | **$26.77/天·月**（实例费 + CU 合并实测） | 实测出口流量远低于假设 3,942 GB/月 |
| EIP | 保有 $17.52 + 出口流量 $319.30 | **$21.90**（保有费）+ 上量后估算 **$0.37** | 出口流量按 **100 MB/天** 估算（见 7.10.8），远低于原假设 |
| WAF 3.0 企业版 | $1,400/月 × 2 | **未开通**（$0） | 任务 20 未执行；账单与 `DescribeInstance` 双证 |
| DCDN | $60/月 | **未开通**（$0） | `DcdnServiceNotFound`：服务未激活 |
| 云解析 DNS | 企业旗舰版 $13.92/月 | **免费版**（$0）；GTM 3.0 独立 $6.72/月 | 实际用免费版 DNS + GTM 3.0 接入 |
| GTM | 旗舰版 $140/月 | **GTM 3.0 按量 $6.72/月** | 改用 GTM 3.0（postpay），探测 60 s × 3 节点 |
| OSS | $4.64 + $2.32 | **$0.03** | 实际用量极小 |
| SLS | $7.00 + $2.33 | **$11.41** | 写入量实测略高于假设（k8s-log 为主） |
| ARMS Prometheus | $8.80 | 已含在 SLS 项 | ARMS 实例为 remote-write，落 SLS |
| ARMS 应用监控 | $168.00 | **未开通**（$0） | 4 Agent 未接入 |
| 云监控拨测 | $145.15 | **$1.55** | 实测口径远低于 $8.4/万次 的假设 |
| Tair（mnl） | 4GB 主备 按量 $89.35 | 企业版主备 包月 **$64.63** | 规格改为 1G/2DB/6proxy；付费改包月 |
| Tair（sg） | 4GB 主备 按量 $99.28 | 集群版 包月 **$88.02** | 规格与付费方式均变 |
| ClickHouse | 社区版双副本 8C32G **包月** $1,728.32/站 × 2 站 | 企业版 **按量** 单 AZ 2 节点 / OSS 存储，**单站 ${m(R['ck']*D)}** | ① 改为企业版按量；② **仅马尼拉 1 站**；③ 部署改单 AZ |
| RDS PG 高可用 | 未公示，参照 PolarDB $2,944.82/月 | **$168.26/月**（实测） | 规格由 16C64G 实为 **2C8G**；参照值虚高 17× |
| 运维跳板节点 | 未列 | **$48.25/月** | 新增（`newapi-ops-mnl`，包月） |
| ACK 内网 CLB | 未列 | **$39.15/月**（3 集群） | 新增（ACK 自动创建） |
| KMS 3.0 | 「暂计 0」 | **$10.52/月** | 新增（凭据管家已启用） |
| **合计（生产两站）** | **9,865.36** | **{m(prod)}** | ↓ 约 **{m((9865.36-prod)/9865.36*100)}%** |

**降幅主因**：① **WAF 未开通**（−2,800/月）；② **CK 由 2 站包月改 1 站按量**（−2,374/月）；③ **RDS 参照值虚高**（−2,777/月）；④ 流量类（NAT CU + EIP 出口 + DCDN）与拨测实测远低于假设（−约 700/月）；⑤ GTM 由旗舰版订阅改 3.0 按量（−133/月）。
**升幅项**：ECS 由包月改按量（+363/月）、SLS（+2/月）、新增 ops 节点 / 内网 CLB / KMS（+98/月）。

#### 7.10.8 降本与优化（基于实测重算）

| 手段 | 空间（实测口径） | 代价 / 前提 |
| --- | --- | --- |
| **★ ECS 数据盘 300G → 100G** | 实测数据盘（挂 `/var/lib/container`，nvme1n1）**整盘 used 7.9 GiB** / 容量 290 GiB ⇒ 使用率 **2.7%**（该盘同时承载 `/var/lib/kubelet` + `/var/lib/containerd` + `/var/log/pods` 三个 bind 目录；仅 imageFs 口径为 4.4–4.8 GiB）⇒ 降 100G 后按现用量使用率 ≈ **8.2%**（≈ 12 倍余量）。省 = 每台 **${m((DISK300_H-DISK100_H)*H)}/月**（$55.45→$18.48）：mnl 4 台 **${m((DISK300_H-DISK100_H)*H*4)}/月** + sg 2 台 **${m((DISK300_H-DISK100_H)*H*2)}/月** ⇒ **合计 ${m((DISK300_H-DISK100_H)*H*6)}/月**（年化 ${m((DISK300_H-DISK100_H)*H*6*12)}，占生产两站 ${m((DISK300_H-DISK100_H)*H*6/prod*100)}%） | ⚠ 云盘**不支持原地缩容** ⇒ 须改节点池 `data_disks[0].size=100` 并**逐台轮转节点**（cordon → drain → 删除 → 节点池自动补新节点）；挂盘由 **ACK 内置 `[step=diskinit]` 步骤**自动完成（实测 `ack-deploy.log`），**无需改 `disk_init`** ⇒ 建议先灰度 1 台验证 |
| **★ 马尼拉按新下限常态 2 台**（4 → 2） | 单台 **${m(per_mnl)}/月**（`g9ae.2xlarge` + 300G ESSD PL1）⇒ 减 2 台省 **${m(per_mnl*2)}/月** | ⚠ 下限现为 **min 2**（2026-10-14 13:00 由 4 调整）；跨 AZ 由 2/2 变 **1/1**，**失去「单 AZ 故障仍余 2 台」的冗余**；能否真缩由 ACK 按利用率判定 |
| **★ 新加坡按新下限常态 1 台**（2 → 1） | 减 1 台省 **${m(per_sg_g9ae)} ~ ${m(per_sg_g8ine)}/月**（含 300G 盘；`g9ae` 台 ${m(per_sg_g9ae)} / `g8ine` 台 ${m(per_sg_g8ine)}） | ⚠ 下限现为 **min 1**（2026-10-14 12:59 由 2 调整）；备站**只剩单 AZ 单节点**，接管 RTO 与容量须重评 |
| ClickHouse 降配 | 当前 **${m(R['ck']*D)}/月**，已是最大单项：调低 server 数 / 预留 CU / 缩短 `LOG_SQL_CLICKHOUSE_TTL_DAYS`（现 90 天） | 日志保留期缩短、查询性能下降 |
| 新加坡冷备 | 常态置 0 副本 → 省 2 节点 + 2 盘 ≈ **$861.46/月** | 接管 RTO 秒级 → 分钟级 |
| 备站「减配」 | 备站为低流量旁站，可评估降到 `g9ae.xlarge` 级规格 | 接管期容量需重新标定 |
| 雅加达 dev | 按需启停（当前 ≈ **${m(sub_jkt)}/月**） | 压测窗口外无环境 |
| 拨测间隔 | 当前 5 min 已是低成本档（$1.55/月），无优化空间 | — |
| 出口流量 | 现测 NAT CU 极低（< 1 CU/天）；按 **100 MB/天** 估算仅 **${m(TRAFFIC_MNL_MONTH)}/月** ⇒ 当前**不构成成本瓶颈**（标度表见下注） | 日均出口 > 27 GB 才破 $100/月；上量前考虑 NAT 资源包 |

**不计入本表**：① 上游 token 成本（与网关 SLA 解耦）；② **不含 GA**（理由见 7.1）；③ 跨区数据库读写公网流量（RDS 国际站公网流量 100% 折扣）；④ 一次性费用（证书 / 域名，见 7.10.6）。

**⚠ 流量口径与「上量后」估算（2026-10-14 更新）**：2026-10 账单中「云数据传输（CDT）」与 EIP 流量项均 ≈ $0 ⇒ **当前尚无真实业务出口流量**（未对上游发量，正式发布 = Day 4 任务 34）。按项目负责人给定口径「**上量后 ≈ {TRAFFIC_MB_DAY} MB/天**」，已作为独立行计入 7.10.1（**+${m(TRAFFIC_MNL_MONTH)}/月**）。

**流量类单价**（阿里云国际站官网公开定价页，2026-10-14 查证）：

| 计费项 | 单价 | 口径 |
| --- | --- | --- |
| EIP **出方向**流量（BGP 多线） | **$0.081/GB** | 新加坡 / 菲律宾马尼拉**同价**；雅加达 $0.090 |
| NAT 增强型**容量单位 CU** | **$0.043/CU**（跨 AZ）· $0.034（单 AZ，0~100 万 CU） | **1 CU = 处理流量 1 GB**（入 + 出**均计**） |
| **合计（生产口径）** | **$0.124/GB** | EIP $0.081 + NAT CU $0.043 |

**流量成本标度表**（mnl/sg 口径；折月按 30.4167 天，1 GB = 1,024 MB）：

| 出口流量 | 折月 | 流量成本/月 | 定位 |
| --- | --- | --- | --- |
| **{TRAFFIC_MB_DAY} MB/天（本次口径）** | **{TRAFFIC_GB_MONTH:.2f} GB** | **${m(TRAFFIC_MNL_MONTH)}** | 与账单 $0 档基本一致 ⇔ 「未上量」 |
| 1 GB/天 | 30.42 GB | $3.77 | 低强度试用 |
| 10 GB/天 | 304.17 GB | $37.71 | 小规模上线 |
| 100 GB/天 | 3.04 TB | $377.14 | 中等规模 |
| **1 TB/月** | 1,024 GB | **$127.02** | 标度基准（= 原提示口径） |

⇒ **结论**：当前流量成本**可忽略（< $0.4/月）**；只要**日均出口 ≤ 10 GB，流量费 ≤ $38/月，不改变成本结构**（仍由 ClickHouse + ECS 主导）。**突破 $100/月需日均出口 > 27 GB**，届时须重评 NAT CU 分档并考虑 NAT 资源包（按量→资源包可省约 20–30%）。

#### 7.10.9 单价来源

| 资源 | 实测单价 | 取证方式 |
| --- | --- | --- |
| ECS `g9ae.2xlarge`（mnl） | $0.44252/h（实例 + 100G 系统盘） | `aliyun ecs DescribePrice`，2026-10-14 |
| ECS `g9ae.2xlarge`（sg） | $0.49732/h | 同上 |
| ECS `g8ine.2xlarge`（sg） | $0.53832/h | 同上 |
| ECS `g9ae.large` / `g9i.large`（jkt） | $0.124328 / $0.112728 /h | 同上 |
| ESSD PL1 300G 数据盘 | $0.07596/h | 同上（两地同价） |
| `ecs.c9i.large` + 40G（包月） | $48.25/月 | 同上 |
| RDS `pg.n4.2c.2m` 2C8G HA + 100G ESSD PL1 | $168.26/月 | `aliyun rds DescribePrice` + 2026-09 实付 |
| Tair 企业版主备（mnl） | $64.63/月 | 2026-09 `DescribeInstanceBill` 实付 |
| Tair 集群版（sg） | $88.02/月 | 2026-10 `DescribeInstanceBill` 实付 |
| ACR 企业版基础版 | $157.00/月 | 2026-09 `DescribeInstanceBill` 实付 |
| ACK Pro 控制面 | $0.09/集群·h | 账单反推（$2.16/天/集群） |
| ALB 标准版（实例 + LCU） | $0.437/天 | 账单反推 |
| NAT 增强型（实例 + CU） | $0.880 ~ 0.881/天 | 账单反推 |
| EIP 保有费 | $0.120/天·IP（≈ $0.005/h） | 账单反推 |
| ClickHouse 企业版 | $35.587/天 | 账单反推 |
| GTM 3.0 / KMS / SLS / CMS / OSS | 见 7.10.1 | 账单反推 |
| ACK 内网 CLB | $0.429/天 | 账单反推 |
| **EIP 出方向流量** | **$0.081/GB**（mnl / sg）· $0.090/GB（jkt） | **阿里云国际站官网 EIP 定价页**，2026-10-14 |
| **NAT 增强型容量单位 CU** | **$0.043/CU**（跨 AZ）· $0.034（单 AZ，0~100 万 CU）；**1 CU = 1 GB** | **阿里云国际站官网 NAT 网关计费页**，2026-10-14 |

**官方定价页参考**：NAT [88658](https://www.alibabacloud.com/help/doc-detail/88658.htm) · EIP [pay-as-you-go](https://www.alibabacloud.com/help/en/eip/pay-as-you-go) · ALB [billing-rules](https://www.alibabacloud.com/help/en/slb/application-load-balancer/product-overview/alb-billing-rules) · GTM [gtm3-product-billing](https://www.alibabacloud.com/help/en/dns/gtm3-product-billing) · ACK [86759](https://www.alibabacloud.com/help/doc-detail/86759.htm) · ClickHouse [pricing](https://www.alibabacloud.com/help/en/clickhouse/product-overview/pricing/) · OSS [pricing-list](https://www.alibabacloud.com/product/oss-pricing-list) · SLS [billable-items](https://www.alibabacloud.com/help/en/log-service/latest/billable-items) · ARMS [pricing](https://www.alibabacloud.com/product/arms/pricing)

*成本表生成：`deploy/ops/gen_cost_table.py`（`--apply` 自动回写并备份）· 取证脚本：`deploy/logs/t_cost_*.sh|py` · 核价基准日 **2026-10-14** · 账期 **2026-10-01~10-14***
*更新 2（2026-10-14 10:5x）：① 余额告警解除（**充值受理中**）；② **OV 证书退款确认**（净额 0）⇒ 证书实付 **$212.07**；③ 新增**上量后出口流量估算**（100 MB/天 ⇒ $0.37/月）+ 标度表；④ 7.10.1/7.10.2/7.10.3 三表改按 **USD/月 降序**排列。*
*更新 3（2026-10-14 13:0x）：负责人两次 `ModifyClusterNodePool` 调低节点池伸缩下限（**mnl min 4→2**、**sg min 2→1 / max 12→10**，ActionTrail 实证 12:59 / 13:00）。**实测 ECS 实例、磁盘、规格一律未变**（全部 `CreationTime` 仍为 2026-09-29，无替换）⇒ **常态表数字不变**；新增 **7.10.4 目标态行**（mnl 2 / sg 1 估算）与 **7.10.8 两条降本行**。*
"""


def patch(path):
    txt = open(path, encoding="utf-8").read()
    m = re.search(r"^### 7\.10 .*?(?=\n---\n)", txt, re.S | re.M)
    if not m:
        print(f"  ! {os.path.basename(path)} 未匹配 §7.10 区块，跳过")
        return False
    bak = os.path.join(ROOT, ".workbuddy", "backup",
                       f"cost_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}_{os.path.basename(path)}")
    os.makedirs(os.path.dirname(bak), exist_ok=True)
    shutil.copy2(path, bak)
    open(path, "w", encoding="utf-8").write(txt[:m.start()] + markdown().rstrip() + txt[m.end():])
    print(f"  ✓ {os.path.basename(path)} §7.10 已更新（备份 .workbuddy/backup/{os.path.basename(bak)}）")
    return True


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ns = ap.parse_args()
    if ns.apply:
        patch(os.path.join(ROOT, "impl_deploy.md"))
        patch(os.path.join(ROOT, "impl_tech.md"))
    else:
        print(markdown())
