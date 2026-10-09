# ACK 集群台账 · 马尼拉 / 新加坡

> 任务 10（马尼拉）/ 后续任务 24（新加坡）的唯一真源。
> 证据目录：`deploy/logs/task10_<ts>/`（原始 JSON 全部留存）
> 配套脚本：`deploy/task10/ack_mnl.sh`（幂等，`--dry-run`）

---

## 1. 马尼拉主集群（任务 10 · 2026-09-29 落地）

| 项 | 值 |
|---|---|
| **cluster_id** | **`cd57e40ce9a634c1698c2f5c5e09bd93c`** |
| 名称 | `ack-newapi-mnl` |
| 规格 | `ack.pro.small`（ACK Pro 小规格） |
| cluster_type / profile | `ManagedKubernetes` / `Default` |
| 区域 | `ap-southeast-6`（马尼拉） |
| **资源组** | **`rg-aek4nyivmmsb6iy`（rg-ph-mnl）** ✅ |
| K8s 版本 | `1.35.7-aliyun.1` |
| VPC | `vpc-5tst1tgeessxn1azwasg2` |
| 节点 vSwitch | app-a `vsw-5tswpyzfa8od6je95td1h`(6a) · app-b `vsw-5tshuvvtrqm97tnwe1ddm`(6b) |
| Pod vSwitch（Terway） | 同节点 vSwitch（`ENITrunking=false`，Shared ENI 高密度模式） |
| Service CIDR | `172.21.0.0/20` |
| CNI | `terway-eniip` v1.17.7 |
| ProxyMode | `ipvs` |
| Runtime / 镜像 | `containerd` 2.3.4 / `AliyunLinux3ContainerOptimized` |
| IPStack | `ipv4` |
| 时区 | `Asia/Manila` |
| SNAT | **关**（`snat_entry=false`，出口走任务 6 的 NAT） |
| 公网端点 | **关**（`endpoint_public_access=false`，`PublicSLB=false`） |
| 私网端点 | `https://10.0.22.182:6443` |
| 删除保护 | **开** |
| 自动升级 | `channel=stable, enabled=true` |
| 维护窗口 | 周二 `03:00–06:00`（Asia/Manila，业务低峰） |
| 创建耗时 | **3 分 39 秒**（11:53:38 → 11:57:01） |

### 1.1 RRSA / OIDC（**任务 17 直接取用**）

```json
{
  "enabled": true,
  "audience": "https://kubernetes.default.svc",
  "oidc_arn":  "acs:ram::5108890064395960:oidc-provider/ack-rrsa-cd57e40ce9a634c1698c2f5c5e09bd93c",
  "oidc_name": "ack-rrsa-cd57e40ce9a634c1698c2f5c5e09bd93c",
  "issuer":    "https://oidc-ack-ap-southeast-6.oss-ap-southeast-6.aliyuncs.com/cd57e40ce9a634c1698c2f5c5e09bd93c,https://kubernetes.default.svc",
  "jwks_url":  "https://oidc-ack-ap-southeast-6.oss-ap-southeast-6.aliyuncs.com/cd57e40ce9a634c1698c2f5c5e09bd93c/keys",
  "open_api_configuration_url": "https://oidc-ack-ap-southeast-6.oss-ap-southeast-6.aliyuncs.com/cd57e40ce9a634c1698c2f5c5e09bd93c/.well-known/openid-configuration"
}
```

> ⚠️ **region 级资源**：新加坡集群（任务 24）必须另建一套 OIDC Provider，马尼拉的 `issuer` 在 `ap-southeast-1` **读不到**。M4 演练最常见失败点。

### 1.2 集群自动创建的依赖资源（**全部继承集群 RG**）

| 类型 | ID | 名称 | 资源组 |
|---|---|---|---|
| 集群安全组 | `sg-5tsaatp5w68vyqszezja` | `alicloud-cs-auto-created-security-group-cd57e…` | `rg-aek4nyivmmsb6iy` ✅ |
| 内网 SLB（APIServer） | `lb-5ts6qwxumktojy2qs3omu` | `ManagedK8SSlbIntranet-cd57e…` | `rg-aek4nyivmmsb6iy` ✅ |
| SLS 审计项目 | `k8s-log-cd57e40ce9a634c1698c2f5c5e09bd93c` | — | `rg-aek4nyivmmsb6iy` ✅ |

