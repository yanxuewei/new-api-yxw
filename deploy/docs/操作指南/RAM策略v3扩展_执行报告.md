# RAM 策略 v3 扩展 + ACK 集群 RBAC 核验 · 执行报告

> 日期：2026-10-10 · 账号 `5108890064395960` · 执行者：墨（AI）· 授权：fanyan
> 触发：用户反馈 RAM 用户 **`daimingming`**（UserId `218577891456544282`）① 控制台看不到
> **SSL 数字证书 / Tair 数据库（兼容 Redis）**；② ACK「无状态应用」报
> `APISERVER.403 deployments.apps is forbidden`。

---

## 一、诊断：这是**两套互不相通**的授权体系

| 体系 | 管什么 | 报错长相 |
|---|---|---|
| **RAM 策略** | 能不能调阿里云 OpenAPI（Tair/证书/ACK 控制台的 API 面） | 控制台显示「无权限查看」 |
| **K8s RBAC** | K8s 里能不能 list/get/update 资源（deployments/pods…） | `APISERVER.403 … is forbidden: User "<uid>" cannot list resource "deployments"` |

两个症状分别对应两套体系，必须**分别**处理。用户截图里「ack 无状态应用」是 RBAC，「ssl 数字证书 / Tair」是 RAM。

### 关键事实（实测）

- `daimingming` 在用户组 **`ops-prod_group`**（`g-B4IOgVKh1TVnRDWM`），**用户级无任何直接挂载策略** ⇒ 权限全部经组继承。
- `ops-prod_group` 挂 3 条自定义策略：`newapi-ops-operator` + `newapi-enforce-mfa` + `newapi-audit-protect`。
- 原 `newapi-ops-operator`（v2，2026-09-25 控制台创建，**正文无 IaC**）的 Allow 里**既没有 `kvstore:*` 也没有 `yundun-cert:*`**。
- ACK 侧 `DescribeUserPermission` 实测：**17:21 时仅 SG 集群一条 `ops`**；**17:24:59 被改为 3 个集群全部 `admin`**（用户自行在控制台操作）⇒ 403 已解除。

---

## 二、改动 1｜RAM 策略 `newapi-ops-operator` → **v3**（已发布并设为默认）

### 新增 Allow（11 条前缀）

| 前缀 | 服务 | 对应截图症状 |
|---|---|---|
| `kvstore:*` | 云数据库 Tair（兼容 Redis） | ✅ Tair 数据库 |
| `hdm:*` | DAS 数据库自治服务（Tair 控制台依赖） | ✅ 同上 |
| `yundun-cert:*` | 数字证书管理服务（原 SSL 证书） | ✅ ssl 数字证书 |
| `arms:*` | 应用实时监控 ARMS + **Grafana 工作区** | 任务 26 闭环组件 |
| `clickhouse:*` | 云数据库 ClickHouse 企业版（日志库 CK） | 项目自用 |
| `quotas:*` | 配额中心 | 控制台公共页 |
| `resourcemanager:Get*` / `List*` | 资源管理（资源组只读） | 控制台公共页 |
| `ram:GetResourceGroup*` / `ListResourceGroup*` / `ListAssociatedTransferSetting` / `LookupResourceGroupEvents` | 资源组只读（官方示例口径） | 同上 |
| `tag:Get*` / `List*` / `Describe*` | 标签服务只读 | 同上 |
| `*:ListTagResources` / `*:DescribeTags` / `*:DescribeTagKeys` / `*:ListTagKeys` / `*:ListTagValues` | 跨服务标签只读（取 `AliyunTAGReadOnlyAccess` 口径） | 同上 |

> 前缀**逐个在系统策略里核准**（不是凭记忆写）：`AliyunKvstoreFullAccess→kvstore:*`、`AliyunHDMFullAccess→hdm:*`、
> `AliyunYundunCertFullAccess→yundun-cert:*`、`AliyunClickHouseFullAccess→clickhouse:*`、
> `AliyunQuotasFullAccess→quotas:*`、`AliyunTAGReadOnlyAccess→tag:* + *:ListTagResources…`；
> 资源组口径取自官方文档《RAM用户使用资源组》的「资源组只读权限」示例。
> 另核实：**证书服务只有一个前缀 `yundun-cert`**，不存在 `cas:` / `ssl:` 独立策略（避免写错前缀静默失效）。

### 新增 Deny（1 条）

| 动作 | 理由 |
|---|---|
| `kvstore:DeleteInstance` | 与既有 `rds:DeleteDBInstance` / `ecs:DeleteInstance` **同口径**；本组设计注记即「生产可写不可销毁」。Tair 是有状态生产实例，误删不可逆 |

> 该 Deny 为**本次唯一"收紧"项**，超出用户原始请求。理由是与策略既有的销毁保护一致；
> **如需放开**：`bash deploy/ops/ram_ops_operator_extend.sh rollback` 回退 v2，或从 JSON 删除该行后重新 apply。
> 未对 `yundun-cert` / `clickhouse` 加 Deny（证书轮换需要删除旧证书；CK 为日志数据、已有 90 天 TTL）。

