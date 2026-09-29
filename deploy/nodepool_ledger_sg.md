# 新加坡备站 · ACK 集群 + 节点池台账（任务 24 / 42）

> 落地日期：**2026-09-29** · 操作环境：WSL Ubuntu + aliyun CLI 3.5.1（国际站）
> 对应任务卡：`阿里云国际站菲律宾部署_详细操作指南-v2.0.md` **任务 24**（新加坡 ACK + 常态 2 节点）、**任务 42**（两集群自动伸缩）
> 马尼拉侧同构台账 → `deploy/nodepool_ledger.md`

---

## 1. 资源清单（实测）

| 项 | 值 |
| --- | --- |
| 集群 ID | `ca75829e3492d491d9d434de087913798` |
| 集群名 | `ack-newapi-sg` |
| 地域 / 版本 / 规格 | `ap-southeast-1` / `1.35.7-aliyun.1` / `ack.pro.small`（Pro 托管版） |
| 资源组 | `rg-aek4zvb3ldoiyua`（rg-sg）✅ |
| VPC | `vpc-t4nimmwvruexbnene0a3r`（10.1.0.0/16） |
| **Service CIDR** | **`172.22.0.0/20`** ← 见 §5「与文档的刻意偏离」 |
| vSwitch | `vsw-t4nbvsnvo4z52sumr9sck`（app-a / 1a / 10.1.16.0/20）· `vsw-t4n3dthz1ma6tp7bqor6h`（app-b / 1b / 10.1.32.0/20） |
| 内网端点 | `https://10.1.19.73:6443`（公网端点**未开**） |
| RRSA | `enabled=true`；`oidc_arn=acs:ram::5108890064395960:oidc-provider/ack-rrsa-ca75829e3492d491d9d434de087913798` |
| 集群安全组（控制面 ENI） | `sg-t4nevyfflaeo3tdvi510` ← **已手工补 6443，见 §3** |
| 删除保护 | `true` |
| 密钥对 | `newapi-sg`（导入 fanyan 的 `id_ed25519.pub`） |
| **节点池** | `np-ab...` = `npab9d46aefe3a4649b074543f36f32599` / `np-sg-ph-standby` |
| **ESS 伸缩组** | `asg-t4ngzbg7m9u84y59dkxl`（min **2** / max **12** / `MultiAZPolicy=BALANCE` / `AzBalance=true`） |
| 节点（2 台） | `i-t4nb4aj0ssltm7jjaawuv`（`ecs.g9ae.2xlarge` / 1a / `10.1.19.103`）<br>`i-t4nha3jicbebtvf3tr7v`（`ecs.g8ine.2xlarge` / 1b / `10.1.38.113`） |
| 节点安全组 | `sg-t4n0qnhy8mxq9g733r67`（`sg-sg-app`，**未**自建托管组） |
| 系统盘 / 数据盘 | `cloud_essd` 100G PL1 / `cloud_essd` 300G PL1（挂 `/var/lib/containerd`） |
| 标签 | 节点池 tags：`site=sg` `env=prod` `track=stable`；节点 labels：`track=stable` `site=sg` |

---

## 2. 终验结果

- **集群 12/12 PASS**（id / name / state / version / spec / type / RG / VPC / proxy / timezone / 删除保护 / RRSA）
- **节点池 17/17 PASS，0 FAIL**（RG · 镜像 · BALANCE · 公网带宽0 · key_pair · 系统盘 essd/100 · 节点 SG · 数据盘 300G/PL1 · user_data 3600B · 节点数2 · 跨2区 · 每区≥1 · 全在 rg-sg · 无公网IP · ESS BALANCE）
- **集群内落地核查**（云助手直连私网节点，未用任何 hosts/EndpointSlice hack）：

