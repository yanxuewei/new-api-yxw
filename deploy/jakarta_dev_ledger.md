# 雅加达 dev 环境台账（newapi-dev / 方案 A）

> 建台账口径与 `eip_ledger.md`、`nodepool_ledger_sg.md` 一致：只记录**实测回读值**，不记录计划值。
> 依据 `deploy/docs/任务45环境隔离修订_2026-09-29.md` §5.3 / §7。执行时间 2026-09-30（UTC+0），操作身份 `ram-user yanxuewei`，账号 `5108890064395960`，全程 WSL Ubuntu。

## 1. Phase 1 —— 零成本网络层（已建成，实测回读）

| 资源 | ID | 实测值 | 归属 |
|---|---|---|---|
| VPC | `vpc-k1ano67avx98nr3n1bg5d` | **`vpc-newapi-jkt-dev`** / 10.2.0.0/16 / Available | `rg-nonprod` (`rg-aek4hk3prqgqjcy`) |
| vSwitch pub 5a | `vsw-k1at4vt7fg8v4umkh9lg3` | `vsw-jkt-dev-pub-5a` / 10.2.0.0/24 / ap-southeast-5a / 可用 252 | 同上 |
| vSwitch pub 5b | `vsw-k1aqa1ose29nuq92hcvyt` | `vsw-jkt-dev-pub-5b` / 10.2.1.0/24 / ap-southeast-5b / 可用 252 | 同上 |
| vSwitch app 5a | `vsw-k1agmhxtf974bmzbjlnkp` | `vsw-jkt-dev-app-5a` / 10.2.16.0/20 / ap-southeast-5a / 可用 4092 | 同上 |
| vSwitch app 5b | `vsw-k1aoupd0er378rku728d3` | `vsw-jkt-dev-app-5b` / 10.2.32.0/20 / ap-southeast-5b / 可用 4092 | 同上 |
| vSwitch data 5a | `vsw-k1a9u8pkwwkc6z0x6g0kc` | `vsw-jkt-dev-data-5a` / 10.2.48.0/20 / ap-southeast-5a / 可用 4092 | 同上 |
| vSwitch data 5b | `vsw-k1auat3gn6iagfg7by4sz` | `vsw-jkt-dev-data-5b` / 10.2.64.0/20 / ap-southeast-5b / 可用 4092 | 同上 |
| vSwitch app 5c | `vsw-k1an7x32b5qjtsmklelkt` | `vsw-jkt-dev-app-5c` / 10.2.80.0/20 / ap-southeast-5c / 可用 4092 | 同上 |
| 安全组 | `sg-k1ag5j7s6xbuyjkv3j8c` | `sg-jkt-dev-app` / type=normal | 同上 |

> ⚠ 本表已在 2026-09-30 的「删 7 建 7」偏移对齐后整体刷新（见 §10）。**七段 vSwitch 的 ID 全部是新的**，任何仍引用 `vsw-k1aaxl1a…` / `vsw-k1a1ogs2…` / `vsw-k1aj6eby…` / `vsw-k1asfd46…` / `vsw-k1ax18mz…` / `vsw-k1acp8av…` / `vsw-k1adi3av…` 的旧命令、旧脚本、旧工单一律作废。VPC 与安全组 ID 未变。

> 资源组口径修正：`vpc MoveResourceGroup` 的 `ResourceType` 只支持 `Vpc / Eip / BandwidthPackage / PrefixList / PublicIpAddressPool`，**不含 VSwitch**（实测 `IllegalParam.ResourceType`）。表中 vSwitch 的 `ResourceGroupId` 由 `DescribeVSwitches` 回读为 `rg-aek4hk3prqgqjcy`，是随所属 VPC 归属显示；标签则确已逐段写入（`vpc TagResources --ResourceType VSWITCH`，`ListTagResources` 回读 4 个 key 齐全）。成本归口以标签为准，资源组以 VPC 为准。

标签（成本归口，任务 52）：`env=dev` `project=new-api` `managed-by=realign_jakarta_dev_cidrs.sh` `isolation=structural-vpc`（七段均已回读确认；`ecs TagResources --ResourceType VSWITCH` 实测报 `InvalidResourceType.NotFound`，必须走 vpc 侧）

脚本：`deploy/ops/realign_jakarta_dev_cidrs.sh`（对齐已执行完毕，重跑会在占用性守卫处中止）；`deploy/ops/provision_jakarta_dev_net.sh`（幂等，已按新偏移回写，重跑=只读校验+补齐，含 CIDR/AZ 漂移检测）

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
| RDS 创建预检 | `CreateDBInstance --DryRun=true` → **`DryRunResult: true`**（对齐后已用新偏移重跑一次，仍通过） | 权限、库存、网段、白名单参数全部可用；白名单填 `10.2.16.0/20,10.2.32.0/20,10.2.80.0/20`，`--VSwitchId` 用 data-5a `vsw-k1a9u8pkwwkc6z0x6g0kc` |
| NAT 网关 / EIP 单价 | `GetPayAsYouGoPrice`/`DescribePricingModule` → 空；`AllocateEipAddress --estimate-cost` → `no OpenAPI quotable` | **CLI 无法报价**，需控制台核实；不在本次可省项 |
| 账户余额 | `QueryAccountBalance` → **`AvailableAmount = 0.00 USD`** | 🔴 **硬阻塞**，见 §4 |

## 3. 生产侧未被触碰（写操作后的回归确认）

- 生产 RDS `pgm-5tstdhko64x2c01w` 白名单：**未做任何修改**（本次无写操作）
- 生产 ACR EE `cri-avfqy9xkqi5bj8ee`：ACL **未收口**（仍是 `0.0.0.0/1` + `128.0.0.0/1`）—— 属已知待修安全缺陷，需单独授权
- 马尼拉 / 新加坡 VPC、集群、节点池：零改动
- 第二轮回归（§7 重命名 + §8 pub/data 补齐之后实测回读）：马尼拉 `DescribeVpcs`=1、`DescribeSecurityGroups` TotalCount=8 与补齐前一致；`DescribeCens`=0、`ListVpcPeerConnections`=0（雅加达侧），隔离仍是纯结构性的，未因新增 vSwitch 引入任何跨 VPC 通路

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
for V in vsw-k1an7x32b5qjtsmklelkt vsw-k1auat3gn6iagfg7by4sz vsw-k1a9u8pkwwkc6z0x6g0kc \
         vsw-k1aoupd0er378rku728d3 vsw-k1agmhxtf974bmzbjlnkp \
         vsw-k1aqa1ose29nuq92hcvyt vsw-k1at4vt7fg8v4umkh9lg3; do
  aliyun vpc DeleteVSwitch --region ap-southeast-5 --VSwitchId $V; done
