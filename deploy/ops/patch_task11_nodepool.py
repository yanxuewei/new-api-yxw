#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
回写任务 11（马尼拉 ECS 节点池）实测结论 + 更正指南中 8 处与阿里云 API 不符的字段/表述
—— 2026-09-29 实测（节点池 npaad418131aa84c899be022b5463d13bf）确认的错误：
   ① 建池 body 用 `scaling_group.min_size/max_size` —— ACK 托管节点池**无此字段**，
      上下限只能写 `auto_scaling.min_instances/max_instances`；
   ② 同 body 同时给 `desired_size` 与 `auto_scaling.enable=true` → 报
      `InvalidDesiredSizeOrCount.NotNull`（**互斥**）→ 必须「手动模式建池 → 再开伸缩」两步走；
   ③ `key_name` 字段名错误 → 正确是 `key_pair`；`login_password:""` 冗余且不安全；
   ④ `auto_scaling.health_check_type` / `scale_unsupported` **不存在**（原文档臆造）；
   ⑤ 「`data_disks` 只创建不挂载」**表述错误** —— ACK 自动格式化**最后一块**数据盘，
      并把 `/var/lib/containerd`、`/var/lib/kubelet` 挂上去；
   ⑥ 「快速扩容」片段 `--body '{"scaling_group":{"desired_size":8}}'` —— 开伸缩后**禁止**改
      `desired_size`，应改 `auto_scaling.max_instances`；
   ⑦ 校验 jq 用 `.scaling_group.min_instances` —— 路径错，应为 `.auto_scaling.min_instances`；
   ⑧ `nodepool_info` 缺 `type:"ess"` 与 `resource_group_id`（不写 RG 会落 default 组）。

用法：
  python3 deploy/ops/patch_task11_nodepool.py --check    # 只报告
  python3 deploy/ops/patch_task11_nodepool.py --apply    # 写入（自动 .bak-np11-<ts>）
"""
import argparse
import datetime
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
D = ROOT / "deploy"

GUIDE_V2 = D / "docs" / "阿里云国际站菲律宾部署_详细操作指南-v2.0.md"
GUIDES_OLD = [
    D / "docs" / "阿里云国际站菲律宾部署_详细操作指南.md",
    D / "docs" / "阿里云国际站菲律宾部署_详细操作指南-ch.md",
]
PART2A = D / "wf2" / "part2a.md"
PART5 = D / "wf2" / "part5.md"

NP_ID = "npaad418131aa84c899be022b5463d13bf"
MARK = NP_ID  # 主幂等标记（节点池 ID，只有打过补丁才会出现）
MARK_PART2A = '"type":"ess","resource_group_id":"rg-aek4nyivmmsb6iy"'
MARK_PART5 = "# 节点不够 → 调高节点池自动伸缩上限"

# ============================================================================
# 共用片段
# ============================================================================

JQ_OLD = ("  | jq -r '.nodepools[]|[.nodepool_info.nodepool_id,.auto_scaling.enable,"
          ".scaling_group.min_instances,.scaling_group.max_instances]|@tsv'")
JQ_NEW = ("  | jq -r '.nodepools[]|[.nodepool_info.nodepool_id,.auto_scaling.enable,"
          ".auto_scaling.min_instances,.auto_scaling.max_instances]|@tsv'")

MSIZE_OLD = "多机型 + `min_size` 常备"
MSIZE_NEW = "多机型 + `auto_scaling.min_instances` 常备"

QUICK_CMD_OLD = r"""aliyun cs ModifyClusterNodePool --ClusterId ${ACK_MNL_ID} --NodepoolId ${NP_MNL} --body '{"scaling_group":{"desired_size":8}}'"""
QUICK_CMD_NEW = r"""aliyun cs ModifyClusterNodePool --ClusterId ${ACK_MNL_ID} --NodepoolId ${NP_MNL} --region ap-southeast-6 \
  --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":4,"max_instances":8}}'