```
nodes: 2/2 Ready=True · zone=1a / 1b · site=sg
kube-system Pod: 20 Running / 0 其他
CNI: 10-terway.conflist          kubectl: v1.35.7-aliyun.1
kubelet=active  containerd=active
nofile: containerd=200000  kubelet=200000  shell=262144
数据盘: /dev/nvme1n1 290G → /var/lib/containerd
Terway CRD: network.alibabacloud.com/v1beta1 等 10 个已注册
出口 IP: 仅命中已登记 SG EIP 池（47.84.126.214 / 47.84.29.162 / 47.84.83.76）
```

- 配额：`ap-southeast-1` vCPU **96**，已用 **16**（2×8）→ 上限 12 台，与 `max_instances` 相等 ✅
- vSwitch 余量：1a free=**4073** · 1b free=**4084**（告警线 <200 → P2）

---

## 3. ★ 血案同构复现：ACK 建集群漏放行控制面 6443

**新加坡集群建出后立刻核对，100% 复现马尼拉的缺陷**：

```
sg-t4nevyfflaeo3tdvi510   name=alicloud-cs-auto-created-security-group-<集群ID>
  ingress 规则数 = 1  →  仅 ICMP -1/-1 ← 0.0.0.0/0
  ❌ 没有任何 6443 规则
```

→ 结论：**这是 ACK 平台侧缺陷，不是个案**，`ap-southeast-6` 与 `ap-southeast-1` 均复现，**新集群会稳定重现**。

**处置**：本次在**建节点池之前**就补上规则，因此 2 台节点**首次引导即成功**，完全没有重演马尼拉那条「DNS→EndpointSlice→kube-proxy IPVS→Terway→NotReady」的 6 小时排障链。

```bash
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-1 --SecurityGroupId sg-t4nevyfflaeo3tdvi510 \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 6443/6443 \
  --Permissions.1.SourceCidrIp 10.1.0.0/16 --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 \
  --Permissions.1.Description "ack-cp-allows-vpc-to-apiserver-6443"
```

**SOP（写进流程）**：任何新建 ACK 集群，**第 1 步**就是查 `security_group_id` 有没有 6443；没有就补，再建节点池。

---

## 4. 任务 42｜两集群自动伸缩现状（已对齐）

| | 马尼拉 `np-mnl-app` | 新加坡 `np-sg-ph-standby` |
| --- | --- | --- |
| nodepool_id | `npaad418131aa84c899be022b5463d13bf` | `npab9d46aefe3a4649b074543f36f32599` |
| ESS | `asg-5tsd68ew4u0wutaqk5cy` | `asg-t4ngzbg7m9u84y59dkxl` |
| auto_scaling | `enable=true` type=cpu **min 4 / max 8** | `enable=true` type=cpu **min 2 / max 12** |
| ESS Min/Max | 4 / 8 | 2 / 12 |
| 实况 | total=4 healthy=4 offline=0 failed=0 | total=2 healthy=2 offline=0 failed=0 |
| 可用区分布 | 6a:2 / 6b:2 | 1a:1 / 1b:1 |
| **AzBalance** | **true（本次新补）** | **true（本次新补）** |
| 配额不变量 | 8 × 8 vCPU = **64** = 已批配额（顶满） | 12 × 8 = **96** = 已批配额（顶满） |

**容量口径（对齐后续 HPA）**：按 **request** 规划、留 30% 余量 —— 8C 节点可分配约 7.2C，stable 副本 request 2C → 每节点约 3 个副本。**勿按 limit（4C）算**，否则会出现「HPA 显示已达标而 Pod 全 Pending」。

**未完成项**：任务 42 步骤 4 的 `PodDisruptionBudget pdb-new-api-stable`（`minAvailable: 70%`）依赖 **namespace `new-api`**，由 **任务 17** 创建 → 顺延至任务 17 之后执行，避免现在硬造 namespace。

---

## 5. 坑（本次实测新增，编号 A–F）

### 坑 A ★｜`MultiAZPolicy=BALANCE` ≠ 开启可用区均衡，必须另设 `AzBalance=true`