aliyun vpc DeleteVpc --region ap-southeast-5 --VpcId vpc-k1ano67avx98nr3n1bg5d
```

删除顺序必须**倒序**（先建的后删），且只在各段可用 IP 仍为满值（252 / 4092）时安全；一旦 ACK 节点池或 RDS 绑定，`DeleteVSwitch` 会直接报 `DependencyViolation`，这层保护不依赖人工记忆。

⚠ **对齐前的那套 CIDR 已不可回滚**：§10 的「删 7 建 7」是单向操作，旧七段的 ID 已销毁。若要恢复到对齐前的布局，只能再执行一轮同规格的删建（把 `deploy/ops/realign_jakarta_dev_cidrs.sh` 里的 `TARGET` 换成旧 CIDR 表），成本仍为零，但会再次改变全部资源 ID —— 届时必须先确认没有任何资源绑定。

只撤销 pub / data 四段（保留 app 三段）：把上面 `for` 循环里的 ID 换成 `vsw-k1at4vt7fg8v4umkh9lg3 vsw-k1aqa1ose29nuq92hcvyt vsw-k1a9u8pkwwkc6z0x6g0kc vsw-k1auat3gn6iagfg7by4sz`；但这会破坏 §10 建立的三站点逐槽同构，不建议。

## 6. 已同步到方案表（2026-09-30）

`菲律宾部署方案-v2.3-修订版.xlsx` → sheet **「网络与安全规划」** 已写入 Phase 1 实测值（下表行号为重命名 + pub/data 补齐 + 新加坡补全 + 偏移对齐后的最终口径）。既有行的文字、单元格样式、列宽未改写；因多次插入行，原有行号与各段横幅合并区整体下移，`dimension` 现为 `A1:F62`。改前快照依次为 `…xlsx.bak-20260930`（首次写入前）、`…xlsx.bak-before-pubdata`、`…xlsx.bak-before-sg`、`…xlsx.bak-before-resync`、`…xlsx.bak-before-realign`；校验：zip 条目现为 22 项（含 4 个目录项，Excel 保存后条目数由 23 归一为 22），本轮仅 `xl/worksheets/sheet5.xml` 变化，全部 XML 可解析，6 个合并区为 A1:F1、A26:F26、A33:F33、A53:F53、A61:F61、A62:F62，58 行行号唯一且有序。

| 落点 | 行 | 内容 |
|---|---|---|
| 网络规划段（雅加达 dev） | **R18–R25** | 雅加达 dev VPC `vpc-newapi-jkt-dev` 10.2.0.0/16 + 七段 vSwitch，行序按 pub → app → data（与马尼拉段一致）：pub 5a/5b（10.2.0.0/24、10.2.1.0/24）、app 5a/5b/5c（10.2.16.0/20、10.2.32.0/20、10.2.80.0/20）、data 5a/5b（10.2.48.0/20、10.2.64.0/20）；F 列逐行写「对齐马尼拉同名槽位 + 偏移对齐重建后的真实 vsw-id」 |
| 新加坡段实测补全 | **R11–R17** | 控制台实测该 VPC 有 6 段，原表缺 `vsw-sg-data-a 10.1.48.0/20`、`vsw-sg-data-b 10.1.64.0/20`，已补录（含真实 ID 与「可用 IP 4092 = 段内零实例」的预留判定）；R12–R15 四行备注也补了真实 ID 与占用数；E11 口径由「不含数据库」改为「数据库段已按偏移预留、未挂实例」 |
| EIP 规划段（生产 8 EIP 之后） | **R31** | dev 自有 NAT+EIP，数量记「1（待核准）」，备注明确**禁止并入生产上游/RDS 白名单池** |
| 安全组规则段（马尼拉/新加坡之后） | **R46–R51** | `sg-jkt-dev-app` 出向：drop 10.0.0.0/16、drop 10.1.0.0/16、drop TCP 5432 → 43.118.96.65/32（均优先级 1）+ accept 443 + accept UDP 53；入向「无自定义规则」并记生产侧未被触碰 |
| 表尾说明（新增一行） | **R62** | 结构性隔离口径（无 CEN / 无 VPC 对等连接，实测均为 0）、namespace 只是 RBAC 边界、Phase 2 未创建清单、RDS DryRun 已过；并已改写为对齐后的白名单三段（10.2.16.0/20、10.2.32.0/20、10.2.80.0/20）与「CIDR 偏移与马尼拉/新加坡逐槽同构」 |

> 2026-09-30 二次同步：项目负责人在 Excel 中打开该表并保存，导致 D18 的 VPC 名回退为旧名、新加坡补录未落盘；已按上表重新写入（改前快照 `…xlsx.bak-before-resync`），并保留其手工调整的行序（pub → app → data）与新增的 `vpc-newapi-mnl-prod` / `vpc-newapi-sg-prod` 生产 VPC 名。Excel 保存会把 inlineStr 单元格转回共享字符串，属正常归一化，不影响内容。
>
> 2026-09-30 三次同步（偏移对齐）：本轮写入前负责人已主动关闭 Excel，`NO_LOCK` 校验通过后一次性改写 17 个单元格（D18/F18、D19–D25 + F19–F25、A62），回读校验「旧 vsw-id 残留 0 处」，改前快照 `…xlsx.bak-before-realign`，文件 64249 字节。

## 7. 命名对齐马尼拉（2026-09-30，纯元数据、零成本、可回滚）

规则：去掉 `newapi-` 段，站点码后接 `-dev`，角色位沿用马尼拉词表（`pub` / `app` / `data`）。资源 ID、CIDR、可用区、安全组规则均未变动，只改 `*Name` 属性。

| 资源 | ID（不变） | 旧名 | 新名 |
|---|---|---|---|
| VPC | `vpc-k1ano67avx98nr3n1bg5d` | `vpc-newapi-jkt-dev` | `vpc-jkt-dev` |
| vSwitch 5a | `vsw-k1aaxl1aqbc42ac7yb7ms` | `vsw-newapi-jkt-dev-node-5a` | `vsw-jkt-dev-app-5a` |
| vSwitch 5b | `vsw-k1a1ogs29dvgvqethz27g` | `vsw-newapi-jkt-dev-node-5b` | `vsw-jkt-dev-app-5b` |
| vSwitch 5c | `vsw-k1aj6eby0v5lpwrswov45` | `vsw-newapi-jkt-dev-pod-5c` | `vsw-jkt-dev-app-5c` |
| 安全组 | `sg-k1ag5j7s6xbuyjkv3j8c` | `sg-newapi-jkt-dev` | `sg-jkt-dev-app` |

> ⚠ 后续修正：上表 VPC 那一行的「新名」`vpc-jkt-dev` 已在 §10 中改回 **`vpc-newapi-jkt-dev`**，因为生产 VPC 实名形态是 `vpc-newapi-<site>-<env>`（负责人 2026-09-30 定口径）。vSwitch / SG 三行仍有效，未被后续操作推翻。

两处判断（可随时改，重命名命令见下）：
1. **三段子网统一用 `app`**：马尼拉的 `vsw-mnl-app-a/b` 在表里的用途正是「ACK Pod 私有子网」，`data` 专指 RDS/Tair/ClickHouse，`pub` 专指 ALB 公网子网。dev 这三段都服务 ACK（节点 + Pod），因此 5c 由 `pod` 归到 `app`，而不是新建 `pod` 角色词。
2. **安全组带角色后缀 `app`**：马尼拉/新加坡的 SG 全部是 `sg-<site>-<role>`（`sg-mnl-alb` / `sg-mnl-app` / `sg-mnl-db` / `sg-sg-app`），裸 `sg-jkt-dev` 会破坏该形态；若你更想要短名，执行下面的命令改回即可。

```bash
R=ap-southeast-5
aliyun vpc ModifyVpcAttribute --region $R --VpcId vpc-k1ano67avx98nr3n1bg5d --VpcName vpc-jkt-dev   # 已再改回 vpc-newapi-jkt-dev，见 §10
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1aaxl1aqbc42ac7yb7ms --VSwitchName vsw-jkt-dev-app-5a
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1a1ogs29dvgvqethz27g --VSwitchName vsw-jkt-dev-app-5b
aliyun vpc ModifyVSwitchAttribute --region $R --VSwitchId vsw-k1aj6eby0v5lpwrswov45 --VSwitchName vsw-jkt-dev-app-5c
aliyun ecs ModifySecurityGroupAttribute --region $R --SecurityGroupId sg-k1ag5j7s6xbuyjkv3j8c --SecurityGroupName sg-jkt-dev-app
```

回读校验（已实测通过）：`DescribeVpcs` / `DescribeVSwitches` / `DescribeSecurityGroups` 均返回新名，VPC 与各段 vSwitch 状态 `Available`，SG 仍为 `normal` 类型、出向 **7 条规则**（见 §1.1，其中 UDP 53 有 3 条）不变。

方案表落点：**`菲律宾部署方案-v2.3-修订版.xlsx`** sheet「网络与安全规划」共改 11 处名称文本（当时的 D16–D19 四行、B40–B45 六行、R56 说明一行；这些行号在 §8 插入四行后已下移，最终行号见 §6 表），资源 ID / CIDR / 合并区 / 样式均未变；包内 23 个 part 仅 `xl/worksheets/sheet5.xml` 变化。写入时该文件曾被 Excel 打开（`~$` 锁文件导致覆盖被拒），先另存临时版本，锁释放后已同步回 v2.3 原文件名，临时副本已删除。校验：`newapi-jkt-dev` 出现 0 次。改前快照仍为 `菲律宾部署方案-v2.3-修订版.xlsx.bak-20260930`（Phase 1 写入前的原始态）。


## 8. pub / data 段补齐（2026-09-30，零成本）

> ⚠ 本节记录的是补齐当时的布局（app 占了 `10.2.0.0/20` 这个 pub 槽），该偏移错位已在 §10 通过「删 7 建 7」修正。现网请以 §1 表为准。

先回答「为什么有 5c」：实测 `ecs DescribeZones`，**雅加达 ap-southeast-5 有 3 个可用区**（5a / 5b / 5c），而马尼拉 ap-southeast-6 只有 2 个（6a / 6b）、新加坡 ap-southeast-1 有 4 个。马尼拉表里角色段都是 a/b 成对，是因为它只有 2 个 AZ；雅加达多一个 5c，app 段就切成三段，让节点池 `AzBalance` 能在 3 个 AZ 间摊分（某 AZ 规格售罄不至于整池卡住）。Terway ENIIP 下 Pod IP 取自节点所在 AZ 的 vSwitch，并不存在独立的「Pod 专用子网」，所以 5c 的用途描述已从「ACK Pod 子网」改为「ACK 节点子网（第 3 可用区）」。

按马尼拉 pub / app / data 三角色补齐后的 `10.2.0.0/16` 布局：

| 角色 | 段 | 大小 | 用途（对齐马尼拉） |
|---|---|---|---|
| app | 10.2.0.0/20 · 10.2.16.0/20 · 10.2.32.0/20 | /20 ×3 | ACK 节点 + Pod（= `vsw-mnl-app-a/b`，马尼拉表里其用途即「ACK Pod 私有子网」） |
| pub | 10.2.48.0/24 · 10.2.49.0/24 | /24 ×2 | ALB / 公网入口子网（= `vsw-mnl-pub-a/b`；ALB 强制跨 2 AZ，故成对） |
| data | 10.2.64.0/20 · 10.2.80.0/20 | /20 ×2 | dev RDS PG 17.0 主 + Tair，多可用区/备实例候选（= `vsw-mnl-data-a/b`，数据库不暴露公网） |

app 三段沿用已建成资源，未动 CIDR；新增四段顺延到 48 / 49 / 64 / 80，七段互不重叠、均 `Available`，`10.2.96.0/19` 起仍留有空余。新增四段已打 `env=dev / project=new-api / managed-by / isolation=structural-vpc` 标签（`vpc TagResources --ResourceType VSWITCH`，`ListTagResources` 回读确认）。

**白名单口径（防止后续误 widening）**：dev RDS 的 `SecurityIPList` 只放 **app 三段**。data 段是数据库自己所在的子网、pub 段是入口子网，都不进数据库白名单；生产段 `10.0.0.0/16`、`10.1.0.0/16` 依旧绝对禁止。RDS 建实例时 `--VSwitchId` 用 `vsw-jkt-dev-data-5a`。

安全组未新增：pub / data 段资源继续复用 `sg-jkt-dev-app` 的出向 deny 契约即可满足隔离验收 V1 / V11。若 Phase 2 决定给 dev 数据库单独建 `sg-jkt-dev-data`，届时按同一形态补三条优先级 1 的 drop，并在本表加行。

## 9. 三站点偏移表核对与新加坡补全（2026-09-30，只读实测）

> 本表的「雅加达 dev」列已按 §10 对齐后的现网值更新（对齐当时的实测值见 §8）。

控制台实测（`vpc DescribeVpcs` + `DescribeVSwitches`）：

| 槽位 | 马尼拉 ap-southeast-6 | 新加坡 ap-southeast-1 | 雅加达 dev ap-southeast-5 |
|---|---|---|---|
| VPC | `vpc-newapi-mnl-prod` 10.0.0.0/16（`vpc-5tst1tgeessxn1azwasg2`） | `vpc-newapi-sg-prod` 10.1.0.0/16（`vpc-t4nimmwvruexbnene0a3r`） | `vpc-newapi-jkt-dev` 10.2.0.0/16 |
| pub | 10.0.0.0/24 (6a) · 10.0.1.0/24 (6b) | 10.1.0.0/24 (1a) · 10.1.1.0/24 (1b) | ✅ 10.2.0.0/24 · 10.2.1.0/24（对齐后） |
| app | 10.0.16.0/20 · 10.0.32.0/20 | 10.1.16.0/20 · 10.1.32.0/20 | ✅ 10.2.16.0/20 · 10.2.32.0/20（+ 第 3 AZ 追加 10.2.80.0/20） |
| data | 10.0.48.0/20 · 10.0.64.0/20 | 10.1.48.0/20 · 10.1.64.0/20 | ✅ 10.2.48.0/20 · 10.2.64.0/20（对齐后） |
| 段数 | 6（全部有占用：pub 250/252、app 4066·4080） | 6（pub 251·252、app 4073·4084、data 4092·4092=零实例） | 7（全部零实例） |

结论两条：

1. **新加坡表缺 2 行**：`vsw-sg-data-a 10.1.48.0/20`、`vsw-sg-data-b 10.1.64.0/20` 在云上早已存在（可用 IP 4092 = 未挂任何资源），原表只记了 pub/app 四行。已按实测补录进方案表 R16–R17，并给 R12–R15 补上真实 ID 与占用数；E11 的「不含数据库」改为「数据库段已按偏移预留、未挂实例」，避免下一个人误判规划漏项。
2. **生产两站点偏移逐槽同构**（pub=.0/.1 的 /24、app=16/32 的 /20、data=48/64 的 /20），dev 不同构：app 段占了 `10.2.0.0/20` 这个 pub 槽，pub/data 顺延到 48/49/64/80。vSwitch 的 CIDR 与可用区均不可修改，对齐只能删建；七段当时全部零绑定（可用 IP = 满值，仅系统路由表关联，无网络 ACL），所以**只有那时能免费做**，ACK / RDS 一落地就永久锁死。方案与脚本见 `deploy/ops/realign_jakarta_dev_cidrs.sh`（Step 0 会逐段复校占用，非满即 ABORT）；**已于 2026-09-30 经项目负责人核准执行完毕，全过程见 §10**。

另记一处命名事实：生产 VPC 实名带 `newapi` 段（`vpc-newapi-mnl-prod` / `vpc-newapi-sg-prod`，形态为 `vpc-newapi-<site>-<env>`）。负责人 2026-09-30 定口径：dev 也按同构形态走，VPC 已改回 `vpc-newapi-jkt-dev`（见 §10）；vSwitch / SG 仍保持 §7 确立的 `vsw-jkt-dev-<role>-<az>` / `sg-jkt-dev-app` 形态，因为生产侧这两类资源的名称本身就不带 `newapi` 段。

## 10. 偏移对齐「删 7 建 7」（2026-09-30，已核准执行，零成本）

**授权记录**：负责人原文「雅加达需要偏移对齐，可以删 7 建 7。 生产 VPC 实名带 newapi，这次我先关闭了excel」—— 明确批准破坏性删建，并给出 VPC 命名口径；写表前已实测 `~$` 锁文件不存在（`NO_LOCK`）。

执行前守卫（逐段，非满即 ABORT）：七段可用 IP 实测 pub 252/252、其余 4092/4092，即**零资源绑定**（`AvailableIpAddressCount == num_addresses - 4`；四个保留地址是系统网关/广播/保留位，属正常，不是占用）。

### 10.1 执行时间线（含一次真实故障与恢复）

1. `bash deploy/ops/realign_jakarta_dev_cidrs.sh`：Step 0 逐段复校通过 → 删除 7 段 → 依次建成 `pub-5a`、`pub-5b`、`app-5a`、`app-5b`。
2. **第 5 段创建时报错中断**：`ERROR: request to vpc.ap-southeast-5.aliyuncs.com failed: read tcp …: read: connection reset by peer`（瞬时网络抖动，非权限/配额/库存问题）；脚本 `set -euo pipefail` 如期在 data-5a 处退出 —— 此时 VPC 处于**四段在线、三段缺失**的半程态。
3. 恢复方式：**按名称幂等续跑**（先 `DescribeVSwitches --VpcId` 按 `VSwitchName` 查，存在则复用、缺失才建），补齐 `data-5a`、`data-5b`、`app-5c` 并逐段打标签。未产生重复段、未产生半途 CIDR。
4. `vpc ModifyVpcAttribute --VpcName vpc-newapi-jkt-dev`（纯元数据、零成本）。
5. 全量回读 + 回归 + RDS 零成本预检（见 10.3 / 10.4）。

> 这条经验值得记住：**破坏性批量操作必须在每一步可恢复**。本轮脚本若没有「按名查找」的分支，重跑会直接建出重名或错序的段。后续凡涉及成删成建的清单，一律先写成名称幂等再执行。

### 10.2 新旧对照（旧 ID 已销毁，仅作审计线索）

| 槽位 | 旧 CIDR / 旧 ID（已删） | 新 CIDR / 新 ID（现网） |
|---|---|---|
| pub-5a | 10.2.48.0/24 `vsw-k1asfd46ijq7dqurfhccb` | 10.2.0.0/24 `vsw-k1at4vt7fg8v4umkh9lg3` |
| pub-5b | 10.2.49.0/24 `vsw-k1ax18mzbsodwlpy7j48v` | 10.2.1.0/24 `vsw-k1aqa1ose29nuq92hcvyt` |
| app-5a | 10.2.0.0/20 `vsw-k1aaxl1aqbc42ac7yb7ms` | 10.2.16.0/20 `vsw-k1agmhxtf974bmzbjlnkp` |
| app-5b | 10.2.16.0/20 `vsw-k1a1ogs29dvgvqethz27g` | 10.2.32.0/20 `vsw-k1aoupd0er378rku728d3` |
| app-5c | 10.2.32.0/20 `vsw-k1aj6eby0v5lpwrswov45` | 10.2.80.0/20 `vsw-k1an7x32b5qjtsmklelkt` |
| data-5a | 10.2.64.0/20 `vsw-k1acp8av186m4e72y2lkt` | 10.2.48.0/20 `vsw-k1a9u8pkwwkc6z0x6g0kc` |
| data-5b | 10.2.80.0/20 `vsw-k1adi3avmtqx4c3th6h1g` | 10.2.64.0/20 `vsw-k1auat3gn6iagfg7by4sz` |

第 3 可用区（5c）追加在末尾 `10.2.80.0/20` 而不是插在中间，是为了让 5a/5b 的槽位偏移与马尼拉/新加坡**逐位相同**；`10.2.96.0/19` 起仍留有空余。

### 10.3 执行后回归（全部实测，非计划值）

- 七段 `Status=Available`，可用 IP 回到满值（252 / 4092），标签 `env=dev / project=new-api / managed-by=realign_jakarta_dev_cidrs.sh / isolation=structural-vpc` 四键齐全。
- `sg-jkt-dev-app`（`sg-k1ag5j7s6xbuyjkv3j8c`）**未删未建**，出向仍 7 条：prio1 Drop TCP 5432→43.118.96.65/32、prio1 Drop ALL→10.1.0.0/16、prio1 Drop ALL→10.0.0.0/16、prio10 Accept TCP 443→0.0.0.0/0、prio10 Accept UDP 53→100.100.2.136/138、prio20 Accept UDP 53→0.0.0.0/0 —— 隔离契约零变化（本轮只动子网段，没动安全组）。
- 生产侧零触碰：`DescribeCens`=0、`ListVpcPeerConnections`=0、生产 RDS `pgm-5tstdhko64x2c01w` 白名单未改、马尼拉/新加坡 VPC 与集群未改。**未产生任何一笔费用。**

### 10.4 下游参数变更（Phase 2 必须按此填，旧值全部作废）

```
RDS  --VSwitchId   = vsw-k1a9u8pkwwkc6z0x6g0kc        (vsw-jkt-dev-data-5a, 10.2.48.0/20)
     --SecurityIPList = 10.2.16.0/20,10.2.32.0/20,10.2.80.0/20   (仅 app 三段)
     DryRun 复跑结果 = DryRunResult: true   ✅
