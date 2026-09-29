#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_task24_sg.py —— 任务 24 / 42 实测结论回写（幂等）

覆盖文件：
  A 组（同源，逐字相同）：
    deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md
    deploy/wf2/part2a.md
  B 组（旧修订，任务 24 段逐字相同）：
    deploy/阿里云国际站菲律宾部署_详细操作指南.md
    deploy/阿里云国际站菲律宾部署_详细操作指南-ch.md

用法：
  python3 deploy/patch_task24_sg.py --check     # 只报告命中情况
  python3 deploy/patch_task24_sg.py --apply     # 写盘（自动 .bak-np24-<ts> 备份）
"""
import datetime
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MARK = "ca75829e3492d491d9d434de087913798"   # 新加坡集群 ID：打过补丁才会出现

DONE_BLOCK = """> **✅ 已落地（2026-09-29）** · 集群 `ca75829e3492d491d9d434de087913798`、节点池 `npab9d46aefe3a4649b074543f36f32599`
>
> | 项 | 实测值 |
> | --- | --- |
> | 集群 | `ack-newapi-sg` / `1.35.7-aliyun.1` / `ack.pro.small` / `rg-aek4zvb3ldoiyua` |
> | 内网端点 | `https://10.1.19.73:6443`（**公网端点未开**） |
> | **Service CIDR** | **`172.22.0.0/20`** —— **刻意与马尼拉的 `172.21.0.0/20` 错开**。两集群 Service 网段相同，将来接云企业网/CEN 时会成死锁，且该属性**建后不可改**（马尼拉任务 10 坑 2 原话） |
> | 密钥对 | `newapi-sg` —— 密钥对**不跨 region**，且 `DescribeKeyPairs` **取不到 `PublicKeyBody`**（实测 `body_len=0`），只能重新 `ImportKeyPair` 导入本地公钥 |
> | 节点池 / ESS | `np-sg-ph-standby` / `asg-t4ngzbg7m9u84y59dkxl`；auto_scaling **min 2 / max 12** |
> | 节点（2 台） | `g9ae.2xlarge`@**1a** + `g8ine.2xlarge`@**1b**（**勿硬编码机型分布** —— 1b 没有 g9i） |
> | 终验 | 集群 12/12 + 节点池 **17/17 PASS**；集群内 2/2 `Ready`、`site=sg`、nofile=**200000**、Terway CNI、300G 盘已挂 `/var/lib/containerd` |
>
> 完整台账 → **`deploy/nodepool_ledger_sg.md`**；脚本 `deploy/task24_ack_sg.sh`（建集群）+ `deploy/task24_nodepool_sg.sh`（**复用任务 11 同一份逻辑与 user_data**）+ `deploy/nodepool_azbalance_fix.sh`（跨区均衡断言）。
>
> **★ 建完集群第 1 件事：核对控制面安全组有没有 6443。** 新加坡**同构复现**了马尼拉那条缺陷（见下方坑 6）；本卡已在**建节点池之前**补上，所以 2 台节点**首次引导即成功**，完全没重演马尼拉那条 6 小时排障链。
"""

KENG_567 = """- 坑 5｜**`multi_az_policy: BALANCE` ≠ 开启跨区均衡（2026-09-29 实测，两地同源）**。现象：建池 body 写了 `BALANCE`、`DescribeScalingGroups` 也回读 `MultiAZPolicy=BALANCE`，但 desired=2 建出来是 **1a:2 / 1b:0**。根因：ESS 有**独立的 `AzBalance` 开关**，**ACK 不设置它** → 实例创建阶段不做跨区均衡，顺着「能买到机型 / 有库存」的交换机把实例全塞一个区。佐证：把 `instance_types` 首位换成两区都在售的 `g9ae` **仍然全落 1a** → 与机型无关。修复：`aliyun ess ModifyScalingGroup --ScalingGroupId <asg> --AzBalance true --BalanceMode BalancedBestEffort [--AutoRebalance true]`（幂等脚本 `deploy/nodepool_azbalance_fix.sh mnl|sg`），生效后 ESS 会先在另一区补 1 台再削掉多余的那台，收敛 1:1。**⚠️ 该字段 `DescribeScalingGroups` 不回读，且经 ACK 侧改池后可能被覆盖 → 每次改完节点池都要重跑断言。** `BalanceMode` 取 `BalancedBestEffort`（可用性优先）而非 `BalancedOnly`（目标区没货则整个伸缩活动失败）—— 备站扩不出容比短暂失衡危险得多。
- 坑 6｜**ACK 建集群漏放行控制面 6443 —— 两个地域都复现，是平台缺陷不是个案**。现象：集群 `security_group_id`（名 `alicloud-cs-auto-created-security-group-<集群ID>`）入向**只有 ICMP 一条**，**没有任何 6443** → 节点 bootstrap 用**内网域名**连 API Server 报 `curl (7) Connection timed out`，重试 120 次 × 2s、卡满 **10 分钟**才放弃 → 节点不注册 / Terway 起不来 / 节点永久 `NotReady`（完整故障链见 `deploy/nodepool_ledger.md` §7）。**易误判点**：错误码是 `curl (7)` **不是** `(6)` —— DNS 是通的、TCP 连不上；且 `ping` 能通（ICMP 恰在白名单里）。**SOP**：建完集群先查该 SG 有无 6443，没有就 `AuthorizeSecurityGroup` 放行 `TCP 6443 ← <VPC 段>`，**再**建节点池。**新加坡实测**：`sg-t4nevyfflaeo3tdvi510` 建出时同样只有 ICMP。
- 坑 7｜**删节点池必须等 ESS 真正清零，否则必得 `delete_failed`**。现象：`--MinSize 0 --MaxSize 0 --DesiredCapacity 0` 之后立刻 `DeleteClusterNodepool` → ACK 任务报 **`ScalingGroup's instances not empty`**，池变 `delete_failed`（该状态下连 `RemoveNodePoolNodes` 也被拒，报 `InvalidNodePoolStatus.Forbidden`）。根因：容量归零是**异步**的，实例先进入 `Removing:Wait`，**实测约 6–7 分钟**才真正释放。修复：**轮询 `DescribeScalingGroups.TotalCapacity == 0`** 再删；若已 `delete_failed`，清零后**重发一次删除**即可恢复（无需重建集群）。
"""

T42_NOTE = """# ⚠️ 除 min/max 外还必须断言 ESS 的**跨区均衡开关**（该字段不回读，同任务 24 坑 5）：
#    bash deploy/nodepool_azbalance_fix.sh mnl     # 再对 sg 跑一遍
#    实测：马尼拉此前 `AzBalance` 也是关的 —— 它的 6a:2/6b:2 只是「运气好」，本次已补正。
"""

T42_KENG4 = """- 坑 4｜**`MultiAZPolicy=BALANCE` ≠ 已开跨区均衡**：ACK 不设 ESS 独立的 `AzBalance`，伸缩时会把新节点**全塞进有库存的那个可用区**（实测 1a:2 / 1b:0）→ 可用区级故障会一次打掉整个节点池。**改进**：每池建后 / **每次经 ACK 改池后**都跑 `deploy/nodepool_azbalance_fix.sh <mnl|sg>` 断言，并用「实例的可用区分布」间接验证（`AzBalance` 不可回读）。
"""

# ---------------- A 组（v2.0 / wf2 part2a） ----------------
A_HEAD_OLD = """### Day 2 · 任务 24｜新加坡 ACK 集群 + 常态 2 节点节点池（单人，1 人时，14:00–15:00，前移）