# ⚠️ 开伸缩后禁止改 desired_size；临时扩容请提 max_instances，并同步抬 HPA maxReplicas"""
QUICK_CMT_A_OLD = "# 节点不够 → 调高节点池的期望节点数（desired_size）"
QUICK_CMT_B_OLD = "# 节点不够 → 抬节点池期望值"
QUICK_CMT_NEW = "# 节点不够 → 调高节点池自动伸缩上限（开伸缩后【禁止】再改 scaling_group.desired_size）"

# ---- 建池 body：按行替换（v2.0 与 part2a 只差一行 image_type，按行替换两文件通吃）----
BODY_LINES = [
    (r"""{"nodepool_info":{"name":"np-mnl-app"},""",
     r"""{"nodepool_info":{"name":"np-mnl-app","type":"ess","resource_group_id":"rg-aek4nyivmmsb6iy"},""",
     "body: nodepool_info 补 type=ess + resource_group_id"),
    (r"""   "system_disk_category":"cloud_essd","system_disk_size":100,""",
     r"""   "system_disk_category":"cloud_essd","system_disk_size":100,"system_disk_performance_level":"PL1",""",
     "body: 补 system_disk_performance_level=PL1"),
    (r"""   "data_disks":[{"category":"cloud_essd","size":300}],""",
     r"""   "data_disks":[{"category":"cloud_essd","size":300,"performance_level":"PL1"}],""",
     "body: 补 data_disks performance_level=PL1"),
    (r"""   "desired_size":4,"min_size":4,"max_size":8,"instance_charge_type":"PostPaid",""",
     r"""   "desired_size":4,"instance_charge_type":"PostPaid",""",
     "body: 删除臆造字段 min_size/max_size"),
    (r'''   "key_name":"${ECS_KEYPAIR}","login_password":"",''',
     r'''   "key_pair":"${ECS_KEYPAIR}",
   "security_group_ids":["sg-5tsil3ca5dfkqefks1g9"],''',
     "body: key_name → key_pair + 补 security_group_ids"),
    (r"""   "user_data":"<base64(Step 3 脚本)>"},
 "auto_scaling":{"enable":true,"health_check_type":"NODE","scale_unsupported":false}}""",
     r"""   "user_data":"<base64(Step 3 脚本)>"}}""",
     "body: 移除 auto_scaling（改由 Step 2b 开伸缩）"),
]

# ---- v2.0 独有的说明性段落 ----
PRE_OLD = (r"""> **⚠️ 建池前须补一个前置**：`scaling_group.key_name: ${ECS_KEYPAIR}` —— 账号当前 **0 个 ECS 密钥对**"""
           r"""（`ecs DescribeKeyPairs` → `TotalCount=0`）。二选一：① `aliyun ecs CreateKeyPair --RegionId """
           r"""ap-southeast-6 --KeyPairName newapi-mnl`（返回私钥，需离线保管）；② 改用 `login_password`。"""
           r"""**不设任一，节点池创建会失败。**""")
PRE_NEW = (r"""> **✅ 前置已就绪（2026-09-28 执行）**：字段名是 `scaling_group.key_pair`（**不是 `key_name`**）。"""
           r"""密钥对 `newapi-mnl` 已创建（`aliyun ecs DescribeKeyPairs --RegionId ap-southeast-6`），私钥已离线保管。"""
           r"""**⚠️ 建池 body 必须带 `key_pair`，否则节点池创建失败。**""")

UP_OLD = (r"""> **⚠️ 配套（坑 8）**：显式关闭「自动升级 OS 镜像」（API 侧 `management.auto_upgrade_policy.auto_upgrade_os`，"""
          r"""**该字段名待建池时实测复核**）—— 自动升级会重置 `ulimit -n` 回 1024，静默破掉 `LimitNOFILE=200000`。"""
          r"""升级窗口必须与变更冻结对齐。""")
