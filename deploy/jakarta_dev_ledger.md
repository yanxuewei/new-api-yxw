# 雅加达 dev 环境台账（newapi-dev / 方案 A）

> 建台账口径与 `eip_ledger.md`、`nodepool_ledger_sg.md` 一致：只记录**实测回读值**，不记录计划值。
> 依据 `任务45环境隔离修订_2026-09-29.md` §5.3 / §7。执行时间 2026-09-30（UTC+0），操作身份 `ram-user yanxuewei`，账号 `5108890064395960`，全程 WSL Ubuntu。

## 1. Phase 1 —— 零成本网络层（已建成，实测回读）

| 资源 | ID | 实测值 | 归属 |
|---|---|---|---|
| VPC | `vpc-k1ano67avx98nr3n1bg5d` | `vpc-jkt-dev` / **10.2.0.0/16** / Available | `rg-nonprod` (`rg-aek4hk3prqgqjcy`) |
| vSwitch 5a | `vsw-k1aaxl1aqbc42ac7yb7ms` | `vsw-jkt-dev-app-5a` / 10.2.0.0/20 / ap-southeast-5a | 同上 |
| vSwitch 5b | `vsw-k1a1ogs29dvgvqethz27g` | `vsw-jkt-dev-app-5b` / 10.2.16.0/20 / ap-southeast-5b | 同上 |
| vSwitch 5c | `vsw-k1aj6eby0v5lpwrswov45` | `vsw-jkt-dev-app-5c` / 10.2.32.0/20 / ap-southeast-5c | 同上 |
| 安全组 | `sg-k1ag5j7s6xbuyjkv3j8c` | `sg-jkt-dev-app` / type=normal | 同上 |

标签（成本归口，任务 52）：`env=dev` `project=new-api` `managed-by=provision_jakarta_dev_net.sh` `isolation=structural-vpc`

脚本：`deploy/provision_jakarta_dev_net.sh`（幂等，已跑 4 轮验证可重复执行）

### 1.1 出方向规则（deny 优先于 accept，这是"不能互通"的第二层保险）

```
prio= 1 drop   ALL  -1/-1      10.0.0.0/16    ← 马尼拉生产 VPC
prio= 1 drop   ALL  -1/-1      10.1.0.0/16    ← 新加坡生产 VPC
prio= 1 drop   TCP  5432/5432  43.118.96.65/32 ← 生产 RDS **公网**端点（VPC 边界管不到的那条路）
prio=10 accept TCP  443/443    0.0.0.0/0      ← 拉马尼拉 EE 公网端点 / 上游
prio=10 accept UDP  53/53      100.100.2.136/32, .138/32
prio=20 accept UDP  53/53      0.0.0.0/0
```

### 1.2 隔离不变量复核（必须恒为 0）

```
aliyun cbn DescribeCens --region ap-southeast-1 | jq '.Cens.Cen|length'   -> 0
aliyun vpcpeer ListVpcPeerConnections --region ap-southeast-5 | jq .TotalCount -> 0
aliyun rds DescribeDBInstanceIPArrayList --DBInstanceId pgm-5tstdhko64x2c01w  -> 不含 10.2.*（见 §3）
```

## 2. 计费层前置实测（**尚未创建任何计费资源**）

| 项 | 实测 | 结论 |
|---|---|---|
| 雅加达可用区 | `ap-southeast-5a / 5b / 5c` | 三区均可用 |
| 企业级 vCPU 配额（postpay） | **total=512 / used=0** | ⚠ **更正**：修订文档 E7 记的「50」有误，实际 512，dev 落雅加达配额完全不构成约束 |
| `ecs.g9i.large` + 40G ESSD 包月 | **66.41 USD/月**（Original=Trade，USD） | 与文档 §6 一致 |
| RDS PG **17.0** `pg.n2.2c.1m` / 20G essd | **43.38 USD/月**（`OrderLines.0.depreciateInfo.listPrice`） | 与 PG 15 同价；5b/5c 在售（`DescribeAvailableClasses` 含该类） |
| RDS 创建预检 | `CreateDBInstance --DryRun=true` → **`DryRunResult: true`** | 权限、库存、网段、白名单参数全部可用；白名单填 `10.2.0.0/20,10.2.16.0/20,10.2.32.0/20` |
| NAT 网关 / EIP 单价 | `GetPayAsYouGoPrice`/`DescribePricingModule` → 空；`AllocateEipAddress --estimate-cost` → `no OpenAPI quotable` | **CLI 无法报价**，需控制台核实；不在本次可省项 |
| 账户余额 | `QueryAccountBalance` → **`AvailableAmount = 0.00 USD`** | 🔴 **硬阻塞**，见 §4 |

