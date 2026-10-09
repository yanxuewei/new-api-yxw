# 节点池台账（NodePool Ledger）· 马尼拉 / 新加坡

> 任务 11（马尼拉）/ 后续任务 24（新加坡）的唯一真源。
> 配套脚本：`deploy/tasks/task11/nodepool_mnl.sh`（幂等，`--dry-run` / `--verify` / `--enable-autoscaling` / `--delete`）
> 共享 user_data：`deploy/ops/nodepool-userdata-nofile.sh`（马尼拉/新加坡**同一份**，禁止手工点两遍）
> 证据目录：`deploy/logs/task11_<ts>/`

---

## 1. 马尼拉节点池（任务 11 · 2026-09-29 落地）

| 项 | 值 |
|---|---|
| **nodepool_id** | **`npaad418131aa84c899be022b5463d13bf`** |
| 名称 / 类型 | `np-mnl-app` / `ess` |
| **资源组** | **`rg-aek4nyivmmsb6iy`（rg-ph-mnl）** ✅ |
| 集群 | `ack-newapi-mnl` = `cd57e40ce9a634c1698c2f5c5e09bd93c` |
| 区域 | `ap-southeast-6` |
| 容量 | **常态 4 台**；自动伸缩 `enable=true` `min=4` `max=8` |
| **ESS 伸缩组** | **`asg-5tsd68ew4u0wutaqk5cy`**（`acs-nodePool-npaad4181…`，min=4 max=8 `MultiAZPolicy=BALANCE`） |
| 机型池 | `ecs.g9i.2xlarge` › `ecs.g8ine.2xlarge` › `ecs.g9ae.2xlarge`（均 8C32G 同内存比） |
| 实配机型 | **`g9ae.2xlarge` ×4**（ESS 自主挑选，**不严格按 `instance_types` 顺序**；见坑 R） |
| 网络 | vSwitch `vsw-5tswpyzfa8od6je95td1h`(6a) / `vsw-5tshuvvtrqm97tnwe1ddm`(6b)·`multi_az_policy=BALANCE` |
| **节点安全组** | **`sg-5tsil3ca5dfkqefks1g9`（`sg-mnl-app`）** —— 未自建 `sg-` 托管组 ✅ |
| 镜像 | `AliyunLinux3ContainerOptimized`（ALinux3 容器优化版） |
| 系统盘 / 数据盘 | 100G ESSD PL1 / **300G ESSD PL1**（ACK 自动格式化最后一块数据盘并挂给容器运行时） |
| 公网 | `internet_max_bandwidth_out=0`（**不分配公网 IP**，出入网走 ALB + NAT） |
| 登录 | `key_pair=newapi-mnl`（无密码） |
| Worker RAM 角色 | `KubernetesWorkerRole-4f4f9191-362f-4e36-8420-a41375ef1183` |
| 节点池托管 | **关闭**（`management.enable=false`：无自愈 / 无 CVE 自动修复 / 无 OS 自动升级） |
| user_data | `deploy/ops/nodepool-userdata-nofile.sh`，b64 3600 B，已注入 ✅ |
| 标签（ECS 资源） | `site=ph-mnl` · `env=prod` · `track=stable` |
| 标签（K8s Node） | `site=ph-mnl` · `track=stable`（已写进节点池 `kubernetes_config.labels`，后续扩缩容节点自带） |

### 1.1 节点清单（4 台 · 跨区 2/2）

| instance_id | 机型 | 可用区 | Internal-IP |
|---|---|---|---|
| `i-5ts9wk588cliiweawind` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.194 |
| `i-5tsaatp5w68w13n4z1w8` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.195 |
| `i-5tsawhljdqzwqhmadqv0` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.200 |
| `i-5tsfiz0wh6r2kymp6jwh` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.201 |

云盘：4 × 100G（system）+ 4 × 300G（data），全 `In_use`，**0 块 Available（无孤儿盘）**。

### 1.2 前置：新增账号级服务角色（**本项目首次**）

`CreateClusterNodePool` 走 `desired_size`（手动模式）路径时报：

```
MissingAuth.AliyunOOSLifecycleHook4CSRole
please complete the AliyunOOSLifecycleHook4CSRole ramrole authorization
```

| 项 | 值 |
|---|---|
| RoleName | **`AliyunOOSLifecycleHook4CSRole`** |
| ARN | `acs:ram::5108890064395960:role/aliyunooslifecyclehook4csrole` |
| 信任服务 | `oos.aliyuncs.com`、`cs.aliyuncs.com` |
| 附加策略 | `AliyunOOSLifecycleHook4CSRolePolicy`（System） |
| 创建方式 | `aliyun ram CreateRole` + `aliyun ram AttachPolicyToRole`（**RAM 调用必须 `--region ap-southeast-1`**） |