UP_NEW = (r"""> **⚠️ 配套（坑 8）**：显式关闭「自动升级 OS 镜像」（API 侧 `management.auto_upgrade_policy.auto_upgrade_os: false`，"""
          r"""字段名已实测确认）—— 注意 `management.enable=true` 会**依赖插件 `ack-node-problem-detector`**，未装则报 """
          r"""`InvalidParameter.Management`；**本卡默认不传 `management`（= 不开节点托管）**。自动升级会重置 `ulimit -n` 回 1024，"""
          r"""静默破掉 `LimitNOFILE=200000`；升级窗口必须与变更冻结对齐。""")

K8S_OLD = (r"""> **⚠️ 待复核**：`kubernetes_config` / `runtime` 字段名 —— 本轮查官方 `CreateClusterNodePool` 文档时**未检出** """
           r"""`kubernetes_config` 对象，与本卡第 2 步 body 不一致（疑为文档抓取不全）。建池时以控制台实际返回为准；"""
           r"""若被忽略，`runtime` 走默认 containerd，影响可控。""")
K8S_NEW = (r"""> **✅ 已实测确认**：`kubernetes_config`（含 `runtime` / `cpu_policy` / `labels` / `user_data`）字段有效，"""
           r"""建池成功且 `user_data` 已注入（b64 3600 B）。""")

# ---- 代码块收尾 + 新增 Step 2b ----
TAIL_OLD = r"""aliyun cs CreateClusterNodePool --ClusterId $ID_MNL --body "$(cat nodepool-mnl.rendered.json)"
```"""

TAIL_NEW = r"""aliyun cs CreateClusterNodePool --ClusterId $ID_MNL --body "$(cat nodepool-mnl.rendered.json)"
```

> ⚠️ 上面是**手动模式**（只给 `desired_size:4`，让 ESS 按 `MultiAZPolicy=BALANCE` 均分 6a/6b 各 2）。
> **一步到位的写法必失败** —— 实测 `auto_scaling.enable=true` 与 `scaling_group.desired_size` **互斥**，
> 同 body 提交报 `InvalidDesiredSizeOrCount.NotNull: desired_size/count setting or modification is not supported for autoscaling-enabled nodepool`。

**2b. 打开节点池自动伸缩**（min 4 / max 8；不变量 `max 8 × 8 vCPU = 64` = 马尼拉 ECS vCPU 配额）：

```bash
aliyun cs ModifyClusterNodePool --ClusterId $ID_MNL --NodepoolId $NP_MNL --region ap-southeast-6 \
  --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":4,"max_instances":8}}'
```

> ⚠️ 开伸缩瞬间 ESS 会**先备 6 台再收敛到 min=4**（实测 4→6→8→4）；收敛后须复核跨区仍为 **2/2**，
> 若被削成 `6a:3 / 6b:1` 需删除重建（见坑 10 / 坑 11）。"""

# ---- 数据盘挂载口径更正 ----
DISK_OLD = (r"""4. 数据盘挂给容器运行时：body 里 `data_disks` 只创建不挂载 → 在节点池配置勾选"数据盘挂载到 """
            r"""`/var/lib/containerd` 与 `/var/log`"（新版 ACK 支持），或自定义数据里 `systemctl stop containerd` → """
            r"""格式化 → `mv` → 挂载。【控制台】节点池创建页可看机型过滤列表（含 **Terway 支持 Pod 数**，顺手记下每机型 `SupportedPods`）。""")
DISK_NEW = (r"""4. **数据盘自动挂载（无需手工干预）**：body 里 `data_disks` 创建的数据盘，**ACK 会自动格式化「最后一块」数据盘**，"""
            r"""并把 `/var/lib/containerd`、`/var/lib/kubelet` 一并挂到该盘（实测 4 台 × `/dev/vdb` 300G ESSD PL1，"""
            r"""全部 `In_use`，**0 孤儿盘**）。**原文档「`data_disks` 只创建不挂载」的表述有误。**

> 只有需要**额外**挂 `/var/log`、或指定**非末块**盘时，才需显式写 `disk_init`（TS SDK 实测 schema："""
            r"""`disk_name` / `local_disk` / `mkfs_type` / `mount_for_runtime` / `mount_target`）。"""
            r"""【控制台】节点池创建页可看机型过滤列表（含 **Terway 支持 Pod 数**，顺手记下每机型 `SupportedPods`）。""")