> **设计口径**：集群安全组是 ACK 托管控制面自用，**不是节点安全组**；节点池必须显式挂 `sg-5tsil3ca5dfkqefks1g9`（`sg-mnl-app`），否则 ACK 会自建托管组（见 `sg_ledger.md` 坑 2）。集群级 `is_enterprise_security_group` 保持 `false`（本账号无企业级安全组，且 §8.1 全靠组引用授权）。

### 1.3 已装 addon（9 项，全部落位）

`terway-controlplane`(ENITrunking=false) · `terway-eniip` v1.17.7 · `csi-plugin` v1.37.2 · `csi-provisioner` v1.37.2 · `ack-pod-identity-webhook` · `alb-ingress-controller` · `managed-coredns` · `arms-prometheus` · `logtail-ds` v3.3.3.1-aliyun

（另有 ACK 默认附带：`gateway-api` `metrics-server` `coredns` `ack-ram-authenticator` `alicloud-monitor-controller` `storage-operator` `ack-scheduler` 等）

### 1.4 vSwitch IP 基线（Terway 下每 Pod 占真实 VPC IP）

| vSwitch | 区 | 初始 free | 建簇后 free | 消耗 |
|---|---|---|---|---|
| `vsw-mnl-app-a` `vsw-5tswpyzfa8od6je95td1h` | 6a | 4092 | **4090** | 2（控制面 ENI） |
| `vsw-mnl-app-b` `vsw-5tshuvvtrqm97tnwe1ddm` | 6b | 4092 | **4091** | 1 |

> 告警线：**低于 200 → P2**。每里程碑复核，脚本 `--verify` 已带。

---

## 2. 终验结果（28/28 PASS · 2026-09-29）

```
1. 集群核心参数  11/11 PASS   state/cluster_type/spec/profile/version/proxy_mode/timezone/
                              deletion_protection/resource_group_id/vpc_id/rrsa.enabled
2. 网络形态       7/7  PASS   terway-eniip · ipvs · PublicSLB=false · 172.21.0.0/20 ·
                              containerd · AliyunLinux3ContainerOptimized · ipv4
3. 端点           1/1  PASS   公网端点为空（未开）✓
4. addon 落位     9/9  PASS   9 项全部存在
5. 依赖资源 RG      —         SLB / 安全组 / SLS 三项均 rg-aek4nyivmmsb6iy ✓
6. 幂等            —         同名集群=1，无重复
7. IP 基线         —         app-a 4090 / app-b 4091
```

**未完成项（等前置条件）**：

| 项 | 原因 | 何时做 |
|---|---|---|
| `kubectl get ns`、`api-versions \| grep network.alibabacloud.com` | 私网端点，需 **VPC 内**执行 | 任务 46（堡垒机）就绪后 |
| kubeconfig 拉取（`--TemporaryDurationMinutes 60`） | 同上 | 任务 46 |
| 8 EIP 出口复验 / Tair 连通性 | 需 VPC 内计算节点 | 任务 11 节点池就绪后 |

---

## 3. 本卡两个真实坑（实测，非推测）

### 坑 A｜漏写 `resource_group_id` → 静默落到 default，且**不可迁移**

- **现象**：`CreateCluster` body 未带 `resource_group_id` 时，集群落到 `rg-acfnssmgwnsb5oa`（**default**），无任何报错。
- **后果**：违反项目铁律「默认组禁放 new-api 资源」；而且 ACK **不支持资源组迁移** ——
  `resourcemanager MoveResources` 对 ACK 集群返回 **`UnsupportedOperation.MoveResources`**（`Service=cs|ack`、`ResourceType=cluster|Cluster` 四种组合均拒）。
- **唯一解法 = 删除重建**（须先 `ModifyCluster --body '{"deletion_protection":false}'` 关保护，`DeleteCluster` 后重建）。
- **本次实况**：首建集群 `ca9dc32abd3324134844b9be5bc26a139` 落 default → 删除（3 min）→ 重建 `cd57e40c…` 带 RG（3 min 39 s）。**因集群当时为空（节点池 0、无工作负载），重建零成本**；若已建节点池/工作负载，代价完全不同。
- **改进（已落地）**：① 脚本 body 显式写死 `"resource_group_id": "$RESOURCE_GROUP_ID"`（默认 `rg-aek4nyivmmsb6iy`，可 `RESOURCE_GROUP_ID=` 覆盖）；② 终验加**资源组断言**，不符即 `exit 1`。