> ⚠️ 这是**服务角色**，不是用户级策略绑定 → 不违反「仅组级承载、禁止 `AttachPolicyToUser`」铁律，但**须补入 RAM 治理文档**。
> ⚠️ 遗留：`AllowConsoleLogin=true`（API 默认），建议后续置 false 加固。

---

## 2. 终验结果（配置 17/17 + 功能 8/8 · 2026-09-29 15:20 全部闭合）

### 2.1 配置层 17/17 PASS

```
节点池配置  11/11 PASS  RG · 镜像 · multi_az_policy · 公网带宽0 · key_pair ·
                        系统盘 essd/100 · 节点 SG（未自建托管组）· 数据盘 300G/PL1 ·
                        user_data 已注入
节点实况     6/6  PASS  节点数4 · 跨2区 · 每区≥2 · 全在 rg-ph-mnl · 无公网IP · ESS BALANCE
```

### 2.2 功能层 8/8 PASS（2026-09-29 15:20 补齐 —— **原 17/17 并不覆盖这一层**）

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 4 台节点 K8s `Ready` | ✅ 4/4 `Ready=True` | `deploy/d2/nodes-zones.txt` |
| 2 | 跨 2 可用区、每区 ≥2 | ✅ 6a:2 / 6b:2 | 同上 |
| 3 | 节点标签 `site=ph-mnl` | ✅ 4/4（并已写进节点池配置） | 同上 / 坑 S |
| 4 | Terway CNI 初始化 | ✅ `/etc/cni/net.d/10-terway.conflist` | 节点内核查 |
| 5 | kubelet / containerd 运行 | ✅ 双 active；containerd 2.3.4 | 节点内核查 |
| 6 | `ulimit -n` ≥200000 | ✅ 软/硬限 **262144**；containerd/kubelet unit 均 200000 | `deploy/d2/node-fd-limit.txt` |
| 7 | 数据盘 300G 挂载给运行时 | ✅ `/dev/nvme1n1` 290G → `/var/lib/containerd`（含 `/var/lib/kubelet`、`/var/log/pods`） | 同上 |
| 8 | 集群可调度工作负载 | ✅ 全 namespace `Running 35 / Succeeded 1 / 其他 0`（修前全部 Pending） | 同上 |

> ⚠️ **教训**：任务 11 原报告「17/17 PASS」时，集群实际是 **0 Worker** —— 配置项全绿 ≠ 功能可用。
> 本卡验收标准从今以后分「配置层 / 功能层」两段，**功能层必须看到 `Ready` + 工作负载 Running**。

辅助观测：vSwitch free 6a=4088 / 6b=4089（告警线 <200 → P2）；ECS vCPU 配额 **64**，已用 **32**（4×8），上限 8 台。

---

## 3. 本卡踩到的坑（**全部实测，非推测**）

### 坑 D｜自动伸缩开启时不能设 `desired_size`/`count`，而 ACK 建池会「先备多台再削到 min」

- 报错原文：`InvalidDesiredSizeOrCount.NotNull: Parameter desired_size/count setting or modification is not supported for autoscaling-enabled nodepool`
- 后果：开伸缩建池时**节点数完全由 ESS 决定**。实测 ACK **先备 6 台**（3/3 均匀）**再削到 min=4**，削的时候把跨区分布削成了 **6a:3 / 6b:1** —— 违反「6a/6b 各 ≥2」与 R15「单 AZ 故障仍有 2 副本」。
- **正解（两步走，已验证）**：
  1. 先建**手动模式**节点池（`scaling_group.desired_size=4`，不传 `auto_scaling`）→ ESS 按 `BALANCE` 均匀给 **2/2**；
  2. 再 `aliyun cs ModifyClusterNodePool --body '{"auto_scaling":{"enable":true,"type":"cpu","min_instances":4,"max_instances":8}}'` 打开伸缩。
- 补充实测：**开伸缩的瞬间 ESS 仍会扰动**（本次观测 4→6→8→4），但**最终收敛回 4 台且保持 2/2**。
- 语义澄清：`min_instances`/`max_instances` 是**节点池总节点数**的上下限（官方原文：「最大实例数不要小于当前节点池中的节点数，否则会直接导致节点池缩容」），`desired_size` 是期望值，**两者不能相加**。配额不变量：`max_instances(8) × 8 vCPU = 64 = 已批配额`。

### 坑 E｜删节点池会被 ESS 的 `MinSize` 无限重建，池残留 `delete_failed`