ACK  节点池 vswitch_ids = app 三段（10.2.16.0/20 · 10.2.32.0/20 · 10.2.80.0/20，AzBalance 摊分 5a/5b/5c）
ALB  公网子网 = pub 两段（10.2.0.0/24 · 10.2.1.0/24）
```

方案表同步：sheet「网络与安全规划」R18–R25 + R62 共 17 个单元格按新偏移重写，旧 vsw-id 残留 **0** 处；改前快照 `菲律宾部署方案-v2.3-修订版.xlsx.bak-before-realign`，校验后包内仅 `xl/worksheets/sheet5.xml` 变化、64249 字节。脚本同步：`deploy/ops/realign_jakarta_dev_cidrs.sh` 头部标注已执行 + 只读复查命令；`deploy/ops/provision_jakarta_dev_net.sh` 的 `VPC_NAME` / `VSWITCHES` / `APP_CIDRS` 全部按新偏移回写，并新增复用分支的 CIDR/AZ 漂移检测（`bash -n` 通过）。

## 11. Phase 2 建设（2026-09-30 18:00–18:35 UTC+8，**已产生费用**）

授权口径：负责人对「2a NAT+EIP → 2c ACK → 2b RDS → 2d 工作负载」的支出授权，并指示「EIP 没货就跳过买不到的、继续下一步」。

### 11.0 两个前置疑问的实测答案

1. **「余额 0.00 能不能开按量」= 能。** `QueryAccountBalance` 仍报 `AvailableAmount 0.00 / CreditAmount 0.00 / QuotaLimit 0.00 USD`，但本轮 EIP、NAT、ACK、RDS 四类按量资源**全部下单成功**。结论：BSS 的 `AvailableAmount` 不能作为「能否下单」的判据（该账号处于递延/可信支付态），任务 10 的 `RISK.RISK_CONTROL_REJECTION` 当时是别的原因。**台账 §2 里把它标为「硬阻塞」是误判，以本节为准。**
2. **「EIP 没货」= 未复现。** `AllocateEipAddress` 一次成功。若控制台报无货，多半是特定带宽/特定计费方式（如包年包月、特定 BGP 池）无货，按量 `PayByTraffic` 有货。

### 11.1 2a —— NAT + EIP（实测回读）

| 资源 | ID | 实测值 |
|---|---|---|
| EIP | `eip-k1ans4dqvvci8x4jx1fx3` | 名称 `eip-jkt-dev-nat` / **147.139.170.11** / 5 Mbps / `PayByTraffic` / `InUse`→NAT / `rg-nonprod` |
| NAT 网关 | `ngw-k1aij9gqb72y38kl31vd2` | `nat-jkt-dev` / Enhanced / internet / `Available` / 落在 **pub-5a** `vsw-k1at4vt7fg8v4umkh9lg3` |
| SNAT 表 | `stb-k1akdhp3towsobrgitdl6` | 条目 `snat-k1acb22kut2qkwgdx4iub`：`10.2.0.0/16 → 147.139.170.11`，`Available` |
| 默认路由 | `rte-k1akjm3rkrdd62p55brnn` | `0.0.0.0/0 → NatGateway`，**系统随 NAT 自动下发**（无需手工 CreateRouteEntry），`Available` |

> 命名口径：dev 的 NAT 放在 `pub-5a`，与马尼拉「pub 段服务公网入口」的角色分工一致。

**NAT 上线带来的隔离面变化（已同步收紧）**：SNAT 让整段 `10.2.0.0/16` 第一次获得公网可达性，生产 RDS 的**公网**端点 `43.118.96.65` 从「路由不可达」变成「路由可达、仅靠 SG 拦截」。因此把该 IP 的出向规则从「仅 drop TCP 5432」收紧为 **drop ALL**（优先级 1）。`sg-jkt-dev-app` 出向规则由 7 条变 **8 条**：

```
drop ALL  -1/-1      10.0.0.0/16        prio 1   马尼拉生产 VPC
drop ALL  -1/-1      10.1.0.0/16        prio 1   新加坡生产 VPC
drop ALL  -1/-1      43.118.96.65/32    prio 1   生产 RDS 公网端点（本轮新增，覆盖全部端口）
drop TCP  5432/5432  43.118.96.65/32    prio 1   生产 RDS 公网端口（保留，双保险）
accept TCP 443/443   0.0.0.0/0          prio 10  拉马尼拉 EE 公网端点 / 上游
accept UDP 53/53     100.100.2.136/32   prio 10  阿里云内部 DNS
accept UDP 53/53     100.100.2.138/32   prio 10  阿里云内部 DNS
accept UDP 53/53     0.0.0.0/0          prio 20  DNS 兜底
```

### 11.2 2c —— ACK dev 集群 + 节点池（实测回读）

| 项 | 值 |
|---|---|
| 集群 | `cb0abf5bc06034f7bbdb991752f6f3e62` / `ack-newapi-jkt-dev` |
| 规格 | **`ack.standard`（基础版，集群管理费 0）** —— 生产是 `ack.pro.small`；Pro 版约 0.6 USD/h（≈ 430 USD/月），dev 用 Pro 会把预算整体撑爆 |
| 版本 | `1.35.7-aliyun.1`（与马尼拉/新加坡一致，决策 D3 同规格） |
| 网络 | Terway **ENIIP**（`addons=[terway-eniip]`，无 overlay `container_cidr`，Pod IP 直接取自节点 vSwitch） |
| vSwitch | 节点 = Pod = app 三段 `vsw-k1agmhxtf974bmzbjlnkp` / `vsw-k1aoupd0er378rku728d3` / `vsw-k1an7x32b5qjtsmklelkt`（`pod_vswitch_ids` 与 `vswitch_ids` 同值，与马尼拉 `PodVswitchId` 元数据结构一致） |
| Service CIDR | **172.23.0.0/20**（马尼拉 172.21.0.0/20、新加坡 172.22.0.0/20 顺延，保持三站点同构，便于运维记忆） |
| 其它 | `proxy_mode=ipvs` / `ip_stack=ipv4` / `snat_entry=false`（复用 11.1 已建 NAT，避免重复计费） / **`endpoint_public_access=false`（API Server 仅内网）** / `deletion_protection=true` / `resource_group=rg-nonprod` / 标签 `env=dev,project=new-api,isolation=structural-vpc` |
| 节点池 | `np-jkt-dev-app` / `npd3cc9d7f0503472f85420d30436269b5` / ESS `asg-k1a59qtckc246wh9r3ay` |
| 伸缩 | `min=1 / max=3`、`multi_az_policy=BALANCE`、机型 `ecs.g9i.large` / `g8ine.large` / `g9ae.large`、系统盘 `cloud_essd 40G`、`PostPaid`、`internet_max_bandwidth_out=0`（节点无公网 IP，出网走 NAT）、无 SSH 密钥（运维入口用云助手，见 11.5） |
| 稳态节点 | **2 台**：`i-k1afy1aqgdl8rwa9gxvf` `g9i.large` 5a `10.2.25.174`；`i-k1ab0p31qirf7ejgdsg9` `g9ae.large` 5b `10.2.36.199` |

**必须记账的费用偏差（本轮最重要的一条）**：原估「稳态 ≈110 USD/月」按 **1 台节点** 计。实测伸缩链路为 `0→1`（min 兜底，10:12:49）→ `1→2→3`（autoscaler 因 pending 的 `coredns` 跨可用区打散，10:13:22 同一秒内连加两台，顶到 max）→ `3→2`（10:24:19 autoscaler 回收唯一那台「只有 DaemonSet」的空节点）。**稳态是 2 台，不是 1 台**：

```
节点：2 × 66.41 ≈ 132.82 USD/月（原估 66.41）
RDS ：43.38 USD/月
NAT + EIP：按量，CLI 无法报价（CU + 出向流量），保守另计
⇒ 稳态 ≈ 176 USD/月 + NAT/EIP，比授权口径高约 66 USD/月
```

要把节点压回 1 台，只有两条路（都需你定）：① 节点池 `vswitch_ids` 收到单可用区（牺牲 AZ 冗余，coredns 打散约束自然满足）；② 保留 2 台但接受预算上修。**当前状态是 2 台在计费。**

### 11.3 2b —— dev RDS PostgreSQL（实测回读）

| 项 | 值 |
|---|---|
| 实例 | `pgm-d9j9p421lzx4gw73` / `rds-newapi-jkt-dev` / **Running** |
| 引擎 | PostgreSQL **17.0** / `pg.n2.2c.1m` / 20 GB / **`cloud_essd`** / `Basic` / `Postpaid` |
| 位置 | `ap-southeast-5a` / **data-5a** `vsw-k1a9u8pkwwkc6z0x6g0kc` / 内网 IP `10.2.54.76` |
| 端点 | `pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com:5432`，`DescribeDBInstanceNetInfo` 回读 **只有一条 `IPType=Private`**，未开公网端点 |
| 白名单 | `default` = `10.2.16.0/20,10.2.32.0/20,10.2.80.0/20`（**仅 app 三段**，与 §8/§10.4 契约一致）；另有 `hdm_security_ips` = `100.104.16.128/26,100.104.58.192/26`（阿里云 DMS/HDM 服务侧自动添加，非本 VPC 地址，属平台内置，不视为隔离破口） |

两处纠错与一条经验：

1. **存储类型**：§2 记的 `--DBInstanceStorageType=generic` 是错的。DryRun 实测 `generic` → `DBInstanceStorageTypeFormatFault`，`cloud_ssd` / `local_ssd` → `InvalidStorage.Malformed`（20G 不满足其最小值），只有 **`cloud_auto` / `cloud_essd`** 通过。
2. **超时要复核，不要盲目重试**：`CreateDBInstance` 连续两次返回 `context deadline exceeded`（客户端超时），但服务端其实已受理。幸而 `DescribeDBInstances` 复核显示 `TotalRecordCount=1`，**没有重复下单**。结论：RDS/ECS 这类「写接口超时」必须先 `Describe*` 复核再决定是否重试，否则按量实例会成倍计费。

### 11.4 隔离验收（节点内实测，V1 / V11 部分）

在 `i-k1afy1aqgdl8rwa9gxvf` 上执行（云助手，命令内容不含任何凭据）：

```
[1] 出网公网 IP            = 147.139.170.11   ✅ 与 11.1 的 EIP 一致（NAT 生效）
[3] 43.118.96.65:5432      = BLOCKED          ✅ 生产 RDS 公网端点从 dev 不可达
[4] 10.0.16.20:6443        = BLOCKED          ✅ 马尼拉生产 VPC 不可达
[5] 10.1.19.73:6443        = BLOCKED          ✅ 新加坡生产 API Server 不可达
[6] dev RDS 内网端点:5432  = REACHABLE        ✅ 同 VPC 通路正常
```

`[2]` 一项显示 DNS FAIL 是**探针主机名写错**（`registry-ap-southeast-6.aliyuncs.com` 本身不存在）；`[1]` 的 `curl https://ifconfig.me` 已成功解析并连通，反证 DNS 正常。V2–V10（namespace RBAC、镜像拉取凭据、Secret 不同名、日志 project 分家等）仍待 2d 部署后补测。