**前置/状态**："""

# wf2/part2a.md 同段但标题用「人员A」措辞
A_HEAD_OLD_2A = """### Day 2 · 任务 24｜新加坡 ACK 集群 + 常态 2 节点节点池（人员A，1 人时，14:00–15:00，前移）

**前置/状态**："""

A_NP_OLD = """# nodepool-sg.json：instance_types=[ecs.g9i.2xlarge,ecs.g8ine.2xlarge,ecs.g9ae.2xlarge]、
# desired_size:2、min_size:2、max_size:12、multi_az_policy:BALANCE、internet_max_bandwidth_out:0、
# tags site=sg/env=prod；user_data 与任务 11 Step 3 完全同一份脚本（禁止手工点两遍）
envsubst < nodepool-sg.json > nodepool-sg.rendered.json
aliyun cs CreateClusterNodePool --ClusterId $ID_SG --body "$(cat nodepool-sg.rendered.json)\""""

A_NP_NEW = """# nodepool-sg.json：instance_types=[ecs.g9ae.2xlarge,ecs.g9i.2xlarge,ecs.g8ine.2xlarge]  ← 顺序见坑 5
# multi_az_policy:BALANCE、internet_max_bandwidth_out:0、tags site=sg/env=prod
# user_data 与任务 11 Step 3 完全同一份脚本（禁止手工点两遍）
# ⚠️ 两步走（同任务 11）：先手动模式 desired_size:2 建池 → 再 ModifyClusterNodePool 开
#    auto_scaling{enable,type:"cpu",min_instances:2,max_instances:12}
#    （开伸缩后**禁止**再给 scaling_group.desired_size，否则 InvalidDesiredSizeOrCount.NotNull）
# ⚠️ resource_group_id 必须显式写（同任务 10 坑 5，漏写静默落 default 组且不可迁移）
envsubst < nodepool-sg.json > nodepool-sg.rendered.json
aliyun cs CreateClusterNodePool --ClusterId $ID_SG --body "$(cat nodepool-sg.rendered.json)"
# ★ 建池后【两件事必做】：
#   ① bash deploy/nodepool_azbalance_fix.sh sg        # ESS 跨区均衡，否则全落一个区（坑 5）
#   ② 核对控制面安全组有无 6443，没有就补（坑 6）"""