## 3. 生产侧未被触碰（写操作后的回归确认）

- 生产 RDS `pgm-5tstdhko64x2c01w` 白名单：**未做任何修改**（本次无写操作）
- 生产 ACR EE `cri-avfqy9xkqi5bj8ee`：ACL **未收口**（仍是 `0.0.0.0/1` + `128.0.0.0/1`）—— 属已知待修安全缺陷，需单独授权
- 马尼拉 / 新加坡 VPC、集群、节点池：零改动

## 4. 待你核准后才继续（Phase 2，全是计费项）

```
2a  dev 专用 NAT 网关 + 独立 EIP         单价 CLI 报不出，需确认
2c  ACK dev 集群（基础版）+ 节点池        min=1 g9i.large = 66.41/月  + max=3
2b  RDS PG 17.0 pg.n2.2c.1m 20G          43.38/月（已 DryRun 通过）
2d  newapi-dev 工作负载 + 三库冒烟        复用 2a/2b/2c
3   隔离验收 V1-V11 实测 + 本台账收口      免费
```

稳态合计 **≈110 USD/月 + NAT/EIP**（按 §5.4 决策 D4=`min=1`）。

两个必须先回答的问题：

1. **余额 0.00 USD**：任务 10 曾出现 `OpenAckService → RISK.RISK_CONTROL_REJECTION`，当时与"余额 0.00"高度相关；`eip_ledger.md` 坑 2 记过「欠费 → EIP 被回收重分配 → 白名单静默失效」。若结算口径/宽限期没确认就开按量资源，最坏情况是**建一半被风控拦**，留下半成品资源和一笔已发生费用。
2. **是否授权这笔月度支出**（以及 `min=1` 还是 `min=0`）。

## 5. 回滚（本台账对应的零成本层，随时可撤销）

```bash
aliyun ecs DeleteSecurityGroup --region ap-southeast-5 --SecurityGroupId sg-k1ag5j7s6xbuyjkv3j8c
for V in vsw-k1aj6eby0v5lpwrswov45 vsw-k1a1ogs29dvgvqethz27g vsw-k1aaxl1aqbc42ac7yb7ms; do
  aliyun vpc DeleteVSwitch --region ap-southeast-5 --VSwitchId $V; done
aliyun vpc DeleteVpc --region ap-southeast-5 --VpcId vpc-k1ano67avx98nr3n1bg5d
```

## 6. 已同步到方案表（2026-09-30）

`菲律宾部署方案-v2.3-修订版.xlsx` → sheet **「网络与安全规划」** 已写入 Phase 1 实测值（下表行号与命名均为重命名后的口径）。既有行的文字、单元格样式、列宽均未改写；因为插入行，原有行号与各段落横幅的合并区**整体下移**（A16:F16→A20:F20、A22:F22→A27:F27、A36:F36→A47:F47、A44:F44→A55:F55），`dimension` 由 A1:F44 扩为 A1:F56。改前快照：`菲律宾部署方案-v2.3-修订版.xlsx.bak-20260930`；校验：包内 23 个 part 仅 `xl/worksheets/sheet5.xml` 变化，全部 XML 可解析，mergeCell 由 5 个变为 6 个，52 行行号唯一且有序。

| 落点 | 行 | 内容 |
|---|---|---|
| 网络规划段（马尼拉/新加坡之后） | **R16–R19** | 雅加达 dev VPC `10.2.0.0/16` + 三个 vSwitch（10.2.0.0/20 5a、10.2.16.0/20 5b、10.2.32.0/20 5c），备注带真实资源 ID 与「Terway 下 Pod IP 即 VPC 地址」口径 |
| EIP 规划段（生产 8 EIP 之后） | **R25** | dev 自有 NAT+EIP，数量记「1（待核准）」，备注明确**禁止并入生产上游/RDS 白名单池** |
| 安全组规则段（马尼拉/新加坡之后） | **R40–R45** | `sg-jkt-dev-app` 出向：drop 10.0.0.0/16、drop 10.1.0.0/16、drop TCP 5432 → 43.118.96.65/32（均优先级 1）+ accept 443 + accept UDP 53；入向「无自定义规则」并记生产侧未被触碰 |
| 表尾说明（新增一行） | **R56** | 结构性隔离口径（无 CEN / 无 VPC 对等连接，实测均为 0）、namespace 只是 RBAC 边界、Phase 2 未创建清单、RDS DryRun 已过 |