- 现象：`DeleteClusterNodepool` 返回 `task_id` 看似受理，但**永远删不掉**；池状态变 `delete_failed`，此后 `RemoveNodePoolNodes` 直接报 `InvalidNodePoolStatus.Forbidden: cannot operate nodepool when nodepool state is delete_failed`。
- 根因：**ESS 伸缩组 `MinSize=4`** —— ACK 每删一台，ESS 立刻补一台；另 `GroupDeletionProtection=true` 挡删除。
- **正解**：
  1. 关保护：`aliyun ess ModifyScalingGroup --RegionId <r> --ScalingGroupId <asg> --GroupDeletionProtection false`
  2. **把容量压到 0**：`aliyun ess ModifyScalingGroup --ScalingGroupId <asg> --MinSize 0 --MaxSize 0 --DesiredCapacity 0`（否则永远重建）
  3. 再 `aliyun cs DeleteClusterNodepool` → 2 步内收敛。
- ⚠️ 走 `DELETE /clusters/.../nodepools/...` 这种 ROA 形式时**不能带 `--force`**（CLI 报 `too many arguments`）。

### 坑 F｜手动模式建池需要账号级 OOS 生命周期钩子角色

见 §1.2。不授权就报 `MissingAuth.AliyunOOSLifecycleHook4CSRole`，且**只在 `desired_size` 路径触发**（开伸缩建池时不触发）——极易误判为"API 不支持手动指定节点数"。

### 坑 G｜`data_disks[].encrypted` 是**字符串**不是布尔

`"encrypted": false` 报 `Unmarshal type error: expected=string, got=bool, field=scaling_group.data_disks.encrypted`。取值 `"true"`/`"false"`，或直接省略。

### 坑 H｜`management.enable=true` 依赖 `ack-node-problem-detector` addon

报 `InvalidParameter.Management: addon ack-node-problem-detector is not installed; please install the addon`。
本卡**默认关闭托管**（与指南 body 一致）→ 副作用：无节点自愈、无 CVE 自动修复；**反向收益**：坑 8「自动升级 OS 把 ulimit 重置回 1024」由构造保证不成立（`management.auto_upgrade_policy.auto_upgrade_os` 字段名已实测确认存在）。
若要开启：先装 addon，再 `ModifyClusterNodePool` 带 management 块（脚本 `MANAGED=1` 开关已留）。

---

## 4. CLI 口径速查（本卡新增）

| 坑 | 正解 |
|---|---|
| `aliyun cs <具名参数>` 报 `InvalidAction.NotFound`（"Specified api is not found"） | **必须带 `--region <r>`**；不带就报这个**误导性**错误（易误判为 API 不可用） |
| 节点枚举字段取 `.status` → 全 null | `DescribeClusterNodes` 返回的是 **`node_status`**（另有 `state`） |
| `DescribeClusterNodes` 数量少于实际 | 它会漏掉**尚未注册**的节点；以 **`ess DescribeScalingInstances`** 或 `ecs DescribeInstances` 为准 |
| `DescribeTaskInfo --TaskId` 无效 | 参数名是 **`--task_id`** |
| 马尼拉 `ess`/`ecs` 端点偶发 `context deadline exceeded` / `connection reset by peer` | 端点抖动（非权限问题）→ 重试给到 **5 次 × 8s**，脚本 `api()` 已设 |
| `data_disks` 对象形式 | ✅ 支持：`[{"category":"cloud_essd","size":300,"performance_level":"PL1"}]` |

---

## 5. 待办

- [ ] **任务 13**：集群级「节点伸缩」方案配置（节点池侧 min/max 已就位；集群侧扩缩容顺序策略/缩容阈值仍需配）
- [ ] **任务 22 关联**：`sg-mnl-app` 的 3000 端口入向规则已就位（组引用 ALB）；节点侧无需再加
- [x] `kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl` / `ulimit -n` 落地核查 → **2026-09-29 已完成**，见 `deploy/d2/nodes-zones.txt`、`deploy/d2/node-fd-limit.txt`
- [x] `/var/log/newapi-node-init.log` 复核（4/4 正常收尾）→ 已完成
- [ ] 8 EIP 出口复验、Tair 连通性验证 → 节点已就绪，**现在就能做**（云助手，不必等堡垒机）
- [ ] 任务 24 建新加坡节点池：**同一份 user_data**、`site=sg`、`desired=2/min=2/max=12`、`resource_group_id=rg-aek4zvb3ldoiyua`、SG `sg-t4n0qnhy8mxq9g733r67`；**同样按「先手动 2 台 → 再开伸缩」两步走**
- [ ] RAM 治理文档补录 `AliyunOOSLifecycleHook4CSRole`；并把 `AllowConsoleLogin` 置 false