# ---- 坑 9 后追加实测坑 10-16 ----
K9_OLD = (r"""- 坑 9｜`instance_types` 混不同内存比（g 8C32G 与 r 8C64G）→ request/limit 与 HPA 口径错乱 → """
          r"""只混同规格族，HPA 用 CPU 利用率（基于 request）。""")
K9_ADD = r"""- 坑 10｜**`auto_scaling.enable=true` 与 `scaling_group.desired_size` 互斥** → 同 body 报 `InvalidDesiredSizeOrCount.NotNull` → 后果：按原文「一次提交」必失败，且报错不提示字段冲突 → 改进：**严格两步走**（手动模式建池 → `ModifyClusterNodePool` 开伸缩），本卡已改。
- 坑 11｜**开伸缩瞬间 ESS 先备 6 台再削到 min=4，削节点会破坏跨区均衡**（实测被削成 `6a:3 / 6b:1`）→ 后果：违反「每区 ≥2」，单 AZ 故障承受力不达标 → 改进：**先手动模式建池**（ESS 按 `BALANCE` 给 2/2）**再开伸缩**；一旦被削坏，停伸缩后**删除重建**（见坑 12）。
- 坑 12｜**删节点池 ≠ 删干净：ESS 组 `MinSize>0` 会无限重建被删节点，节点池卡 `delete_failed`**（`RemoveNodePoolNodes` 报 `InvalidNodePoolStatus.Forbidden`）→ 根因：`DeleteClusterNodepool` 只删 ACK 侧，**ESS 伸缩组继续补机器**；再叠加 `GroupDeletionProtection=true` 则彻底删不掉 → 修复：`aliyun ess ModifyScalingGroup --GroupDeletionProtection false` → `--MinSize 0 --MaxSize 0 --DesiredCapacity 0` → 再 `DeleteClusterNodepool`（两步收敛）。详见 `deploy/nodepool_ledger.md`。
- 坑 13｜**手动模式建池需账号级服务角色 `AliyunOOSLifecycleHook4CSRole`**，缺失直接 `MissingAuth.AliyunOOSLifecycleHook4CSRole` → 改进：`aliyun ram CreateRole --region ap-southeast-1`（信任 `oos.aliyuncs.com` + `cs.aliyuncs.com`）+ `AttachPolicyToRole --PolicyType System --PolicyName AliyunOOSLifecycleHook4CSRolePolicy`；若不需要生命周期钩子，**不传 `management`** 即可绕开。
- 坑 14｜**字段名陷阱**：密钥对是 `key_pair`（**不是 `key_name`**）；数据盘加密 `data_disks[].encrypted` 是**字符串**（传布尔 → `Unmarshal type error: expected=string, got=bool`）；`auto_scaling` **没有** `health_check_type` / `scale_unsupported`（臆造字段）；ACK 托管节点池**无** `scaling_group.min_size/max_size`，上下限统一走 `auto_scaling.min_instances/max_instances`。
- 坑 15｜**节点托管 `management.enable=true` 依赖插件 `ack-node-problem-detector`**，未装报 `InvalidParameter.Management` → 改进：本卡默认**关闭节点托管**；确需托管则先装插件。自动升级 OS 镜像走 `management.auto_upgrade_policy.auto_upgrade_os: false`（与坑 8 呼应）。
- 坑 16｜**aliyun CLI 3.x 具名参数调用必须带 `--region`**：`aliyun cs ModifyClusterNodePool --ClusterId … --NodepoolId … --body …` 缺 `--region` 会报 `InvalidAction.NotFound: Specified api is not found`（**极易误判为 API 不可用/权限不足**）→ 改进：所有 `cs` / `ess` / `ecs` 具名调用一律带 `--region`（马尼拉 `ap-southeast-6`，新加坡 `ap-southeast-1`）。"""