### 发布记录

| 项 | 值 |
|---|---|
| 新版本 | **v3**（`CreateDate 2026-10-10T09:29:09Z`）· 已 `SetAsDefault=true` |
| AttachmentCount | **3**（挂给 `ops_group` / `dev_group` / `ops-prod_group`） |
| 描述 | 已同步更新（`UpdatePolicyDescription`）为 v3 口径 |
| 生效链路 | `daimingming` → 组 `ops-prod_group` → `newapi-ops-operator` **DefaultVersion=v3** ✅ |
| 复核 | `VERIFY=PASS`（11 条新 Allow 全在位 + 7 条原有动作未丢） |

---

## 三、改动 2｜ACK 集群 RBAC（**未改动，已由用户自行完成**）

### 实测时间线

| 时刻 | `DescribeUserPermission(daimingming)` |
|---|---|
| 17:21 | `[SG cluster → ops]` 仅 1 条 |
| **17:24:59** | `[SG→admin, MNL→admin, cb0abf5b…→admin]` **3 条，全 admin** |

⇒ 用户已自行在控制台把授权补齐，**403 应已解除**。因此**未执行任何 RBAC 写入**（避免把 admin 降权）。

### 三个集群

| cluster_id | region | 说明 |
|---|---|---|
| `cd57e40ce9a634c1698c2f5c5e09bd93c` | ap-southeast-6 | **马尼拉主站** |
| `ca75829e3492d491d9d434de087913798` | ap-southeast-1 | **新加坡备站** |
| `cb0abf5bc06034f7bbdb991752f6f3e62` | ap-southeast-6 | 另一 ack.standard 集群（2026-09-30 建，私网端点 `10.2.25.173:6443`） |

### ★ 两条 API 语义坑（已固化进脚本护栏）

1. **`cs GrantPermissions` 是全量覆盖**（"overwrites all existing cluster permissions"）⇒ body 里必须列出该用户要保留的**全部**集群，否则会把其它集群的授权一起抹掉。
   本脚本 `apply` 因此改为 **「读现状 → 原样保留所有集群 → 只改角色」**。
2. **防降权护栏**：若目标角色低于现状（如把 `admin` 改 `ops`），`apply` **直接拒绝**，必须显式 `ALLOW_DOWNGRADE=1`。
   本次正是这条护栏挡住了「把 admin 降成 ops」的误操作。
3. 请求体字段按官方文档：`{cluster, role_name(预置角色名), role_type(cluster|namespace|all-clusters), namespace?, is_custom, is_ram_role}`；
   而**响应**里预置角色名落在 `role_type`、`role_name` 为空 —— 请求/响应字段名不一致，勿互相套用。

---

## 四、IaC（新增，本报告对应的可复现资产）

| 文件 | 作用 |
|---|---|
| `deploy/ops/ram_policy_newapi-ops-operator.v3.json` | **策略正文唯一真源**（此前只存在于控制台，不可追溯） |
| `deploy/ops/ram_ops_operator_extend.sh` | `check / apply / verify / desc / rollback`（幂等；apply 含发布+复核+描述同步；rollback 回退 v2） |
| `deploy/ops/ack_rbac_grant.sh` | `check / apply / verify`（读现状→保留全部集群→改角色；含防降权护栏） |

```bash
# 只读核验
bash deploy/ops/ram_ops_operator_extend.sh check
bash deploy/ops/ack_rbac_grant.sh check

# 回滚
bash deploy/ops/ram_ops_operator_extend.sh rollback   # 默认版本回退 v2
```

---

## 五、遗留与建议

1. **策略版本上限 5**：现有 v1/v2/v3，还有 2 个额度；后续再改建议先清理历史版本。
2. **`newapi-ops-operator` Description 与指南配图的旧串已不一致**：`deploy/ops/gen_guide_images.py` 里仍写着 v2 口径的
   "VPC/ECS/ACK/RDS/SLB/WAF/DNS describe + deploy write…"，且版本号写死 "3"。**下次重生成配图前需同步**。
3. **`enforce-mfa` 生效面**：该策略对**未过 MFA 的控制台会话**全 Deny（AK 调用不判定）——本次新增的服务族同样受此约束，属预期。
4. **未加 Deny 的服务**：`clickhouse:*` 含 `DeleteDBInstance` 未拦；`yundun-cert:*` 含删证书未拦（轮换需要）。如需与 RDS/Tair 同等保护，在 JSON Deny 段追加即可。
5. **ACK 侧无 IaC 基线**：本次 3 条 admin 授权是控制台手工产物，未留 API 痕迹。已提供 `ack_rbac_grant.sh` 作为后续 IaC 通道，建议后续变更改走脚本以便追溯。