### 坑 B｜「删了集群就干净了」是错的

- ACK 自建的 **内网 SLB / 集群安全组 / SLS 审计项目** 是独立资源。
  - **重建路径**：它们随新集群创建，自动继承**集群的资源组** → 三项全部落 `rg-ph-mnl` ✅（正确路径）
  - **迁移路径**（不可行，仅作反证）：即便迁移成功，这三项也会**留在 default**，形成半拉子状态
- 另：`DeleteCluster` **不会删掉** SLS 项目 `k8s-log-<old-id>`，实测删除集群后该项目残留在 default RG，须手工 `aliyun sls DeleteProject --project <name> --region <r>`（本次已清理）。

### 坑 C｜SLA 口径：「regional / zonal」是**地域属性**，不是建簇选项

阿里云 ACK SLA（版本生效日期 **2023-04-01**）原文：

> **1.4 区域级集群（regional cluster）**：ACK Pro 集群所在区域（Region）的可用区（AZ）数量为 **3 个及以上**。
> **1.5 可用区级集群（zonal cluster）**：ACK Pro 集群所在区域（Region）的可用区（AZ）数量为 **2 个及以下**。
> **2.2 服务可用性承诺**：区域级集群 **99.95%**；可用区级集群 **99.50%**。

- **马尼拉 `ap-southeast-6` 只有 6a / 6b 两个 AZ** → 本集群在 SLA 定义上**就是 zonal**，控制面承诺 **99.50%**（月不可用上限 ≈ **3.6 h**），**无法通过任何建簇选项提升**。
- 指南 `-v2.0.md` / `.md` / `-ch.md` / `wf2/part2a.md` 原表述「选 regional 多可用区控制面可得 99.95%，否则 8.2 推导链从根上错」**双重错误**：① 选不了；② ACK 控制面**不在** §8.2 的五项串联链（`0.9999^5`）内，8.2 推导**不受影响**。已由 `deploy/patch_ack_task10.py` 更正。
- **实际影响与对冲**：控制面不可用**不影响已运行 Pod**（数据面继续服务），但**部署 / 扩缩容 / HPA 扩节点会停摆**。对冲：冻结期内不依赖临时扩缩容；弹性余量预留（常态 4+2 节点已含）。

---

## 4. CLI 口径速查（本卡踩过的）

| 坑 | 正解 |
|---|---|
| `DescribeKubernetesVersionMetadata` 用 `--RegionId` → `MissingRegion` | 参数是 **`--Region`**（无 Id） |
| 版本字段取 `.kubernetes_version` → 全 null | 实际字段是 **`.version`**；`--Mode creatable` 查可建版本 |
| `OpenAckService` 报 `RISK.RISK_CONTROL_REJECTION` | 账号级风控（余额 0.00 USD 相关）；**已开通后**重跑返回 `ORDER.OPEND`（幂等成功态） |
| `resourcemanager` 在 `ap-southeast-6` 报 `unknown endpoint` | 必须 **`--region ap-southeast-1`** |
| `MoveResources` 报 `Illegal parameter serialization format` | 要 **flat 格式** `--Resources.1.Service/ResourceType/ResourceId/RegionId` + `--method POST` |
| `ModifyCluster` 关删除保护 / 配自动升级 | `--body '{"deletion_protection":false}'`；`operation_policy.cluster_auto_upgrade` + `maintenance_window` 均可用 body 设（**无需控制台**） |
| ACK 自动创建的 SLB 找不到 | 是 **SLB（CLB）不是 ALB**：`aliyun slb DescribeLoadBalancers`，名为 `ManagedK8SSlbIntranet-<cluster_id>` |

---

## 5. 待办

- [ ] 任务 11 建节点池时把 `sg-5tsil3ca5dfkqefks1g9` 填进 `scaling_group.security_group_ids`（集群级 `is_enterprise_security_group` 保持 `false`）
- [ ] 任务 17 取用 §1.1 的 `oidc_arn` / `issuer` 建 RAM OIDC Provider 与角色信任策略
- [ ] 任务 24 建新加坡集群时**同样带 `resource_group_id`**（`rg-aek4zvb3ldoiyua`），并另建一套 OIDC