---

## 6. 文档回写（2026-09-29，**已完成**）

脚本：`deploy/ops/patch_task11_nodepool.py`（幂等，`--check` / `--apply`，自动 `.bak-np11-<ts>`）。

覆盖 **5 份文件**：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（52 行）、`…指南.md`（52）、`…指南-ch.md`（52）、`wf2/part2a.md`（33）、`wf2/part5.md`（7）。

修正的 8 类错误（均为**实测**推翻原文）：

| # | 原文档写法 | 实测正解 |
|---|---|---|
| 1 | `scaling_group.min_size:4 / max_size:8` | ACK 托管节点池**无此字段** → 走 `auto_scaling.min_instances` / `max_instances` |
| 2 | 同 body 给 `desired_size` + `auto_scaling.enable=true` | **互斥**，报 `InvalidDesiredSizeOrCount.NotNull` → **两步走** |
| 3 | `scaling_group.key_name` | 正确为 **`key_pair`**；`login_password:""` 已删 |
| 4 | `auto_scaling.health_check_type` / `scale_unsupported` | **臆造字段**，已删 |
| 5 | 「`data_disks` 只创建不挂载」 | **错** → ACK 自动格式化**最后一块**数据盘并挂 `/var/lib/containerd`、`/var/lib/kubelet` |
| 6 | 快速扩容 `--body '{"scaling_group":{"desired_size":8}}'` | 开伸缩后**禁止**改 `desired_size` → 改 `auto_scaling.max_instances` |
| 7 | 校验 jq 用 `.scaling_group.min_instances` | 路径错 → `.auto_scaling.min_instances` |
| 8 | `nodepool_info` 仅 `{name}` | 补 `type:"ess"` + `resource_group_id`（遗漏会落 default 组） |

同时：4 份指南新增「✅ 已落地」块（本节 §1 摘要）；v2.0 + part2a 新增**坑 10–16**；旧版指南新增**坑 5–8**；v2.0 的「前置 / 自动升级 / `kubernetes_config` 待复核」三处标注全部改为**已实测确认**。

> 幂等标记：主标记 = nodepool_id；`part2a` / `part5` 用各自新增字段串。复跑 `--check` → 5/5 `[已是最新]`。
> ⚠️ 注意：`health_check_type` / `scale_unsupported` / 「只创建不挂载」在文档中仍有**少量残留**，均为**说明性引用**（正文里解释"这些字段是错的"），非漏改。

---

## 7. ✅ 根因定位与修复（2026-09-29 15:00–15:20，**已闭环**）

> 触发：fanyan 截图提问「为什么这个地方有失败？会有什么影响？」
> 结论：**任务 11 的 17/17 PASS 只覆盖「配置项」；功能层 4/4 节点全部 bootstrap 失败，集群 0 Worker。**
> 根因：**ACK 创建集群时没有在「控制面 ENI 的安全组」放行 TCP 6443** → 节点与 Pod 都无法直连 API Server ENI。
> 处置：补齐该安全组规则 + 重跑 bootstrap → **4/4 `Ready`，集群可用**。**全程不需要任何 hosts / EndpointSlice hack。**
>
> **📌 工单闭环（2026-09-30）**：就"为何控制面 SG 不放行 6443"提的阿里云工单已答复——**平台侧已修复**（对**新建**集群生效）。存量两集群的 6443 仍由我方 09-29 所补规则承担（`CreateTime` 可证），**勿撤**；SOP 维持（新建集群仍先复核 6443，若观察到 ACK 已自动放行即可降级该步骤）。详见 `deploy/docs/工单_ACK马尼拉控制面安全组缺失.md` §7。

### 7.1 现象：控制台「失败 2」是失真显示

| 来源 | 总数 | 正常 | 失败 |
|---|---|---|---|
| 控制台 | 4 | 2 | 2 |
| ACK API（`DescribeClusterNodePools`） | `total_nodes:4` | `healthy_nodes:4` | **`failed_nodes:0`**、`offline_nodes:2` |

- 控制台「**失败**」列映射的是 **`offline_nodes`**（离线/未注册），**不是** ACK 语义的 `failed_nodes`（= 0）。
- 「**正常 2**」同样失真：`healthy_nodes` 采的是 **ESS 生命周期状态**口径，不是 K8s Ready。
- **逐台登录 4 台节点实测：4/4 bootstrap 失败，一台都没起来。**

### 7.2 根因：一条缺失的安全组规则，解释全部现象