### 11.5 运维持有

- API Server 仅内网，本地无法直接 `kubectl`；节点上有 `/usr/bin/kubectl` 但**无 kubeconfig**，kubelet 自带凭据权限不足。后续 k8s 侧操作二选一：① 云助手 + 临时下发 admin kubeconfig（会把凭据留在 `DescribeInvocationResults` 里，用完需清）；② 给集群开公网端点 + SLB ACL 白名单。**本轮未采用任何一种**，本轮 k8s 侧只做了 `crictl pods`（零凭据）。
- 伸缩链路证据取自 `ess DescribeScalingGroups` / `DescribeScalingActivities`，比看控制台更可靠。

## 12. Phase 2d 工作负载 + 三库冒烟 + Phase 3 隔离验收（2026-10-12，**已闭合**）

### 12.0 执行位定版（回答 §11.5 留下的二选一）

两个"执行位"本轮都用了**同一条既有通道**，没有新增凭据面：

| 面 | 执行位 | 凭据形态 | 实测收口 |
|---|---|---|---|
| `kubectl` | 云助手 → dev 节点内 `/usr/bin/kubectl`（`deploy/lib/ack_remote_jkt_dev.sh`） | `DescribeClusterUserKubeconfig --TemporaryDurationMinutes 15 --PrivateIpAddress true`，节点侧临时目录 700 / 文件 600，跑完 `rm -rf` | 每次回显 `cleaned=YES`，本机侧凭据同轮删除 |
| SQL | **集群内临时 psql Pod**（`postgres:17-alpine`，DSN 经 `secretKeyRef` 注入） | 口令只经临时 `Secret/t2d-dba` 进集群，同一调用内删除 | 残留检查 `NotFound` ×2 |

