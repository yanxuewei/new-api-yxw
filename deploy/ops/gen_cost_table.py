#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 impl_deploy.md / impl_tech.md 的 §7.10 成本结构（阿里云国际站官网价口径）。

价格来源三类：
  CLI   —— 本次 `aliyun ecs|r-kvstore DescribePrice` 实测（2026-09-27）
  DOC   —— 阿里云国际站官方文档 / 定价页公开价（URL 见源索引）
  TODO  —— 官网未公开单价，须登录购买页复核

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
HOURS = 730  # 按量项统一折月小时数（与官方「月档价」区分）

# ---------------------------------------------------------------- 假设量（可调）
ASSUME = {
    "mnl_egress_gb": 3942,     # 马尼拉月出口流量：40 Mbps 峰值 × 30% 平均利用率 ≈ 3.94 TB
    "sg_egress_gb": 500,       # 新加坡备 region 常态月流量
    "mnl_alb_lcu": 5.4,        # 8,000 并发连接 ÷ 3,000 与 3,942 GB ÷ 730 h 取大者
    "sg_alb_lcu": 1.0,
    "dcdn_gb": 500,
    "oss_gb_mnl": 200,
    "oss_gb_sg": 100,
    "sls_write_mnl": 30,
    "sls_store_mnl": 60,
    "sls_write_sg": 10,
    "sls_store_sg": 20,
    "arms_metric_mnl": 50,     # 百万条/月
    "arms_metric_sg": 10,
    "arms_agent_mnl": 4,       # Agent 在线数
    "probe_wan": 17.28,        # 万次/月：4 探测点 × 1 分钟 1 次
    "ck_store_gb": 200,
    "rds_ref_hourly_per_node": 2.017,  # 同规格 PolarDB PG 16C64G 官方公开价（上限参照）
    "rds_ha_nodes": 2,                 # 高可用 = 1 主 1 备
}

# ------------------------------------------------------------------ 单价格
P = {
    "ecs_mnl_2xl": 232.37,     # g9i.2xlarge + 100 G ESSD PL1 系统盘（Month 档价）
    "ecs_mnl_xl": 123.79,      # g9i.xlarge + 100 G 系统盘
    "ecs_sg_2xl": 256.50,
    "disk_300g": 0.07596 * HOURS,
    "ack_pro": 0.09,           # USD/集群/小时
    "acr_ee": 113.00,          # 2020 版官方国际站 PDF，现官网未公示
    "alb_inst": 0.021,         # 标准版实例费 USD/小时
    "alb_lcu": 0.007,          # USD/LCU/小时
    "nat_inst": 0.043,         # 跨可用区容灾实例费 USD/小时
    "nat_cu": 0.043,           # USD/CU/小时（1 CU = 1 GB 处理流量）
    "eip_hold": 0.006,         # USD/小时/IP
    "eip_traffic": 0.081,      # USD/GB
    "waf_ee": 1400.00,         # 企业版订阅 USD/月（含 5,000 QPS + 10 域名）
    "dns_year": 167.00,        # 企业旗舰版 81 + DNS 安全基础防御 86，USD/域名/年
    "gtm": 140.00,             # 旗舰版 USD/月
    "dcdn": 0.12,              # USD/GB（亚太 1 区，0–10 TB 档）
    "oss_zrs": 0.0232,         # USD/GB/月（标准·同城冗余 ZRS）
    "sls_write": 0.061,        # USD/GB
    "sls_store": 0.002875 * 30,  # USD/GB/月（标准存储按天计价 ×30）
    "arms_prom": 0.176,        # USD/百万条
    "arms_appmon": 1.4,        # USD/Agent/天
    "probe": 8.4,              # USD/万次（境外 PC 运营商探测点）
    "tair_mnl": 0.1224,        # 4 GB 主备版 USD/小时
    "tair_sg": 0.136,
    "ck_node": 819.36,         # ClickHouse 社区版双副本 8C32G USD/月/节点
    "ck_store": 0.448,         # USD/GB/月（双副本 ESSD PL1）
}