控制面有两个 `apiserver` 实例（马尼拉仅 2 AZ → 2 台控制面，lease 印证 `apiserver-gprgi7s…` / `apiserver-mcjcxjiz…`），
它们的 ENI 与节点同 VPC、同 vSwitch 段：

```
10.0.22.183 → eni-5ts2ay28ah0w6a5spv78  (k8s-eni-1790654108, Secondary, vsw 6a)
10.0.43.190 → eni-5tsaatp5w68vyqt00kqf  (k8s-eni-1790654105, Secondary, vsw 6b)
共用安全组    sg-5tsaatp5w68vyqszezja
```

该安全组由 ACK 自动创建，**创建后入方向只有 1 条规则**：

| 安全组 | 名称 | 入方向规则 |
|---|---|---|
| `sg-5tsaatp5w68vyqszezja` | `alicloud-cs-auto-created-security-group-cd57e40ce9a634c1698c2f5c5e09bd93c` | **仅 `ICMP -1/-1 src=0.0.0.0/0`** —— **没有任何 6443** ❌ |

实测（补规则前 / 后，节点内 `curl -sk https://<ip>:6443/version`）：

| IP | 身份 | 补规则前 | 补规则后 | ICMP |
|---|---|---|---|---|
| `10.0.22.183` | 6a apiserver ENI | ❌ 超时 4.0s | ✅ **200 / 6.1ms** | ✅ |
| `10.0.43.190` | 6b apiserver ENI | ❌ 超时 4.0s | ✅ **200 / 8.2ms** | ✅ |
| `10.0.22.182` | SLB VIP（`ManagedK8SSlbIntranet-<cid>`） | ✅ 200 / 6.2ms | ✅ 200 / 6.2ms | ✅ |

**⇒ DNS 记录与 `kubernetes` EndpointSlice 从头到尾都是对的** —— 它们指向的 183 / 190 就是真实的 apiserver ENI 地址。
182 之所以一直能通：它是 SLB VIP，走 **SLB ENI 后端模式**，不经过该安全组。

> ⚠️ **`ping` 通 ≠ 端口通**：ICMP 恰好在白名单里 → ARP / ICMP 全绿会让人误判「网络没问题」。**必须测 TCP 端口**。
> ⚠️ `curl` 报的是 **`(7) Connection timed out`** 不是 `(6) Could not resolve host` → **解析成功、纯 TCP 被丢**；别去查 DNS。

### 7.3 失败链路（4 台完全一致）

第一层 —— 节点根本没能 bootstrap：

```
attach_node.sh → ensure_kube_version
  → curl -k --connect-timeout 4 https://apiserver.<cid>.ap-southeast-6.cs.aliyuncs.com:6443/version
  → curl: (7) Failed to connect ... Connection timed out（重试 120 次 × 2s，cloud-init 卡满 606s）
  → FailGetKubeVersion → exit 1
  → containerd / kubelet 从未安装启动 · 300G 数据盘从未 auto-fdisk · 节点从未注册
```

第二层 —— 即使节点 join 了也会 NotReady：

```
apiserver ENI 6443 被 SG 丢
  → kube-proxy(IPVS) 的 kubernetes Service RealServer（183 / 190）不可达
  → Terway(eniip) 走 in-cluster config（ClusterIP 172.21.0.1:443）失败
      "task: eniOnly error: … dial tcp 172.21.0.1:443: i/o timeout"
  → /etc/cni/net.d/ 为空 → cni plugin not initialized → 节点 NotReady
```

### 7.4 修复（1 条 API 调用 + 重跑 bootstrap）

```bash
# 1) 补控制面安全组入方向规则（源 = 集群 VPC 10.0.0.0/16）
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 \
  --SecurityGroupId sg-5tsaatp5w68vyqszezja \
  --IpProtocol tcp --PortRange 6443/6443 --SourceCidrIp 10.0.0.0/16 \
  --Description "ack-cp-allows-vpc-to-apiserver-6443"

# 2) 4 台节点重跑 ACK 首次引导（云助手，免堡垒机）
#    nohup setsid bash /var/lib/cloud/instance/scripts/part-001 > /var/log/nd-rerun.log 2>&1 &
```

修复后实测（4/4 台一致）：

| 指标 | 修前 | 修后 |
|---|---|---|
| `FailGetKubeVersion` | 4/4 | **0** |
| bootstrap 耗时 | 卡满 606s 放弃 | **~45–90s** |
| `Worker node joined successfully` | 无 | **4/4** |
| **K8s 节点状态** | 无节点 / NotReady | **4/4 `Ready=True`** |
| `/etc/cni/net.d/` | 空 | **`10-terway.conflist`** |
| kube-system Pod | 全部 Pending | **Running 35 / 其他 0** |
| `offline_nodes` | 2 | **0** |
| `ulimit -n` | — | **262144（≥200000 达标）** |
| `/etc/hosts` workaround | 需要 | **0 条（不再需要）** |