与生产同构（任务 13/27 用的是同一种"Pod 里跑 psql"形状），差别只在 dev 的 kubeconfig 换成 15 分钟临时凭据。**没有**开集群公网端点，**没有**留任何长期凭据。

### 12.1 本卡产物（全部新增文件，未改动 fork 里的既有业务代码）

```
deploy/jakarta_dev/newapi-dev.yaml          # Namespace/Quota/SA/CM/Deploy/Svc 六合一（4 处有意偏差写在文件头）
deploy/jakarta_dev/dev_deploy.sh            # 执行器：--precheck/--render-check/--apply-base/--secret/--grants/
                                            #   --db-owner-probe/--db-owner-fix/--apply-app/--verify/--logs/--smoke/--isolation/--status/--delete
deploy/jakarta_dev/dev_grants.sql           # 权限 SQL（scope|SQL 逐行，runner 一条一次 psql -c）
deploy/jakarta_dev/dev_rds_finalize.sh      # 口令轮转 / DSN 重建 / 只读复核（--rotate/--dsn/--grant/--verify）
deploy/jakarta_dev/bodies/{apply_base,apply_secret,apply_grants,apply_app,verify,logs,smoke,status,delete,
                            db_owner_fix,db_owner_probe,isolation,isolation_rbac}.sh
deploy/lib/ack_remote_jkt_dev.sh            # 15 分钟临时凭据版远端通道
```

### 12.2 权限模型：一次真实走偏 + 非破坏纠偏（坑 11 的现场版）

**走偏**：本轮曾按"生产 API 口径"调 `GrantAccountPrivilege --AccountPrivilege DBOwner`。RDS 回 `RequestId` 成功，但 `DescribeAccounts` 回读 `DatabasePrivileges` 仍是空 —— 即坑 11 说的"API 侧看不到、但实际动了库 owner"。`--grants` 的生效判据回读把它抓了出来：

```
db_owner=newapi          （主库）  ⇒ has_create_runtime=true
db_owner=newapi_migrate  （日志库）
```

运行账号成了库 owner ⇒ schema 级 ACL 形同虚设，最小化没有真正生效。

**纠偏可达路径（全部实测）**：

| 尝试 | 结果 |
|---|---|
| `ALTER DATABASE … OWNER TO aurora` | `ERROR: must be able to SET ROLE "aurora"` —— owner 校验已过，卡在目标角色 |
| `SET ROLE aurora` | `permission denied`；`newapi_ops` 只有 `pg_rds_superuser`（admin=false） |
| `RevokeAccountPrivilege`（回到 API 侧零权限的正确形状） | 回 `RequestId` 成功，但 **owner 不变** ⇒ RDS 没有"还原内部账号 owner"的通路 |
| `ALTER DATABASE … OWNER TO newapi_ops` | **成功**，两库 owner 均已交回应用绝不使用的高权限账号 |

`pg_rds_superuser` 也测过（`SET ROLE` 可用），但拿保留组角色当库 owner 属未验证用法，**没有采用**。

纠偏后判据（`--grants` 回读，非计划值）：

```
[main]  db_owner=newapi_ops  has_create_migrate=true  has_create_runtime=false
        nspacl=pg_database_owner=UC/…,newapi_migrate=UC/pg_database_owner,newapi=U/pg_database_owner
        default_acl=newapi_migrate={newapi=arwd/…} {newapi=rU/…}
[logs]  db_owner=newapi_ops  has_create_runtime=true  has_create_migrate=false   ← dev 有意偏差：日志库 DDL 由 newapi 承担
```

### 12.3 新坑（建议并入指南任务 13/17 的坑表）：PG 的 DSN 必须是 URL 形态

`--apply-app` 首启即 `CrashLoopBackOff`，容器日志：

```
[SYS] using MySQL as database
[error] failed to initialize database, got error invalid DSN: missing the slash separating the database name
```

根因在代码里，与云侧无关：`model/main.go:151` 的 `chooseDB()` **只按 DSN 前缀**（`postgres://` / `postgresql://`）判定 PG；libpq 的 `host=… dbname=… password=…` k/v 形态会直接掉进 `main.go:168` 的 MySQL 分支。dev 的 DSN 原本正是 k/v 形态。

处置：`dev_rds_finalize.sh` 的 `rebuild_dsn()` 改产 URL 形态，三键重建（口令已实测纯字母数字，无需百分号编码；这与**坑 10** 是同一条约束的另一侧 —— `#` 等保留字符必须转义）。`bodies/apply_secret.sh` 加了硬闸门：DSN 前缀不是 `postgres://` 就**直接 exit 1**，不允许把这个错误带进 Pod。

**可泛化判据**：凡"用 psql 验证通过"的 DSN 都不能代表应用能用 —— 应用只认 URL 前缀，psql 两种形态都认。与坑 10 的"`redis-cli` 通不代表 `go-redis` 通"完全同构。

### 12.4 首启与三库冒烟（`--verify` / `--smoke` 实测）

```
Pod new-api-dev-d6cfd49ff-4zj9s 1/1 Running（节点 ap-southeast-5.10.2.36.199，SA new-api-app，
    镜像 acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-master:20261012-a8e646954）
New API ready in 446 ms
[GIN] GET /api/status → 200 ×N（探针）
S1 /api/status 200 ｜ S2 / 200 ｜ S3 svc DNS new-api-dev.newapi-dev.svc=172.23.5.57:80 → 200
S4 三 DSN 落库面：SQL_DSN_MIGRATE tables=36 ｜ SQL_DSN tables=36 ｜ LOG_SQL_DSN tables=2
S5 权限链：select users ⇒ 0 行；update users ⇒ 成功 0 行；create table _t2d_forbid ⇒ ERROR: permission denied for schema public
S6 越界清理：public_tables_left=36，无 _t2d 残留
S7 DDL/迁移日志行数=38（SQL_SLOW_THRESHOLD_MS=1 生效，与生产 master 同构）
```

`S5` 那条 `permission denied for schema public` 就是坑 11 想要的最终证据：运行账号读得到、改得动、**建不了表**，建表只有 `newapi_migrate` 能做。

### 12.5 Phase 3 隔离验收 V1–V11（全部实测；`bodies/isolation.sh` + `bodies/isolation_rbac.sh`）

网络面在 **Pod 网络命名空间**里测（terway 直接给 Pod 分 VPC IP，比 §11.4 的节点侧更贴近应用真实路径），探针 Pod 复用已缓存的 `postgres:17-alpine`（busybox `nc` / `nslookup`）。