## 7. 命名对齐马尼拉（2026-09-30，纯元数据、零成本、可回滚）

规则：去掉 `newapi-` 段，站点码后接 `-dev`，角色位沿用马尼拉词表（`pub` / `app` / `data`）。资源 ID、CIDR、可用区、安全组规则均未变动，只改 `*Name` 属性。

| 资源 | ID（不变） | 旧名 | 新名 |
|---|---|---|---|
| VPC | `vpc-k1ano67avx98nr3n1bg5d` | `vpc-newapi-jkt-dev` | `vpc-jkt-dev` |
| vSwitch 5a | `vsw-k1aaxl1aqbc42ac7yb7ms` | `vsw-newapi-jkt-dev-node-5a` | `vsw-jkt-dev-app-5a` |
| vSwitch 5b | `vsw-k1a1ogs29dvgvqethz27g` | `vsw-newapi-jkt-dev-node-5b` | `vsw-jkt-dev-app-5b` |
| vSwitch 5c | `vsw-k1aj6eby0v5lpwrswov45` | `vsw-newapi-jkt-dev-pod-5c` | `vsw-jkt-dev-app-5c` |
| 安全组 | `sg-k1ag5j7s6xbuyjkv3j8c` | `sg-newapi-jkt-dev` | `sg-jkt-dev-app` |

两处判断（可随时改，重命名命令见下）：
1. **三段子网统一用 `app`**：马尼拉的 `vsw-mnl-app-a/b` 在表里的用途正是「ACK Pod 私有子网」，`data` 专指 RDS/Tair/ClickHouse，`pub` 专指 ALB 公网子网。dev 这三段都服务 ACK（节点 + Pod），因此 5c 由 `pod` 归到 `app`，而不是新建 `pod` 角色词。
2. **安全组带角色后缀 `app`**：马尼拉/新加坡的 SG 全部是 `sg-<site>-<role>`（`sg-mnl-alb` / `sg-mnl-app` / `sg-mnl-db` / `sg-sg-app`），裸 `sg-jkt-dev` 会破坏该形态；若你更想要短名，执行下面的命令改回即可。

```bash
R=ap-southeast-5
aliyun vpc ModifyVpcAttribute --region $R --VpcId vpc-k1ano67avx98nr3n1bg5d --VpcName vpc-jkt-dev
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1aaxl1aqbc42ac7yb7ms --VSwitchName vsw-jkt-dev-app-5a
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1a1ogs29dvgvqethz27g --VSwitchName vsw-jkt-dev-app-5b
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1aj6eby0v5lpwrswov45 --VSwitchName vsw-jkt-dev-app-5c
aliyun ecs ModifySecurityGroupAttribute --region $R --SecurityGroupId sg-k1ag5j7s6xbuyjkv3j8c --SecurityGroupName sg-jkt-dev-app
```

回读校验（已实测通过）：`DescribeVpcs` / `DescribeVSwitches` / `DescribeSecurityGroups` 均返回新名，VPC 与三段 vSwitch 状态 `Available`，SG 仍为 `normal` 类型、出向 6 条规则不变。

方案表落点：**`菲律宾部署方案-v2.3-修订版.xlsx`** sheet「网络与安全规划」共改 11 处名称文本（D16–D19 四行、B40–B45 六行、R56 说明一行），资源 ID / CIDR / 行号 / 合并区 / 样式均未变；包内 23 个 part 仅 `xl/worksheets/sheet5.xml` 变化。写入时该文件曾被 Excel 打开（`~$` 锁文件导致覆盖被拒），先另存临时版本，锁释放后已同步回 v2.3 原文件名，临时副本已删除。校验：`newapi-jkt-dev` 出现 0 次，52 行、6 个合并区保持不变。改前快照仍为 `菲律宾部署方案-v2.3-修订版.xlsx.bak-20260930`（Phase 1 写入前的原始态）。