节点清单（修复后最终态）：

| instance_id | 机型 | 可用区 | Internal-IP |
|---|---|---|---|
| `i-5ts9wk588cliiweawind` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.194 |
| `i-5tsaatp5w68w13n4z1w8` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.195 |
| `i-5tsawhljdqzwqhmadqv0` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.200 |
| `i-5tsfiz0wh6r2kymp6jwh` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.201 |

### 7.5 遗留 / 风险

| # | 项 | 说明 |
|---|---|---|
| 1 | **手工补的安全组规则** | 该规则由我方添加，ACK 未建。若 ACK 后续运维重置该 SG，需重加 → **建议提工单要求 ACK 侧补齐**（文本见 `deploy/docs/工单_ACK马尼拉控制面安全组缺失.md`） |
| 2 | 源放宽到 `10.0.0.0/16` | 覆盖节点 / Pod / SLB 全部可能源；API Server 仍需 mTLS 客户端证书，风险可控。如需收紧可改为「节点 SG + Pod vSwitch 段」 |
| 3 | 新加坡同构集群（任务 24） | **建集群后第一件事就是核对控制面 SG 是否有 6443 规则**，否则会原样复现 |

### 7.6 新增坑（I–S，全部实测）

| # | 坑 | 正解 |
|---|---|---|
| I | **控制台「失败」列 ≠ `failed_nodes`** | 实际映射 `offline_nodes`；「正常」用 ESS 生命周期口径也会失真 → **不要以控制台数字判断节点可用性** |
| J | **`ping` 通不代表端口通** | 控制面 SG 只放行 ICMP → ARP/ICMP 全绿、6443 全丢。**必须测 TCP 端口** |
| K | **`curl (7) timed out` ≠ DNS 问题** | `(6)` 才是解析失败。`(7)` = 解析成功但 TCP 被丢 → 先查安全组/端口 |
| L | **`DescribeClusterNodes` 不返回全部节点** | 字段名是 `node_status`（可能 `Unknown`）→ 数节点用 `ess DescribeScalingInstances` |
| M | **云助手是私网节点的唯一直连通道**（免堡垒机） | `aliyun ecs RunCommand --Type RunShellScript`（**不是 `Shell`**）→ `DescribeInvocationResults` 取 `Output`（**需 base64 解码**）；`RunCommand` 默认不持久化命令对象，用完自动清 |
| N | **ACK 的 bootstrap 排在自有 user_data 之前** | `user-data.txt` = `ACK attach_node.sh` 段 → `set +e` → 我方段 ⇒ 我方脚本里改配置**救不了当次 bootstrap** |
| O | **ESS 会自动替换 bootstrap 失败的节点** | 本次观测替换 2 轮（14:17 / 14:38）。**修复时必须按「当前实际实例 ID」**，台账历史 ID 会作废 |
| P | **重跑 `user-data.txt` 会重复 `--auto-fdisk`** | 已挂载则报 `DiskinitError`（`mkfs.ext4 … exit status 1`）——**无害**，盘已正确挂载、节点已 join |
| Q | **`pam_limits` 会把 nofile 向上取整到 2 的幂** | 写 200000 → 登录 shell 实得 **262144**；systemd 侧不取整（仍 200000）。验收口径应为「≥ 200000」 |
| R | **ESS 不严格按 `instance_types` 顺序取机型** | 本次重建后 4 台**全落 `g9ae.2xlarge`**（首次创建时是 g9i×2 + g9ae×2）→ 只要机型池内同规格即可，**勿在文档里硬编码机型分布** |
| S | **`kubernetes_config.labels` 才是节点标签真源** | 只给 `track` 不给 `site` 时，`kubectl get nodes -l site=ph-mnl` **一台都选不到**（ECS 资源 tag ≠ K8s 节点 label）。已补 `site=ph-mnl` 进节点池配置 |

### 7.7 影响

- 功能面：集群曾 0 Worker，业务 Pod 无法调度 → 任务 12 起全部阻塞（**现已解除**）。
- 成本面：4 台 `g9ae.2xlarge` 按量计费空转约 1 小时（**现已恢复产出**）。
- 计划面：任务 11 原挂 11:00–14:00 窗口，实际 **15:20 才真正闭合**。

---

## 8. 工具与证据（可复用）