A_KENG4 = "- 坑 4｜节点标签/污点不统一 → 主备反亲和失效 → 两集群统一 `site`/`env`/`track`，`topologySpreadConstraints` 用 `DoNotSchedule`（软约束会让 4 副本挤一个 AZ）。"

A_T42_EXPECT = "# 期望：np-mnl-app enable=true min=4 max=8；对新加坡同跑，期望 np-sg-ph-standby enable=true min=2 max=12"

A_T42_KENG3 = '- 坑 3｜自动伸缩的新节点不带手工调优：只有初始 4 台"是对的" → 一切节点调优必须进节点池 User Data。'

# ---------------- B 组（.md / -ch.md） ----------------
B_HEAD_OLD = """### 6.4 任务 24｜新加坡 ACK 集群 + 常态 2 节点节点池

#### 操作步骤"""

B_CL_OLD = """{"name":"ack-newapi-sg","cluster_spec":"ack.pro.small","region_id":"ap-southeast-1","kubernetes_version":"1.35.0-aliyun.1",
 "vpcid":"${VPC_SG_ID}","vswitch_ids":["${VSW_SG_APP_A}","${VSW_SG_APP_B}"],
 "container_cidr":"10.1.128.0/17","service_cidr":"10.1.0.0/20",
 "ip_stack":"ipv4","network":"terway-eniip","node_cidr_mask":"25",
 "snat_entry":false,"endpoint_public_access":false,"deletion_protection":true,
 "timezone":"Asia/Singapore","proxy_mode":"ipvs",
 "addons":[{"name":"terway-eniip"},{"name":"csi-plugin"},{"name":"csi-provisioner"},
           {"name":"ack-pod-identity-webhook"},{"name":"alb-ingress-controller"},
           {"name":"managed-coredns"},{"name":"arms-prometheus"},{"name":"logtail-ds"}]}"""

B_CL_NEW = """{"name":"ack-newapi-sg","cluster_type":"ManagedKubernetes","profile":"Default",
 "cluster_spec":"ack.pro.small","region_id":"ap-southeast-1","kubernetes_version":"1.35.7-aliyun.1",
 "vpcid":"${VPC_SG_ID}","vswitch_ids":["${VSW_SG_APP_A}","${VSW_SG_APP_B}"],
 "pod_vswitch_ids":["${VSW_SG_APP_A}","${VSW_SG_APP_B}"],
 "service_cidr":"172.22.0.0/20","resource_group_id":"rg-aek4zvb3ldoiyua",
 "snat_entry":false,"endpoint_public_access":false,"deletion_protection":true,
 "rrsa_config":{"enabled":true},"timezone":"Asia/Singapore","proxy_mode":"ipvs",
 "addons":[{"name":"terway-controlplane","config":"{\\"ENITrunking\\":\\"false\\"}"},
           {"name":"terway-eniip"},{"name":"csi-plugin"},{"name":"csi-provisioner"},
           {"name":"ack-pod-identity-webhook"},{"name":"alb-ingress-controller"},
           {"name":"managed-coredns"},{"name":"arms-prometheus"},{"name":"logtail-ds"}]}"""

