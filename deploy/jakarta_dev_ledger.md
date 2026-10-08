# 雅加达 dev 环境台账（newapi-dev / 方案 A）

> 建台账口径与 `eip_ledger.md`、`nodepool_ledger_sg.md` 一致：只记录**实测回读值**，不记录计划值。
> 依据 `任务45环境隔离修订_2026-09-29.md` §5.3 / §7。执行时间 2026-09-30（UTC+0），操作身份 `ram-user yanxuewei`，账号 `5108890064395960`，全程 WSL Ubuntu。

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

脚本：`deploy/realign_jakarta_dev_cidrs.sh`（对齐已执行完毕，重跑会在占用性守卫处中止）；`deploy/provision_jakarta_dev_net.sh`（幂等，已按新偏移回写，重跑=只读校验+补齐，含 CIDR/AZ 漂移检测）

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

⚠ **对齐前的那套 CIDR 已不可回滚**：§10 的「删 7 建 7」是单向操作，旧七段的 ID 已销毁。若要恢复到对齐前的布局，只能再执行一轮同规格的删建（把 `realign_jakarta_dev_cidrs.sh` 里的 `TARGET` 换成旧 CIDR 表），成本仍为零，但会再次改变全部资源 ID —— 届时必须先确认没有任何资源绑定。

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
2. **生产两站点偏移逐槽同构**（pub=.0/.1 的 /24、app=16/32 的 /20、data=48/64 的 /20），dev 不同构：app 段占了 `10.2.0.0/20` 这个 pub 槽，pub/data 顺延到 48/49/64/80。vSwitch 的 CIDR 与可用区均不可修改，对齐只能删建；七段当时全部零绑定（可用 IP = 满值，仅系统路由表关联，无网络 ACL），所以**只有那时能免费做**，ACK / RDS 一落地就永久锁死。方案与脚本见 `deploy/realign_jakarta_dev_cidrs.sh`（Step 0 会逐段复校占用，非满即 ABORT）；**已于 2026-09-30 经项目负责人核准执行完毕，全过程见 §10**。

另记一处命名事实：生产 VPC 实名带 `newapi` 段（`vpc-newapi-mnl-prod` / `vpc-newapi-sg-prod`，形态为 `vpc-newapi-<site>-<env>`）。负责人 2026-09-30 定口径：dev 也按同构形态走，VPC 已改回 `vpc-newapi-jkt-dev`（见 §10）；vSwitch / SG 仍保持 §7 确立的 `vsw-jkt-dev-<role>-<az>` / `sg-jkt-dev-app` 形态，因为生产侧这两类资源的名称本身就不带 `newapi` 段。

## 10. 偏移对齐「删 7 建 7」（2026-09-30，已核准执行，零成本）

**授权记录**：负责人原文「雅加达需要偏移对齐，可以删 7 建 7。 生产 VPC 实名带 newapi，这次我先关闭了excel」—— 明确批准破坏性删建，并给出 VPC 命名口径；写表前已实测 `~$` 锁文件不存在（`NO_LOCK`）。

执行前守卫（逐段，非满即 ABORT）：七段可用 IP 实测 pub 252/252、其余 4092/4092，即**零资源绑定**（`AvailableIpAddressCount == num_addresses - 4`；四个保留地址是系统网关/广播/保留位，属正常，不是占用）。

### 10.1 执行时间线（含一次真实故障与恢复）

1. `bash deploy/realign_jakarta_dev_cidrs.sh`：Step 0 逐段复校通过 → 删除 7 段 → 依次建成 `pub-5a`、`pub-5b`、`app-5a`、`app-5b`。
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

方案表同步：sheet「网络与安全规划」R18–R25 + R62 共 17 个单元格按新偏移重写，旧 vsw-id 残留 **0** 处；改前快照 `菲律宾部署方案-v2.3-修订版.xlsx.bak-before-realign`，校验后包内仅 `xl/worksheets/sheet5.xml` 变化、64249 字节。脚本同步：`realign_jakarta_dev_cidrs.sh` 头部标注已执行 + 只读复查命令；`provision_jakarta_dev_net.sh` 的 `VPC_NAME` / `VSWITCHES` / `APP_CIDRS` 全部按新偏移回写，并新增复用分支的 CIDR/AZ 漂移检测（`bash -n` 通过）。

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