### 8.1 云助手执行模板（私网节点通用）

```bash
# 下发（Type 必须是 RunShellScript；--CommandContent 需 base64）
aliyun ecs RunCommand --RegionId ap-southeast-6 --region ap-southeast-6 \
  --Type RunShellScript --ContentEncoding Base64 --Timeout 600 \
  --InstanceId.1 i-xxx --Name "np11-xxx" \
  --CommandContent "$(base64 -w0 /tmp/body.sh)"
# 轮询（Output 为 base64，需解码）
aliyun ecs DescribeInvocationResults --RegionId ap-southeast-6 --region ap-southeast-6 --InvokeId t-xxx
```

> 命令对象清理：`RunCommand` 默认**不持久化** → 本次无需清理（`DescribeCommands` 仅剩 ACK 自建的 `cs4linuxapsoutheast-6v2`）。

### 8.2 集群 admin 通道（本次新打通，**以后不必等堡垒机**）

```bash
aliyun cs DescribeClusterUserKubeconfig --ClusterId <cid> --region ap-southeast-6 --PrivateIpAddress true
# → server: https://10.0.22.182:6443（SLB VIP）
# 把 kubeconfig 内 ca/crt/key 解 base64 落成 PEM，即可在节点内用 curl 直连 REST API（无需 kubectl）
```

⚠️ 权限为 cluster-admin，凭据只落节点 `/tmp`，用完即删。

### 8.3 本次证据文件

- `deploy/d2/nodes-zones.txt`（M2 里程碑要求：两集群 `kubectl get nodes` 跨 AZ）
- `deploy/d2/node-fd-limit.txt`（M2 里程碑要求：`ulimit -n`）

---

## 9. 待办

- [ ] **提交工单**：要求 ACK 侧补齐控制面安全组 6443 规则（文本 → `deploy/docs/工单_ACK马尼拉控制面安全组缺失.md`）
- [x] ~~**任务 13**：集群级「节点伸缩」方案配置~~ → **编号更正：文档里「节点伸缩」是任务 42**（任务 13 是 RDS 账号最小化，早已完成）。任务 42 已执行，见 §10
- [ ] **任务 22 关联**：`sg-mnl-app` 的 3000 端口入向规则已就位（组引用 ALB）；节点侧无需再加
- [ ] 8 EIP 出口复验、Tair 连通性验证 → 节点已就绪，**现在就能做**（云助手）
- [x] ~~**任务 24** 建新加坡节点池~~ → **已完成 2026-09-29，17/17 PASS**；台账 → `deploy/nodepool_ledger_sg.md`
- [ ] RAM 治理文档补录 `AliyunOOSLifecycleHook4CSRole`；并把 `AllowConsoleLogin` 置 false

---

## 10. ★ 跨集群新增坑：`AzBalance`（2026-09-29，任务 42）

**马尼拉这个池其实也一直没开可用区均衡** —— 它 6a:2 / 6b:2 只是「运气好」。任务 42 复核两池伸缩配置时发现并修掉了：

- ACK 建节点池只设 ESS 的 `MultiAZPolicy=BALANCE`，**不设独立的 `AzBalance`**。仅前者时，ESS 在**实例创建阶段不做跨区均衡**，会顺着「有库存的交换机」把实例全塞进去 —— 新加坡 desired=2 建出来是 **1a:2 / 1b:0**（先把首位机型换成两区都在售的 `g9ae` 仍全落 1a，证明与机型无关）。
- 修复与断言（**幂等，两地通用**）：
  ```bash
  bash deploy/ops/nodepool_azbalance_fix.sh mnl     # 马尼拉 asg-5tsd68ew4u0wutaqk5cy
  bash deploy/ops/nodepool_azbalance_fix.sh sg      # 新加坡 asg-t4ngzbg7m9u84y59dkxl
  ```
- ⚠️ `AzBalance` **`DescribeScalingGroups` 不回读**；且**任何经 ACK 侧改节点池后都要重跑断言**（可能被覆盖）。
- 马尼拉处置结果：`AzBalance=true` 已断言，分布仍 **6a:2 / 6b:2**（未开 `AutoRebalance`，不动现有节点）。

**任务 42 现状（两池均已对齐）**

| | 马尼拉 `np-mnl-app` | 新加坡 `np-sg-ph-standby` |
| --- | --- | --- |
| auto_scaling | `enable=true` min **4** / max **8** | `enable=true` min **2** / max **12** |
| ESS | 4 / 8 | 2 / 12 |
| AzBalance | **true（本次新补）** | **true** |
| 配额不变量 | 8×8 = 64 = 已批（顶满） | 12×8 = 96 = 已批（顶满） |
| 实况 | total=4 healthy=4 offline=0 | total=2 healthy=2 offline=0 |