- **现象**：ACK 建池 body 写了 `multi_az_policy: BALANCE`，`DescribeScalingGroups` 也回读 `MultiAZPolicy=BALANCE`，但 desired=2 建出来是 **1a:2 / 1b:0**。
- **根因**：ESS 有**独立的 `AzBalance` 开关**，ACK **不设置它**。仅 `MultiAZPolicy=BALANCE` 时，ESS 在**实例创建阶段不做跨区均衡**，而是顺着「能买到机型 / 有库存」的交换机把实例全塞进去。
- **佐证**：把 `instance_types` 首位换成两区都在售的 `g9ae` **仍然全落 1a** → 证明与机型无关，是均衡开关没开。
- **修复**：`aliyun ess ModifyScalingGroup --GroupId <asg> --AzBalance true --BalanceMode BalancedBestEffort [--AutoRebalance true]` → 立即生效：ESS 先在 1b 补 1 台（total 2→3），再削掉 1a 一台（3→2），收敛 **1a:1 / 1b:1**。
- **⚠️ 不可回读**：`AzBalance` **不出现在 `DescribeScalingGroups` 返回里** → 「是否已开启」只能靠实例的可用区分布间接证明，或幂等重设。
- **⚠️ 会被覆盖**：任何经 ACK 侧（`ModifyClusterNodePool` / 控制台）改节点池后，**必须重跑断言**。
- **工具**：`deploy/nodepool_azbalance_fix.sh mnl|sg| <region> <asg_id> [--rebalance]`（幂等）
- **`BalanceMode` 取值**：`BalancedBestEffort`（默认，可用性优先：目标区无货时会在别区补足）/ `BalancedOnly`（均衡优先：目标区创建失败则**整个伸缩活动失败**）。本项目选 **BestEffort** —— 备站扩不出容比短暂失衡危险得多。

### 坑 B｜机型候选顺序会决定可用区落点（1b 没有 g9i）

- `ecs.g9i.2xlarge` 在 **ap-southeast-1b 完全不在售**（1a 有）；`g8ine` / `g9ae` 两区都有。
- ACK **不暴露**「按交换机绑机型」的 `instance_type_overrides`（`--help` 已核，`scaling_group` 只有 `instance_types` / `instance_patterns` 平铺列表）。
- 因此：**`instance_types` 首位必须是「两区都在售」的机型**，否则 ESS 选型后再选可用区，会把实例全放到首位机型所在的那个区。
- 最终取值：**`ecs.g9ae.2xlarge,ecs.g9i.2xlarge,ecs.g8ine.2xlarge`**（与马尼拉的 `g9i,g8ine,g9ae` 顺序**刻意不同**）。
- 实测机型分布：1a=`g9ae.2xlarge`、1b=`g8ine.2xlarge`（**勿硬编码机型分布**，两区目录不同）。

### 坑 C｜删节点池必须**先等 ESS 真正清零**，否则必得 `delete_failed`

- **现象**：`ModifyScalingGroup --MinSize 0 --MaxSize 0 --DesiredCapacity 0` 之后立刻 `DeleteClusterNodepool` → 节点池进入 **`delete_failed`**；ACK 任务报 `ScalingGroup's instances not empty`。
- **根因**：容量归零是**异步**的，实例先进入 `Removing:Wait`，**实测约 6–7 分钟**才真正释放。此时 ACK 的删除流程已经跑完并判定失败。
- **修复顺序**：
  1. `ess ModifyScalingGroup --GroupDeletionProtection false`
  2. `ess ModifyScalingGroup --MinSize 0 --MaxSize 0 --DesiredCapacity 0`
  3. **轮询 `DescribeScalingGroups.TotalCapacity == 0`**（别只看 DesiredCapacity）
  4. 再 `cs DeleteClusterNodepool --body '{"release_node":true,"drain_node":false}'`
  5. 若已 `delete_failed`：清空后**重发一次删除**即可恢复（无需重建集群）。
- **附**：`delete_failed` 状态下的节点池**无法** `RemoveNodePoolNodes`（报 `InvalidNodePoolStatus.Forbidden`）。