# ---- 任务 13 的 Modify 调用 ----
MOD_OLD = r"""aliyun cs ModifyClusterNodePool --ClusterId $ID_MNL --NodepoolId $NP_MNL \
  --body '{"auto_scaling":{"enable":true,"health_check_type":"NODE","scale_unsupported":false}}'"""
MOD_NEW = r"""aliyun cs ModifyClusterNodePool --ClusterId $ID_MNL --NodepoolId $NP_MNL --region ap-southeast-6 \
  --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":4,"max_instances":8}}'
# ⚠️ 具名调用必须带 --region（否则报误导性的 InvalidAction.NotFound）；
#    auto_scaling 无 health_check_type / scale_unsupported（臆造字段，已删除）"""

# ---- ✅ 已落地块 ----
DONE_ANCHOR = (r"""**前置/状态**：任务 10 集群 running。**开工第一件事（Day 2 第一阻塞风险）= 机型可用性验证**，"""
               r"""v2 实测已确认 `g8i` 全系未在马尼拉上架（2026-09-25），本卡机型基线已改为 `ecs.g9i.2xlarge`（8C32G），"""
               r"""备选 `g8ine.2xlarge`；配额 50→64 已批复（状态 `Agree`），建池前仍需复核。""")

DONE_BLOCK = r"""**✅ 已落地（2026-09-29，任务 11 完成）** — 节点池 `npaad418131aa84c899be022b5463d13bf`（`np-mnl-app` / `ess` / `rg-aek4nyivmmsb6iy`），ESS 伸缩组 `asg-5tsd68ew4u0wutaqk5cy`

| 项 | 实测值 |
|---|---|
| nodepool_id | `npaad418131aa84c899be022b5463d13bf` |
| 节点数 / 分布 | 4 台，`ap-southeast-6a` **2** / `ap-southeast-6b` **2** ✅ |
| 实例规格 | `ecs.g9i.2xlarge` ×2 + `ecs.g9ae.2xlarge` ×2（均 **8C32G**） |
| 镜像 / 运行时 | `AliyunLinux3ContainerOptimized` / `containerd` |
| 磁盘 | 系统盘 ESSD **PL1 100G** + 数据盘 ESSD **PL1 300G**（8 块全 `In_use`，0 孤儿盘） |
| 安全组 / 公网 | `sg-5tsil3ca5dfkqefks1g9`（未自建托管组）/ `internet_max_bandwidth_out=0`（**无公网 IP**） |
| 伸缩 | `auto_scaling.enable=true`，min **4** / max **8**（`type=cpu`），ESS `MultiAZPolicy=BALANCE` |
| nofile 调优 | `user_data` 已注入（b64 3600 B）→ systemd `/etc/systemd/system.conf.d` + kubelet/containerd drop-in + `sysctl.d` 三处 |

终验 **17/17 PASS，0 FAIL**；完整字段、ESS 删池坑、CLI 速查 → **`deploy/nodepool_ledger.md`**。
**仍未完成**：`kubectl get nodes -l site=ph-mnl`、`ulimit -n`=200000 落地核查、`/var/log/newapi-node-init.log` 复核需 **VPC 内**执行 → 等任务 46（堡垒机）。"""


# ============================================================================
# 替换集
# ============================================================================