**容量口径**：按 **request** 规划 + 留 30% 余量（8C 节点可分配 ≈7.2C，stable 副本 request 2C → 每节点 ≈3 副本）；**勿按 limit 4C 算**。

## 11. ✅ 任务 42 收尾（2026-09-30，PDB 已建，本卡全部落地）

- `pdb-new-api-stable`（ns `new-api`，`minAvailable: 70%`，selector `app=new-api,track=stable`）**已创建**（此前因任务 17 未建 ns 而顺延）。当前 `ALLOWED DISRUPTIONS=0` 属预期——匹配 Pod 为 0，stable Deployment（任务 23）上线后随副本数变化。
- **AzBalance 复断言（2026-09-30）**：两池均重跑 `deploy/ops/nodepool_azbalance_fix.sh`（幂等），分布 **6a:2/6b:2**、**1a:1/1b:1**，与 09-29 一致，无漂移。
- 配额不变量复核：马尼拉 8×8=64 / 新加坡 12×8=96，均顶满已批配额（64/96，工单 Agree）——`max_size` 不可再调大，除非先提配额。

**⛔ 仍挂账：伸缩压测验证（卡片「验证方法」整段）**——唯一前置：`new-api-stable` Deployment 尚未部署（任务 23/24），无从 scale。
（付费方式订正见下 §11.1：**实为按量**，无"预付/不退款"问题，原"须预算签字"前提作废；配额约束 = 马尼拉 8×8=64 顶满按量已批 64、新加坡 12×8=96 顶满 96。）
→ 触发条件：任务 23 部署 stable 后，低峰窗口执行「scale 12 → 观察 Pending→扩容→Running → 缩回 4」，证据回填本节。

### 11.1 ⚠️ 付费方式实测订正（2026-09-30）：两池实为**按量（PostPaid）**，"全面转包年"决策未落地

三层 API 证据一致（控制台节点池列表"自动收缩策略"列显示"（包年包月）"与执行层矛盾，**以 API 为准**）：

| 视角 | 字段 | 马尼拉 | 新加坡 |
|---|---|---|---|
| ACK 节点池 `DescribeClusterNodePoolDetail` | `scaling_group.instance_charge_type` / `period` / `auto_renew` | `PostPaid` / 0 / false | `PostPaid` / 0 / false |
| ECS 实例本体 `DescribeInstances` | `InstanceChargeType` / `ExpiredTime` | `PostPaid` / `2099-12-31`（按量哨兵值） | 同 |
| ESS 伸缩配置 `DescribeScalingConfigurations`（**扩容新节点真正走的那层**） | `InstanceChargeType` / `Period` | `null`（ESS 中 null=按量） | `null` |

根因：建池脚本 `deploy/tasks/task11/nodepool_mnl.sh` 写死 `instance_charge_type:"PostPaid"` → **2026-09-28"ECS 节点池全面转包年（PrePaid，1 年 + 自动续费）"决策从未落到节点池**，而任务 11 坑 7/7b（扩容即预付、库存独立）与本卡前置的成本模型都建立在 PrePaid 前提上。

**✅ 已裁定（2026-09-30，负责人）：选 A —— 维持按量**；配额口径固定为按量 `q_ecs_enterprise_postpay_c`（64/96，顶满 max_size），`prepay_c`=100/100 降为备查。三选项留档：
- **A. 维持按量 ✅**：弹性最灵活，新加坡备区（低频启用）语义合适；代价是马尼拉 4 台常驻节点按量单价高于包年（实测差价可用 `DescribePrice`，注意任务 11 坑 7：Prepaid 用 `--CommodityCode rds`、Postpaid 用 `bards`，先看 `chargeType` 自校）。
- ~~**B. 补执行转包年**~~（否决）：基线 4 台走 ECS `ModifyInstanceChargeType`；节点池 `instance_charge_type` 改 PrePaid 让扩容走包年 → 回到坑 7"扩容即预付、缩容不退款"的成本刚性。
- ~~**C. 混合**~~（否决）：马尼拉基线转包年 + 新加坡保持按量；成本表需分列两种口径。

**文档回写**：v2.0 指南共 **38 处**已按本裁定订正（`deploy/ops/patch_prepaid_to_postpaid_20260930.py`，幂等，含建池 body/配额口径/成本表/坑 7·7b 状态标记），备份 `*.bak-prepaid2postpaid-20260930-180320`；另见 `deploy/docs/付费方式修订记录-2026-09-28.md` 追加的 2026-09-30 节。