### 坑 D｜`AliyunOOSLifecycleHook4CSRole` 也是新加坡侧必需的服务角色

账号级角色，马尼拉任务 11 已建 → 新加坡**无需重建**（同账号共享）。若删过要重建：`ram CreateRole`（信任 `oos.aliyuncs.com` + `cs.aliyuncs.com`）+ `AttachPolicyToRole --PolicyType System --PolicyName AliyunOOSLifecycleHook4CSRolePolicy`。

### 坑 E｜密钥对不能跨 region 复用，且取不到公钥体

- `DescribeKeyPairs` **不返回** `PublicKeyBody`（马尼拉 `newapi-mnl` 实测 `body_len=0`）→ 无法把已有密钥对「复制」到新地域。
- 处置：**导入本地公钥**（`id_ed25519.pub`）为新地域密钥对，一套私钥管两地：
  ```bash
  aliyun ecs ImportKeyPair --RegionId ap-southeast-1 --KeyPairName newapi-sg \
    --PublicKeyBody "$(cat ~/.ssh/id_ed25519.pub)"
  ```

### 坑 F｜`set -u` 下 case 分支里 `$1` 未绑定会直接崩

`--wait) do_wait ;;` + `do_wait(){ local cid="$1" ... }` → `$1: unbound variable`。改 `do_wait "${2:-}"`。

---

## 6. 与文档的刻意偏离

| 项 | 文档口径 | 实际采用 | 理由 |
| --- | --- | --- | --- |
| Service CIDR（新加坡） | 未明写，隐含沿用马尼拉的 `172.21.0.0/20` | **`172.22.0.0/20`** | 两集群 Service CIDR 相同会在未来接云企业网/CEN 时成为**不可修改的死锁**（马尼拉任务 10 坑 2 原话）。错开是零成本保险。 |
| `instance_types` 顺序 | 「与马尼拉相同」 | `g9ae,g9i,g8ine` | 见坑 B —— 1b 无 g9i。 |
| 终验「每区节点数」 | 沿用马尼拉「≥2」 | SG 断言改为 **≥1** | 常态 2 台不可能每区 2 台。已参数化为 `MIN_PER_ZONE`。 |

---

## 7. 工具与产物

| 文件 | 说明 |
| --- | --- |
| `deploy/task24_ack_sg.sh` | 建集群：`--check` / `--keypair` / `--create` / `--wait` / `--verify` / `--all`（幂等） |
| `deploy/task24_nodepool_sg.sh` | 节点池薄封装，**复用** `task11_nodepool_mnl.sh`（两地同一份 user_data / 逻辑） |
| `deploy/nodepool_azbalance_fix.sh` | ESS `AzBalance` 断言/修复（**两地通用**，改完节点池必跑） |
| `deploy/nodepool-userdata-nofile.sh` | 节点 user_data（两地共用，2700 B → b64 3600 B） |
| `deploy/logs/task24_*` | 建集群 / 建池 / 终验原始证据 |

**被拆掉的一次性产物**（仅留档，勿再引用）：`np2a1f97d36e2947899d11a90d32f8ceb9` / `asg-t4njdtaf52bj8lg1gfcz`（跨区失衡的那一版）。

---

## 8. 待办

- [ ] **任务 42 步骤 4**：`pdb-new-api-stable`（`minAvailable: 70%`）→ 等**任务 17** 建出 `new-api` namespace 后执行
- [ ] 任务 24 验证项「egress-probe 只出现 4 个 SG EIP」的**完整 8 次采样**，与「节点出网可达马尼拉 ACR 公网端点」→ 可随时用云助手补跑（已具备条件）
- [ ] 任务 24 与主站一致性核对（`SESSION_SECRET` 同源 KMS、镜像 tag、`NODE_TYPE=slave`）→ 属任务 28 范畴
- [ ] **报障补充材料**：向阿里云补充「新加坡地域同样复现控制面 SG 缺 6443」，佐证其为平台缺陷