def build_rows(site):
    """返回 [(cat, name, spec, billing, rate, amount, src), ...]"""
    a, mnl = ASSUME, site == "mnl"
    r = []
    if mnl:
        r.append(("计算", "ECS 节点池 #12", "g9i.2xlarge（8C32G）+ 100 G ESSD PL1 系统盘", "包月档价",
                  f"$232.37/台·月 × 4 台", P["ecs_mnl_2xl"] * 4, "CLI"))
        r.append(("计算", "ECS 数据盘 #12", "300 G ESSD PL1", "按量",
                  f"$0.07596/GB·h ≈ $55.45/台·月 × 4", P["disk_300g"] * 4, "CLI"))
        r.append(("计算", "staging / perf #33", "g9i.xlarge（8C16G，按需）", "包月档价",
                  f"$123.79/台·月 × 2 台", P["ecs_mnl_xl"] * 2, "CLI"))
    else:
        r.append(("计算", "ECS 节点池 #8", "g9i.2xlarge（8C32G）+ 100 G ESSD PL1 系统盘", "包月档价",
                  f"$256.50/台·月 × 2 台", P["ecs_sg_2xl"] * 2, "CLI"))
        r.append(("计算", "ECS 数据盘 #8", "300 G ESSD PL1", "按量",
                  f"$0.07596/GB·h ≈ $55.45/台·月 × 2", P["disk_300g"] * 2, "CLI"))

    r.append(("计算", "ACK Pro 托管版 #11" if mnl else "ACK Pro 托管版 #7", "控制面 SLA 99.95%",
              "按量", "$0.09/集群·h", P["ack_pro"] * HOURS, "DOC"))
    r.append(("计算", "ACR 企业版 #13" if mnl else "ACR 企业版 #6", "基础版实例",
              "订阅", "$113/月（2020 版 PDF，待复核）", P["acr_ee"], "TODO"))

    lcu = a["mnl_alb_lcu"] if mnl else a["sg_alb_lcu"]
    r.append(("接入", "ALB #6" if mnl else "ALB #4", "标准版实例费", "按量",
              "$0.021/h", P["alb_inst"] * HOURS, "DOC"))
    r.append(("接入", "ALB LCU", "并发连接与流量取大者", "按量",
              f"$0.007/LCU·h × {lcu} LCU", P["alb_lcu"] * lcu * HOURS, "DOC"))

    eg = a["mnl_egress_gb"] if mnl else a["sg_egress_gb"]
    r.append(("网络", "NAT 网关 #4" if mnl else "NAT 网关 #3", "跨可用区容灾实例费", "按量",
              "$0.043/h", P["nat_inst"] * HOURS, "DOC"))
    r.append(("网络", "NAT CU", "1 CU = 1 GB 处理流量", "按量",
              f"$0.043/CU·h × {eg:,} CU", P["nat_cu"] * eg, "DOC"))
    r.append(("网络", "EIP 保有费 #5" if mnl else "EIP 保有费 #3", "4 个固定 EIP（上游白名单池）", "按量",
              "$0.006/h·IP × 4", P["eip_hold"] * HOURS * 4, "DOC"))
    r.append(("网络", "EIP 出口流量", "按使用流量计费", "按量",
              f"$0.081/GB × {eg:,} GB", P["eip_traffic"] * eg, "DOC"))

    r.append(("安全", "WAF 3.0 #7" if mnl else "WAF 3.0 #5", "企业版（含 5,000 QPS + 10 域名）",
              "订阅", "$1,400/月", P["waf_ee"], "DOC"))
    if mnl:
        r.append(("接入", "云解析 DNS #8", "企业旗舰版 + DNS 基础防御", "订阅（年付）",
                  "$167/域名·年 ÷ 12", P["dns_year"] / 12, "DOC"))
        r.append(("接入", "GTM #9", "旗舰版（主备地址池，15 s 探测）", "订阅",
                  "$140/月", P["gtm"], "DOC"))
        r.append(("接入", "DCDN #10", "按流量计费，亚太 1 区", "按量",
                  f"$0.12/GB × {a['dcdn_gb']} GB", P["dcdn"] * a["dcdn_gb"], "DOC"))

    oss_gb = a["oss_gb_mnl"] if mnl else a["oss_gb_sg"]
    sw = a["sls_write_mnl"] if mnl else a["sls_write_sg"]
    ss = a["sls_store_mnl"] if mnl else a["sls_store_sg"]
    mm = a["arms_metric_mnl"] if mnl else a["arms_metric_sg"]

    r.append(("存储", "OSS Bucket #19" if mnl else "OSS Bucket #13",
              f"标准·同城冗余 ZRS，{oss_gb} GB", "按量",
              f"$0.0232/GB·月 × {oss_gb} GB", P["oss_zrs"] * oss_gb, "DOC"))
    r.append(("观测", "SLS #22" if mnl else "SLS #17", f"写入 {sw} GB + 存储 {ss} GB", "按量",
              "$0.061/GB(写) + $0.0863/GB·月(存)",
              P["sls_write"] * sw + P["sls_store"] * ss, "DOC"))
    r.append(("观测", "ARMS Prometheus #23" if mnl else "ARMS #17",
              f"按写入量计费，{mm} 百万条/月", "按量",
              f"$0.176/百万条 × {mm}", P["arms_prom"] * mm, "DOC"))
    if mnl:
        r.append(("观测", "ARMS 应用监控 #23", f"{a['arms_agent_mnl']} 个 Agent 常驻", "按量",
                  f"$1.4/Agent·天 × {a['arms_agent_mnl']} × 30 天",
                  P["arms_appmon"] * a["arms_agent_mnl"] * 30, "DOC"))
        r.append(("观测", "Grafana #37", "共享版工作区", "免费", "免费", 0.0, "DOC"))
        r.append(("观测", "云监控拨测 #24", "4 探测点 × 1 分钟 1 次（境外）", "按量",
                  f"$8.4/万次 × {a['probe_wan']} 万次", P["probe"] * a["probe_wan"], "DOC"))

    r.append(("数据", "Tair 主备版 #17" if mnl else "Tair 主备版 #11", "4 GB 主备", "按量",
              f"${P['tair_mnl'] if mnl else P['tair_sg']}/h",
              (P["tair_mnl"] if mnl else P["tair_sg"]) * HOURS, "CLI"))
    r.append(("日志", "ClickHouse #18" if mnl else "ClickHouse #12",
              "社区版双副本 8C32G ×2 节点", "包月",
              "$819.36/节点·月 × 2", P["ck_node"] * 2, "DOC"))
    r.append(("日志", "ClickHouse 存储", f"ESSD PL1 双副本 {a['ck_store_gb']} GB", "包月",
              f"$0.448/GB·月 × {a['ck_store_gb']} GB", P["ck_store"] * a["ck_store_gb"], "DOC"))
    r.append(("网络", "VPC / vSwitch / 安全组 / ActionTrail", "——", "免费", "免费", 0.0, "DOC"))

    if mnl:
        h = ASSUME["rds_ref_hourly_per_node"] * ASSUME["rds_ha_nodes"]
        r.append(("数据", "RDS PG 高可用 #14", "pg 16C64G（1 主 1 备）+ ESSD PL1", "按量",
                  "⚠️ 官网未公示；参照 PolarDB 同规格 $2.017/节点·h × 2", h * HOURS, "TODO"))
    return r


