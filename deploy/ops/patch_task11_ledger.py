#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 nodepool_ledger.md 的 §7/§8（基于错误假设的 DNS 结论）重写为实测根因（控制面 SG 缺 6443）。
幂等：已打过则直接退出。用法：--check | --apply"""
import datetime
import shutil
import sys
from pathlib import Path

LEDGER = Path(__file__).resolve().parent.parent / "nodepool_ledger.md"
MARK = "## 7. ✅ 根因定位与修复"
CUT_AT = "## 7. ⚠️ 重大发现"

NEW_TAIL = """## 7. ✅ 根因定位与修复（2026-09-29 15:00–15:20，**已闭环**）

> 触发：fanyan 截图提问「为什么这个地方有失败？会有什么影响？」
> 结论：**任务 11 的 17/17 PASS 只覆盖「配置项」；功能层 4/4 节点全部 bootstrap 失败，集群 0 Worker。**
> 根因：**ACK 创建集群时没有在「控制面 ENI 的安全组」放行 TCP 6443** → 节点与 Pod 都无法直连 API Server ENI。
> 处置：补齐该安全组规则 + 重跑 bootstrap → **4/4 `Ready`，集群可用**。**全程不需要任何 hosts / EndpointSlice hack。**

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
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 \\
  --SecurityGroupId sg-5tsaatp5w68vyqszezja \\
  --IpProtocol tcp --PortRange 6443/6443 --SourceCidrIp 10.0.0.0/16 \\
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
aliyun ecs RunCommand --RegionId ap-southeast-6 --region ap-southeast-6 \\
  --Type RunShellScript --ContentEncoding Base64 --Timeout 600 \\
  --InstanceId.1 i-xxx --Name "np11-xxx" \\
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
- [ ] **任务 13**：集群级「节点伸缩」方案配置（节点池侧 min/max 已就位；集群侧扩缩容顺序策略/缩容阈值仍需配）
- [ ] **任务 22 关联**：`sg-mnl-app` 的 3000 端口入向规则已就位（组引用 ALB）；节点侧无需再加
- [ ] 8 EIP 出口复验、Tair 连通性验证 → 节点已就绪，**现在就能做**（云助手）
- [ ] **任务 24** 建新加坡节点池：**同一份 user_data**、`site=sg`、`desired=2/min=2/max=12`、`resource_group_id=rg-aek4zvb3ldoiyua`、SG `sg-t4n0qnhy8mxq9g733r67`；**同样「先手动 2 台 → 再开伸缩」两步走**；**建完先核对控制面 SG 6443**
- [ ] RAM 治理文档补录 `AliyunOOSLifecycleHook4CSRole`；并把 `AllowConsoleLogin` 置 false
"""

PAIRS = [
    ("| 实配机型 | `g9i` ×2 + `g9ae` ×2（伸缩扰动期换过一批，仍在机型池内） |",
     "| 实配机型 | **`g9ae.2xlarge` ×4**（ESS 自主挑选，**不严格按 `instance_types` 顺序**；见坑 R） |",
     "§1 实配机型"),
    ("| 标签 | `site=ph-mnl` · `env=prod` · `track=stable` |",
     "| 标签（ECS 资源） | `site=ph-mnl` · `env=prod` · `track=stable` |\n"
     "| 标签（K8s Node） | `site=ph-mnl` · `track=stable`（已写进节点池 `kubernetes_config.labels`，后续扩缩容节点自带） |",
     "§1 标签拆两行"),
    ("| instance_id | 机型 | 可用区 | 创建(UTC) |\n|---|---|---|---|\n"
     "| `i-5ts2ay28ah0w7fljiknd` | `ecs.g9i.2xlarge` | ap-southeast-6a | 05:25 |\n"
     "| `i-5tsil3ca5dfksbhln1zz` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 05:56 |\n"
     "| `i-5tsawhljdqzwpk2rgt67` | `ecs.g9i.2xlarge` | ap-southeast-6b | 05:25 |\n"
     "| `i-5ts9p560en42mwhc78ax` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 05:56 |",
     "| instance_id | 机型 | 可用区 | Internal-IP |\n|---|---|---|---|\n"
     "| `i-5ts9wk588cliiweawind` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.194 |\n"
     "| `i-5tsaatp5w68w13n4z1w8` | `ecs.g9ae.2xlarge` | ap-southeast-6a | 10.0.22.195 |\n"
     "| `i-5tsawhljdqzwqhmadqv0` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.200 |\n"
     "| `i-5tsfiz0wh6r2kymp6jwh` | `ecs.g9ae.2xlarge` | ap-southeast-6b | 10.0.43.201 |",
     "§1.1 节点清单换新实例"),
    ("- [ ] `kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl` / `ulimit -n`=200000 落地核查 → 私网端点，需 **VPC 内**（任务 46 堡垒机）\n"
     "- [ ] 节点 nofile 脚本执行结果可在节点 `/var/log/newapi-node-init.log` 复核（需 VPC 内）\n"
     "- [ ] 8 EIP 出口复验、Tair 连通性验证 → 节点已就绪，等堡垒机",
     "- [x] `kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl` / `ulimit -n` 落地核查 → **2026-09-29 已完成**，见 `deploy/d2/nodes-zones.txt`、`deploy/d2/node-fd-limit.txt`\n"
     "- [x] `/var/log/newapi-node-init.log` 复核（4/4 正常收尾）→ 已完成\n"
     "- [ ] 8 EIP 出口复验、Tair 连通性验证 → 节点已就绪，**现在就能做**（云助手，不必等堡垒机）",
     "§5 待办勾掉已完成项"),
]


def main():
    apply = "--apply" in sys.argv
    raw = LEDGER.open(encoding="utf-8", newline="").read()
    nl = "\r\n" if "\r\n" in raw else "\n"

    if MARK in raw:
        print("[已是最新] nodepool_ledger.md")
        return 0

    if CUT_AT not in raw:
        print("[错误] 找不到切割点：", CUT_AT)
        return 1

    new = raw
    changed = []
    for old, rep, tag in PAIRS:
        o = old.replace("\n", nl)
        r = rep.replace("\n", nl)
        if o in new and r not in new:
            new = new.replace(o, r, 1)
            changed.append(tag)
        elif o not in new:
            print("[未匹配]", tag)

    idx = new.index(CUT_AT)
    new = new[:idx] + NEW_TAIL.replace("\n", nl)

    print("[待改] 替换片段：", "；".join(changed) if changed else "（无）")
    print("[待改] §7 起全部重写，长度 %d → %d 字符" % (len(raw), len(new)))

    if apply:
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        shutil.copy2(LEDGER, LEDGER.with_suffix(LEDGER.suffix + ".bak-ledger-" + ts))
        LEDGER.write_text(new, encoding="utf-8", newline="")
        print("[已写入]", LEDGER.name, "备份 .bak-ledger-" + ts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