B_NP_OLD = """{"nodepool_info":{"name":"np-sg-ph-standby"},
 "scaling_group":{"instance_types":["ecs.g9i.2xlarge","ecs.g8ine.2xlarge","ecs.g9ae.2xlarge"],"""

B_NP_NEW = """{"nodepool_info":{"name":"np-sg-ph-standby","type":"ess","resource_group_id":"rg-aek4zvb3ldoiyua"},
 "scaling_group":{"instance_types":["ecs.g9ae.2xlarge","ecs.g9i.2xlarge","ecs.g8ine.2xlarge"],   // ← 顺序见坑 5"""

B_NOTE_OLD = "> 另：`scaling_group.min_size` / `max_size` / `auto_scaling.health_check_type` 均为臆造字段，已从 body 移除。"


def patch(path: Path, pairs, apply: bool):
    if not path.exists():
        return f"[跳过] 不存在：{path}"
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"
    new = raw
    changes = []
    missing = []
    for old, rep, tag in pairs:
        o = old.replace("\n", nl)
        r = rep.replace("\n", nl)
        if o in new and r not in new:
            new = new.replace(o, r, 1)
            changes.append(tag)
        elif r in new:
            pass          # 目标状态已存在 → 幂等跳过
        else:
            missing.append(tag)
    if not changes:
        return f"[未匹配] {path.name}：无可用片段（可能已是新版）"
    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".bak-np24-{ts}"))
        path.write_text(new, encoding="utf-8", newline="")
    out = f"[{'已写入' if apply else '待改'}] {path.name}：" + "；".join(changes)
    if missing:
        out += f"\n           ⚠️ 未命中：{missing}"
    return out


def pairs_v2(head=A_HEAD_OLD):
    return [
        (head, head.split("\n\n")[0] + "\n\n" + DONE_BLOCK + "\n**前置/状态**：", "任务 24 插入「✅ 已落地」块"),
        (A_NP_OLD, A_NP_NEW, "任务 24 建池片段：机型顺序 + 两步走 + AzBalance/6443 提示"),
        (A_KENG4, A_KENG4 + "\n" + KENG_567.rstrip("\n"), "任务 24 追加坑 5–7"),
        (A_T42_EXPECT, A_T42_EXPECT + "\n" + T42_NOTE.rstrip("\n"), "任务 42：补 AzBalance 断言"),
        (A_T42_KENG3, A_T42_KENG3 + "\n" + T42_KENG4.rstrip("\n"), "任务 42 追加坑 4（AzBalance）"),
    ]


def pairs_old():
    return [
        (B_HEAD_OLD, B_HEAD_OLD.split("\n\n")[0] + "\n\n" + DONE_BLOCK + "\n#### 操作步骤", "任务 24 插入「✅ 已落地」块"),
        (B_CL_OLD, B_CL_NEW, "任务 24 建集群 body 修正（cluster_type/profile/pod_vswitch_ids/service_cidr/RG/rrsa）"),
        (B_NP_OLD, B_NP_NEW, "任务 24 建池 body：补 type/RG + 机型顺序"),
        (B_NOTE_OLD, B_NOTE_OLD + "\n>\n" + "\n".join("> " + l for l in KENG_567.rstrip("\n").split("\n")), "任务 24 追加坑 5–7"),
    ]


def main():
    apply = "--apply" in sys.argv
    targets = [
        (ROOT / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md", lambda: pairs_v2(A_HEAD_OLD)),
        (ROOT / "wf2" / "part2a.md", lambda: pairs_v2(A_HEAD_OLD_2A)),
        (ROOT / "阿里云国际站菲律宾部署_详细操作指南.md", pairs_old),
        (ROOT / "阿里云国际站菲律宾部署_详细操作指南-ch.md", pairs_old),
    ]
    for path, fn in targets:
        print(patch(path, fn(), apply))
    return 0


if __name__ == "__main__":
    sys.exit(main())
