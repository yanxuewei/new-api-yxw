# 阿里云工单（可直接粘贴）· ACK 马尼拉集群控制面安全组未放行 6443，导致节点全部初始化失败

> 工单分类：**容器服务 ACK / 集群异常 / 节点无法加入集群**
> 优先级：**P2**（生产集群无法调度任何工作负载，已阻塞 1 小时以上）
> 附件：本文件 + `deploy/nodepool_ledger.md` §7–§8

---

## 一、问题概述

ACK 托管集群 `ack-newapi-mnl`（ap-southeast-6）创建后，**控制面 ENI 的安全组没有放行 TCP 6443**（入方向只有一条 ICMP 规则）。
后果是**任何 Worker 节点、任何 Pod 都无法直连 API Server 的真实地址**，导致：

1. 全部 Worker 节点在初始化脚本 `attach_node.sh` 的 `ensure_kube_version` 阶段失败（`FailGetKubeVersion`），**4/4 节点无法加入集群**，集群 0 个 Worker；
2. 即便人工重跑初始化让节点 join，**Terway CNI 也无法初始化**（Terway 经 ClusterIP 访问 API Server 超时），节点永远 `NotReady`。

**我方已自行补上该安全组规则并验证：补规则后 4/4 节点 `Ready`、集群恢复可调度。**
但仍请阿里云确认这是否为产品缺陷，并修正控制台/模板侧，避免**新建集群原样复现**（我方后续还需在新加坡 `ap-southeast-1` 建同构集群）。

---

## 二、环境信息

| 项 | 值 |
|---|---|
| 账号 ID | 5108890064395960 |
| 地域 | **ap-southeast-6**（马尼拉） |
| 集群 ID / 名称 | `cd57e40ce9a634c1698c2f5c5e09bd93c` / `ack-newapi-mnl`（ManagedKubernetes / ACK Pro） |
| K8s 版本 | `1.35.7-aliyun.1` |
| VPC / CIDR | `vpc-5tst1tgeessxn1azwasg2` / `10.0.0.0/16` |
| 节点池 | `npaad418131aa84c899be022b5463d13bf`（`np-mnl-app`），4 × `ecs.g9ae.2xlarge` |
| 集群创建时间 | 2026-09-29 11:55（UTC+8） |
| 问题发现时间 | 2026-09-29 14:20（UTC+8） |

---

## 三、证据

### 3.1 控制面安全组「创建后」的入方向规则（原始状态）

```
SecurityGroupId : sg-5tsaatp5w68vyqszezja
SecurityGroupName: alicloud-cs-auto-created-security-group-cd57e40ce9a634c1698c2f5c5e09bd93c
Description      : security group of ACK Cluster cd57e40ce9a634c1698c2f5c5e09bd93c

Permissions（入方向）共 1 条：
  ICMP   -1/-1   SourceCidrIp=0.0.0.0/0
  ← 没有任何 TCP 6443 规则
```

### 3.2 绑定该安全组的控制面 ENI（即 apiserver 实例）

```
10.0.22.183 → eni-5ts2ay28ah0w6a5spv78   name=k8s-eni-1790654108  type=Secondary  vswitch=vsw-5tswpyzfa8od6je95td1h(6a)
10.0.43.190 → eni-5tsaatp5w68vyqt00kqf   name=k8s-eni-1790654105  type=Secondary  vswitch=vsw-5tshuvvtrqm97tnwe1ddm(6b)
共用安全组：sg-5tsaatp5w68vyqszezja
```

> 这两个地址**同时出现在**集群内 `kubernetes` Service 的 Endpoints / EndpointSlice 与内网 DNS `apiserver.<cid>.ap-southeast-6.cs.aliyuncs.com` 的解析结果里 ——
> **说明 DNS 与 EndpointSlice 的登记值是正确的**，问题纯在网络层放行。

### 3.3 连通性实测（在 Worker 节点内执行）

| 目标 IP | 身份 | 补规则前 6443 | 补规则后 6443 | ICMP |
|---|---|---|---|---|
| `10.0.22.183` | 6a apiserver ENI | ❌ `curl (7)` 超时 4.0s | ✅ `http=200` 6.1ms | ✅ 通 |
| `10.0.43.190` | 6b apiserver ENI | ❌ `curl (7)` 超时 4.0s | ✅ `http=200` 8.2ms | ✅ 通 |
| `10.0.22.182` | 内网 SLB VIP（`ManagedK8SSlbIntranet-<cid>`） | ✅ `http=200` 6.2ms | ✅ `http=200` 6.2ms | ✅ 通 |