def pairs_v2():
    return BODY_LINES + [
        (PRE_OLD, PRE_NEW, "前置：key_name → key_pair + 密钥对已就绪"),
        (UP_OLD, UP_NEW, "自动升级字段名已实测 + management 依赖提示"),
        (K8S_OLD, K8S_NEW, "kubernetes_config 字段名已实测确认"),
        (TAIL_OLD, TAIL_NEW, "新增 Step 2b 开伸缩（两步走）"),
        (DISK_OLD, DISK_NEW, "更正「data_disks 只创建不挂载」"),
        (K9_OLD, K9_OLD + "\n" + K9_ADD, "追加实测坑 10–16"),
        (MOD_OLD, MOD_NEW, "任务 13 Modify 调用补 --region + 正确 body"),
        (MSIZE_OLD, MSIZE_NEW, "坑 7 min_size 口径 → auto_scaling.min_instances"),
        (JQ_OLD, JQ_NEW, "校验 jq 路径 scaling_group → auto_scaling"),
        (QUICK_CMT_A_OLD, QUICK_CMT_NEW, "快速扩容注释行更正"),
        (QUICK_CMD_OLD, QUICK_CMD_NEW, "快速扩容片段：改 auto_scaling 上限"),
    ]


def pairs_old(guide_is_ch):
    prose_old = (r"""2. 创建节点池（容器服务管理控制台 → 左侧菜单「集群」→「节点池」→「创建节点池」；body 结构同 §6.4 Step 2，"""
                 r"""差异：`desired_size:4`、`min_size:4`、`max_size:8`、`site=ph-mnl`、`instance_types` 用第 1 步结果）。"""
                 if guide_is_ch else
                 r"""2. 建节点池（body 结构同 §6.4 Step 2，差异：`desired_size:4`、`min_size:4`、`max_size:8`、"""
                 r"""`site=ph-mnl`、`instance_types` 用第 1 步结果）。""")
    prose_new = r"""2. 建节点池。**差异项**：`desired_size:4`、`site=ph-mnl`、`instance_types` 用第 1 步结果；上下限走 `auto_scaling.min_instances:4` / `max_instances:8`（**`scaling_group.min_size` / `max_size` 是臆造字段，已作废**）。**必须两步走** —— `auto_scaling.enable=true` 与 `scaling_group.desired_size` **互斥**，同 body 提交报 `InvalidDesiredSizeOrCount.NotNull`（见「坑与注意事项」实测补充）。

```bash
# 2a. 手动模式建池：只给 desired_size（ESS 按 BALANCE 均分 6a/6b 各 2）
cat <<'EOF' > nodepool-mnl.json
{"nodepool_info":{"name":"np-mnl-app","type":"ess","resource_group_id":"rg-aek4nyivmmsb6iy"},
 "scaling_group":{"instance_types":["ecs.g9i.2xlarge","ecs.g8ine.2xlarge","ecs.g9ae.2xlarge"],
   "vswitch_ids":["${VSW_MNL_APP_A}","${VSW_MNL_APP_B}"],
   "image_type":"AliyunLinux3ContainerOptimized",
   "system_disk_category":"cloud_essd","system_disk_size":100,"system_disk_performance_level":"PL1",
   "data_disks":[{"category":"cloud_essd","size":300,"performance_level":"PL1"}],
   "desired_size":4,"instance_charge_type":"PostPaid",
   "internet_max_bandwidth_out":0,"multi_az_policy":"BALANCE",
   "key_pair":"${ECS_KEYPAIR}","security_group_ids":["${SG_MNL_APP}"],
   "tags":[{"key":"site","value":"ph-mnl"},{"key":"env","value":"prod"},{"key":"track","value":"stable"}]},
 "kubernetes_config":{"runtime":"containerd","cpu_policy":"none","labels":[{"key":"track","value":"stable"}],
   "user_data":"<base64(Step 3 脚本)>"}}
EOF
envsubst < nodepool-mnl.json > nodepool-mnl.rendered.json
aliyun cs CreateClusterNodePool --ClusterId ${ACK_MNL_ID} --body "$(cat nodepool-mnl.rendered.json)"

# 2b. 建池成功后开伸缩（min 4 / max 8；不变量 max 8 × 8 vCPU = 64 配额）
aliyun cs ModifyClusterNodePool --ClusterId ${ACK_MNL_ID} --NodepoolId ${NP_MNL} --region ap-southeast-6 \
  --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":4,"max_instances":8}}'
```"""

    sg_body_old = r"""   "data_disks":[{"category":"cloud_essd","size":300}],"desired_size":2,"min_size":2,"max_size":12,
   "instance_charge_type":"PostPaid","internet_max_bandwidth_out":0,
   "multi_az_policy":"BALANCE",
   "tags":[{"key":"site","value":"sg"},{"key":"env","value":"prod"}]},
 "kubernetes_config":{"runtime":"containerd","cpu_policy":"none"},
 "auto_scaling":{"enable":true,"health_check_type":"NODE","scale_unsupported":false}}"""
    sg_body_new = r"""   "system_disk_performance_level":"PL1",
   "data_disks":[{"category":"cloud_essd","size":300,"performance_level":"PL1"}],"desired_size":2,
   "instance_charge_type":"PostPaid","internet_max_bandwidth_out":0,
   "multi_az_policy":"BALANCE","key_pair":"${ECS_KEYPAIR}","security_group_ids":["${SG_SG_APP}"],
   "tags":[{"key":"site","value":"sg"},{"key":"env","value":"prod"}]},
 "kubernetes_config":{"runtime":"containerd","cpu_policy":"none"}}"""

    sg_tail_old = r"""aliyun cs CreateClusterNodePool --ClusterId ${ACK_SG_ID} --body "$(cat nodepool-sg.rendered.json)"
```"""
    sg_tail_new = sg_tail_old + r"""

> ⚠️ **开伸缩必须另起一步**（`auto_scaling` 与 `desired_size` 互斥，同 body 报 `InvalidDesiredSizeOrCount.NotNull`）：
> `aliyun cs ModifyClusterNodePool --ClusterId ${ACK_SG_ID} --NodepoolId ${NP_SG} --region ap-southeast-1 --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":2,"max_instances":12}}'`。
> 另：`scaling_group.min_size` / `max_size` / `auto_scaling.health_check_type` 均为臆造字段，已从 body 移除。"""

    k4_old = (r"""- **坑 4｜系统盘 100G 不够。** 镜像层 + 日志把盘打满 → `Evicted` 风暴。改进：`LOG_DIR` 指向数据盘；"""
              r"""logtail 侧限流；`emptyDir` 设 `sizeLimit`。""")
    k4_new = k4_old + "\n" + r"""- **坑 5｜`auto_scaling.enable=true` 与 `scaling_group.desired_size` 互斥（实测补充）。** 同 body 提交报 `InvalidDesiredSizeOrCount.NotNull` → 改进：**两步走**（手动模式建池 → `ModifyClusterNodePool` 开伸缩）。
- **坑 6｜开伸缩瞬间 ESS 先备 6 台再削到 min=4，破坏跨区均衡（实测补充）。** 被削成 `6a:3 / 6b:1` → 改进：先手动模式建池（`BALANCE` 给 2/2）再开伸缩；被削坏则停伸缩后删除重建。
- **坑 7｜删节点池 ≠ 删干净（实测补充）。** ESS 组 `MinSize>0` 会无限重建被删节点，节点池卡 `delete_failed`（`RemoveNodePoolNodes` 报 `InvalidNodePoolStatus.Forbidden`）→ 修复：`ess ModifyScalingGroup --GroupDeletionProtection false` → `--MinSize 0 --MaxSize 0 --DesiredCapacity 0` → 再 `DeleteClusterNodepool`。
- **坑 8｜字段名/必带参数（实测补充）。** 密钥对是 `key_pair`（非 `key_name`）；`auto_scaling` 无 `health_check_type`/`scale_unsupported`；`data_disks[].encrypted` 是字符串；aliyun CLI 3.x 具名调用**必须带 `--region`**，否则报误导性的 `InvalidAction.NotFound`。"""

    return [
        (sg_body_old, sg_body_new, "SG 节点池 body 去臆造字段 + 补 PL1/key_pair/SG"),
        (sg_tail_old, sg_tail_new, "SG 节点池新增「开伸缩另起一步」提示"),
        (prose_old, prose_new, "任务 11 步骤 2 补两步走 + 正确 body"),
        (k4_old, k4_new, "任务 11 坑列表追加实测坑 5–8"),
        (MSIZE_OLD, MSIZE_NEW, "坑 1 min_size 口径 → auto_scaling.min_instances"),
        (QUICK_CMT_A_OLD, QUICK_CMT_NEW, "快速扩容注释行更正（A 措辞）"),
        (QUICK_CMT_B_OLD, QUICK_CMT_NEW, "快速扩容注释行更正（B 措辞）"),
        (QUICK_CMD_OLD, QUICK_CMD_NEW, "快速扩容片段：改 auto_scaling 上限"),
        (JQ_OLD, JQ_NEW, "校验 jq 路径 scaling_group → auto_scaling"),
    ]