| 编号 | 判据 | 实测 | 结论 |
|---|---|---|---|
| V1 | dev 出网只用**自己**的 NAT EIP | Pod 侧 `147.139.170.11`、节点侧 `147.139.170.11` | ✅ |
| V2 | 生产 RDS 公网端点不可达 | `43.118.96.65:5432 ⇒ BLOCKED` | ✅ |
| V3 | 马尼拉生产 VPC 内网不可达 | `10.0.16.20:6443`、`10.0.0.1:443`、`10.0.22.220:6443` 全 `BLOCKED` | ✅ |
| V4 | 新加坡生产 API Server 不可达 | `10.1.19.73:6443 ⇒ BLOCKED` | ✅ |
| V5 | 生产 ACR EE 的 **VPC 域名不可达**，只有公网入口可达 | `-vpc` 解析到 `10.0.22.220` 但 `443 ⇒ BLOCKED`；公网域名解析 `8.220.143.202` 且 `443 ⇒ OPEN` | ✅（"能解析"≠"能连通"。dns() 首版把 CoreDNS 地址当成应答，已修） |
| V6 | dev RDS 只有 5432 通 | `…:5432 ⇒ OPEN` / `…:6432 ⇒ BLOCKED` | ✅（清单偏差③复核） |
| V7 | dev SA 零 RBAC | ns 内 Role/RoleBinding=0、引用 `new-api-app` 的 ClusterRoleBinding=0、全 ns RoleBinding=0；6 条 `can-i --as=` 全 `no`，同轮对照 admin `can-i get nodes ⇒ yes` ⇒ 判据通道有效 | ✅ |
| V8 | 免密拉取只圈 dev | addon `managed-aliyun-acr-credential-helper` **active v24.01.29.1-5318af4-aliyun**，config 回读 `watchNamespace=newapi-dev` / `serviceAccount=new-api-app` / `AcrInstanceInfo=cri-avfqy9xkqi5bj8ee@ap-southeast-6` / `enableRRSA=false`；`acr-credential-secret-aggregation` **只存在于 newapi-dev**（kube-system / default 无） | ✅ |
| V9 | Secret 里不含任何生产端点/网段 | 逐键 base64 解码后按 `pgm-5tstdhko64x2c01w` / `43.118.96.65` / `new-api-prod` / `10.0.` / `10.1.` / `registry-vpc` 匹配 ⇒ **零命中**（只打印命中与否，值不外泄） | ✅ |
| V10 | 日志库分家 | Pod env 解析：`SQL_DSN`/`SQL_DSN_MIGRATE` ⇒ dev 实例 `:5432/newapi`，`LOG_SQL_DSN` ⇒ dev 实例 `:5432/newapi_logs` | ✅ |
| V11 | 资源面 + 云端结构性通路 | ns 内 1 deploy / 1 svc / 2 cm（含 `kube-root-ca.crt`）/ 2 secret / 2 sa / 1 pod，临时对象 0；`cbn DescribeCens TotalCount=0`；`vpcpeer ListVpcPeerConnections` 在 `ap-southeast-5 / 6 / 1` 三站均 `TotalCount=0` | ✅ |

**Phase 3 结论：dev 与生产之间不存在任何通路** —— 网络层 V2–V5 实测阻断、结构层 V11 零 CEN / 零 Peering、身份层 V7 零 RBAC、数据面 V9/V10 零串台。唯一被许可的跨区动作仍只是"从马尼拉 EE **公网入口**拉镜像"这一条，且它是只读出向、不附带任何生产内网通路。

### 12.6 台账纠错（§11.3 的两处与实际不符）

| 项 | §11.3 原记 | 实测回读 |
|---|---|---|
| 引擎版本 | PostgreSQL 17.0 | **17.10**（临时 psql Pod `select version()`） |
| 付费方式 | `Postpaid` | **`Prepaid`，`ExpireTime=2026-11-12T16:00:00Z`** ⇒ 到期即释放，见 §12.8 |

教训：`CreateDBInstance` 传入的 `--InstanceChargeType` 与最终形态不一定一致（RDS 对新购 PG 走了包月默认值），**付费口径只能以 `DescribeDBInstanceAttribute` 为准**。

### 12.7 凭据暴露与自查（诚实记录，本轮一次自伤）

- **本轮我自己的打码 bug 把两个 dev 口令（旧值）漏进了会话记录**：`--precheck` 的 `sed` 只按 URL 形态 `user:pw@host` 打码，而当时 DSN 是 k/v 形态 ⇒ 漏打。发现后立即 `--rotate` 轮换两个账号，**旧值当场作废**（轮换发生在任何 Secret 落集群之前，所以集群里从未存在过泄露值）。`mask_dsn()` 现已同时覆盖 `password=` 与 `://u:pw@` 两种形态。
- 口令随 `--secret` / `--grants` 的命令体经云助手投递**一次**，与任务 13 跳板 ECS 的既有口径同级；补偿控制 = 用完即轮转 + 载荷文件 `shred -u` + 临时 Secret 同轮删除。
- kubeconfig：15 分钟临时、私网、节点侧 700 目录 / 600 文件，`rm -rf` 后回显 `cleaned=YES`。
- **一次 `--apply-app` 被云助手按 `Timeout` 判失败**（`rollout --timeout=300s` 与 `RunCommand --Timeout 300` 撞在同一秒）⇒ 命令被杀，节点侧临时目录清理没跑。已手工 `rm -rf /tmp/ackctl-*` 并复核；同时把三层上限错开：**rollout 240s < RunCommand 900s ≤ 本地轮询 190×5s**。另修了轮询逻辑：`DescribeInvocationResults` 偶发返回空状态曾被当成"命令结束"，现改为空则继续轮询。
- 云助手命令体上限实测：`CmdContent.ExceedLimit` 出现在 ~16KB；Base64 二次膨胀 1.35× ⇒ body 改为静态文件 + 引号化 heredoc，`--isolation` 拆成两个 body（合并后 15.6KB 被本地闸门拦下）。
- dev 节点**没有 `jq`**（`rc=127`）也**没有 `psql`**、`registry-ap-southeast-5.aliyuncs.com` NXDOMAIN；所有远端回读改用 `kubectl -o go-template/jsonpath`。
- ACR EE 的 `ListRepoTag` 必须用 `--RepoId`（不是 namespace/name），且实例在马尼拉 ⇒ 所有 `cr` 调用带 `--region ap-southeast-6`。

### 12.8 待负责人裁定（不阻塞本次交付）

1. **dev RDS 是包月、2026-11-12 到期** ⇒ 续费 / 转按量 / 到期即释放（dev 可重建）。到期未续会连带 §12.5 的 V6/V10 证据失效。
2. **dev 节点池现有 2 台 2C/8G**（计划 `min=1`）⇒ 保留双节点（可用性）还是缩到 1 台（省一台费用）。
3. **库 owner 口径**：本轮把它纠到 `newapi_ops`（非破坏，最小化已实测生效）。若要求与生产逐字同构（owner=`aurora`），唯一路径是**删库重建** —— 两库现有对象仅 `main=36` / `logs=2` 张应用表，重建等于清空 dev 数据 ⇒ 属破坏性操作，需明确核准后才动。
4. **生产 ACR EE 公网 ACL 仍未收口**（`0.0.0.0/1` + `128.0.0.0/1`，§3 既有缺口）：dev 现在正是走这个公网入口，收口前不要改绑 IP 段，否则 dev 拉镜像会断。
## 13. 任务 13（追加）：负责人手建 Deployment `fanyan-new-api-master` 拉不到镜像 —— 免密拉取定位（2026-10-13）

### 13.0 现象

