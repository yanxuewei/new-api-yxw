# Day 2 · 任务 11｜马尼拉 ECS 节点池 4×g9i.2xlarge 跨 2 可用区 — 执行报告

- 执行时间：2026-09-28 21:08 (GMT+8)
- 依据：`deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（任务 10 / 任务 11）+ `菲律宾部署方案-v2.3-修订版.xlsx`
- 账号：`5108890064395960` · region `ap-southeast-6`（马尼拉）· RG `rg-aek4nyivmmsb6iy`（`rg-ph-mnl`）
- 状态：**Step 1（P0 机型验证）✅ 通过；Step 2（建集群）已实跑确证 → 被风控拦截（余额 0 引发），节点池未建**

---

## 一、结论（先看这段）

| 项 | 结果 |
|---|---|
| 任务 11 Step 1 机型可用性（P0） | ✅ 通过 —— `ecs.g9i.2xlarge` 在 **6a + 6b 双可用区可售** |
| vCPU 配额复核 | ✅ 马尼拉 `64`（工单 `Agree` 2026-09-26）· 新加坡 `96` |
| K8s 可创建版本 | ✅ 含 1.35 —— 实测 **`1.35.7-aliyun.1`**（指南写的 `1.35.0-aliyun.1` **已不可创建**，见 §四） |
| ECS 密钥对 | ✅ 已创建 `newapi-mnl`，私钥 `~/.ssh/newapi-mnl.pem`（600） |
| **任务 10（ACK 集群）状态** | ❌ **未创建** —— 两地集群数均为 0，任务 11 硬前置缺失 |
| **建簇实跑结果** | ❌ **风控拦截** `RISK.RISK_CONTROL_REJECTION`（`OpenAckService --type propayasgo` 被挂起）——**账户余额 0.00 USD 触发**；另有 `MissingPodVswitchIds` 已修正（§八） |
| 交付物 | ✅ 两个可重跑脚本（§三） |

> **关键链路**：余额 0.00 USD → 风控拦下 ACK 服务开通 → `ErrorNotEnabled` → 集群建不出来 → 任务 11 无 `cluster_id`。**须先充值 + 开通 ACK 服务，再跑 `all`。**

---

## 二、Step 1 实测数据（P0 验证，已完成）

### 2.1 机型可用性 `ecs DescribeAvailableResource`

```
ap-southeast-6a	ecs.g9i.2xlarge      ← 首选，可售
ap-southeast-6a	ecs.g8ine.2xlarge    ← 备选 1，可售
ap-southeast-6a	ecs.g9ae.2xlarge     ← 备选 2，可售
ap-southeast-6b	ecs.g9i.2xlarge      ← 首选，可售
ap-southeast-6b	ecs.g8ine.2xlarge
ap-southeast-6b	ecs.g9ae.2xlarge
```

`g9i.2xlarge` 命中 **2 个可用区**，满足 `multi_az_policy: BALANCE` + 「单 AZ 故障仍有 2 副本」。同区域另有 `c9i`（计算型）与 `u2i`（通用型）全系可售，但**内存比不符**（32G 口径），不入 `instance_types`（指南坑 9：只混同规格族）。

### 2.2 配额 `quotas ListProductQuotas --ProductCode ecs-spec`

| 配额码 | 马尼拉 | 新加坡 | 工单状态 |
|---|---|---|---|
| `q_ecs_enterprise_postpay_c`（按量 vCPU） | **64** | **96** | `Agree` 2026-09-26T10:03:23Z（马尼拉，D=64） |
| `q_ecs_enterprise_prepay_c` | 100 | 100 | — |
| `q_ecs_enterprise_spot_c` | 50 | 50 | — |

**容量闭环**：节点池 `max_size 8 × 8 vCPU = 64` = 已批配额，**顶满、零余量** → 扩容前必须重新核配额（指南坑 7）。

### 2.3 Terway Pod 容量（坑 6 核验）

| 机型 | 规格 | EniQuantity | IPs/ENI | **SupportedPods** |
|---|---|---|---|---|
| `ecs.g9i.2xlarge` | 8C32G | 4 | 15 | **45** |
| `ecs.g8ine.2xlarge` | 8C32G | 6 | 15 | **75** |
| `ecs.g9ae.2xlarge` | 8C32G | 4 | 15 | **45** |

`SupportedPods = (EniQuantity-1) × EniPrivateIpAddressQuantity`。4 节点合计 ≥180 Pod 位；注意 `g9i` 与 `g8ine` 容量不同（45 vs 75），若发生机型替换，**每节点 Pod 上限随之变化**。

### 2.4 集群/密钥对现状

| 对象 | 实测 |
|---|---|
| ACK 集群（马尼拉 / 新加坡） | `total_count = 0`（均未创建） |
| ECS 实例（马尼拉） | 0 台 |
| ECS 密钥对（马尼拉） | **空** → 节点池 `key_pair` 无可用密钥，脚本会先创建 `newapi-mnl` |
| vSwitch | `vsw-mnl-app-a` `vsw-5tswpyzfa8od6je95td1h`（10.0.16.0/20, 6a, free 4092）<br>`vsw-mnl-app-b` `vsw-5tshuvvtrqm97tnwe1ddm`（10.0.32.0/20, 6b, free 4092） |
| ACK 服务角色 | ✅ 齐备（`AliyunCSManagedKubernetesRole` / `ManagedNetworkRole` / `ManagedCsiPluginRole` / `ManagedCsiProvisionerRole` / `ManagedArmsRole` / `ManagedLogRole` / `ManagedCmsRole` 均已存在） |

---

## 三、交付物

### 3.1 `deploy/task10_11_ack_mnl.sh`（主脚本，幂等，可重跑）

```bash
./deploy/task10_11_ack_mnl.sh verify      # 只读：机型+配额+版本+Pod容量（P0）
./deploy/task10_11_ack_mnl.sh keypair     # 建密钥对 newapi-mnl（幂等，私钥落 ~/.ssh/newapi-mnl.pem，600）
./deploy/task10_11_ack_mnl.sh cluster     # 任务 10：建 ack-newapi-mnl（K8s 1.35.7，Terway，RRSA，审计，公网端点关）
./deploy/task10_11_ack_mnl.sh nodepool    # 任务 11：建 np-mnl-app（desired 4 / 4–8，跨 6a+6b，BALANCE）
./deploy/task10_11_ack_mnl.sh kubeconfig  # 拉 60 min 临时 kubeconfig → /tmp/kubeconfig-mnl
./deploy/task10_11_ack_mnl.sh check       # 验证：集群/节点池/Pod vSwitch 余量
./deploy/task10_11_ack_mnl.sh all         # verify → keypair → cluster → nodepool → kubeconfig → check
```

关键写死项（杜绝控制台默认值坑）：

| 项 | 值 | 理由 |
|---|---|---|
| `cluster_type` / `cluster_spec` | `ManagedKubernetes` / `ack.pro.small` | Pro 托管版 + **多可用区 regional 控制面**，否则 SLA 只有 99.50% |
| `network` / `proxy_mode` | `terway-eniip` / `ipvs` | CNI 建簇后不可换；kube-proxy ipvs 为 ACK 1.35 默认 |
| `service_cidr` | `172.21.0.0/20` | 不可改，须确认办公网/CEN 不重叠 |
| `snat_entry` | `false` | 硬红线：出网必须走已登记 NAT EIP 池 |
| `endpoint_public_access` | `false` | API Server 只留内网端点（配合任务 46 堡垒机） |
| `deletion_protection` | `true` | 防误删 |
| `enable_rrsa` + `rrsa_config.enabled` | `true` | 任务 17 密钥链路前提 |
| `internet_max_bandwidth_out` | `0` | 坑 5：节点带公网 IP 会让 EIP 白名单形同虚设 |
| `multi_az_policy` | `BALANCE` | 坑 4：单 AZ 建池 → AZ 故障副本全灭 |
| `instance_charge_type` | `PostPaid` | 与配额 `q_ecs_enterprise_postpay_c` 对应 |
| 磁盘 | system 100G `cloud_essd` **PL1** + data 300G `cloud_essd` **PL1** | 坑 2：PL2 有 461G 下限，300G 必须 PL1 |
| `data_disks` + `disk_init` | 300G + `mount_for_runtime: true` | 坑 3：数据盘不给 containerd → 系统盘写满 → `disk-pressure` 驱逐雪崩 |

### 3.2 `deploy/task11_node_init.sh`（节点 `user_data`，三段幂等）

1. **nofile=200000 三处**：`/etc/systemd/system.conf.d/10-newapi-limits.conf`（`DefaultLimitNOFILE`）+ `/etc/security/limits.d/99-newapi.conf` + kubelet/containerd 的 **unit drop-in** `LimitNOFILE` —— 节点 `ulimit -n` 对容器不生效，容器继承 containerd/kubelet，故必须改 unit；
2. **sysctl**：`ip_local_port_range=10240 65535` / `somaxconn=32768` / `tcp_tw_reuse=1`；
3. **数据盘兜底**：仅当 `/var/lib/containerd` 不是挂载点、且发现 ≥200 GiB 的全新空盘（无 fs、无分区、未挂载、非系统盘）时才 `mkfs.ext4` + 写 fstab + 挂载 → **与 `disk_init` 互为兜底，不会重复挂载**。

末段 `systemctl daemon-reload && restart containerd/kubelet` —— 缺这一步 `limits.conf` 对已运行进程无效。

---

## 四、须回填到指南的实测校正

| # | 指南原文 | 实测 | 处理 |
|---|---|---|---|
| C1 | 任务 10 建簇 `kubernetes_version: "1.35.0-aliyun.1"` | 马尼拉 creatable 仅 `1.36.2-aliyun.1` / **`1.35.7-aliyun.1`** / `1.34.10-aliyun.1`；ACK 规则「同一 minor 发布新 patch 后旧 patch 不可再建」→ **`1.35.0` 已不可创建** | 脚本用 `1.35.7-aliyun.1`（minor 仍是 1.35，符合 F 项口径） |
| C2 | 任务 11 Step 1 期望「6a/6b 两区均出现 g9i.2xlarge」 | ✅ 实测成立 | 无需改 |
| C3 | 任务 11 配额期望 64 | ✅ 实测 64 且工单 `Agree` | 无需改 |
| C4 | `aliyun cs DescribeKubernetesVersionMetadata` 传参 | CLI 3.5.1 下必须用 **`--Region`**（`--region` / `--RegionId` 均报 `MissingRegion`）；`--region` 仅对其余 CS 只读 API 有效 | 写入脚本注释 |
| C5 | 任务 11 Step 4「数据盘挂给容器运行时（控制台勾选）」 | API 对应 `scaling_group.disk_init = [{disk_name, mkfs_type, mount_for_runtime:true}]`；与 `data_disks[].disk_name` 需同名匹配 | 脚本双保险（`disk_init` + user_data 兜底） |
| C6 | 任务 10 建簇 body **无 `pod_vswitch_ids`** | 实跑报 `MissingPodVswitchIds: PodVswitchIds is empty`（**服务端强制非空**，Terway 下 Pod 网络必须有 vSwitch 出口） | body 补 `pod_vswitch_ids: [app-a, app-b]`（与节点同段，不越出网络规划） |
| C7 | 任务 10 未列「开通 ACK 服务」前置 | 实跑报 `ErrorNotEnabled: please enable cskpro container service before creating cluster`；`aliyun cs OpenAckService --type propayasgo` 是开通入口（唯一合法值：`propayasgo` / `edgepayasgo`） | 脚本 `cluster` 步骤已加**开通预检硬门禁**，未开通即停并给出处置 |

---

## 五、阻塞项与解除顺序

| # | 阻塞 | 影响 | 解除 |
|---|---|---|---|
| B1 | **账户余额 0.00 USD**（`AvailableAmount: 0.00`, USD） | ① 按量 ECS 创建直接被拒；② **连 ACK 服务开通都被风控拦下**（`RISK.RISK_CONTROL_REJECTION`，order suspended）；③ 已有 EIP/ALB 有欠费回收风险 | 充值（国际站按量建议覆盖首月常态费）+ 必要时联系客服解除风控 |
| B2 | **ACK 服务未开通**（`ErrorNotEnabled: please enable cskpro`） | 建簇 400，任务 10/11 全部停摆 | 余额到位后 `aliyun cs OpenAckService --type propayasgo`（或控制台开通），脚本已内置预检门禁 |
| B2 | 任务 10 集群未创建 | 任务 11 无 `cluster_id`，无法建池 | 跑 `cluster` 步骤（5–15 min） |
| B3 | ECS 密钥对为空 | 节点无 SSH 入口 | 脚本 `keypair` 步骤自动创建 `newapi-mnl`，私钥落 `~/.ssh/newapi-mnl.pem` |
| B4 | ACR VPC 端点未关联马尼拉 VPC（`LinkedVpcs=[]`，任务 16） | 当时记为「节点拉不动镜像 ⇒ 阻塞任务 18」；**实测未真阻塞**——helper 免密 + 公网域名即可拉起（任务 18 报告 §六-①），只是路径未优化 | 另卡处理 ⇒ **已解除**：任务 16 2b 于 2026-10-05 18:18 关联（Ip `10.0.22.220`），任务 18 消费侧 18:53 起改用 `-vpc` 内网域名拉取（`Day2任务18_master迁移幂等_执行报告.md` §十） |

---

## 六、余额解除后的执行序列

```bash
cd /path/to/new-api-yxw
./deploy/task10_11_ack_mnl.sh verify      # 1) 再确认机型/配额（D2 强制）
./deploy/task10_11_ack_mnl.sh all         # 2) 密钥对 → 建集群(5–15min) → 建池 → kubeconfig → check
```

预期验证结果（`check` 步骤会打印命令，需在堡垒机或集群网内执行 kubectl）：

```bash
kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl
#  期望：4 节点 Ready，ap-southeast-6a 与 6b 各 ≥2
kubectl run u --image=busybox --rm -it --restart=Never -- sh -c 'ulimit -n'
#  期望：200000（若 1024/65535 → user_data 未执行或漏 unit drop-in）
kubectl debug node/<node> -it --image=busybox -- sh -c 'df -h /host/var/lib/containerd'
#  期望：300G ESSD 独立盘
```

---

## 七、风险提示（执行前必读）

1. **Pro 托管版建簇失败无法原地续跑** → 只能删除重建；失败先看 `aliyun cs DescribeClusterEvents --ClusterId <id>`（常见：vSwitch IP 不足、RAM 授权缺失）。
2. **配额零余量**：`max 8` 即顶满 64 vCPU，任何额外按量 ECS（含排障用跳板机）都会撞配额。
3. **不要为图快临时开公网端点放行 `0.0.0.0/0`** —— ACK 建簇 body 已固定 `endpoint_public_access:false`，kubectl 走任务 46 堡垒机。
4. **节点池 OS 自动升级会静默把 ulimit 打回 1024**（坑 8）：当前脚本未在 `management.auto_upgrade_policy` 显式关 `auto_upgrade_os`，上线前须补该开关 + node-exporter `process_max_fds` 告警。
5. 本轮**未创建任何计费资源**；唯一新增资源是免费 ECS 密钥对 `newapi-mnl`（私钥 `~/.ssh/newapi-mnl.pem`）。日志在 `deploy/logs/task10_11_*.log`。

---

## 八、建簇实跑记录（2026-09-28 21:23–21:26，三步收敛）

| 轮次 | 命令 | 结果 |
|---|---|---|
| 1 | `task10_11_ack_mnl.sh cluster` | ❌ 脚本 bug：`say "私钥已保存：$pem（…"` —— bash 3.2 把全角括号并入变量名 → `unbound variable`（**密钥对此时已建成功、私钥已落盘**）。扫描全脚本同类写法（`$VAR` 紧跟全角标点）共 3 处，全部改 `${VAR}` |
| 2 | 同上（修复后） | ❌ 服务端 400，**两个独立错误**：`MissingPodVswitchIds: PodVswitchIds is empty` + `ErrorNotEnabled: please enable cskpro container service before creating cluster` → 已按 C6/C7 修正 body 并加开通预检门禁 |
| 3 | 同上（加预检后） | ⛔ **FATAL 风控拦截**：`OpenAckService --type propayasgo` 返回 `RISK.RISK_CONTROL_REJECTION` / *"your order is suspended… contact Customer Service"* → 脚本按预期停在门禁，**不再向建簇 API 发无效请求** |

### 三条实测结论

1. **余额 0 的第一道墙不是 ECS 欠费，而是风控**：付费服务开通即被挂起（order suspended），比资源创建失败更早一步，且提示文案不直接说"余额不足"——须由人联系客服或先充值。
2. **`pod_vswitch_ids` 是 Terway 建簇的必填项**，指南任务 10 的 body 漏写；该错误与「服务未开通」同时返回（`data` 数组多错误），排查时**不能只看第一条**。
3. **`OpenAckService --type` 只有两个合法值**：`propayasgo`（ACK 托管/专有/Serverless/注册）与 `edgepayasgo`（边缘）；`cluster` 步骤现已将其作为前置硬门禁。

### 密钥对现状

| 项 | 值 |
|---|---|
| 名称 | `newapi-mnl` |
| 指纹 | `732340d017cd1b1297b4d2c547327520` |
| 私钥 | `~/.ssh/newapi-mnl.pem`（1678 B，权限 `600`，仅创建时下发一次） |

> 密钥对为**地域级**资源，马尼拉与新加坡各需一份；新加坡侧（任务 24）须另行创建。