def render_table(rows):
    out = ["| # | 资源（对应清单号） | 规格 | 计费方式 | 单价与算式 | USD/月 | 来源 |",
           "| --- | --- | --- | --- | --- | --- | --- |"]
    n, sub = 0, 0.0
    for _, name, spec, billing, rate, amt, src in rows:
        n += 1
        tag = {"CLI": "`CLI`", "DOC": "`官网`", "TODO": "`⚠️未公示`"}[src]
        a = "**待复核**" if src == "TODO" else f"{amt:,.2f}"
        out.append(f"| {n} | {name} | {spec} | {billing} | {rate} | {a} | {tag} |")
        if src != "TODO":
            sub += amt
    out.append(f"| | **小计（不含未公示项）** | | | | **{sub:,.2f}** | |")
    return "\n".join(out), sub


def markdown():
    mnl, sg = build_rows("mnl"), build_rows("sg")
    t_mnl, sub_mnl = render_table(mnl)
    t_sg, sub_sg = render_table(sg)

    a = ASSUME
    mnl_node = P["ecs_mnl_2xl"] + P["disk_300g"]
    sg_node = P["ecs_sg_2xl"] + P["disk_300g"]
    traffic_mnl = (P["nat_cu"] + P["eip_traffic"]) * a["mnl_egress_gb"] + \
                  P["alb_lcu"] * a["mnl_alb_lcu"] * HOURS + P["dcdn"] * a["dcdn_gb"]
    traffic_sg = (P["nat_cu"] + P["eip_traffic"]) * a["sg_egress_gb"] + \
                 P["alb_lcu"] * a["sg_alb_lcu"] * HOURS
    mnl_peak = sub_mnl + (8 - 4) * mnl_node + 2 * traffic_mnl
    sg_peak = sub_sg + (12 - 2) * sg_node + 0.5 * traffic_sg
    rds = a["rds_ref_hourly_per_node"] * a["rds_ha_nodes"] * HOURS

    return f"""### 7.10 成本结构（阿里云国际站官网价口径，2026-09-27）

**口径**：全部 USD。`ecs` / `r-kvstore` 单价由 `aliyun DescribePrice` 于 2026-09-27 **实测**，其余为阿里云国际站**官方文档 / 定价页公开价**（出处见 7.10.5）；按量项统一按 **{HOURS} h/月**折月（故 300 G 数据盘按量折月为 ${P['disk_300g']:,.2f}，与官方 Month 档价口径不同）。资源范围严格对齐《菲律宾部署方案 v2.1》的 **资源清单-马尼拉** 与 **资源清单-新加坡** 两个 sheet。

#### 7.10.1 马尼拉主站点（ap-southeast-6，常态 4 节点 + staging/perf）

{t_mnl}

**马尼拉常态小计 ≈ {sub_mnl:,.2f} USD/月**（不含 RDS，RDS 为未公示项，见 7.10.3 参照值）

#### 7.10.2 新加坡备 region（ap-southeast-1，常态 2 节点，PH 备）

{t_sg}

**新加坡常态小计 ≈ {sub_sg:,.2f} USD/月**

#### 7.10.3 汇总

| 口径 | 马尼拉 | 新加坡 | 合计（USD/月） |
| --- | --- | --- | --- |
| **常态**（4 + 2 节点） | {sub_mnl:,.2f} | {sub_sg:,.2f} | **{sub_mnl + sub_sg:,.2f}** |
| 含 RDS 高可用参照值（仅马尼拉） | {sub_mnl + rds:,.2f} | {sub_sg:,.2f} | **{sub_mnl + sub_sg + rds:,.2f}** |
| **接管峰值**（8 + 12 节点；流量 3× / 1.5×） | {mnl_peak:,.2f} | {sg_peak:,.2f} | **{mnl_peak + sg_peak:,.2f}** |
| 包年包月优化后（估算，见 7.10.6） | ≈ {sub_mnl * 0.75:,.2f} | ≈ {sub_sg * 0.75:,.2f} | ≈ **{(sub_mnl + sub_sg) * 0.75:,.2f}** |

**RDS PG 参照值**：官网未公示规格费与 ESSD 存储价（仅公开 Serverless RCU $0.0746 马尼拉 / $0.0796 新加坡、备份 $0.00004/GB·h），故按同规格公开可查的 PolarDB PG 16C64G 按量价 **$2.017/节点·小时** 作**上限参照**，高可用 = 1 主 1 备 → 2 × $2.017 × {HOURS} = **{rds:,.2f} USD/月**。RDS 实际通常低于此值，须登录购买页复核后替换。

#### 7.10.4 后付费（按量）项的折月假设

| 按量项 | 官方单价 | 假设用量 | 折月（马尼拉 / 新加坡） |
| --- | --- | --- | --- |
| NAT CU | $0.043/CU·h（1 CU = 1 GB 处理流量） | {a['mnl_egress_gb']:,} / {a['sg_egress_gb']:,} GB | {P['nat_cu'] * a['mnl_egress_gb']:,.2f} / {P['nat_cu'] * a['sg_egress_gb']:,.2f} |
| EIP 出口流量 | $0.081/GB | 同左 | {P['eip_traffic'] * a['mnl_egress_gb']:,.2f} / {P['eip_traffic'] * a['sg_egress_gb']:,.2f} |
| ALB LCU | $0.007/LCU·h | {a['mnl_alb_lcu']} / {a['sg_alb_lcu']} LCU | {P['alb_lcu'] * a['mnl_alb_lcu'] * HOURS:,.2f} / {P['alb_lcu'] * a['sg_alb_lcu'] * HOURS:,.2f} |
| DCDN | $0.12/GB（亚太 1 区） | {a['dcdn_gb']} GB/月 | {P['dcdn'] * a['dcdn_gb']:,.2f} / — |
| OSS ZRS | $0.0232/GB·月 | {a['oss_gb_mnl']} / {a['oss_gb_sg']} GB | {P['oss_zrs'] * a['oss_gb_mnl']:,.2f} / {P['oss_zrs'] * a['oss_gb_sg']:,.2f} |
| SLS | 写入 $0.061/GB；存储 $0.002875/GB·天 | 马尼拉 写 {a['sls_write_mnl']}、存 {a['sls_store_mnl']} GB | {P['sls_write'] * a['sls_write_mnl'] + P['sls_store'] * a['sls_store_mnl']:,.2f} / {P['sls_write'] * a['sls_write_sg'] + P['sls_store'] * a['sls_store_sg']:,.2f} |
| ARMS Prometheus | $0.176/百万条（0–50 百万/天档） | 马尼拉 {a['arms_metric_mnl']} 百万条/月 | {P['arms_prom'] * a['arms_metric_mnl']:,.2f} / {P['arms_prom'] * a['arms_metric_sg']:,.2f} |
| ARMS 应用监控 | $1.4/Agent·天 | {a['arms_agent_mnl']} Agent 常驻 | {P['arms_appmon'] * a['arms_agent_mnl'] * 30:,.2f} / — |
| 云监控拨测 | $8.4/万次（境外 PC 运营商点） | {a['probe_wan']} 万次/月 | {P['probe'] * a['probe_wan']:,.2f} / — |

> **最大变量是出口流量**。方案 8.5 按「1,000 并发 ≈ 40 Mbps」估算，本表取峰值 40 Mbps、平均利用率 30% → 月流量 ≈ {a['mnl_egress_gb']:,} GB。流量每增加 1 TB，马尼拉 NAT CU + EIP 流量合计 **+${(P['nat_cu'] + P['eip_traffic']) * 1024:,.1f}**；若长期跑满 40 Mbps，该口径下此项将升至 **${(P['nat_cu'] + P['eip_traffic']) * 40 / 8 * 3600 * HOURS / 1024:,.0f}/月**，故必须落成本标签与预算告警（清单 #39）。

#### 7.10.5 单价来源与未公示项

| 标记 | 含义 |
| --- | --- |
| `CLI` | 本次 `aliyun ecs DescribePrice`（ECS / 磁盘）、`aliyun r-kvstore DescribePrice`（Tair）实测 |
| `官网` | 国际站官方文档 / 定价页公开价：NAT [88658](https://www.alibabacloud.com/help/doc-detail/88658.htm) · EIP [pay-as-you-go](https://www.alibabacloud.com/help/en/eip/pay-as-you-go) · ALB [billing-rules](https://www.alibabacloud.com/help/en/slb/application-load-balancer/product-overview/alb-billing-rules) · WAF [billing-description](https://www.alibabacloud.com/help/en/waf/web-application-firewall-3-0/product-overview/billing-description/) · DNS [price-dns](https://www.alibabacloud.com/help/en/dns/price-dns) · GTM [gtm3-product-billing](https://www.alibabacloud.com/help/en/dns/gtm3-product-billing) · ACK [86759](https://www.alibabacloud.com/help/doc-detail/86759.htm) · DCDN [pricing](https://www.alibabacloud.com/product/dcdn/pricing) · ClickHouse [pricing](https://www.alibabacloud.com/help/en/clickhouse/product-overview/pricing/) · OSS [pricing-list](https://www.alibabacloud.com/product/oss-pricing-list) · SLS [billable-items](https://www.alibabacloud.com/help/en/log-service/latest/billable-items) · ARMS [pricing](https://www.alibabacloud.com/product/arms/pricing) · 拨测 [pay-as-you-go](https://www.alibabacloud.com/help/zh/cms/product-overview/pay-as-you-go) · PolarDB [compute-node-billing-rules](https://www.alibabacloud.com/help/zh/polardb/latest/compute-node-billing-rules) |
| `⚠️未公示` | 官网未公开单价，须登录购买页复核 |

| 未公示项 | 现状 | 复核方式与影响 |
| --- | --- | --- |
| RDS PG 高可用 16C64G + ESSD PL1 | 规格费与存储价均未公示（见 7.10.3 参照值 {rds:,.2f}/月） | 登录 `rdsbuy.console.alibabacloud.com` 或控制台价格计算器；该项是马尼拉第二大成本，**必须复核后再出预算** |
| ACR 企业版基础版 | 表内 $113/月 源自 2020 版官方国际站计费 PDF，现文档已不列价 | 控制台 ACR 购买页；偏差 >10% 需回填（两地合计 ≈ $226/月） |
| KMS 凭据管家软件密钥 | 官网未公示单价 | 控制台购买页；预期为小额固定费，暂计 0 |
| ClickHouse 马尼拉 | 官方地域价目表**未列 ap-southeast-6** | 按新加坡价估算，下单前用计算器核对（差幅预期 ≤15%） |

**与上一版口径的差异**：① 按量项改用 `{HOURS} h/月` 折算（旧表用 720 h，单节点 $287.06 → 现 ${P['ecs_mnl_2xl'] + P['disk_300g']:,.2f}）；② 机型统一 `g9i`（`g8i` 全系马尼拉无库存）；③ **新增此前未量化的 WAF / DNS / GTM / DCDN / ARMS 应用监控 / 拨测**，合计 ≈ **${1400 + 13.92 + 140 + 60 + 168 + 145.15:,.2f} USD/月**，是成本量级抬升的主因。

#### 7.10.6 降本与优化

| 手段 | 空间 | 代价 / 前提 |
| --- | --- | --- |
| 包年包月 | RDS 官方折扣率 **1 年 70% / 3 年 45%**（×目录价）；ECS 折扣须控制台价格计算器核（CLI `DescribePrice` 无 `InstanceChargeType`）。整站乐观口径 ≈ **↓25%** | 需承诺期，失去按量弹性 |
| 新加坡冷备 | 常态置 0 副本 → 省 2 节点 ≈ **${sg[0][5] + sg[1][5]:,.2f} USD/月** | 接管 RTO 秒级 → 分钟级 |
| 备站 WAF | 接管时才必需，可评估「按年订阅 vs 接管期临时启用」 | 备站安全基线下降，接管期须补规则 |
| ClickHouse 降配 | 两地合计 **${(P['ck_node'] * 2 + P['ck_store'] * a['ck_store_gb']) * 2:,.2f} USD/月**，为第二大项：缩短 TTL / 单节点 / 备站复用主站 | 日志保留期缩短、跨区写日志风险 |
| 拨测间隔 | 1 分钟 → 5 分钟：**${P['probe'] * a['probe_wan']:,.2f} → ${P['probe'] * a['probe_wan'] / 5:,.2f} USD/月** | 故障发现时延变长 |
| staging / perf | 按需启停（当前全天计 **${P['ecs_mnl_xl'] * 2:,.2f} USD/月**） | 压测窗口外无环境 |
| 出口流量 | DCDN 动静态分离、压缩与流式优化；该项为最大变量（见 7.10.4） | 需应用侧配合，见 8.5 |

**不计入本表**：① 上游 token 成本（与网关 SLA 解耦，独立列预算，第九章 R-30 要求建立客户维度成本告警）；② **不含 GA**（理由见 7.1：GA 加速段是用户就近接入，无法改善出站跨境链路，且会把上游看到的源 IP 改为 GA 侧地址、破坏白名单与 SNI/证书模型）；③ 跨区数据库读写公网流量（RDS 国际站公网流量 100% 折扣、免费）；④ 一次性费用（域名、证书、迁移人力）。
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