> **关键点**：`ping` 一直通（ICMP 在白名单里），只有 TCP 6443 被丢。
> `curl` 错误码是 **`(7) Failed to connect … Connection timed out`**，**不是 `(6)`（解析失败）** → DNS 正常，纯 TCP 被安全组拦截。
> 182 之所以通：它是 SLB VIP，走 SLB ENI 后端模式，不经该安全组。

### 3.4 ACK 自身日志（节点内）

```
/var/log/ack-deploy-error-code.log : FailGetKubeVersion
/var/log/ack-deploy-error-msg.log  : failed: unable to get kube version from apiserver
/var/log/ack-deploy.log            : 连续 120 次
    curl -k --connect-timeout 4 https://apiserver.<cid>.ap-southeast-6.cs.aliyuncs.com:6443/version
    curl: (7) Failed to connect ... Connection timed out
cloud-init                         : 耗时 606 秒后放弃
```

### 3.5 CNI 侧连带失败（节点内 `crictl logs`）

```
task: eniOnly
error: … dial tcp 172.21.0.1:443: i/o timeout      # ClusterIP 访问 API Server，RealServer 即 183/190
→ /etc/cni/net.d/ 为空 → kubelet 报 cni plugin not initialized → NotReady
```

### 3.6 我方的修复动作与结果

```bash
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 \
  --SecurityGroupId sg-5tsaatp5w68vyqszezja \
  --IpProtocol tcp --PortRange 6443/6443 --SourceCidrIp 10.0.0.0/16 \
  --Description "ack-cp-allows-vpc-to-apiserver-6443"
```

| 指标 | 修前 | 修后 |
|---|---|---|
| `FailGetKubeVersion` | 4/4 失败 | **0** |
| 节点 K8s 状态 | 无节点 / `NotReady` | **4/4 `Ready=True`**（6a:2 / 6b:2） |
| `/etc/cni/net.d/` | 空 | **`10-terway.conflist`** |
| kube-system Pod | 全部 Pending | **Running 35 / 其他 0** |

---

## 四、影响

1. **4 台 Worker 全部无法加入集群**，集群 0 Worker，**无法调度任何业务 Pod**（集群级故障）。
2. 节点池持续按量计费但零产出；且 ESS 会把 `bootstrap` 失败的实例判定为「Healthy/InService」（因生命周期钩子超时放行），**集群不会自愈**，只会反复替换出同样失败的新实例（本次观测替换 2 轮）。
3. 所有经 ClusterIP 访问 API Server 的组件（Terway、coredns 等 addon）全部受影响。

---

## 五、诉求

1. **确认根因**：ACK 创建该集群时，为何未在自动创建的控制面安全组 `sg-5tsaatp5w68vyqszezja` 中放行 TCP 6443（入方向仅有 ICMP）？
2. **修正产品侧**：请核查 ap-southeast-6 及**其他地域**是否存在同类缺陷，并修复建集群流程/模板，确保控制面安全组默认放行节点与 Pod 网段访问 6443。
   **这对我方影响直接**：我方后续还需在新加坡 `ap-southeast-1` 建同构集群，若缺陷普遍存在会再次踩坑。
3. **安全组归属确认**：我方临时补的规则是否会被 ACK 侧运维/控制器重置？若会，请提供官方推荐的持久化做法（例如由 ACK 统一维护该规则）。
4. 请评估**是否需要对受影响集群做任何额外检查**（例如控制面健康、SLB 后端配置、PrivateZone 记录一致性）。

---

## 六、临时规避说明（供参考，非诉求）

我方已按 §3.6 补上安全组规则，并重跑节点初始化，**集群当前已完全可用**（4/4 Ready，业务可调度）。
本次修复未修改 DNS、未修改 EndpointSlice、未做任何 hosts 覆盖 —— 因为事实证明这两处登记值本来就是正确的。
如贵方修复后该规则由 ACK 托管，我方可撤下自建规则。