def pairs_part5():
    return [
        (QUICK_CMT_A_OLD, QUICK_CMT_NEW, "快速扩容注释行更正"),
        (QUICK_CMD_OLD, QUICK_CMD_NEW, "快速扩容片段：改 auto_scaling 上限（禁止 desired_size）"),
        (JQ_OLD, JQ_NEW, "校验 jq 路径 scaling_group → auto_scaling"),
    ]


# ============================================================================

def patch(path, pairs, apply, insert_done=None, mark=MARK):
    if not path.exists():
        return f"[跳过] 不存在：{path}"
    raw = path.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"

    def nt(s):
        return s.replace("\n", nl)

    # 幂等：标记已在 + 没有任何待改片段（每个 old 都已消失或 new 已存在）→ 视为最新
    pending = [t for (o, s, t) in pairs if nt(o) in raw and nt(s) not in raw]
    done_pending = False
    if insert_done:
        a, blk = insert_done
        done_pending = nt(a) in raw and nt(blk) not in raw
    if mark in raw and not pending and not done_pending:
        return f"[已是最新] {path.name}"

    new = raw
    changes = []

    for old, new_s, tag in pairs:
        o, s = nt(old), nt(new_s)
        if o in new and s not in new:
            new = new.replace(o, s, 1)
            changes.append(tag)

    if insert_done and not done_pending:
        a, blk = nt(insert_done[0]), nt(insert_done[1])
        if a in new and blk not in new:
            new = new.replace(a, a + nl + nl + blk, 1)
            changes.append("插入「✅ 已落地」块")

    if not changes:
        return f"[未匹配] {path.name}：无可用替换片段，需人工看"

    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, path.with_suffix(path.suffix + f".bak-np11-{ts}"))
        path.write_text(new, encoding="utf-8", newline="")
    return f"[{'已写入' if apply else '待改'}] {path.name}：" + "；".join(changes)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    on = args.apply

    print(patch(GUIDE_V2, pairs_v2(), on, insert_done=(DONE_ANCHOR, DONE_BLOCK)))

    for p in GUIDES_OLD:
        is_ch = p.name.endswith("-ch.md")
        head = ("### 7.1 任务 11｜马尼拉 ECS 节点池（4×8C32G，跨 2 个可用区，nofile 调优）" if is_ch
                else "### 7.1 任务 11｜马尼拉 ECS 节点池（4×8C32G，跨 2 AZ，nofile 调优）")
        print(patch(p, pairs_old(is_ch), on, insert_done=(head, DONE_BLOCK)))

    print(patch(PART2A, pairs_v2(), on, insert_done=None, mark=MARK_PART2A))
    print(patch(PART5, pairs_part5(), on, insert_done=None, mark=MARK_PART5))
    return 0


if __name__ == "__main__":
    sys.exit(main())