控制台「使用镜像创建」建的无状态负载，落在 dev ns `newapi-dev`，`0/2` 一直起不来；同 ns 的 `new-api-dev` 是 `1/1`。
镜像填的是 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20261009-a8e646954`。

### 13.1 先排除"镜像不存在"这条误判（云端只读，`aliyun cr`，region 必须 ap-southeast-6）

EE 实例 `cri-avfqy9xkqi5bj8ee` 共 8 个仓库，`newapi-prod/newapi-master` = `crr-eo15b1p46wt8yeek`，`RepoStatus=NORMAL`；
其 tag `20261009-a8e646954` **存在**，`Status=NORMAL`，`ImageSize=78071398`，
`Digest=829a4277fe4791dc341ce759f9a4d5d2008d949f28109b547327872fd510fff0` —— 与 dev 正在跑的
`newapi-dev/newapi-master:20261012-a8e646954`（以及 `20261013-d481f5ba2`、`yxw-test`）**digest 完全相同**。

⇒ 结论：不是 tag 写错、不是仓库不存在。指向 prod 与指向 dev 拉到的是同一份镜像内容，**只是命名/隔离口径不对**（见 13.5）。

### 13.2 集群侧实测（`deploy/jakarta_dev/dev_deploy.sh --diagnose-pull`，body `bodies/diagnose_pull.sh`，全程只读）

D1 三要素对照（免密只认「镜像 / SA / imagePullSecrets」）：

```
fanyan-new-api-master  sa=（=default）  pullSecrets=（空）   img=…/newapi-prod/newapi-master:20261009-a8e646954
new-api-dev            sa=new-api-app   pullSecrets=（空）   img=…/newapi-dev/newapi-master:20261012-a8e646954
```

D2 原始报错串（决定性证据，两个阶段各有原因）：

| 时间 | 用的域名 | 报错原文（要点） | 性质 |
|---|---|---|---|
| 早期 `847cc75465-*` | `acr-newapi-mnl-registry**-vpc**.ap-southeast-6…` | `dial tcp 10.0.22.220:443: i/o timeout` | **网络不可达**（跨区私网入口） |
| 现在 `77bdff6b7-*`/`c4bb97798-*` | `acr-newapi-mnl-registry.ap-southeast-6…`（公网入口） | `pull access denied … insufficient_scope: authorization failed` | **根本没带凭据**（匿名拉私有库） |

D3 `Secret/acr-credential-secret-aggregation` 在 `newapi-dev` 内存在，`auths` 同时登记了 `-vpc` 与公网两个域名（值应打码，见 13.4 事故）。
D4 ns 内 2 个 SA：`default` 的 `imagePullSecrets` **为空**；`new-api-app` 挂着 `acr-credential-secret-aggregation`。
D5 `kube-system/acr-configuration` ConfigMap **不存在** —— 该集群的 helper 是托管形态，作用域只在 CS API 侧
（§12.5 V8 已回读：`serviceAccount=new-api-app`、`watchNamespace=newapi-dev`、`AcrInstanceInfo=[cri-avfqy9xkqi5bj8ee @ ap-southeast-6]`）。

**根因一句话**：ACR 免密组件是**按名字把临时凭据挂到指定 ServiceAccount** 的，不是"ns 里有 Secret 就自动生效"。
控制台「使用镜像创建」默认用 `default` SA 且不写 `imagePullSecrets`，所以 Pod 一个凭据都拿不到 ⇒ `insufficient_scope`。

### 13.3 免密拉取的三条路径（都已对着实测证据核过）

| 方案 | 做法 | 代价 / 适用 |
|---|---|---|
| **A（推荐，零组件改动）** | 把该 Deployment 的 Pod 模板 `serviceAccountName` 改成 **`new-api-app`**（控制台：修改部署 → 高级配置 → 服务账户），随后 `rollout restart` | 与 `new-api-dev` 完全同构：免密由 SA 承载、Pod 不写 `imagePullSecrets`。多应用共用一个 SA 在 dev 可接受 |
| B（保持 `default` SA） | Pod 模板显式写 `imagePullSecrets: [{name: acr-credential-secret-aggregation}]` | 立即可用，但该 Secret 由 helper 托管、随 `watchNamespace` 生灭；把它当业务依赖会让" Secret 从哪来"变难追。适合救急，不适合作长期约定 |
| C（长期干净） | 为该应用建独立 SA（如 `fanyan-app`），再到 CS 控制台「组件管理 → managed-aliyun-acr-credential-helper → 配置」把该名字加进 `serviceAccount`（逗号分隔多个） | 唯一与"每个工作负载自己的 SA"权限模型一致的做法，但要改集群组件配置（作用域仍只在 `watchNamespace=newapi-dev`，不影响生产） |

三条都**不需要**自建长期 AK 的 docker-server Secret——那会绕过免密、把口令留在人手抄的清单里，违反 §12 的凭据纪律。

### 13.4 本轮新增坑（写进复用清单）

- **坑 15｜跨区复用 EE 时 `-vpc` 域名不可路由**：`acr-newapi-mnl-registry-vpc.ap-southeast-6…` 解析到**马尼拉侧 VPC 的私网 IP**（实测 `10.0.22.220`），
  雅加达 dev VPC 与三区之间按计划**没有 CEN/Peering**（§12.5 V11 = 0 条）⇒ 必然 `i/o timeout`，且这个报错长得像"防火墙问题"，极易误判。
  结论：dev 复用马尼拉 EE 走公网入口，**镜像域名必须不带 `-vpc`**（与「acr ee 比较贵，暂时复用马尼拉 EE 走公网入口跨区拉」的裁定一致）。
- **坑 16｜helper 只绑"配置里点名"的 SA**：`Secret` 存在 ≠ Pod 拿得到。判断顺序应为
  `Pod 的 SA` → `SA.imagePullSecrets` → `Secret 是否在 ns`，而不是先看 Secret。
- **坑 17｜打码正则漏大写**：ACR `dockerconfigjson` 的键名是 **`Username`/`Password`**（首字母大写），
  小写正则 `(username|password)` 完全没命中 ⇒ 见 13.6。

### 13.5 顺带要纠的口径（不是故障，是隔离设计）

`newapi-prod/*` 是**生产命名空间**。免密令牌是**实例级**的，技术上 dev 能拉到 prod 仓库，但这与
「正式环境和开发/测试环境彻底隔离」的要求相冲突（隔离是命名+权限口径上的，网络层已按 V1–V11 证实不通）。
且 §13.1 已证明 prod 那个 tag 与 dev 的 `20261012-a8e646954` 是同一 digest —— 指 prod **没有任何收益**。
⇒ 建议 dev 的手建负载一律用 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-*:<tag>`。
另注意该负载 `replicas=2`，跨区公网每副本拉 78 MB，dev 配额是 `pods 20`，不是问题但会明显拖慢首启。

### 13.6 凭据暴露事件（第二次，同类成因）—— 如实记录

- **事实**：D3 原 body 用小写打码正则（坑 17），把 dev 集群里 `acr-credential-secret-aggregation` 的
  **临时拉取口令原文（`cr_temp_user` + STS 型 token）输出进了会话记录**。用户名与实例 ID 同批可见。
- **有效窗口**：token 内 `time` 字段 = `1791931523000` ⇒ 到期 **2026-10-13 22:45 UTC / 10-14 06:45 CST**，
  即自暴露起约 **20.5 小时**后自然失效；helper 的 `expiringThreshold=15m` 会在那之前换新值（集群内副本会换，**已外泄的这条不会因此提前失效**）。
- **权限面**：该 token 是**实例级**凭据，覆盖 `cri-avfqy9xkqi5bj8ee` 全部命名空间（含 `newapi-prod`），
  即 §12.8 第 4 项仍未收口的公网 ACL（`0.0.0.0/1` + `128.0.0.0/1`）也一并适用 ⇒ **风险叠加**，不是"只影响 dev"。
- **本卡已做的纠偏**：打码正则改为 `-i` + 值整体替换 + 长串一律省略，并已用合成样本本地验证输出只剩 `***`（未再上集群取真值）。
- **不可用的补救（写清楚，避免误判）**：ACR EE 没有"吊销单个临时 token"的 OpenAPI；删掉集群里的 Secret 只会让 helper 生成新值，
  **不会让已外泄的旧值提前失效**。真正能压窗口的只有：① 收紧 EE 公网入口 ACL（但会立刻断掉 dev 跨区拉取，需与 §12.8-4 一起裁定）；
  ② 等自然到期（≤20.5 h）。**未擅自执行任一项**，因两者都会动到共享入口/生产可达面。
- 与 §12.7 同一类根因：**打码是"事后正则"而不是"结构性不取值"**。后续任何 body 一律遵循
  "能只打印键名/长度就不打印值"，需要结构时用 `go-template` 取指定字段，禁止整份 `dockerconfigjson` 落地。

### 13.7 本卡产物 / 动作

- 新增：`deploy/jakarta_dev/bodies/diagnose_pull.sh`（只读，命令体 4.3 KB，无载荷）。
- 修改：`deploy/jakarta_dev/dev_deploy.sh` 加 `--diagnose-pull` 分发与 `render_check` 覆盖（该 body 走**零凭据 header**，
  刻意不复用 `SEC_B64` 分支，免得诊断脚本白带一份 DSN）。
- 云端只读：`aliyun cr ListRepository` / `ListRepoTag`（region ap-southeast-6）。
- **未做任何集群写入**：没有 patch 该 Deployment、没有改 SA、没有改 helper 配置、没有改 ACL。
  13.3 的 A/B/C 三条都等负责人选定后再落，落法与回读口径同 §12。
### 13.8 方案 A 已执行（负责人 2026-10-13 裁定「选A」）—— 写入面与回读证据

**产物**：新增 `deploy/jakarta_dev/bodies/fix_pull_sa.sh`（只 patch `serviceAccountName`，命令体 4.0 KB）；
`dev_deploy.sh` 加 `--fix-pull-sa <deploy>` 分发（**必须显式给负载名**，不给就直接拒，刻意无默认值）与 `render_check` 覆盖。

**实际写入（唯一一处）**：

```
=== F0 闸门   before: name=fanyan-new-api-master  sa=（default）  replicas=1
             image=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20261009-a8e646954
             SA=new-api-app 的 imagePullSecrets=acr-credential-secret-aggregation（非空才允许动手）
=== F1 patch  deployment.apps/fanyan-new-api-master patched
```

没有碰的：helper 组件配置、Secret、RBAC、镜像名、replicas、`new-api-dev` 全部对象。

**回读（生效判据只认回读，不认 patch 返回码）**：

```
=== F2  after: sa=new-api-app   deploy级pullSecrets=（空）  ⇒ 与 new-api-dev 同构（免密挂在 SA 上）
        新 RS fanyan-new-api-master-768f8495d6  sa=new-api-app des/cur=1/0
        旧 RS 77bdff6b7 / 7b7b7c5f7f / 847cc75465  sa=（default） des/cur=0/0  ← 滚动过程中的残留
=== F3  deployment "fanyan-new-api-master" successfully rolled out   rollout_rc=0
=== F4  ready=1/1  updated=1
        fanyan-new-api-master-768f8495d6-vnjgt  ready=true  restarts=0
        imageID=…/newapi-dev/newapi-master@sha256:829a4277fe4791dc341ce759f9a4d5d2008d949f28109b547327872fd510fff0
```

复采（`--diagnose-pull`，只读）里的决定性一行 —— 拉取真的成功了，不再是 `insufficient_scope`：

```
30s  Normal  Pulling  pod/fanyan-…-768f8495d6-vnjgt  Pulling image "acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/…"
29s  Normal  Pulled   pod/fanyan-…-768f8495d6-vnjgt  Successfully pulled image "…" in 574ms (574ms including waiting). Image size: 78074406 bytes.
D6  只剩 new-api-dev ready=1/1 ⇒ ns 内已无未就绪负载
```

**证据边界（不把话说满）**：

1. `574ms` + `imageID` 落在 `newapi-dev/…@sha256:829a42…` ⇒ **manifest/tag 解析是走公网入口凭据成功的**（这一步才是本次修的），
   但**镜像层由节点本地缓存命中提供**（同 digest 早被 `new-api-dev` 拉过）。所以本次证明的是"授权链路通了"，
   **没有**证明"78 MB 层数据能跨区公网下载"。要验那条得换一个节点上没有的 tag（会产生跨区下行流量），未擅自执行。
2. `Image size` 两次读数不同：F4 侧事件 `78074406` vs `aliyun cr` 侧 `78071398`（压缩层合计与 CRI 口径差异），不作为异常。
3. `replicas` 本轮读到 **1**，而 §13.2 D6 时是 **2** ⇒ 期间负载被人从控制台改过副本数（本卡命令体里没有 replicas 相关写操作，
   F1 的 patch JSON 只有 `serviceAccountName` 一个字段）。记录以防后续对不上数。

**13.6 暴露事件的后续处置**：把 D3 从"事后正则打码"改成**结构性只取域名**
（`go-template` 取 `dockerconfigjson` → `grep -oE '[a-z0-9.-]*\.cr\.aliyuncs\.com' | sort -u`，值通道从命令里彻底消失），
已用合成样本验证输出只含两个域名。外泄的临时 token 仍按 §13.6 结论**等自然到期（2026-10-14 06:45 CST）**，
收紧公网 ACL 与 §12.8-4 一起裁定，不单动。

**仍待办（负责人侧决定）**：该负载镜像仍指向 `newapi-prod/*`。技术上能拉（本次已证），但与"dev/prod 彻底隔离"的命名口径相冲，
且 §13.1 已证与 `newapi-dev/newapi-master:20261012-a8e646954` 同 digest ⇒ 换成 dev 命名空间零损失。改动只需一次 `set image`，等指令。
### 13.9 该负载镜像已从 `newapi-prod/*` 换到 `newapi-dev/*`（负责人 2026-10-13 裁定「可以换」）

**改前先拿证据**（`aliyun cr ListRepoTag --region ap-southeast-6 --RepoId crr-d0l6yu3mrddv4tbw`）：
`newapi-dev/newapi-master` 下 `20261013-d481f5ba2` / `yxw-test` / `20261012-a8e646954` / `20261009-a8e646954`
四个 tag 全部 `Status=NORMAL`，`ImageSize=78071398`，**digest 一律 `829a4277fe…fff0`**
⇒ 与 §13.1 的 `newapi-prod/newapi-master:20261009-a8e646954` 同一份内容，换命名空间是**等价替换**，不是降级或换版本。
选定 `20261012-a8e646954`（与 `new-api-dev` 清单所用 tag 逐字相同，便于同构比对）。

**产物**：新增 `bodies/set_image.sh` + `dev_deploy.sh --set-image <deploy> <image>`。
闸门是**白名单**而非黑名单（只放行 `…ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-master:<yyyymmdd>-<sha>`），
离线自测三类误配全部在任何 `kubectl` 之前被拒（rc=2）：

| 被拒的镜像 | 为什么必须挡 |
|---|---|
| `newapi-prod/newapi-master:20261009-a8e646954` | 本次要消除的口径（dev 引用生产命名空间） |
| `newapi-dev/newapi-master:yxw-test` | 非发布 tag，避免把临时标签固化进负载 |
| `…-vpc.ap-southeast-6…/newapi-dev/…:20261012-a8e646954` | §13.4 坑 15：跨区 `-vpc` 不可路由，注定 `i/o timeout` |

**实际写入（唯一一处）**：`deployment.apps/fanyan-new-api-master image updated`。SA 未受影响（回读仍 `new-api-app`）。

**回读与实测**：

```
after: image=…/newapi-dev/newapi-master:20261012-a8e646954     after: sa=new-api-app
deployment "fanyan-new-api-master" successfully rolled out      rollout_rc=0
ready=1/1  updated=1
  fanyan-…-79cf8fbd8b-lgkvw  sa=new-api-app  ready=true  restarts=0
  imageID=…/newapi-dev/newapi-master@sha256:829a4277fe4791dc341ce759f9a4d5d2008d949f28109b547327872fd510fff0
  Normal Pulled "…newapi-dev/newapi-master:20261012-a8e646954" in 59.804s (including waiting). 78074406 bytes
  Normal Created / Normal Started ⇒ 容器真的起来了，不是只拉下来
```

`imageID` 的 digest 与 §13.1 / §13.8 三处读数一致 ⇒ 等价替换得到独立印证。

**证据边界的更新（对 13.8-① 的修订，不要把话说满）**：本次 `59.804s` 含滚动排队等待
（事件里同时出现 `1 old replicas are pending termination`），且该 digest 的层此前已被 `new-api-dev` 拉进节点缓存
⇒ **仍然没有**做过"节点冷缓存下 78 MB 跨区公网全量下载"的耗时/成功率验证。这条挂为未证，
真要验得换一个节点上没有的 tag（会产生跨区下行流量，需批准）。

**当前 `newapi-dev` ns 终态**：`new-api-dev` 1/1（本卡产物，镜像/SA/清单均未动）；
`fanyan-new-api-master` 1/1，`sa=new-api-app`，镜像 `newapi-dev/newapi-master:20261012-a8e646954`。
两个负载现在共用同一条免密链路、同一个 dev 命名空间，`newapi-prod/*` 在 dev ns 内已无引用。
### 13.10 「节点冷缓存跨区全量下载」这条未证项的处置：现有注册表内容下**结构上不可验**（负责人 2026-10-13「可以的」授权跨区下行后实测）

**产物**：新增只读 body `bodies/node_image_cache.sh` + `dev_deploy.sh --node-image-cache`（已进 `--render-check`）。

**EE 侧先把"有没有第二个 digest 可拉"问清楚**（`aliyun cr ListRepoTag`，region ap-southeast-6，实例 `cri-avfqy9xkqi5bj8ee`）：

| 仓库 | tag 情况 | digest |
|---|---|---|
| `newapi-dev/newapi-master` | `20261013-d481f5ba2` / `yxw-test` / `20261012-a8e646954` / `20261009-a8e646954` | **全部 `829a4277fe…fff0`** |
| `newapi-test/newapi-master` | `20261012-a8e646954` | 同上 |
| `newapi-prod/newapi-master` | `20261009-a8e646954` 等 | 同上 |
| `newapi-dev/newapi-slave`、`newapi-prod/newapi-pg-bouncer`、`newapi-pre/newapi-master`、`newapi-test/newapi-slave` | **空仓库**（`TotalCount=0`） | — |

⇒ 整个实例只流转**一个** digest。containerd 的 content store 按 digest 存层，换 tag / 换命名空间照样命中缓存
⇒ 拿现有任何 tag 做"冷拉"都只会测到缓存命中（这正是 §13.8-① 里 574ms 与 §13.9 里 59.8s 的真实成因）。
**这条不是我没做，是当前内容下做不出来。**

**节点侧实测（只读，未删镜像、未拉载荷、未改对象）**：

```
C1/C3  节点上唯一的 ACR 镜像 = newapi-dev/newapi-master:20261012-a8e646954，ID 1de3df3c01235，digest 829a4277fe…fff0
       两个在跑的 Pod（new-api-dev 与 fanyan）imageID 与之一字不差 ⇒ 缓存命中的判定成立
C4     curl -sSI https://acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/v2/
       HTTP/2 401
       www-authenticate: Bearer realm="https://dockerauth-ap-southeast-6.aliyuncs.com/auth",
                         service="registry.aliyuncs.com:ap-southeast-6:international:cri-avfqy9xkqi5bj8ee"
```

**C4 是本轮最有价值的一条**：不带任何凭据，从雅加达 dev 节点（源地址 `10.2.25.174`）到马尼拉 EE **公网入口**的
TCP + TLS + HTTP/2 + registry v2 应用层**全部打通**，401 是未授权的预期响应，`service` 串里的
`ap-southeast-6:international:cri-avfqy9xkqi5bj8ee` 还独立印证了打到的是**这一个实例**（不是别处的公共端点）。
配合 §13.8/§13.9 两次 `insufficient_scope` 消失与 `Pulled → Created → Started`，
链路可达性 + 授权正确性两项已经是双口径互证；**唯一还挂着的**就是"78 MB 层的冷下行耗时/成功率"。

**顺手修了一个坏读数**：C2 原先 `grep '"id":"sha256:<64>"'` 恒为 0（crictl 的 JSON 带空格缩进，模式没命中），
改成按默认表格第 3 列取 IMAGE ID 再去重，并在本地用合成样本验证过去重语义。旧的 `0` 不作为任何结论的证据。

**要真正闭合这条，只有三条路（都超出「可以的」那句授权范围，故未擅自动手）**：

| 路径 | 代价 | 判断 |
|---|---|---|
| ① 推一个新 digest（改一行代码重新构建出一个从未上过该节点的图片） | 要过 CI/ACR 构建，可能产生构建与存储费用；属"产生费用的操作" ⇒ 需明确核准 | 最干净，但要花钱且为此专门发版不值 |
| ② 在节点上 `crictl rmi` 掉现有缓存再做冷拉 | **破坏性**：两个在跑的负载一旦 Pod 重建/节点重启就得跨区重拉，把"缓存兜底"这层被动安全主动拆掉 | 不建议在 dev 上为了一个数字这么干 |
| ③ 等下一次真实版本 bump | 零额外动作、零费用：新 digest 天然就是冷拉，`Pulled in Xs` 事件会自动给出数字 | **推荐**。把这条挂成"下一次发版顺带采集" |

**当前 ns 终态不变**：`new-api-dev` 1/1、`fanyan-new-api-master` 1/1，两者同 SA（`new-api-app`）同 dev 命名空间，
`newapi-prod/*` 在 dev ns 内仍无引用。本轮**未对集群做任何写入**。
