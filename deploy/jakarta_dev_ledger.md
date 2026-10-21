# 雅加达 dev 环境台账（newapi-dev / 方案 A）

> 建台账口径与 `eip_ledger.md`、`nodepool_ledger_sg.md` 一致：只记录**实测回读值**，不记录计划值。
> 依据 `deploy/docs/任务45环境隔离修订_2026-09-29.md` §5.3 / §7。执行时间 2026-09-30（UTC+0），操作身份 `ram-user yanxuewei`，账号 `5108890064395960`，全程 WSL Ubuntu。
> **2026-10-17 增补 §11.2.1**：dev 节点池漂移更正——实测 `auto_scaling.enable=false + desired_size=4`（固定 4 台在计费，非上文所记 2 台）、单节点 Pod 上限 15 的机型 ENI 来历、以及 `Account.Arrearage` 导致 9 次扩容静默失败。取证脚本 `deploy/scripts/jkt-dev-recon.sh`，整改脚本 `deploy/scripts/jkt-dev-remediate.sh`。同日追加两项优化的核实结论（降 requests 的前提不成立、定时伸缩只能用 ACK `desired_size`），**均为结论、未执行写操作**，见该文档 §七。
> **同日 18:0x 再增补 §11.2.2**：负责人已重建节点池为 `np-jkt-dev-x4c`（单一 `ecs.g9i.xlarge`、`min=max=2`、按量）⇒ **§11.2.1 与文档 §七 的整改项全部作废**，只留作取证过程。新增「按量 vs 包年包月 vs 抢占式」的 `DescribePrice` 实测对比（1 年包每台 95.83 USD/月，**省 39%**，2 台年省约 1,473 USD）与官方转换约束。**同样未执行任何写操作。**

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
| `ecs.g9i.large` + 40G ESSD **包月（预付）** | **66.41 USD/月**（Original=Trade，USD） | 与文档 §6 一致。⚠ **这是包年包月预付价，不是按量单价**：2026-10-17 复算 `DescribePrice --PriceUnit Hour` = **0.112728 USD/h ⇒ 82.29 USD/月**（×730h）。本节下文与 11.2.1 用 66.41 估「按量在计费」的节点月费，一律低估 **19.4%** |
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
                                          ← 计划值，已过时：实测固定 4 台 ≈265.64/月，见 11.2.1
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
| 节点池 | `np-jkt-dev-app` / `npd3cc9d7f0503472f85420d30436269b5` / ESS `asg-k1a59qtckc246wh9r3ay` —— **⚠ 2026-10-17 18:0x WIB 复看：该池已不存在（`ErrorNodePoolNotFound`），现池见 11.2.2 `np-jkt-dev-x4c`** |
| 伸缩 | **⚠ 2026-10-17 实测：`auto_scaling.enable=false` + `scaling_group.desired_size=4` ⇒ 固定 4 台常驻，`min/max` 已不生效。** 建池参数为 `min=1 / max=3`（仓库 `ack_jkt_dev_nodepool.json` 至今仍写这组值，属漂移）、`multi_az_policy=BALANCE`、机型 `ecs.g9i.large` / `g8ine.large` / `g9ae.large`、系统盘 `cloud_essd 40G`、`PostPaid`、`internet_max_bandwidth_out=0`（节点无公网 IP，出网走 NAT）、无 SSH 密钥（运维入口用云助手，见 11.5）。另注：`desired_size=4 > max_instances=3` 本身自相矛盾，只有固定容量模式才允许这么写，说明这条池子被控制台改过而未回填 |
| 稳态节点 | **2026-10-17 实测 4 台**（原记「2 台」已过期，见 11.2.1）：`i-k1afy1aqgdl8rwa9gxvf` `g9i.large` 5a `10.2.25.174`；`i-k1ab0p31qirf7ejgdsg9` `g9ae.large` 5b `10.2.36.199`；`i-k1ahsgvna3udifwksje5` `g9i.large` 5c `10.2.90.153`（10-14 09:29Z）；`i-k1afs8wedv35k7z56g1g` `g9i.large` 5c `10.2.90.163`（10-17 00:37Z） |

**必须记账的费用偏差（建池当日，2026-09-30）**：原估「稳态 ≈110 USD/月」按 **1 台节点** 计。实测伸缩链路为 `0→1`（min 兜底，10:12:49）→ `1→2→3`（autoscaler 因 pending 的 `coredns` 跨可用区打散，10:13:22 同一秒内连加两台，顶到 max）→ `3→2`（10:24:19 autoscaler 回收唯一那台「只有 DaemonSet」的空节点）。**建池当日稳态是 2 台，不是 1 台**（该结论已被 11.2.1 推翻，现为 4 台）：

```
节点：2 × 66.41 ≈ 132.82 USD/月（原估 66.41）
      ⚠ 2026-10-17 复算更正：节点是 PostPaid，按量单价 0.112728 USD/h ⇒ 82.29/台/月
        ⇒ 按量实际 2 × 82.29 ≈ 164.6 USD/月；66.41 是包月预付价，只适用于「已转包年包月」之后
RDS ：43.38 USD/月
NAT + EIP：按量，CLI 无法报价（CU + 出向流量），保守另计
⇒ 稳态 ≈ 176 USD/月 + NAT/EIP，比授权口径高约 66 USD/月
```

要把节点压回 1 台，当时给出两条路：① 节点池 `vswitch_ids` 收到单可用区（牺牲 AZ 冗余，coredns 打散约束自然满足）；② 保留 2 台但接受预算上修。**⚠ 这条「当前状态是 2 台在计费」已过时——2026-10-17 实测为 4 台在计费，见 11.2.1。**

#### 11.2.1 2026-10-17 漂移更正：固定 4 台 / 单节点 Pod 上限 15 / 欠费导致扩容静默失败

触发：看 ACK 控制台发现 4 台 2C8G 节点物理 CPU 仅 3.95%~4.95%、内存 14.9%~18.5%，而每台 Allocatable Pod 固定 15，调度器内存 Request 已 ~~83%~~（**16:0x 带口径复看更正：节点池大盘「内存 request 利用」实为 47.5%／CPU 45.9%，真实使用率 2.9%；83% 口径不明，见该文档 §7.2**）（实际使用 4.27%）。全程 `Describe*` 只读取证，脚本见 [deploy/scripts/jkt-dev-recon.sh](scripts/jkt-dev-recon.sh)，整改脚本见 [deploy/scripts/jkt-dev-remediate.sh](scripts/jkt-dev-remediate.sh)，完整报告见 [docs/雅加达dev集群空转与Pod上限_取证与整改_2026-10-17.md](docs/雅加达dev集群空转与Pod上限_取证与整改_2026-10-17.md)。

**⚠ 16:0x 控制台复看（D 级目视，待 OpenAPI 复算）**：**期望节点数 3／集群实际 2 台／按量 2 台**（本节上文 API 实测是 `desired_size=4`／4 台）。⇒ 期望值在两小时窗口内被改过、节点在掉，且**余额恢复后 ESS 会再弹一台回 3**（§11.2.1 那 9 次失败的同机制）。这是当前比任何 request 调整都优先的一条。

三条更正（均以 OpenAPI 现值为准，覆盖本节上文）：

| 项 | 上文原记 | 2026-10-17 实测 |
|---|---|---|
| 伸缩方式 | 弹性伸缩 `min=1/max=3` | **`auto_scaling.enable=false` + `desired_size=4`，固定 4 台**；min/max 是死字段 |
| 节点数 | 稳态 2 台（10-14 又加 1 台） | **4 台**：两台有 `k8s.io/cluster-autoscaler` 标签（建池期 autoscaler 产物），两台无（期望容量补货产物） |
| 节点月费 | ≈132.82 USD | **4 × 66.41 ≈ 265.64 USD/月**（按量口径应为 4 × 82.29 ≈ 329.2，见 §11.2 复算更正） |

**Pod 上限 15 的来历（不是配额，是机型 ENI 硬限）**：本集群为 Terway 共享 ENI 模式（11.2 已记 `addons=[terway-eniip]`、无 overlay `container_cidr`），每个 Pod 占一个 ENI 辅助私网 IP，官方限额公式：

```
单节点最大 Pod 数 = (EniQuantity − 1) × EniPrivateIpAddressQuantity + hostNetwork Pod 数
ecs.g9i.large / g9ae.large = (3 − 1) × 6 + 3 = 15      ← 与控制台一致
```

- 改 kubelet `maxPods` **提不上去**：官方明确「使用节点 ENI 的 Pod 限额由节点规格决定，maxPods 只影响 hostNetwork Pod」。
- Terway 要求单节点 Pod 限额 >11 才能入集群 ⇒ 2C8G 的 `large` 档本身就贴着下限，是选型问题而非配置问题。
- 实测四台节点**辅助 IP 全为 0**，即 Pod 数远未接近 15 ⇒ **Pod 上限不是当前瓶颈**，不要为提高它而扩容。
- 三条 vSwitch（app 三段 `/20`）可用 IP 各 4074~4081 ⇒ 排除子网枯竭。

**最重要的一条：欠费会让扩容在 K8s 侧完全静默。** 伸缩活动记录显示 `2026-10-16T15:35Z → 23:37Z` **连续 9 次** `Add "1" ECS instance` 失败，错误码一律 `Account.Arrearage`（"Your account has an outstanding payment."），到 `2026-10-17T00:37Z` 余额恢复到 2,429.77 USD 后第 10 次才成功——这台就是控制台调度图 ~08:30（雅加达本地 08:37）台阶的来源。K8s 侧没有 Event、没有 Pending 报警，只能从 `ess DescribeScalingActivities` 看到。**余额预警必须独立成一条告警，不能依赖集群侧监控。**

**提高 Pod 上限的可行机型（含库存核实）**：

```
ecs.g8ine.large   2C8G  3 ENI × 10 IP ⇒ 23 Pod   5a NO_DATA / 5b Available / 5c NO_DATA  ✗ 不可用
ecs.g9i.xlarge    4C16G 4 ENI × 15 IP ⇒ 48 Pod   5a/5b/5c 全 Available                    ✓ 推荐
ecs.g9ae.xlarge   4C16G ——                      ⇒ 5c NO_DATA                              ✗
```

⇒ 与马尼拉「g8i 全系未上架」同类：**候选机型必须先跑 `DescribeAvailableResource` 再进 BALANCE 列表**，否则无货可用区会持续扩容失败。推荐路径是「4 台 `large` → 2 台 `g9i.xlarge`」：总算力持平（8C32G）、月费基本不变，但单节点 Pod 上限 15→48、节点数减半、DaemonSet 与节点预留开销减半。

**尚未做、需本人拍板**：① 固定几台 / 是否恢复弹性伸缩（恢复会重新引入上文的 coredns 跨 AZ 顶 max 问题）；② 是否换 `g9i.xlarge`（需滚动替换时间窗）；③ 余额告警接云监控站点监控还是邮件闸门。`deploy/ack_jkt_dev_nodepool.json` 的 `auto_scaling` 段仍是建池值，**本轮未回填**。

**2026-10-17 追加两条官方核实（A 级，尚未执行任何写操作）**：

- **定时伸缩与弹性伸缩互斥，且 ESS 侧那条路是官方高危**。官方《使用须知及高危风险操作说明》列「修改 ESS 伸缩组的最大或最小实例数」为「可能导致扩缩容异常」、「对开启自动伸缩的节点池进行手动扩容或缩容」为「结果与期望不符、**不可恢复**」；《手动扩缩容节点池》/《节点与节点池 FAQ》均要求「请勿直接操作节点池相关的伸缩组」。⇒ 节点池级定时伸缩只能用 ACK 自己的 `ModifyClusterNodePool scaling_group.desired_size`（该字段官方语义：「节点池应该维持的总节点数量……建议至少配置 2 个节点，以确保集群组件正常运行」），**夜间缩到 1 台属官方不推荐档**；ACK 无节点池级原生 cron（定时类方案 CronHPA/AHPA 都在 Pod 层）。上文 ① 因此变为二选一。
- **「按 P95 下调 requests 消除假扩容」不成立，两条理由**（原文见 [docs/…取证与整改_2026-10-17.md](docs/雅加达dev集群空转与Pod上限_取证与整改_2026-10-17.md) §7.2）：① 实测 `auto_scaling.enable=false` ⇒ autoscaler 不在场，request 占比不会触发任何扩容；② 带口径的大盘复看显示**内存 request 利用实为 47.5%**（不是 83%），本来就低于 50% 目标；而 ACK 自己的资源画像给出的**推荐值 5.39 GiB 反而高于当前申请 3.6 GiB**，方向存疑。⇒ 在按 §7.6 复算口径之前不动 request。request 里另有约 3~3.4 GiB 是 kube-system 组件、每台付一份、不可压缩 ⇒ 省钱主线是换 `g9i.xlarge` 让节点减半，不是调 request。

#### 11.2.2 2026-10-17 18:0x WIB（11:08 UTC）复看：节点池已被重建 + 计费方式单价实测

负责人直接重建了节点池并换机型 ⇒ 上一条（11.2.1）的整改项与配套文档 §七 的 P0–P6 **全部作废**，保留作过程记录。本节只记两件事：新池的实测回读，和「按量转包年包月能省多少」的官方报价实测。**全程 `Describe*` 只读，未执行任何写操作。**

**节点池实况（C 级：`cs DescribeClusterNodePools` + `cs DescribeClusterNodes` + `ecs DescribeInstances`）**

| 项 | 值 |
|---|---|
| 节点池 | `np-jkt-dev-x4c` / `np72446b422a6441c0bc96762a796aed26`（`type=ess`） |
| 旧池 | `np-jkt-dev-app` / `npd3cc9d…6269b5` → **`ErrorNodePoolNotFound`**；伸缩组 `asg-k1a59qtckc246wh9r3ay` 随之失效 |
| 伸缩组/配置 | `asg-k1adh3qjtrpnr4gnzfs1`（`LifecycleState=Active`、`DesiredCapacity=null`、`Min=Max=2`、`Total=Active=2`）/ 伸缩配置 `asc-k1ahcn6v6rivopmjugy6`（`InstanceType=[ecs.g9i.xlarge]`、`SpotStrategy=NoSpot`、系统盘 `cloud_essd`） |
| 机型 | **单一 `ecs.g9i.xlarge`**（4C16G）⇒ 换到了 Pod 上限 48 那一档；「掺回 large 规格会掉到 15 Pod/台」的风险随单机型消失 |
| 伸缩 | `auto_scaling.enable=true`、**`min_instances=2` / `max_instances=2`** ⇒ 等效钉死 2 台。`desired_size=null`（走自动模式），11.2.1 那条「期望 3 / 实际 2、余额恢复即弹回」的漂移**不再存在** |
| 付费类型 | `instance_charge_type=PostPaid`；两台实例 `ExpiredTime=2099-12-31T15:59Z`、`SpotStrategy=NoSpot` 互证确为按量 |
| 系统盘 | `cloud_essd` 40G（与旧池一致） |
| 节点 | `i-k1afs8wedv35rai4pmx2`（5a）、`i-k1aen3t7wrqv5j66uzj8`（5c），均 `Running`，AZ 冗余保住 |
| 余额 | `bssopenapi QueryAccountBalance` → **AvailableAmount 2,413.11 USD**（10-16 的 `Account.Arrearage` 已解除） |
| 仓库 JSON | ✅ **已回填且与 OpenAPI 一致**：[deploy/ops/jkt_nodepool_x4c.json](ops/jkt_nodepool_x4c.json) 与现池 **12/12 字段比对全一致**（`instance_types=[ecs.g9i.xlarge]`、`instance_charge_type=PostPaid`、`system_disk_category/size=cloud_essd/40`、`multi_az_policy=BALANCE`、`image_type=AliyunLinux3ContainerOptimized`、`internet_max_bandwidth_out=0`、三段 `vswitch_ids`、`auto_scaling.enable/min/max/type = true/2/2/cpu`）。⇒ 本轮三源漂移**已闭合**（台账＋仓库 JSON＋OpenAPI 同向）。旧的 `deploy/ack_jkt_dev_nodepool.json` 描述的是**已删除的旧池**（`min=1/max=3`＋三机型），属死引用，别再拿它做漂移对比 |

**计费方式单价实测（C 级：`ecs DescribePrice --RegionId ap-southeast-5 --ResourceType instance --InstanceType ecs.g9i.xlarge --SystemDisk.Category cloud_essd --SystemDisk.Size 40 --InternetChargeType PayByTraffic`）**

按量单价 **0.215328 USD/h**（实例 0.2052 ＋ 系统盘 0.010128）⇒ 月化 ×730h = **157.19 USD/台**，年化 ×8760h = 1,886.27 USD/台。

| 方案 | API 报价/台 | 折月/台 | 每台月省 vs 按量 | 2 台月费 | 2 台年省 | 一次性预付 |
|---|---|---|---|---|---|---|
| 按量（现状） | 0.215328/h | 157.19 | — | 314.38 | — | 无 |
| 包月 1 个月 | 126.73 | 126.73 | 30.46（19.4%） | 253.46 | 731 | 253.46 |
| 包月 3 / 6 个月 | 380.19 / 760.38 | 126.73 | 19.4%（**折月完全相同 ⇒ 中期包无叠加折扣**） | 253.46 | 731 | 760.38 / 1,520.76 |
| **包年 1 年** | 1,149.94（折 370.82） | **95.83** | 61.36（**39.0%**） | **191.65** | **1,472.7** | **2,299.88 ＝ 余额的 95%** |
| 包年 2 年 | 1,848.04 | 77.00 | 80.19（51.0%） | 154.00 | 1,924.6 | 3,696.08（需充值） |
| 包年 3 年 | 2,172.38 | 60.34 | 96.85（61.6%） | 120.68 | 2,324.4 | 4,344.76（需充值） |
| （参考）抢占式 | 0.051168/h | 37.35 | 119.84（**76.2%**） | 74.70 | 2,876 | 无，但会被回收 |

> 对照：11.2 的 66.41 是 `g9i.large` 的**包月预付价**，其按量单价为 0.112728 USD/h ⇒ 82.29 USD/月。此前按 66.41 估的按量月费（132.82 / 265.64）**一律低估 19.4%**。

**break-even（比折扣更该看）**：包年包月只在「真 7×24 常驻」时才划算。用按量小时价 0.215328 除过去 ⇒ 1 年包需每月跑 **≥445 h（占全月 61%）** 才比按量便宜，3 年包 ≥280 h。当前 `min=max=2` 属常驻，条件成立；若日后回到「夜间关机 / 缩到 1 台」，包月会把那部分收益直接抵消，且已付的钱退不回来。

**转换前必须认的官方约束（A 级）**

1. 「**修改节点池的付费类型仅对扩容的新节点生效，不会改变节点池内已有节点的付费类型**」⇒ 要真正省钱得走两条腿：节点池改 `PrePaid` ＋ 购买时长/自动续费，**存量 2 台另需在 ECS 控制台批量「按量付费转包年包月」**（ACK《接入云上 ECS 算力》《创建与管理节点池》）。
2. 「将 ECS 实例从按量付费转为包年包月时，**请勿勾选「转为包年包月磁盘」**。包年包月云盘无法支持容器应用重启，可能会影响业务运行」（ACK《计费 FAQ》《云产品资源费用》）⇒ 只转实例，系统盘保持按量。
3. 「（包年包月实例）到期前，**需要将实例转换为按量付费实例后才能释放**」＋「到期后未在指定时间内续费，实例将自动释放」（ECS《计费方式概述》、ACK 费用文档）⇒ dev 的换机型/缩台/重建自由度会明显下降；刚做过一次换机型，这条要重点权衡。
4. 「为保证节点池统一，**不支持将按量付费、包年包月节点池修改为抢占式实例节点池，反之亦然**」⇒ 抢占式那条路只能新建池。
5. 集群管理费不受影响（本集群 `ack.standard` 基础版为 0）；CLB 自 2024-12-01 起不再支持按量转包月。
6. 当前 `min=max=2`，「包月妨碍自动缩容」这条暂不成立；但一旦放开 `min<max`，包月节点已付过钱、缩容不退款。

**结论（未执行）**：能确定这 2 台至少用一年、机型不再动 ⇒ 转 **1 年包**，2 台 191.65 USD/月、**年省约 1,473 USD（39%）**，但需一次预付 2,299.88（余额的 95%）。若还要保留折腾空间 ⇒ 维持按量，另用**节省计划**抵扣（官方推荐组合，不绑机型规格；本账号折扣报价未取得，需在费用中心测算页看）。3 年包年省 2,324（61.6%）但锁死且要充值，不建议给 dev。

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
## 14. 新负载 `new-api-dev-slave` 拉不到镜像 —— 「凭据晚于 Pod 创建」时序坑（2026-10-14）

### 14.0 现象

控制台手建的 `deployment/new-api-dev-slave`（ns `newapi-dev`，建于 **17:46:30 HKT**）0/1，
Pod `new-api-dev-slave-548745dc66-dx7js` 报：

```
failed to resolve reference "acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-master:20261012-a8e646954":
  ... pull access denied, repository does not exist or may require authorization:
  server message: insufficient_scope: authorization failed
```

同 ns、**同镜像同 tag** 的 `new-api-dev`（SA=`new-api-app`）22 分钟前刚拉成功 ⇒ 先排除"tag 不存在 / 网络不通"。

### 14.1 根因（两层，均为实测）

| 层 | 事实 | 证据 |
|---|---|---|
| ① 该负载没指定 SA ⇒ 落到 `default` | 模板 `serviceAccountName` **缺键**（`<no value>`），Pod 解析为 `default`；而 helper **安装时**的 `serviceAccount` 只有 `new-api-app`（台账 §12.5 V8 / §13.2 D4）⇒ `default` 上无凭据 ⇒ 匿名拉私有库 | 旧 Pod `sa=default  pullSecrets=[]`；对照 Pod `sa=new-api-app  pullSecrets=[acr-credential-secret-aggregation]` |
| ② helper 配置被改，但**凭据挂载晚于 Pod 创建** | 负责人 **17:14:53** 重提 helper 配置（ActionTrail `InstallClusterAddons` / `CS` / `yanxuewei`），`serviceAccount` 变为 **`new-api-app,default`**（并带入控制台占位符 `notifyEmail: xxx@aliyun.com`）。该改动确实让 `default` SA 拿到了 `acr-credential-secret-aggregation` —— **但该 Pod 建于 17:46:30，其 `spec.imagePullSecrets` 已由 ServiceAccount 准入控制器在创建那一刻固化为空数组，而 Pod spec 不可变** ⇒ 这个 Pod 永远读不到凭据 | ① 同 SA、同镜像，**只重建 Pod 即通**（14.3）；② helper 的 Secret 最近一次刷新 `09:54:06Z` > Pod 创建 `09:46:30Z` |

⇒ 一句话：**「SA 上有没有凭据」不是判据，「凭据挂上时 Pod 建没建」才是。** 这是台账 §13 坑 16 的反向版本
（§13 是"Secret 存在 ≠ Pod 拿得到"，本节是"SA 后补了凭据 ≠ 老 Pod 能拿到"）。

### 14.2 helper 线上配置回读（`cs GET /clusters/<cid>/addon_instances/managed-aliyun-acr-credential-helper`）

```
AcrInstanceInfo=[{cri-avfqy9xkqi5bj8ee, ap-southeast-6}]  enableRRSA=false  expiringThreshold=15m
serviceAccount="new-api-app,default"          ← 安装时为 "new-api-app"
watchNamespace="newapi-dev"   state=active  version=v24.01.29.1-5318af4-aliyun
notifyEmail="xxx@aliyun.com"                  ← 控制台表单占位符，非真实邮箱
```

> 注：`GET /clusters/{id}/addon_instances` **不返回 config**；要带组件名走 REST 子路径才有。`DescribeAddonInstance` 等
> 三个具名 API 在 CLI 3.5.1 里**元数据缺失**（报 `invalid flag --ClusterId`）。

### 14.3 修复与回读（唯一写入 = 一次 rollout restart）

```
X0  before: pod …-548745dc66-dx7js  sa=default  pullSecrets=[]        ready=/1
    闸门  : default.imagePullSecrets=[acr-credential-secret-aggregation]（非空才动手）
X1  deployment.apps/new-api-dev-slave restarted
X2  after : pod …-c8c976556-7bnrf    sa=default  pullSecrets=[acr-credential-secret-aggregation]   ← 决定性
X3  rollout_rc=0   deployment "new-api-dev-slave" successfully rolled out
X4  ready=1/1  updated=1
    pod …-c8c976556-7bnrf  phase=Running  ready=true  restarts=0
    imageID=…/newapi-dev/newapi-master@sha256:829a4277fe4791dc341ce759f9a4d5d2008d949f28109b547327872fd510fff0
    事件：Pulled "…" already present on machine and can be accessed by the pod
```

**证据边界（与 §13.9 同）**：本次 `already present on machine` ⇒ 仍是**节点缓存命中**，没有做"冷缓存 78 MB 跨区全量下载"的耗时/成功率验证；该未证项仍按 §13.10 挂"下一次发版顺带采集"。

### 14.4 本卡产物

- 新增 `deploy/jakarta_dev/bodies/fix_pull_restart.sh`：**只重建 Pod**，不动任何 spec。
  闸门：`TARGET` 必填、不得为 `new-api-dev`、且解析出的**实际生效 SA** 必须有免密 Secret（否则提示改走 `--fix-pull-sa`）；
  现存 Pod 已带凭据则**幂等退出**。默认 `APPLY=0`（只出计划），`APPLY=1` 才真做。
- `deploy/jakarta_dev/dev_deploy.sh`：新增 `--fix-pull-restart <deploy>` 分发，并纳入 `--render-check`。
- 取证脚本：`deploy/logs/t_jkt_slave_diag{,2}.sh`、`t_jkt_slave_spec.sh`、`t_jkt_trail{,2}.sh`。
- 用法：`bash deploy/jakarta_dev/dev_deploy.sh --fix-pull-restart <deploy>`（计划）
  / `APPLY=1 bash deploy/jakarta_dev/dev_deploy.sh --fix-pull-restart <deploy>`（落地）

### 14.5 遗留（待负责人裁定，均未动手）

1. ~~**`SQL_DSN` 取值与该负载的角色不符**：`NODE_TYPE=slave` 但 `SQL_DSN ← secretKeyRef/new-api-secrets[SQL_DSN_MIGRATE]`~~ ⇒ **2026-10-15 复核已不成立**：控制台手建负载期间已把 secretKeyRef 改为 `key=SQL_DSN`（实测回读 deploy 与 Pod 双规格一致），结合 §16.2 的 Secret 切 6432，slave 主库已经池（@6432），与"slave 不该拿 DDL 账号"的最小化口径同时闭合。
2. **helper 把 `default` 圈进作用域的影响面**：好处是控制台手建负载不再必然拉不到镜像；代价是 `newapi-dev` 内
   **任何**用 `default` SA 的 Pod（含一次性调试 Pod）都拿到 **EE 实例级**凭据 —— §13.6 已证该 token 覆盖
   `cri-avfqy9xkqi5bj8ee` **全部命名空间（含 `newapi-prod`）**，且 §12.8-4 的公网 ACL 仍未收口。保留 or 回收由负责人定。
3. `deployment/new-api-dev-slave` 模板标签是 `app=new-api-dev-slave`，**没有任何 Service 选中它**（ns 内只有
   `service/new-api-dev`，selector 为 `app=new-api, track=dev`）⇒ 它当前不对外提供入口；若本意是要承接流量，需要补 Service / Ingress。

## 15. dev Tair（Redis）初始化与接线（2026-10-15，参照生产任务 7 口径）

> 执行参照：指南 v2.0「Day 1 · 任务 7｜Tair 主备 4GB」+ 本台账 §12 的 dev 通道。证据：`deploy/logs/tair_jkt_dev_20261015/`。

### 15.1 实例实测回读（负责人控制台自建，本卡只做初始化，未建实例）

| 项 | 实测值 |
|---|---|
| 实例 | `r-d9j5iy2q82p1ugiwrt` / `tair-jkt-dev-newapi`（⚠ 截图辨认曾误作 `r-r9j5…`，以 API 回读为准） |
| 状态 | `Normal`（创建当天即就绪） |
| 架构 | `NodeType=double` 主备，**Zone 5a 主 / 5b 备**（雅加达支持多 AZ 主备，与马尼拉"不支持跨 AZ"不同，见 tair.sh 头注释） |
| 规格 | `tair.rdb.1g`（Tair 企业版内存型 5.0）/ **Capacity=1024MB** |
| 落位 | `vpc-k1ano67avx98nr3n1bg5d` + data-5a `vsw-k1a9u8pkwwkc6z0x6g0kc` + `rg-aek4hk3prqgqjcy`（rg-nonprod）——与 §10.4 下游参数契约一致 |
| 端点 | `r-d9j5iy2q82p1ugiwrt.redis.ap-southeast-5.rds.aliyuncs.com:6379`（内网，从连接信息回读，未手拼） |
| 付费 | `PrePaid` |

**与任务 7 的两处偏差（如实记录）**：
1. **规格 1GB，非任务 7 标题的 4GB**。dev 单人环境可接受（任务 7 坑 3 的"升集群版"更不适用）；上线后看 `INFO stats` 决定升配。
2. **实例由负责人控制台自建**（任务 7 是 CLI 建）⇒ 口令未经保管目录，本卡用 `ResetAccountPassword` 轮换后入库（`ResetPassword` 在 CLI 里不是合法 API，r-kvstore 里改口令走 `ModifyInstanceAttribute` / `ResetAccountPassword`；默认账号名 = 实例 ID `r-d9j5iy2q82p1ugiwrt`）。

### 15.2 四步初始化（全部云侧回读复核，非返回码）

| 步 | 命令 | 回读判据 |
|---|---|---|
| 参数 | `ModifyInstanceConfig`（tair.sh 实测口径，非 ModifyInstanceParameter） | `maxmemory-policy=allkeys-lru`；`#no_loose_disabled-commands=flushall,flushdb,keys` ✅ |
| 白名单 | `ModifySecurityIps --SecurityIpGroupName jkt_app --ModifyMode Cover` | `jkt_app = 10.2.80.0/20,10.2.16.0/20,10.2.32.0/20`（**仅 app 三段**，§8 契约；`default` 组保持 127.0.0.1 未动；`hdm_security_ips` 为平台内置）✅ |
| 口令 | `ResetAccountPassword`（19 位纯字母数字，URL 免转义） | 存 `/root/.deploy_secrets_dev/dev_redis` + `REDIS_CONN_STRING`（均 600，会话零明文）✅ |
| 接线 | `dev_deploy.sh --secret`（5 键）→ `--restart new-api-dev` | `secret/new-api-secrets configured`；`REDIS_CONN_STRING b64len=136`；`successfully rolled out`，ready=1/1 ✅ |

### 15.3 端到端验证（双口径）

1. **探针 Pod（`--redis-probe`，redis:7-alpine，secretKeyRef 注入，跑完即删）**：
   `PING→PONG`；`DBSIZE=1`；scan 出 **`rateLimit:v2:ip:GA:10.2.36.199`**（应用真实写入，与任务 29 新加坡 V2 同形状）；
   `CONFIG GET maxmemory-policy→allkeys-lru`（运行面复核）；`FLUSHALL→NOPERM`（禁用命令真生效）；
   `INFO stats：total_commands_processed=10080 / instantaneous_ops_per_sec=6`。
2. **应用面**：新 Pod `Running ready=true`，`New API ready in 1998 ms`，`/api/status` 探针 200（Pod 能起来本身就证明 Redis Ping 过了——`common/redis.go` 的 Ping 失败走 `FatalLog`）。

### 15.4 本卡产物与遗留

- 产物：`dev_deploy.sh` 加 `--restart <deploy>` / `--redis-probe` 两个子命令（APPLY=0 计划制，负载名必须显式给）；
  `bodies/rollout_restart.sh`、`bodies/redis_probe.sh`（均**零凭据 body**：探针口令经 secretKeyRef 进 Pod，不进命令体/节点 shell，§13.6 纪律）；
  `apply_secret.sh` 键列表 4→5 并加 `redis://` 前缀闸门（`common/redis.go:35` 只认 `ParseURL`，k/v 形态必 FatalLog——与 PG DSN 前缀坑同构）。
- 遗留：① `new-api-dev-slave` 同挂 `envFrom: new-api-secrets`，下次重启起也会启用 Redis（本卡未动它）；② 1GB 容量余量观察（`INFO memory`）；③ dev Tair 为包月，到期口径待与 §12.8-1（dev RDS 到期）一并裁定。

## 16. dev RDS 托管 PgBouncer 开启 + 参数对齐马尼拉 + DSN 切 6432（2026-10-15）

> 参照生产任务 41。证据：`deploy/logs/pgbouncer_jkt_dev_20261015/`。dev 实例是 **Basic 系列**——官方文档证实 PgBouncer 支持**基础系列与高可用系列**（PG 11+、内核 20240830+），Basic 不是障碍。

### 16.1 云侧（全部回读复核）

| 步 | 动作 | 判据 |
|---|---|---|
| 开启 | `ModifyDBInstanceConfig --ConfigName pgbouncer --ConfigValue true` | `PGBouncerEnabled=true`，16 条 `pgbouncer.*` 出现，实例全程 Running（无重启）✅ |
| 参数同步 | `ModifyParameter --Forcerestart false`（差异仅 4 项） | 回读 diff=0，**与马尼拉现网逐字一致** ✅：`default_pool_size 20→50`、`max_client_conn 100→2000`、`pool_mode transaction→session`、`stats_users ''→newapi_ops` |
| 连通 | `--pg-port-probe`（pg_isready，Pod 侧零凭据） | 5432 与 6432 双格 accepting ✅ |

两处实测坑：① CLI 里**没有**开 PgBouncer 的具名代理 API（`ModifyDBProxy` 系是 MySQL PolarProxy，对 PG 恒空——任务 41 坑 1 的同源结论），开启走 `ModifyDBInstanceConfig`；② `ModifyParameter --Parameters` 的**值必须全字符串**（数字字面量报 `InvalidParameters.Format`，与指南 3b 示例一致）。

⚠ **`pool_mode` 同步取的是马尼拉现网值 `session`**（10-12 已核实为 09-30 未登记云写；指南日常基线是 transaction、待兼容矩阵后热切）。dev 按"以马尼拉实况为准"同步；切回一条命令：`ModifyParameter --Parameters '{"pgbouncer.pool_mode":"transaction"}' --Forcerestart false`。

### 16.2 Secret 与负载（经云助手，APPLY 闸门制）

- 保管目录与集群 Secret 同步：`SQL_DSN`、`LOG_SQL_DSN` 端口 **5432→6432**；`SQL_DSN_MIGRATE` **保持 5432**（与生产 master 口径逐字同构：迁移账号不经池，`ph/master-deployment.yaml:100`）。
- `new-api-dev`、`new-api-dev-slave` 各一次 rollout restart → 均 `1/1 Running`。
- 三库冒烟（psql 用应用自己的 Secret）：`SQL_DSN(@6432 经池) tables=36`、`LOG_SQL_DSN(@6432 经池) tables=2`、`SQL_DSN_MIGRATE(@5432) tables=36`；S1/S2/S3 200、S5 权限链正常 ⇒ **经池链路真实生效** ✅。

### 16.3 生效面与遗留

- 本次切 6432 实际经池的是：两负载的**日志库**（LOG_SQL_DSN）+ Secret 的 `SQL_DSN` 键。master 主库 env 显式取 `SQL_DSN_MIGRATE`（5432 直连，生产口径：迁移账号不经池）。~~slave 主库仍取 MIGRATE 键~~ ⇒ **2026-10-15 补核：slave 的 secretKeyRef 已是 `SQL_DSN`（控制台侧改过，§14.5-1 同步订正），且其 Pod 晚于 Secret 切 6432 重启（startedAt 09:36:44Z）⇒ slave 主库经池已生效，无需任何写入**。回读：Pod `Running/ready/restarts=0`，`ready in 159 ms`，无 fatal。至此 dev 侧主库经池状态 = **master 直连（口径如此）/ slave 经池**，与生产 `ph/master-deployment.yaml`（master 直连、stable 经池）逐位同构。
- 产物：`dev_deploy.sh` 新增 `--pg-port-probe`（零凭据 body `bodies/pg_port_probe.sh`，pg_isready 双格预检）。
- dev 池参数随马尼拉联动：马尼拉侧任何 `pgbouncer.*` 变更后，dev 需同轮重发（本卡只做了一次性对齐，未建自动同步）。

## 17. dev OSS Bucket（`oss-newapi-jkt-dev`，镜像马尼拉、无 CRR）（2026-10-16）

> 参照任务 8（马尼拉 `oss-newapi-mnl`）逐项镜像；**用户要求不配跨区域复制**。证据：`deploy/logs/oss_jkt_dev_20261016/`。

| 项 | 实测值（全部 API 回读，非返回码） |
|---|---|
| 桶 | `oss-newapi-jkt-dev` / ap-southeast-5 / `rg-nonprod` / Standard / **ZRS** / ACL=private |
| 版本控制 | `Enabled` |
| 阻止公共访问 | `BlockPublicAccess=true` |
| 生命周期 | `newapi-version-cleanup`（删标记 + 非当前版本 30 天 + 分片 7 天；无降冷规则） |
| Bucket Policy | Allow 4 主体（admin/ops/cicd-push/iac-terraform）× `rds-backup/*`、`app-assets/*`（ListObjects 带 Prefix 条件）；**Python 生成，修正了马尼拉策略里 `$5108890064395960` 的 zsh 拼接残留** |
| CRR | **未配置**（`get-bucket-replication` ⇒ 404 `NoSuchReplicationConfiguration`） |
| 标签 | `env=dev` `project=new-api` `isolation=structural-vpc` |

验证：读写删冒烟全通（公网入口，AK）；dev Pod 内 `oss-ap-southeast-5-internal.aliyuncs.com` → **403**（TCP+TLS+HTTP 全通、匿名被拒=预期）；`ossutil` 在本机 `/usr/local/bin/ossutil`（2.2.1，凭据走 aliyun CLI 配置链，**不需要** `~/.aliyun/ossutilconfig`）。

两点与马尼拉的地域差异（记档防误判）：① 雅加达多可用区 ⇒ ZRS 桶允许降冷（马尼拉不允许）；本桶无降冷规则，属配置选择。② ZRS/LRS 创建后不可变更，若未来 dev 要省成本需删桶重建为 LRS（注意桶名删除后短窗口被占的 `BucketAlreadyExists` 教训）。

## 18. dev 图片桶 `dev-img-likha` + `dev-img.likha.hk`（2026-10-16）

> 镜像生产 `img-likha`/`img.likha.hk`（`deploy/docs/OSS静态资源域名img.likha.hk_配置与证书续期_2026-10-13.md`）。证据：`deploy/logs/oss_dev_img_20261016/`。

| 项 | 实测值 |
|---|---|
| 桶 | `dev-img-likha` / ap-southeast-5 / **public-read** / ZRS / Standard / **BPA=false**（显式关，坑 4.2）/ 标签 dev 三件套 |
| 自定义域名 | `dev-img.likha.hk`，Status=Enabled；CNAME → `dev-img-likha.oss-ap-southeast-5.aliyuncs.com`（RecordId 2111004321323668480）；归属 TXT `_dnsauth.dev-img`（RecordId 2111004166729911296，保留勿删） |
| HTTPS | `CertificateConfiguration.CertId=606823-ap-southeast-1`（`*.likha.hk` 通配符覆盖），list-cname 回读 Certificate 段齐全（Fingerprint 与生产绑定逐字一致，2027-04-28） |
| 端到端 | DNS 权威/公共递归一致；匿名 HTTPS 读 200 + 内容一致；不存在对象 404；匿名列举 403 ✅ |

**证书续签连带（已登记）**：`dev-img.likha.hk` 是 `606823` 证书的第 4 个落点——`deploy/cert/targets.yaml` 的 oss 目标 sites 扩为 2 个（image-static + dev-image-static），renew_action / R1 note / oss_note 同步改为双桶重绑；换新 CertId 时两桶都动，漏一个对应域名旧证到期当晚即失效。

与生产的差异：dev 桶无版本控制/生命周期/Bucket Policy（生产 img-likha 也没有这三项）；多打了成本标签。使用纪律同生产口径：**桶是公共读，不放敏感文件；只绑专用子域，绝不绑主域名**。

## 19. dev 个人域名 dev-yxw / dev-zzj / dev-xd（2026-10-16）

> 负责人需求：新增 3 个开发域名，DNS 参考 `dev` 记录；路由经确认按人指负载（`dev-yxw → yxw-new-api-slave`，`dev-zzj/dev-xd → new-api-dev-slave` 过渡）。证据：`deploy/logs/oss_dev_img_20261016/`（10-dns-*、11-routes-e2e.txt）。

**DNS**（likha.hk zone，alidns，与 `dev` 记录同值同 TTL）：
`dev-yxw` / `dev-zzj` / `dev-xd` 三条 CNAME → `alb-4okmogghe7hbv5fwm6.ap-southeast-5.alb.aliyuncsslbintl.com`（dev ALB `alb-newapi-jkt-dev`），RecordId `2111042095309275136` / `2111042099759426560` / `2111042103756663808`。

**路由**（dev ALB 443 监听 `lsn-22gsroti342rp3dvo4` 默认证 = 606823 `*.likha.hk` ⇒ 新子域 HTTPS 免换绑）：清单 SSOT = `deploy/jakarta_dev/dev_routes.yaml`（1 Service + 6 Ingress，apply 回读 created ×7）——

| 域名 | 80 | 443 后端 | 实测 |
|---|---|---|---|
| dev-yxw.likha.hk | 301 → 自身 https | `svc/yxw-new-api-slave`（新补 Service；该 deploy **replicas=0**） | https 503（无端点，扩副本即恢复） |
| dev-zzj.likha.hk | 301 → 自身 https | `svc/new-api-dev-slave`（过渡，等各自负载建好再切） | https **200** ssl=0 ✅ |
| dev-xd.likha.hk | 301 → 自身 https | `svc/new-api-dev-slave`（同上） | https **200** ssl=0 ✅ |
| dev.likha.hk（回归） | 301 | new-api-dev-slave | 200 未受影响 ✅ |

要点：① `fanyan-new-api-*` 已被控制台改名 **`yxw-new-api-master` / `yxw-new-api-slave`**（replicas=0、无 Service）⇒ 本卡补了 `svc/yxw-new-api-slave`（selector `app=yxw-new-api-slave`，port 80→targetPort http/3000）；dev-yxw 要通就把该 deploy 扩副本（其 SA=default，helper 已圈 default ⇒ 拉镜像通）。② redirect Ingress 的 `RedirectConfig.host` 是**硬编码**值 ⇒ 每个域名必须有自己的 redirect 件（不能共用 dev 那条，否则 301 会打到 dev.likha.hk）；order 用 2/3/4 与 51/52/53 与 dev 的 1/50 错开。


## 15. 四项裁定落地：DSN 收权 + dev.likha.hk 对外入口（2026-10-15，**已执行**）

负责人四项裁定：① DSN 过宽「需要改」② helper 保留 `default` 作用域（ACR EE 太贵，其它站点均经
外网从主站 EE 拉镜像）③ slave 要对外承接流量，买**一个** ALB ④ 加 `dev.likha.hk` 域名。

### 15.1 DSN 收权（已执行）

`deploy/jakarta_dev/bodies/fix_dsn.sh`：strategic-merge patch（env 按 name 合并，避免索引脆弱），
`SQL_DSN` 的 secretKeyRef.key **`SQL_DSN_MIGRATE` → `SQL_DSN`**。触发滚动重建，新 Pod
`7fd87f877d-n74bw` 1/1 Running（readiness `/api/status` 通过 = DB 连接正常），旧 Pod 终止。
已接线：`dev_deploy.sh --fix-dsn`（默认 APPLY=0 只出计划）。

### 15.2 ALB + Service + Ingress（已执行）

前置：jkt 集群**没有** `alb-ingress-controller`（重建时未随 addons 装，`ack_jkt_dev_create.json`
只装了 terway-eniip）→ 补装（task `T-6ad044c9871942010300010c`，state=active）。

| 构件 | 值 |
|---|---|
| ALB | **`alb-4okmogghe7hbv5fwm6`**（alb-newapi-jkt-dev，Internet，Active；DNS 名 `alb-4okmogghe7hbv5fwm6.ap-southeast-5.alb.aliyuncsslbintl.com`，公网 IP `147.139.241.96`(5a) / `8.215.59.192`(5b)） |
| zoneMappings | `vsw-jkt-dev-pub-5a`(vsw-k1at4vt7fg8v4umkh9lg3) + `vsw-jkt-dev-pub-5b`(vsw-k1aqa1ose29nuq92hcvyt) |
| 监听器 | 80 HTTP（idle 60/req 600）+ 443 HTTPS（`tls_cipher_policy_1_2_strict_with_1_3`，证书 **`606823-ap-southeast-1`** 跨地域复用，IsDefault） |
| IngressClass | `alb` → parameters AlbConfig `jkt-alb`（集群此前没有） |
| Service | `newapi-dev/new-api-dev-slave`（ClusterIP→3000，selector `app=new-api-dev-slave`，照抄生产 ClusterIP/ENI 型口径） |
| Ingress 80 | host dev.likha.hk → Redirect **301** → https（actions.redirect + use-annotation，order=1） |
| Ingress 443 | host dev.likha.hk `/` → svc:80（order=50） |

IaC 真源 **`deploy/jakarta_dev/dev_ingress.yaml`**（五构件一文件）；接线 `dev_deploy.sh --apply-ingress`
（载荷 INGRESS_B64，默认只 render 校验）。管理红线同生产：只经 AlbConfig/Ingress 管理，**AlbConfig 带
finalizer ⇒ `kubectl delete albconfig jkt-alb` 会级联删云上 ALB**。

### 15.3 DNS（已执行）

`dev.likha.hk` CNAME → ALB DNS 名，TTL 600，RecordId **`2110572139455158272`**。
`deploy/manifests/dns-likha-hk.sh` 已扩展 `TYPE=CNAME`（`RR=dev` 即管理 dev 记录）。
至此 likha.hk 记录 **9 → 10 条**。

### 15.4 验收（全部通过）

| 项 | 期望 | 实测 |
|---|---|---|
| 权威解析 | CNAME → jkt ALB DNS 名 | ns7/ns8 一致 ✅ |
| 递归解析 | A = ALB 双 AZ IP | 147.139.241.96 / 8.215.59.192 ✅ |
| https 443 | 200 | 3/3 200（双 IP 轮询，~1.1–1.4s）✅ |
| 证书 | `*.likha.hk` DV | `CN=*.likha.hk` / Aliyun RSA TLS DV G1 / verify ok ✅ |
| http 80 | 301 → https | `301 → https://dev.likha.hk/api/status` ✅ |
| 内容 | new-api | `/api/status` 返回正常 JSON ✅ |

### 15.5 新踩坑与遗留

- ★ **`aliyun cs POST /clusters/<id>/components/install` 必须 `--header "Content-Type=application/json"`**，
  否则报 `FAILED_TO_READ_REQUEST`（body 已正确给 JSON 也照样失败）——本仓首个 cs REST POST，与既有
  GET 用法不同。CLI 具名 `--addons` 在 3.5.1 不存在。
- **ALB 按量计费新账**：实例费 + LCU，dev 流量极小 ⇒ 预计每月个位数 USD；**§7.10 成本表尚未纳入**，
  下次跑 `gen_cost_table.py` 时需加一行（jkt ALB）。
- §13.10 的「跨区公网拉镜像冷缓存耗时」仍未验（本次 DSN 重建命中节点缓存）。
- helper 保留 `default` 作用域 = §14.5-2 的**既有裁定**（负责人 2026-10-15 确认），公网 ACL 收口仍挂账。
## 14. 任务 14：ns 内出现第二个负载 `new-api-dev-slave` —— 免密潜伏坑回归（2026-10-13）

**起因**：§13 结束后负责人把 `fanyan-new-api-master` 删了，但 ns 里多出一个**不是本卡产物**的
`new-api-dev-slave`（Deployment + 同名 Service，配额从 1/20 变 **2/20**）。
§12.5 的 V1–V11 是"单负载"时采的 ⇒ 必须回归，否则台账里的隔离证据与现状脱节。

**产物**：新增只读 body `bodies/ns_regression.sh` + `dev_deploy.sh --ns-regression`（进 `--render-check`，命令体 6.8 KB）。
途中修了自己写死的一处缺陷：body 里把负载名硬编码成 `new-api-dev / fanyan-…`，负载一删一多就查空 ⇒
N1/N2 全部改成**自动发现**（这本身是条通用教训：探测脚本不许写死被探测对象的名字）。

### 14.1 Service × Pod × Endpoints：没有串后端

```
svc/new-api-dev        sel={"app":"new-api","track":"dev"}      172.23.5.57:80   → 10.2.90.156 → pod/new-api-dev-594fdf5795-wxt49
svc/new-api-dev-slave  sel={"app":"new-api-dev-slave"}          172.23.7.101:80  → 10.2.36.215 → pod/new-api-dev-slave-7fd87f877d-n74bw
```
两个 selector 无交集，Endpoints 各自只有一个后端且归属正确 ⇒ §13 那类"手建负载误挂进 dev Service"的情况没有发生。

### 14.2 DSN 落点（V10 同口径，进程内实测，只打印 host/port/db）

| Pod | `SQL_DSN` | `LOG_SQL_DSN` | `NODE_TYPE` |
|---|---|---|---|
| `new-api-dev-…-wxt49` | host=`pgm-d9j9p421lzx4gw73…ap-southeast-5` db=`newapi` | 同实例 db=`newapi_logs` | **master** |
| `new-api-dev-slave-…-n74bw` | host=`pgm-d9j9p421lzx4gw73…ap-southeast-5` db=`newapi` | 同实例 db=`newapi_logs` | **slave** |

⇒ 两 Pod 全部只指向 dev 实例，无生产实例/生产网段；master/slave 角色分离正确。
键来源也符合生产形态：master `SQL_DSN ← Secret/SQL_DSN_MIGRATE`（迁移角色），
slave `SQL_DSN ← Secret/SQL_DSN`（应用角色）⇒ **slave 拿不到迁移角色的凭据**，这是对的。

### 14.3 本轮核心发现：`new-api-dev-slave` 正在重演 §13 的免密坑，只是还没爆

```
[new-api-dev]        sa=new-api-app   image=…/newapi-dev/newapi-master:20261012-a8e646954
[new-api-dev-slave]  sa=（=default）  image=…/newapi-dev/newapi-master:20261012-a8e646954   ← 同一个镜像、不同 SA
```
它现在能跑，**不是因为配置对，而是因为节点 content store 里已经有 `829a4277fe…fff0` 这一层**（§13.10 C1/C3 实测：
ns 里唯一的 ACR 镜像就是它）。一旦遇到 ①新 digest（下次发版）②扩容出的新节点 ③节点重装/缓存清理，
它就会精确复现 §13.2 那条 `pull access denied … insufficient_scope: authorization failed`，
而且因为发生在"要用的那一刻"，排查成本比现在高得多。这就是 §13.4 坑 16 的活体样本：
**Secret 在 ns 里 ≠ Pod 拿得到，免密只认 Pod 的 SA**。

修法与 §13.8 完全一致（`serviceAccountName: new-api-app`，helper 作用域不用动），一条 `--fix-pull-sa new-api-dev-slave` 即可，
属集群写入 ⇒ **未擅自执行，等负责人裁定**。

### 14.4 顺带两处与既定命名/隔离口径不一致（只记录，不改别人的对象）

- slave 的标签是 `site=jkt` + `track=stable`，master 是 `site=jkt-dev` + `track=dev`。
  负责人 2026-10-11 定的命名规则是「雅加达跟马尼拉保持一致，只在站点名后加 `-dev` 后缀」⇒ dev ns 里出现 `site=jkt`
  与生产同标，会污染以后按 `site` 做的成本/隔离归集；`track=stable` 在 dev 里也没有对应语义。
- slave 落在 `ap-southeast-5b`，master 在 `5c` ⇒ AZ 分散，这条是好事，记录备查。

### 14.5 其余回归项（无破口）

```
N3 两个负载都有 requests(200m/512Mi) 与 limits(1/1Gi)、readinessProbe=/api/status ⇒ 不是控制台裸建的那种空配置
N4 配额 pods 2/20，requests.cpu 400m/2，limits.cpu 2/3；kubectl top：两 Pod 各 1m CPU / 25-26Mi 内存
N5 V7 ns 内 Role+RoleBinding=0、引用 new-api-app 的 ClusterRoleBinding=0
   V8 免密 Secret 仍在 ns（helper 作用域未变，仍只点名 new-api-app）
   V9 逐 Secret 逐键扫生产串台 ⇒ 无 [XX] 行（新负载没把生产端点/网段带进 dev Secret）
```
N2 的日志判定行为空是因为两 Pod 已连续运行 2d16h，启动那几行早被日志轮转推出 tail 窗口；
库落点以 14.2 的**进程内 env 实测**为准（比日志更强）。

**本卡动作边界**：全程只读（`get` / `logs` / `exec ls·find·printenv`），未 apply/patch/delete 任何对象。
## 15. 任务 15：`default` SA 进免密组件的复核 + slave 负载标签对齐（2026-10-13）

### 15.1 负责人自行处置 §14.3：先双口径核实"真的落地了"，再动别的

台账纪律不认"我改了"，只认回读。两个独立口径：

**云侧（组件配置本体，`aliyun cs GET /clusters/<cid>/addon_instances/managed-aliyun-acr-credential-helper`）**

```
state=active  version=v24.01.29.1-5318af4-aliyun
config={"AcrInstanceInfo":[{"instanceId":"cri-avfqy9xkqi5bj8ee","regionId":"ap-southeast-6"}],
        "enableRRSA":false,"expiringThreshold":"15m",
        "serviceAccount":"new-api-app,default",   ← 本轮新增
        "watchNamespace":"newapi-dev"}
```

**集群内（真正决定 Pod 拿不拿得到凭据的那一层，`--diagnose-pull` D4）**

```
default      pullSecrets=acr-credential-secret-aggregation   ← 改前为空
new-api-app  pullSecrets=acr-credential-secret-aggregation
```

⇒ §14.3 那个"靠节点缓存兜底的潜伏坑"已经**从根上关掉**（比我建议的方案 A 更省事：不动负载，扩组件作用域）。
`watchNamespace` 仍只有 `newapi-dev`，没有外溢到生产 ns。
D2 全 ns 无 `ImagePullBackOff`/`ErrImagePull` 原文。

### 15.2 标签对齐：`new-api-dev-slave` 的 `site=jkt`/`track=stable` → `jkt-dev`/`dev`

**动手前的命门探测**（只读）：Deployment 的 `spec.selector.matchLabels` 是**不可变字段**，
若它含 `site`/`track`，改 Pod 模板标签会让控制器选不到旧 Pod ⇒ 造孤儿。实测：

```
new-api-dev          selector={"app":"new-api","track":"dev"}          ← 含 track，所以这个负载绝不能这么改
new-api-dev-slave    selector={"app":"new-api-dev-slave"}              ← 不含 site/track ⇒ 安全
```
body 里把这条做成硬闸门（`grep -qE '"(site|track)"' <<<"$SEL"` 命中即 exit 1），不是口头保证。

**连带风险也想清楚了两条**：改完 `track=dev` 会不会误进 `new-api-dev` Service 的后端？
不会 —— 那个 selector 还要求 `app=new-api`，而 slave 是 `app=new-api-dev-slave`。改后 Endpoints 归属实测证实。

**实际写入**：`deployment.apps/new-api-dev-slave patched`，只有 `site`/`track` 两个键、两层（顶层 `metadata.labels` + `spec.template.metadata.labels`）。
`app`/`env`/`project` 一概没碰（顶层原本只有 `app`，是否补齐 `env`/`project` 不在这次范围内，留给负责人）。

```
after 顶层labels={"app":"new-api-dev-slave","site":"jkt-dev","track":"dev"}
after 模板labels={"app":"new-api-dev-slave","env":"dev","project":"new-api","site":"jkt-dev","track":"dev"}
after selector={"app":"new-api-dev-slave"}（保持不变，已证）
deployment "new-api-dev-slave" successfully rolled out     rollout_rc=0
后端归属：svc/new-api-dev → 10.2.90.156 → pod/new-api-dev-594fdf5795-wxt49
后端归属：svc/new-api-dev-slave → 10.2.25.179 → pod/new-api-dev-slave-5898984fc6-8ppvr   ← 只收本负载，无串台
ready=1/1；default SA 仍挂 acr-credential-secret-aggregation
```
L4 里同时列到旧 Pod `7fd87f877d-n74bw`（`site=jkt`/`track=stable`）是 Terminating 残留，非并存；
新 Pod 落在 `ap-southeast-5a`（旧在 5b）⇒ AZ 由调度器重新分配，dev 单副本无稳定性问题。

**这次改动的真实代价**（事先已告知）：模板标签变更触发一次滚动重建，slave 重启了一次。

**产物**：新增 `bodies/align_labels.sh` + `dev_deploy.sh --align-labels <deploy>`（进 `--render-check`，命令体 3.9 KB）。
途中遇到一次 `DescribeClusterUserKubeconfig` 超时（CS API 抖动，同一调用几分钟前后均成功），第二次即通过 ——
失败发生在**取凭据阶段**，命令未投递、集群未被写入，属安全失败。

## 16. slave 顶层标签补齐（2026-10-15，SCOPE=meta ⇒ 零重建）

### 16.1 这一节只解决一件事：上一轮遗留的形状差

§15 把 slave 的**模板**标签对齐了，但顶层 `metadata.labels` 仍缺 `env` / `project`：

| 负载 | 顶层 labels（改动前） | 模板 labels（改动前） |
|---|---|---|
| new-api-dev（master，参照） | app, env, project, site, track | app, env, project, site, track |
| new-api-dev-slave | app, site, track **（缺 2 键）** | app, env, project, site, track |

顶层标签是**给负载对象本身**贴的（控制台筛选、成本归集按 Deployment 维度聚合时吃它），
模板标签是给 Pod 贴的（Service selector 吃它）。两者是不同的东西 —— 上一轮只修了后者。

### 16.2 工具改造：一份 body 覆盖所有键与层，不再一键一 body

`bodies/align_labels.sh` 重写为参数化（`KV=` 逗号分隔键值对、`SCOPE=meta|template|both`），
门禁按"结构性前置条件"设计，而不是事后正则：

- 键白名单只放 `site|track|env|project`；**`app` 一律拒改**（Service selector 与成本归集都依赖它的值）。
- 值正则 `^[a-z0-9-]+$`。
- `SCOPE != meta` 时，先读 `spec.selector.matchLabels`，**待改键若出现在 selector 里直接拒绝**
  （selector 是不可变字段，改模板标签会让新 Pod 落不进 selector ⇒ 孤儿 Pod）。
  `SCOPE=meta` 跳过该门：顶层元数据根本不进 selector 判定。
- `TARGET` 必须显式传，刻意不给默认负载名。

执行侧 `dev_deploy.sh --align-labels <deploy> <KV> <scope>`，四参缺一即 `die`；
非 meta 层会先打一句"会滚动重建一次"的提醒。

### 16.3 落地与回读（生效判据只认回读）

```
bash dev_deploy.sh --align-labels new-api-dev-slave "env=dev,project=new-api" meta
```

```
before 顶层labels={"app":"new-api-dev-slave","site":"jkt-dev","track":"dev"}
after  顶层labels={"app":"new-api-dev-slave","env":"dev","project":"new-api","site":"jkt-dev","track":"dev"}
after  selector={"app":"new-api-dev-slave"}（未变）
参照 new-api-dev 顶层：仅目标有的键=（空）| 仅参照有的键=（空）
```

**键集差集双向为空** ⇒ 与 master 同形。注意"同形"指键集合相同；
`app` 的**值**仍然不同（`new-api` vs `new-api-dev-slave`），这是刻意的 ——
两个负载必须靠 `app` 值区分，否则 Service 后端会串。

### 16.4 反向验证：没有重建才是这次正确的标志

改动 meta 层若引发 Pod 重建，说明我对 K8s 语义的理解有误，所以 L4 用身份指纹反证：

```
BEFORE/AFTER = 每 Pod 的「名字|pod-template-hash|容器重启数」拼接排序
结果：[ok] 完全一致 ⇒ 未发生重建
现状：1/1 ready
      new-api-dev-slave-5898984fc6-8ppvr  1/1  Running  重启 0  已运行 13m
```

`13m` 这个 AGE 本身就是证据：Pod 早于本次改动创建，没有被替换。
后端归属同时复测了一次隔离面：

```
svc/new-api-dev        → 10.2.90.156 → pod/new-api-dev-594fdf5795-wxt49
svc/new-api-dev-slave  → 10.2.25.179 → pod/new-api-dev-slave-5898984fc6-8ppvr
```

两个 Service 各自只指自己那组 Pod，没有交叉 —— 与 §14 的结论一致，本次改动没碰这条线。

### 16.5 一处判据文案修正（自我纠偏）

原 body 无论 SCOPE 为何都先打印"SCOPE 含模板层 ⇒ 会滚动重建一次"，
meta 模式下这句是**错的**（会把读者带向错误的风险预期）。已改为按 SCOPE 三分支各自表述。
教训：判据文案要跟着分支走，不能写在分支外面当公共结论。

### 16.6 写入面与未做事项

- 本次唯一写入：`new-api-dev-slave` 顶层 `metadata.labels` 增加 `env=dev`、`project=new-api`。
- 未做（都需要负责人点头，见 §12.8）：dev RDS 续费/转按量/释放、节点池 2↔1、DB owner 改 aurora、
  马尼拉 ACR EE 公网 ACL 收紧。
- §13.10 的冷缓存跨区下载仍未验证，等下一次真实版本发布时顺带采集。
## 17. 任务 45（改口径后执行）：雅加达 pre/perf 底座 + 双库冒烟（2026-10-15，**pre 侧已闭合 / perf 侧被可售性阻断**）

**裁定（负责人 2026-10-15 五条 + 收口授权「可以直接按现网实际情况修改内容 / 可以直接操作」）**：① staging 与 perf 都建在雅加达开发站，**正式环境（马尼拉）零改动**；② ns 名 `new-api-staging` → **`new-api-pre`**（perf 仍 `new-api-perf`）；③ `pgbouncer.pool_mode` 回到 `session`，**只改雅加达**；④ RDS 不复用主实例的独立 schema/库 ⇒ **新建库 `newapi_pre` / `newapi_perf`**；⑤ `new-api-pre` **与 dev 共用机器**（现网唯一节点池 `np-jkt-dev-app`），perf 保持独立节点池 2×`g9i.xlarge` + taint；单人本轮口径降为 **SQLite + PG 双库冒烟**。

### 17.1 落地产物（全部为新文件，未改既有清单）
`deploy/jakarta_pre/pre_deploy.sh`（执行器，子命令 `--ns-base/--addon-verify/--pull-check/--db-ports/--db-state/--create-db/--apply-grants/--dev-baseline/--gen-secret/--apply-secret/--apply-app/--smoke/--diag*`）+ `bodies/*.sh`（13 个远端 body）+ `pre_grants.sql` + `new-api-pre.yaml`。通道仍是 `deploy/lib/ack_remote_jkt_dev.sh`（云助手 → 节点内 kubectl，硬门禁 15000 字节 ⇒ 冒烟拆两个 body，不是绕过）。

### 17.2 每步实测回读
1. **ns 底座 ✅**：`new-api-pre` / `new-api-perf` 各 Namespace + ResourceQuota + SA `new-api-app`（`create_ns.sh`）。配额有 ResourceQuota ⇒ 任何 Pod 必须声明 requests/limits，首版漏写被 API 直接拒（已补）。
2. **免密作用域 ✅ + 真实拉取反证**：`managed-aliyun-acr-credential-helper` 的 `watchNamespace=newapi-dev,new-api-pre,new-api-perf`；探针 Pod 在两 ns 各自看到 `secret/acr-credential-secret-aggregation` 且 SA `imagePullSecrets` 非空，实测从**马尼拉 EE 公网入口跨区**拉到 `newapi-master:20261015-c62445555`：**77,430,712 B / 42.157 s ≈ 1.85 MB/s**（冷缓存，顺带闭合 §13.10 的余项）。
3. **pool_mode ⇒ 零写操作**：09:2x 读数时雅加达实例无池字段；17:5x 再读已出现 `PGBouncerEnabled=true` + 18 条 `pgbouncer.*`，其中 **`pgbouncer.pool_mode=session`**。⇒ 开池发生在我的两次读数之间、**不是我做的**（我全程只 `Describe*`；`set_rds_pooler.sh` 只在 `APPLY=0` 计划态跑过）。判据按实况记为"目标值已达成 + 非本卡所改"。
   - **6432 实测**：节点侧 TCP `OPEN`、PG 握手应答 `SSLRequest=S`（5432 同样 OPEN）。**业务侧真正走池**：`new-api-pre` 的 `SQL_DSN` 端口 = 6432，AutoMigrate 经池建出 **42 张表** ⇒ "池在承载真实 DDL/DML"，握手只是必要条件。
   - **马尼拉同步纠错（不改马尼拉）**：卡片原判据写"马尼拉维持 `transaction`"与现网不符 —— `DescribeParameters` 实测马尼拉亦为 `pool_mode=session`，且 `deploy/docs/G11连接数预算表_线上核实_2026-10-12.md` 已用 ActionTrail 证成 2026-09-30 09:33 由 root 主账号未登记切换、2026-10-13 裁定"先不切回 = 维持 session"。⇒ **"只改雅加达"没有可改对象**，两地都已是 session，本卡零写即满足。
   - 读数教训（已写进卡片 V4）：字段名是 **`ParameterName`** 不是 `ParameterKey`，且 JSON 是 `": "` 带空格的美化格式 —— 紧格式 grep 会**静默假阴性**（我先后踩过这两条）。`DescribeModifyParameterLog` 回 `InternalError`，不可用。
4. **两库 + 权限链 ✅**：`newapi_pre` / `newapi_perf` 建成（UTF8，`DescribeDatabases` 回读 `Running`，空库）。owner 走 `GrantAccountPrivilege`（PG+云盘只有 `DBOwner` 一个值）→ 目标账号 **`newapi_ops`**（业务账号绝不可为 owner，坑 11）；库内三段式由 `pre_grants.sql` 逐条执行并回读：`db_owner=newapi_ops`、`has_create_migrate=true`、`has_usage_migrate=true`、**`has_create_runtime=false`**、`has_usage_runtime=true`、`default_acl=newapi_migrate=…{newapi=arwdDxt}`、`tables=0`（建库时点）。
   - **权限链反证 ✅**：以运行账号 `newapi` 直接 `CREATE TABLE` ⇒ `permission denied for schema public`；migrate 账号建表成功 ⇒ 切分真正生效（不是"命令返回 0"）。
   - 与 dev 同构的有意偏差：**无 logs 段**（本轮不建 pre 日志库）、**不写 database 级 CONNECT/REVOKE**（坑 14 与 dev 台账口径保持一致）。
5. **Secret ✅**：`--gen-secret` 在堡垒机保管目录 `/root/.deploy_secrets_dev/`（mode 600）内生成 `PRE_SQL_DSN` / `PRE_SQL_DSN_MIGRATE`（端口 **6432**）等键；`--apply-secret` 的 payload 门禁 K1–K6 全过（键集合、URL 前缀 `postgres://`、非空 SESSION_SECRET），并**只输出指纹不输出值**：`SESSION_SECRET` 指纹 pre=`881a665a44ff` vs dev=`734c5af1db1d` ⇒ **不同**（坑 1）。口令未进 Pod spec 命令行、未进 stdout、未进台账。
6. **pre 工作负载 ✅（被容量实测倒逼改了资源档）**：首版按 dev 清单 `requests 500m/1Gi` ⇒ 两副本全 Pending，scheduler 原文 `0/3 nodes are available: 1 Too many pods, 3 Insufficient cpu`。诊断（`diag_nodes.sh`/`diag_mem.sh`）实测：三台 `allocatable.cpu=1930m`，已请求 **1.69–1.80 核**（大头 `arms-prometheus` 单 Pod 报 **1 核**），一台 **16/15 Pod 超限**；而**集群实际 CPU 使用率仅 2%** ⇒ 这是**请求量分配饱和，不是物理容量不足**。⇒ pre 降为 `requests 100m/256Mi / limits 500m/512Mi` 后排进，rollout 完成、**`1/1 Running`**，集群内 `http://new-api-pre.new-api-pre.svc.cluster.local/api/status` 200（`"success":true`）。
   - **与裁定 ⑤ 的冲突已记账**：pre 与 dev 共机 ⇒ dev 的验证窗口会被 pre 挤占；**perf 独立节点池因此从"可选"变"必需"**。
7. **双库冒烟 ✅**：
   - **PG（V1）**：经 6432 池，`/api/status` 200 + `newapi_pre` 内 **42 表** + 服务端 `ssl=1`（TLS 在池侧终结，回读自 `pg_stat_ssl`）。
   - **SQLite（V2）**：同镜像、无 `SQL_DSN` 的临时 Pod，日志自证 `SQL_DSN not set, using SQLite as database`、`ready in 307 ms`、落盘文件 **`/data/one-api.db`**。
   - **两条原判据按实况作废**：① "version 与镜像 tag 一致" 实测不成立（`/api/status` 回 `"version":""`，构建未注 ldflags）；② SQLite 文件名原写 `new-api.db`，现网是 `one-api.db`。两者降级为"记录，不门槛"。
8. **隔离反证 ✅**：dev 三个负载 Pod 身份指纹（name/pod-template-hash/restartCount）与本卡执行前的 `--dev-baseline` 逐行一致 ⇒ **本卡对 `newapi-dev` 零写**。唯一例外 `new-api-channel-task-dev` 模板哈希 `d6579bfc7 → 597d78649d`（镜像 `…e0a5cae3 → …5603216a`），`managedFields.manager=OneConsole-App-CS`、时间 `10:15:10Z` ⇒ **控制台侧第三方变更，不是本卡**（诚实归因，不当成"我改的"也不当成"没事"）。pre ns 对象清单只有 pre 三件套 + 已清理的冒烟 Pod；pre 无 Ingress/ALB ⇒ 只在 ns 内被路由；两地 DSN/域名字符串在清单里互相不可达（结构隔离：独立集群 + 独立 VPC）。

### 17.3 未执行 / 阻断
- **perf 独立节点池 ⏸**：**唯一门槛是费用核准**（红线：新建节点池 = 新增 ECS 费用）。⚠ 上一小节写的「裁定机型 `ecs.g9i.xlarge` 在 `ap-southeast-5` 实测不可售 / `g9i` 自 `2xlarge` 起售」**作废**，见 §17.5。建池调用一条都没做过。
- **perf 工作负载 / V5 压测 ⏸**：依赖上项；且任务 53 已实测本站"无管理员会话、无可用上游渠道"⇒ V5 顺延 T+14。
- **MySQL 列 ⏸**：按裁定顺延 T+14（三库矩阵未闭合，出口清单相应行保持不勾选）。
- **载体到期风险**：两库都落在 **2026-11-12 到期**的 Prepaid 实例 `pgm-d9j9p421lzx4gw73` 上（§12.8 ① 续/释仍未裁定）。

### 17.4 凭据扫描
本卡新增/修改的 20 个文件（含指南）`grep -cE "eyJ[A-Za-z0-9]{20,}"` 全部 **0 命中**；DSN 在文档与输出中一律 `***` 或只给 sha256 前 12 位指纹；保管目录外无明文。

### 17.5 自我更正（2026-10-16）：perf 机型「不可售」是读数假阴性
**错误结论**：§17.3 上一版与指南任务 45（坑 8 / 步骤 5 约束② / 出口清单 / 移交限制四处）都写明「`ecs.g9i.xlarge` 在 `ap-southeast-5` 三 zone 查不到、`g9i` 家族自 `2xlarge` 起售」，并据此把 perf 建池判为"机型阻断"。

**复核证据**（全部只读 API）：
- `DescribeAvailableResource --RegionId ap-southeast-5 --DestinationResource InstanceType --InstanceChargeType PostPaid --IoOptimized optimized --NetworkCategory vpc`：5a/5b/5c 三 zone 都列出 `ecs.g9i.xlarge` 与 `ecs.g9i.large`，`Status=Available`、`StatusCategory=WithStock`。
- 逐 zone 带 `--ZoneId <z> --InstanceType ecs.g9i.xlarge` 的精确查询：三地均回 `Available / WithStock`；`InstanceChargeType=PrePaid` 口径同样 `Available`。
- `DescribePrice`（按量、含 40GiB `cloud_essd`、不带公网带宽）：**单节点 0.215328 USD/h**（实例 0.2052 + 系统盘 0.010128）⇒ **2 节点 ≈ 0.4307 USD/h ≈ 10.34 USD/天 ≈ 310 USD/月**；压测后缩到 0 只按实际小时计费。

**成因（两次同类错误的共同点：把"我的读取管道没产出"当成"云上没这个对象"）**：
1. jq 字段路径按猜测写（`.AvailableResources.AvailableResource[]` 与 `.SupportedResources.SupportedResource[]` 层级混用）⇒ 空数组；本轮我第一次用同一套错路径复现时，也照样得到空输出。
2. 枚举结果接了 `head` 截断，而该 API 的机型列表**不按规格大小排序**⇒ 截断后的样本里恰好没有 `xlarge/large`，被误读为"从 `2xlarge` 起售"。
   ⇒ 与本卡 V4 的 `ParameterKey`（实为 `ParameterName`）、JSON `"key": value` 带空格两条假阴性是同一类：**空输出必须先证明读取路径本身有效，才能作为"对象不存在"的证据**。已在指南坑 8 落为长期条款。

**仍为真的子结论**：`ecs.g8ine` 仅 `5b` 有货；perf 建池的实际阻断只剩**费用核准**（红线）与任务 53 的「无可用上游渠道 ⇒ V5 顺延」。指南与台账四处文字已同步更正，未对集群/RDS 做任何写操作。

### 17.6 perf 半边：产物已备齐并装好门禁（2026-10-16，**零云端写入**）
- 新增 `deploy/jakarta_pre/new-api-perf.yaml`：ns `new-api-perf`、`track: perf`、`tolerations: dedicated=perf:NoSchedule`、`nodeSelector` 用 `__PERF_NODE_SELECTOR__/__PERF_NODEPOOL_ID__` **占位**（真实值 = 建池后回读 `ack.alibabacloud.com/nodepool-id`，不猜不写死）、副本 2、`requests 1核/2Gi`、DSN 同走 **6432**（与生产同形状，压测才测到被测对象）。`new-api-pre.yaml` 偏差② 里"perf 走 5432"的旧说法随之更正。
- `bodies/apply_pre_secret.sh` / `apply_pre_app.sh` **参数化**（`NS`/`DBNAME`/`APP`/`TRACK`，默认值 = pre 首跑口径，一字不改地保持 pre 行为）⇒ perf 复用同一套门禁逻辑，不复制第二份。顺带把 A0 的键位判断从易错的 `case` glob 改成 `grep -qw`。
- 执行器新增 `--perf-pool / --perf-plan / --perf-gen-secret / --perf-apply-secret / --perf-apply`。**三道门禁实测**（都是本地/只读）：
  1. `--perf-apply` 无标记 ⇒ `P-1 门禁：需要 PERF_APPROVAL=cost-approved`（拒绝）。
  2. `PERF_APPROVAL=cost-approved --perf-apply` ⇒ `P0 门禁：节点池 'np-jkt-perf' 不存在`（拒绝；`DescribeClusterNodePools` 现网只有 `npd3cc9d7f0503472f85420d30436269b5 np-jkt-dev-app state=active types=g9i.large/g8ine.large/g9ae.large nodes=3`）。
  3. `--perf-plan` 只读预检：三 zone `g9i.xlarge` 全 `Available/WithStock`、`0.215328 USD/h`/节点 ⇒ **2 节点 ≈ 0.4307 USD/h ≈ 10.34 USD/天 ≈ 310 USD/月**（按量、40GiB `cloud_essd`、不含公网出流量）。
- ⇒ perf 侧现在**只差负责人一句话的建池核准**；核准后顺序是：建池（`np-jkt-perf`，taint `dedicated=perf:NoSchedule`，PostPaid）→ 节点 `instance type` 回读 → `--perf-gen-secret` → `--perf-apply-secret` → `PERF_APPROVAL=cost-approved --perf-apply` → 双库冒烟；V5 仍受"无可用上游渠道"限制。
- 凭据面复扫：本轮全部改动文件 `grep -cE "eyJ[A-Za-z0-9]{20,}"` = **0**；`--perf-gen-secret` 尚未执行（口令仍不生成，避免无负载可挂的空密钥）。

## 18. 生产事故取证：马尼拉 ClickHouse 实例已被删除 + 账号欠费阻断 perf 建池（2026-10-16，**均为只读取证，零写入**）

### 18.1 触发点
负责人对任务 45 步骤 5 的 perf 建池回了「准」（费用核准成立）。执行 `CreateClusterNodePool` 时被账号侧拒绝，顺带用 ActionTrail 复核其他费用类调用时发现一条**与我方无关的生产删除事件**。两条都记在这里。

### 18.2 perf 建池：被 `Account.Arrearage` 拒绝（不是机型、不是权限）
- 建池载荷已落库为可审计产物：`deploy/jakarta_pre/perf_nodepool.json`（`np-jkt-perf`，2×`ecs.g9i.xlarge`，PostPaid，taint `dedicated=perf:NoSchedule`，标签 `site=jkt-dev/env=dev/project=new-api/track=perf`，vSwitch 三台与 sg 与 dev 池逐字一致，容器运行时 `containerd 2.3.4`，`auto_scaling.enable=false`、`management.enable=false`）。
- 建池前用 `DescribeClusterNodePoolDetail` 抄了 dev 池 `npd3cc9d7f0503472f85420d30436269b5` 的真实配置（types=g9i.large/g8ine.large/g9ae.large、vsw 分别落在 5c/5b/5a、sg-k1ag5j7s6xbuyjkv3j8c、system disk cloud_essd 40、镜像 `aliyun_3_x64_20G_container_optimized_alibase_20260720.vhd`、`desired_size=3`、**无 key pair**（`aliyun ecs DescribeKeyPairs` 该地域 0 条）⇒ 登录凭据走集群侧，载荷里不写任何口令）。
- 实际调用结果：`403 Account.Arrearage`（RequestId 01A14258-82BD-3D1D-B364-52B4C18B6FB3）。
- 只读佐证：`bssopenapi QueryAccountBalance` ⇒ **AvailableAmount = -43.81 USD**，CreditAmount = 0.00，Currency = USD。
- ⇒ **perf 建池在欠费结清前结构性不可行**。结清属负责人的资金动作，AI 不得自行处理。

### 18.3 欠费的暴露面（只读账目，按计费类型分层）
| 资源 | 地域 | 计费 | 状态 | 欠费暴露 |
|---|---|---|---|---|
| ACK worker ECS ×3（`i-k1ahsgvna3udifwksje5` 等，集群 cb0abf5b…） | ap-southeast-5 | **PostPaid** | Running | **直接暴露**（dev + pre 的计算载体） |
| ACK worker ECS ×4（集群 cd57e40c…） | ap-southeast-6 | **PostPaid** | Running | **直接暴露（正式环境）** |
| RDS `pgm-5tstdhko64x2c01w`（正式主库） | ap-southeast-6 | Prepaid，2026-10-28 到期 | Unlock | 到期风险，非欠费停机 |
| RDS `rm-5ts0ez22t67il9oz3`（newapi-logs-mysql） | ap-southeast-6 | Prepaid，2026-11-15 到期 | Unlock | 同上 |
| RDS `pgm-d9j9p421lzx4gw73`（dev/pre 载体） | ap-southeast-5 | Prepaid，**2026-11-12 到期** | Unlock | 同上（§12.8 ① 仍未裁定） |
| ECS `newapi-ops-mnl` | ap-southeast-6 | PrePaid | Running | 低 |
- ⚠ 新发现的到期优先级：**正式主库 2026-10-28 到期**早于 dev 实例的 11-12，§12.8 的续/释裁定要按这个新顺序重排。

### 18.4 生产事故：马尼拉 CK 实例已被删除（ActionTrail 硬证据）
- 事件：`DeleteDBInstance`，`2026-10-15T09:48:55Z`，`svc=ClickHouse`，`errorCode` 缺省（**成功**），资源 `ACS::ClickHouse::EnterpriseDBCluster: cc-5tsv2o51s1360b0pr`，操作主体 **RAM 子用户 `yanxuewei`**，源 IP **14.155.115.41**，UA `AlibabaCloud (linux; amd64) Golang/1.25.x`。
- **不是我做的**：本会话 CLI 身份同为 `acs:ram::5108890064395960:user/yanxuewei`（同 AK 共用），但**本机出口 IP 实测 103.196.22.24 ≠ 14.155.115.41**，且我全程只有 `Describe*`（`aliyun cs`/`rds`/`ecs`/`clickhouse`/`actiontrail`），无任何 Delete 调用。⇒ 同 AK 的另一台机器/另一人操作，需负责人核对是否为本人所为。
- 现状复核（全部只读）：`DescribeDBInstances` 在 ap-southeast-6/5/1、cn-hangzhou、us-east-1 均 **TotalCount=0**；按 id 直查 `DescribeDBInstanceAttribute` ⇒ `InvalidDBInstanceId.NotFound`；窗口内**没有任何后续 CreateDBInstance 成功记录**（10-15 06:12 那条 CreateDBInstance 是 RDS，不是 CK）；集群节点内 `getaddrinfo(cc-5tsv2o51s1360b0pr.clickhouse.ads.aliyuncs.com)` ⇒ **解析失败**。
- **配置侧仍在指向它**：`secret/new-api-secrets` 的 `LOG_SQL_DSN` 仍是 `clickhouse://<账号>:<口令>@cc-5tsv2o51s1360b0pr.clickhouse.ads.aliyuncs.com:8123/<库>`（本条只复述形态，口令不外泄），而 `configmap/new-api-config` 里还留着 `LOG_SQL_CLICKHOUSE_TTL_DAYS=90` ⇒ **正式环境的日志库链路自 2026-10-15 09:48Z 起指向一个不存在的实例**。
- 应用侧实测影响（`bodies/inspect_ck_gone.sh`，零写入）：`new-api` ns 的 6 个 Pod 全 `1/1 Running`、**重启数 0**、创建时间 2026-10-15T06:35Z（早于删除点），近 800 行日志里 `clickhouse` / `dial tcp` / `code 81/210` / `[ERROR]` 命中数**全为 0**。
  ⇒ 结论边界要写清：**"pod 无报错"不等于"日志没丢"**。异步批量写 CK 失败可能只体现在被吞掉的 error 或根本没有落点；本轮没有证据说明日志仍在被完整记录，也没有证据说明请求面被打崩。**待负责人定方向**：① 重建 CK（= 新的按量费用，需核准）② 把 `LOG_SQL_DSN` 切到既有的马尼拉 MySQL `rm-5ts0ez22t67il9oz3`（`newapi-logs-mysql`，Prepaid 已在账）③ 暂时关闭日志库。三者都属变更操作，本轮一条都没做。
- 与卡片的关系：任务 45 **坑 4** 原文写"若 `clickhouse DescribeDBInstances --RegionId ap-southeast-6` 查不到实例 ⇒ 回到任务 9 的四路表重开决策"——**该前提现已成立**，F9（马尼拉 CK 企业版单 AZ）的决策物已不存在。

### 18.5 本轮我自己造成的一次口令外泄（指南坑 7 同类，必须登记）
- 现象：18.4 的取证脚本用正则 `://([^:/]+):[^@]*@` 给 DSN 打码，但 `LOG_SQL_DSN` 的真实形态是 `clickhouse://user:pass@host`（**不是** `user:pass@host` 前置 scheme 的 Postgres 形态）⇒ 正则没命中，**含口令的整串进入了会话输出**。
- 危害评估：该 CK 实例已删除 ⇒ 账号随实例消失，口令不可再用；**但它与仓库里既有的明文是同一串**（见下），且同类口令存在复用风险 ⇒ 按泄露处理，**建议轮换 CK/日志库侧口令**（属破坏性操作，需负责人核准，我不自行执行）。
- 落盘面复查：本次输出只写进 `/tmp/ckk.txt`，**已 `shred -u`**；仓库内**没有**今天新增的命中。但既有的 **4 个受 Git 跟踪的文件**本身含同一形态的明文 DSN（`deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`、`deploy/tasks/task9/ck_wiring.sh`（3 处）、`deploy/tasks/task17/Day2任务17_DSN注入_执行报告.md`、`deploy/docs/日志库ClickHouse_学习手册.md`），另有 4 个 `deploy/logs/**` 备份被 `.gitignore` 兜住不入 Git ⇒ 这是**先于本轮就存在的**问题，原地脱敏需负责人许可（fork 工程尽量不改既有文件）。
- 改进：打码必须**按 scheme 无关**的写法（先 `s#://[^@]*@#://***@#`，再兜 `s#(:[^:/@ ]+)@#@***@#`），并在输出前用长度指纹自证；本轮之后所有取证脚本改走"只打印键名 + 主机名"，不再打印任何 DSN 派生串。

### 18.6 负责人答复落地（2026-10-16）：CK→MySQL 是**已定的改判**，但最后一步没接线
答复三条：① 正在充值；② 生产日志库因 CK 太贵**已改判 MySQL**；③ 仓库既有明文与口令轮换暂不处理（**已按答复关闭**，任务列表相应删除）。

**证据链补齐（全部只读，ActionTrail + RDS API）**：
- `2026-10-15T06:12:56Z` `CreateDBInstance`（svc=Rds，主体 `yanxuewei`，源 IP `14.155.115.41`）⇒ 资源 **`rm-5ts0ez22t67il9oz3`**，即台账里那台 `newapi-logs-mysql`。**与 18.4 的 CK 删除是同一主体、同一 IP、同一天**，先后顺序为"先建 MySQL（06:12）→ 后删 CK（09:48）"⇒ 18.4 那条 Delete **不是误删，是改判的第二步**。
- MySQL 侧现状（`DescribeDatabases` / `DescribeAccounts`，只读）：库 `newapi_logs` `status=Running`、`charset=utf8mb4`；账号 `newapi_logs`（Normal，授权 1 条）+ `newapi_ops`（Super，授权 0 条）；实例 Prepaid，**2026-11-15 到期**，`LockMode=Unlock` ⇒ 载体已就位，不是空壳。

**仍然成立的缺口（这是本轮唯一的"坏消息"）**：正式环境 `secret/new-api-secrets` 的 **`LOG_SQL_DSN` 现值仍指向已删除的 CK 主机**（本条只复述形态 `clickhouse://<账号>:<口令>@cc-5tsv2o51s1360b0pr...:8123/<库>`，口令不外泄），而 `configmap/new-api-config` 仍留着 CK 专属的 `LOG_SQL_CLICKHOUSE_TTL_DAYS=90`；6 个 Pod 的创建时间是 `2026-10-15T06:35Z`（**建 MySQL 之后、删 CK 之前**），且任务 17 早已证 **Secret 变更不会自动重启 Pod** ⇒
- 改判的第三步（**把 `LOG_SQL_DSN` 换成 MySQL 形态的 DSN + 滚动重启**）**没有做过**；
- 因此从 `2026-10-15T09:48:55Z` 起，正式环境的日志写入目标是**一个已不存在的实例**。近 800 行 Pod 日志零错误只能说明"错误没打到 stdout 或被批量吞掉"，**不能**证明日志在正常落库。
- ⇒ 待负责人核准的生产变更（AI 不得自行执行）：`LOG_SQL_DSN` 改为 `mysql://` 形态指向 `rm-5ts0ez22t67il9oz3:3306/newapi_logs`（口令从保管目录取，不外显）→ `rollout restart` `new-api-master`（迁移角色，先让它建日志表）→ 再 `new-api-stable`（4 副本，`maxUnavailable=0`）→ `new-api-canary` → 回读 `information_schema.tables` 与 `logs` 行数增长为生效判据；顺带决定 `LOG_SQL_CLICKHOUSE_TTL_DAYS` 是否作废、MySQL 侧保留策略怎么落。

**充值仍未到账（影响 perf）**：`QueryAccountBalance` 两次读数 `2026-10-16T01:3xZ` = **-43.81 USD**、`01:5xZ` = **-51.97 USD**（AvailableCashAmount=0、CreditAmount=0）⇒ 金额在继续走负，说明按量资源仍在计费而充值未落地；`CreateClusterNodePool` 在此之前仍会被 `Account.Arrearage` 拒。到账后我按 §17.6 的链路续跑 perf，无需重新裁定。

### 18.7 我又造成第二次口令外泄：18.5 开的药方本身不够（2026-10-16，必须登记并纠正）
- 现象：为核对 §18.6「MySQL 形态的 DSN 是否已在保管目录就位」，我在 WSL 本地用 `python3` 打印了 `/root/.deploy_secrets/` 里三个文件的"打码后形态"。结果 **`MYSQL_LOG_DSN_MNL` 的完整串（含口令）原样进了会话输出**，`CK_LOG_DSN_mnl` / `LOG_SQL_DSN` 则被正确打码。
- 根因（这一次不是"正则漏了 scheme 前缀"，是**我的验证方式本身错了**）：MySQL 的 DSN 是 `user:pass@tcp(host:port)/db`，**整串没有 `://`**。18.5 我写下的修法 `s#://[^@]*@#://***@#` 依赖 `://` 存在 ⇒ 对无 scheme 的形态**天然不命中**；我加的兜底 `s#(:[^:/@ ]+)@#@***@#` 在这次用的脚本里**根本没执行**。我当时的判定是"看输出里有没有星号"，星号没出现我却只注意到了主机名，没有把它当成打码失败的信号。
- 危害评估：① 该串指向的是**仍然活着**的 MySQL 实例（`rm-5ts0ez22t67il9oz3`，Prepaid 至 2026-11-15），不像 18.5 那次随着 CK 删除自动失效 ⇒ **必须按有效凭据泄露处理**。② 它同时是 §18.6 计划的正式环境 `LOG_SQL_DSN` 要写入的那一串 ⇒ 接线前默认它已不可信。③ 落盘面：本次只读取、未写临时文件，输出仅存在于会话，`/root/.deploy_secrets/` 权限 600 未变；仓库内**无新增命中**（复查 `rm-5ts0ez22t67il9oz3` 与 `mysql://` 两种键串，只命中文档/台账里既有的主机名引用，无口令）。
- **替换 18.5 的"改进"条目**（原写法已被证伪，留原文是为了可追溯）：对保管目录里的 DSN/凭据文件，**唯一允许的自检输出是「文件名 + 字节数 + sha256 前缀」三样**，一律不打印文件的任何**派生子串**（包括自认为已打码的、包括只截主机名的）。理由：任何"先取一段再打码"的路径，都要靠正则覆盖全部方言才能成立，而 DSN 方言（PG / ClickHouse / MySQL `tcp()` / 无 scheme）是我记忆不住的集合；**不取子串**是唯一与方言无关、因此不可能漏的写法。要验证"是不是 MySQL 形态"，用 `grep -c '@tcp(' 文件` 只回**计数**，不回内容。
- 后续动作（按负责人 2026-10-16 答复③「这个可以暂时不用管」执行，我**不自行处理**，只在此留一条待办事实）：口令轮换与仓库既有明文脱敏被明确搁置 ⇒ 上面"按有效凭据泄露处理"的结论在当前口径下**未被消解**。§18.6 的生产接线若获核准，我会在动手前重跑一次"计数式自检"确认口径，而不会再用打印形态的方式核对 DSN。
- 计数式自检实测（`deploy/` 全目录 + 保管目录，**只回计数与指纹，零内容外显**）：`@tcp(` 命中 **0** ⇒ 本次外泄的那一串**没有落进仓库**；`mysql://…@` 命中 **0**；既有明文 `clickhouse://…@` **16**、`postgres://…@` **25**（先于本轮存在，按答复③搁置）。保管目录三文件：`MYSQL_LOG_DSN_MNL` 122 B / `sha256 aaf98ddf85c2`、`CK_LOG_DSN_mnl` 142 B / `21386218590f`、`LOG_SQL_DSN` 143 B / `3a8fe039bc3d`；形态自检回的是计数 —— `MYSQL_LOG_DSN_MNL` 的 `@tcp(` = **1**、`://` = **0**，这就是 18.5 那套正则必然漏它的**可复现证据**（不是推测）。
- 余额第三次读数（`2026-10-16`，与上两次同一口径）：AvailableAmount **-51.97 USD**、AvailableCashAmount 0.00、CreditAmount 0.00 ⇒ **与前次持平、未继续走负，但充值仍未落地**。perf 仍被 `Account.Arrearage` 挡在门外，链路待命。

## 19. jkt dev 集群 SLS 容器日志开通 + 一次容量事故（2026-10-16，**已落地并验证**）

负责人指令：「帮我在 ack-newapi-jkt-dev 集群也开通 sls 集群日志，配置参照马尼拉的来即可」。
**全文见 `deploy/docs/jkt_dev集群SLS日志开通_执行报告_2026-10-16.md`**，此处只记结论与坑。

### 19.1 落地（三步）

| 步 | 内容 | 结果 |
|---|---|---|
| 1 | logstore + 索引：`deploy/sls/jkt_provision.sh`（照抄 mnl 实测参数；索引 body 从 mnl `GetIndex` 取回裁剪） | `app-stdout` ttl180/17 键 · `app-file` ttl30/纯全文 ✅ |
| 2 | 两份 CR：`deploy/sls/clusterpipelineconfig-app-{stdout,file}-jkt.yaml` | `status.message=success`，SLS 侧已翻译出 global+processors ✅ |
| 3 | 执行器扩至三站：`apply_pipeline_ns.sh` 增加 jkt（专用 remote 通道 + ns `newapi-dev` + 跳过老式 CR 清理） | `apply/verify all jkt` 可用、幂等 ✅ |

**与 mnl 的机制差异**：jkt 是 **`loongcollector` v3.3.10.0**（新采集器，DS 3/3）+ **`loongcollector-operator`**
（CR 翻译器，**必须能调度**，这点与 mnl 内置 `alibaba-log-controller` 不同）；CRD 名同
（`clusteraliyunpipelineconfigs.telemetry.alibabacloud.com`）；project `k8s-log-cb0abf5bc…` 建集群时已存在（RG=rg-nonprod）。

**输入过滤必须改口径**（★ 易漏）：mnl 用 `io.kubernetes.container.name: new-api`，而 jkt 三个负载容器名**各不相同**
（`new-api` / `new-api-dev-slave` / `new-api-channel-task-dev`）⇒ 沿用会**漏掉 dev.likha.hk 背后的 slave**；
改为 `io.kubernetes.pod.namespace: newapi-dev`。实测两容器均入库（slave x54 / dev x46）。

### 19.2 事故：装采集组件把 dev 集群压垮（已闭环）

**11:47 装 loongcollector ⇒ 11:47–11:56 `dev.likha.hk` 503**（`new-api-dev-slave` 与 operator 双双 Pending）。
根因是**容量三重约束**，非采集配置错：3×2C 节点（alloc 1930m/节点、Pod 上限 15/节点）已 86%/97%/98%，
`.174`/`.199` **无 Pod 槽**、唯一有槽的 `.153` CPU 只剩 30m（ARMS Prometheus 单 pod 占 **1000m**）；
新增 3×DS（各 100m+1 槽）+ operator（100m+1 槽）正好吃光余量 ⇒ `2 Insufficient cpu, 2 Too many pods`。

**修法（零成本最小改动）**：`arms-prometheus-ack-arms-prometheus` 的 `requests.cpu` **1000m→300m** + 重建其 Pod
（新请求需重建才计入）。`.153` 98%→77%，两者立即调度成功；`dev.likha.hk` 3/3 **200**。

★ **判据沉淀**：ACK 附加组件的「组件 state=active」≠「组件能跑」——`loongcollector-operator` 这种
**Deployment 形态的翻译器**会因节点满而 Pending，而 **CR 是否被翻译要查 SLS 侧 `GetLogtailPipelineConfig`**，
不能只看 `kubectl apply` 成功。

### 19.3 真相纠正：`app-file` 毫秒在两站**都没生效**（推翻任务 26 报告结论）

逐条对账：mnl（镜像 `20260928-26ac63233`）与 jkt（`20261015-c62445555`）的 file 行均为 `[GIN] … 12:04:43 |`
**无毫秒**，`log_ts=None`。根因：毫秒补丁（`UPSTREAM_CHANGES.md` 条目 1–5，提交 `9fff2aa47`）**在
`feature/log-ms-precision` 分支、PR 未开、未进 main** ⇒ CI 镜像都不含 ⇒ 正则不命中。
stdout 路不受影响（纳秒来自 runtime `_time_`）。属既有挂账 G8，本次**不改码/不重建镜像**。

### 19.4 遗留

① dev 集群容量贴顶（节点池 `np-jkt-dev-app` desired=3/max=3 且**未开自动伸缩**）——本次是"借"ARMS 的 1000m，
建议加 1 台节点（≈$80/月）；② `arms-prom/node-exporter-*` 三 Pod 长期 `ImagePullBackOff`（3 天，独立问题）；
③ ARMS 的 requests 可能被附加组件回滚（回滚时改走 ①）。

### 19.5 追加修复（12:5x）：node-exporter ImagePullBackOff 已解决；第 4 台节点确认**未建成**

- **node-exporter**：jkt 的 DS 引用 `acs/node-exporter:v1.9.1-6a53edf`，该 tag 在 ap-southeast-5 镜像仓 **NotFound**（3 天 2 万次 BackOff）；mnl 同 DS 用 **`v0.17.0-slim`**（4 台 2/2 Running 16 天）。修法：节点上 `crictl pull` 先验证 `-5` 仓**确有** `v0.17.0-slim` → `kubectl set image ds/node-exporter node-exporter=…:v0.17.0-slim`（不动已 Ready 的 kube-rbac-proxy）→ 一次滚动 **3/3 全 2/2 Running**，**全集群 Pending 清零**。⚠ DS 由 arms 附加组件管理，升级可能回滚 tag（届时同命令重打）。
- **第 4 台节点（负责人称已加）实测未建成**：节点池 `desired=4 / actual=3`，ESS 伸缩活动 12:51–12:53 **连续 Failed**（Total Capacity 3→4），余额 **-56.15 USD** 继续走负 ⇒ 与 §17 perf 同款 `Account.Arrearage` 阻断，**充值到账前建不出**；到账后若 ESS 不自动重试，用 `cs ScaleClusterNodePool --count 4` 再触发。

## 20. 任务 45 的 perf 半边落地（2026-10-19，**共池裁定 + 换池副作用**）

### 20.1 裁定变更与其证据
负责人 2026-10-19：**「账号已经有钱了，原来的节点池已经更换了更强的机型，这两个环境可以复用新的节点池」** ⇒ 一次性作废三件旧口径：
- **余额到账**：`QueryAccountBalance` = **+2,306.38 USD**（§17/§18 的 -43.81 / -51.97 / -56.15 全部成为历史；`Account.Arrearage` 这个阻断条件自此消失，perf 不必再建池）。
- **旧池整体替换**：`DescribeClusterNodePools` 只回 **1 个池** —— `np72446b422a6441c0bc96762a796aed26` / **`np-jkt-dev-x4c`**，`types=ecs.g9i.xlarge`、`nodes=2`、PostPaid、`auto_scaling.enable=true`、**taints 为空**、labels `site=jkt-dev,track=dev,env=dev,project=new-api`。旧池 `np-jkt-dev-app`（npd3cc9d7f…）**已不在清单里** ⇒ §19.4 遗留①（容量贴顶）与 §19.5（第 4 台建不出）是被"换更强机型"这条路解决的，不是被加节点解决的。
- **perf 不再独占机器** ⇒ 原"专用池 + taint + nodeSelector"整套设计作废，`perf_nodepool.json` 就此**作废但保留**（我不替负责人销毁核准证据）。

新池实测容量（K1/K2/S5，只读）：两台节点 allocatable 各 **3920m / 14.0 Gi**（合计 7840m）；perf 上线**后**全集群 requests **4.56 核**，单机分别 2.40 / 2.16 ⇒ 每节点还剩 **1.5–1.76 核**。对照 §17.2-6（旧池 3×1930m 已请求 1.69–1.80 核，pre 被迫降到 100m 才排进去）⇒ pre 的 `resources` 现在是被**低估**而不是被压死的，但那是"要不要重开 pre 口径"的另一个决定，本轮没动它。

### 20.2 换池把我自己的一个隐藏假设打断了（本轮唯一的"我踩的坑"）
`deploy/lib/ack_remote_jkt_dev.sh` 的默认落点机器是**硬编码**的 `NODE_ARG="${2:-i-k1afy1aqgdl8rwa9gxvf}"`。换池把 ECS 实例一起换掉 ⇒ 这个 id 指向的实例已释放，**所有** `run_body` 调用（含已验收的 pre 链路）都会打在死实例上，报出来的是"云助手命令失败"，看起来像我的脚本坏了。
- 现网新实例（N2 回读）：`i-k1afs8wedv35rai4pmx2`（10.2.25.190，5a）、`i-k1aen3t7wrqv5j66uzj8`（10.2.90.173，5c）。
- 修法不是换个新 id（`auto_scaling.enable=true` ⇒ id 会继续变，那只是把定时炸弹往后推）：**改成每次现取** —— `DescribeClusterNodes` 选第一个 `state=running` 的实例，取不到就**当场终止**（不向已释放实例发命令，也不猜 id）。已实测生效：本轮 4 次调用都打出 `动态选定节点=i-k1afs8wedv35rai4pmx2（DescribeClusterNodes 现取，未写死）`。
- 教训（与 §17.5 同源）：**配置里写死的资源 id，要在它依赖的那个东西会漂移时立刻质疑**——节点池弹性 = 实例 id 会漂移，而弹性开关是别人今天打开的。
- ⚠ **必须写实名的一点**：这不是新发现。同一份指南里**早有这条坑** —— `deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md:1974` 任务 13 **坑 9**：「用固定实例 ID 跑跨时长的节点验证：ACK 节点池随时在滚……此前登记的 ID 下一轮 `RunCommand` 就 `InvalidInstance.NotFound`。**改进**：**在同一个脚本内先取 Running 节点，再立刻 `RunCommand`，不在脚本之间传 ID**」。我的通道脚本恰恰违反了这句已登记的改进（还把 id 写进了脚本默认的 `${2:-...}`，比"脚本之间传 ID"更糟）。⇒ 结论修正：**踩坑的不是"没人提醒"，是我建的脚本没有遵守已经写在主文档里的规则**。落地修法与坑 9 的改进语句逐字一致（同一次调用内现取 Running 实例）。以后新建任何走云助手的脚本，**先按坑 9 自检有没有硬编码实例 id**。

### 20.3 perf 落地全链路（四步，每步都有回读）
1. `--perf-gen-secret`：`perf_session_secret` 现场生成，**跨环境反证 = `perf 6830c01d0d30` / `dev 734c5af1db1d` / `pre 881a665a44ff`，两两不同**（坑 1 的判据）；两条 DSN 打码后形如 `postgres://newapi:***@pgm-d9j9p421lzx4gw73…:6432/newapi_perf?sslmode=require`，只落保管目录（600）。
2. `--perf-apply-secret`：`secret/new-api-secrets created`。body 的 K1/K2 只出**键名 + 字节数 + host/port/db/user**，口令不进命令体；K6 顺带回了 dev 的 5 个负载指纹（未扰动）。
3. `PERF_APPROVAL=shared-pool-approved --perf-apply`：P0/P1 门禁按新口径重写（**载荷里出现 nodeSelector/toleration 直接拒**，因为共池后那是错的；占位符残留检测从"只查 nodepool"改成"查任何 `__X__`"）。结果 `configmap/deployment/service created` → `rollout_rc=0` → **2/2 Running**，两副本分别落 **5a 与 5c**（`topologySpreadConstraints` 生效），SA=`new-api-app`，镜像跨区免密拉取成功。
4. `--smoke perf`（冒烟 body 参数化后复用 pre 的同一套判据，不是另写一套）：
   - **V1b PG**：`conn=newapi_migrate@newapi_perf ssl=1`、`tables=42`、`users` 表存在 ⇒ **6432 托管池真的在承载业务**（比 TCP 握手强）。
   - **V1c 权限链**：`select count(*) from options` ⇒ 2 行可读；`create table` ⇒ **`ERROR: permission denied for schema public`** ⇒ 运行账号收权符合裁定 ①。
   - **V2 SQLite**：`ready=1（轮询 1 次）`、日志自证 `SQL_DSN not set, using SQLite as database` + `database migration started` + `ready in 242 ms`、`/data/one-api.db` 已建 ⇒ PASS。
   - **V3④**：`http://new-api-perf.new-api-perf.svc.cluster.local/api/status` 返回正常 JSON（只在本 ns 内可路由，无 Ingress/ALB ⇒ 与生产彻底隔离那条仍然成立）。

### 20.4 意外发现：`new-api-perf` 里有一个**不是我建的** `mock-upstream`
冒烟 V3③ 的对象清单里冒出 `deployment.apps/mock-upstream 6/6`（svc ClusterIP 80）。按"陌生对象先归因再用"的规矩查了：
- **时间线**：`created=2026-10-19T05:23:04Z`，`managers=kubectl-client-side-apply + kube-controller-manager` ⇒ 有人 `kubectl apply`，且**早于我 05:26 的 perf apply**，不是我任何 body 的产物。
- **形状**：镜像 `newapi-dev/mock-upstream:20261019-4788bec2e`（tag 日期=今天），容器口 **8080**（svc 80→8080），`requests 100m/128Mi`、`limits 1C/512Mi`，env 只有 7 个键：`FIRST_TOKEN_DELAY_MS / TOKEN_INTERVAL_MS / TOKENS_PER_RESPONSE / TOKEN_TEXT_BYTES / ERROR_RATE / ERROR_STATUS / EXTRA_LATENCY_MS`（值不外显）。
- **与指南对得上**：`deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md:6181-6187` 任务 33 步骤 2  prescribed 的 mock 正是"6 副本 + 这几个延迟/错误率旋钮 + 期望 `6/6 Running`" ⇒ **现网已按卡片把 mock 建好**，判据达成。
- **意义**：perf 侧原先"没有可用上游、压测只能靠真实厂商（会被打死并触发风控）"这条阻断（§17.6 的 ③）已由 mock 解除，**任务 33 的前置条件之一提前满足**。
- **未闭合的一点**：从 perf Pod 里 `wget http://mock-upstream.new-api-perf.svc.cluster.local/` 回的是**空响应体**（`/` 根路径可能就是空 body）。SSE 压测要的是 `/v1/chat/completions`，**这条链路的契约我还没实测**，不能因为 Pod 6/6 Running 就说"压测上游可用"。

### 20.5 本轮登记的三个缺口（都不是"顺手能修"的，需要负责人口径）
1. **ResourceQuota 三 ns 全空**：K5 实测 `new-api-pre` / `new-api-perf` 都 `No resources found`，与卡片步骤 1 的"配额总账"口径不符。`bodies/create_ns.sh` 里那套配额数字（pre 1C/perf 4C）是按**旧池 + 独立 perf 池**算的，现池与裁定都变了 ⇒ **我没有擅自重建**（别人删掉的东西重建回去，风险高于收益），改在 `apply_pre_app.sh` 的 A7 里如实标 `[缺口]` 并打回读。**待裁定**：共池后要不要给 perf/pre 上限（不给的话 perf 一压起来会把 dev/pre 一起带走）。
2. **dev 基线已换代**：`newapi-dev` 现在是 **5 个负载**（多了 `new-api-channel-task-dev`、`yxw-new-api-master`、`yxw-new-api-slave`），镜像也分两档（`20261016-dcd62278` 与 `20261015-c62445555`）。旧文档写"三个负载身份指纹"的判据已过期，本轮读数以 S6/A6/K6 的 5 行指纹为新基线（三处互证，全部 0 重启）。
3. **perf 的档位撑不起任务 33 的 S2**：S2 判据是 **1500 并发 SSE**，perf 现在是 2 副本 × limits 2C（共池余量只剩 1.5–1.76 核/节点）⇒ 真按卡片压会先撞**网关副本**和**共池邻居**，测不到应用容量。这是任务 33 的前置缺口，不是任务 45 的（本轮不动）。

### 20.6 我自己这轮的第二个小 bug（同类于 §17.5，登记为可读性证据）
`readback_perf_state.sh` 的 S3 用了一条 jsonpath 把 `labels` 和 `annotations` 写进**同一个字符串字面量**：`{"\n    annotations={.metadata.annotations}"` —— `{` 在字符串里又起了一个 action，解析器报 `unrecognized character in action: U+005C '\'`。前半段（managers/times/created/uid）已正常返回，所以**归因证据没受影响**，labels/annotations 这一项没读到。修法：一个 `-o jsonpath` 只出一个字段组，别在字面量里嵌 `{}`。⚠ 同 §17.5 的规矩：**报错输出不等于对象不存在**，这里我明确写了"这一项没读到"，没有把报错读成"mock 没有标签"。

## 21. 任务 33 的 S2 半边：perf 压测链路打通 + 降档阶梯实测（2026-10-19，**800 档第一读是错的，已纠正**）

负责人本轮裁定三条：① ResourceQuota **「不用动」**（§20.5-1 的缺口保持登记状态，不擅自重建）；② **「按实际资源降回一些并发，如 1500 并发，下降到 800 并发」**；③ 生产日志库 DSN 改写/发布 **「不要动」**。另：会话权限已放宽，允许我直接重试执行。

### 21.1 前置不是"卡片写了就算有"：三件必须先证明的事
1. **mock 上游的 SSE 契约**（§20.4 留的尾巴）。`bodies/probe_mock_contract.sh` 实测：`POST /v1/chat/completions` 首字 **301 ms**（= `FIRST_TOKEN_DELAY_MS`）、**52 个 `data:` 块**、块间隔 ≈30 ms、末块 `[DONE]`；`/healthz`、`/metrics`、`/v1/models`（`mock-gpt`）都在。⇒ 上游可用**这条以前是推断，现在是实测**。
   ⚠ 同一支脚本的第一版有个我自己造的假 FAIL：`CPod` 的 jsonpath 尾部多打了一个空格 ⇒ 后续 `curl http://$IP:8080` 全部 `curl: (3) Port number ended with ' '`，我一度据此写"mock 不是 OpenAI 兼容 SSE"，而同一次运行的 M6 段已经返回了正常流式体——**自相矛盾被我读成了结论**。修法：字段逐个 `tr -dc '0-9'` / `tr -d ' \r'` 清洗，别把空格带进 URL。
2. **执行器根本不存在**：节点上 `command -v k6 hey ab wrk` **四个全空**，可用的是 `python3 3.6.8` + `curl 7.61.1` ⇒ 卡片里 `k6 run -e VUS=1500 …` 在雅加达站**不可直接执行**。驱动改为仓内自带的 selectors 非阻塞 SSE 驱动（`bodies/run_perf_sse_staircase.sh` 内嵌 python）。指南任务 33 已按实测补注（不删原文，加"本站实测修正"段）。
3. **压测链路是零状态**：`check_perf_load_inputs.sh` 回读 `channels=0 tokens=0 users=0 logs=0`（perf 库是空库），且 `new-api-perf` 已被缩到 **1 副本**（见 21.4）。所以"perf 就绪"不等于"能压"，中间缺的是**管理员 seeding → 渠道 → 令牌**整条链。

### 21.2 建链路上踩的四坑（每个都改了脚本，不是改了口径）
| 现象 | 真相（代码/实测） | 处置 |
| --- | --- | --- |
| `POST /api/token/` 只回 `{"success":true}`，取 `data.id` 为空 | add 接口**不回 id** | 令牌/渠道 id 一律 **SQL 回读**为准；"apply/接口成功"不等于对象存在 |
| 拿 `POST /api/token/:id/key` 的值当 Bearer ⇒ **401 ×6** | 该接口 `data` 是**对象**不是字符串；我 `jval data` 把 dict 打印成 59 字符脏值 | key 改从 DB 读，**先校验形态**（48 位、连字符数=0）再用；`middleware/auth.go` 的鉴权是 `TrimPrefix("sk-")` → `Split("-")[0]` → `DB.Where("key=?")`，脏值必然 `record not found` |
| 修好 key 后 **404 `bad_response_status_code` ×6** | `relay/common/relay_utils.go` 的 `GetFullRequestURL = base_url + "/v1/chat/completions"`（只有 cloudflare 前缀才 `TrimPrefix("/v1")`）⇒ 我把渠道 `base_url` 写成 `…/v1` 就拼成 `/v1/v1/…` | `fix_perf_channel_url.sh`：删掉 `base_url like '%/v1'` 的渠道 → 以不带 `/v1` 重加 → 重试 ⇒ **PASS http=200 ttfb=0.345 data=52 done=1，logs 落库 1 条** |
| 管理员口令丢了（`perfroot` 入库但无人持有口令） | 上一版把"写 Secret"排在取 token id 之后，前一步 exit 就带走了口令 | 恢复：删 `setups`+root+残留行 → `rollout restart` → `/api/setup` 门禁重开（`model/main.go:70 CheckSetup()` 启动时重算 `constant.Setup`；`createRootAccountIfNeed` 在本仓**无调用点**）→ **口令生成后立刻落 Secret**，再往下走 |

### 21.3 S2 阶梯实测（30/100/300/500/800 × 60s，InvokeId `t-ida70hx49bm0sg0`）
| 并发 | 成功流 | 吞吐 | 首字 P50/P95/P99 | 端到端 P50/P95 | 错误构成 | 网关 restarts |
| --- | --- | --- | --- | --- | --- | --- |
| 30 | 960 | 16.0 rps | 342/355/563 ms | 1.84/1.86 s | 30（**全部是在途**，非服务端错误） | 0→0 |
| 100 | 3099 | 51.6 rps | 346/540/603 | 1.86/2.05 | 100（在途） | 0→0 |
| 300 | 8281 | 138.0 rps | 718/902/1006 | 2.22/2.41 | 300（在途） | 0→0 |
| 500 | 12522 | 208.7 rps | 978/1262/1441 | 2.48/2.76 | 500（在途） | 0→0 |
| 800 | 15729 | 262.1 rps | 1493/2017/2249 | 3.00/3.52 | **11776，其中 `http_403=10976`** ⇒ **本轮该档作废** | 0→0 |

**三条读数纪律**（都是本轮实测逼出来的，不是风格问题）：
- **"错误=并发数"不是失败率**。驱动按墙钟收口，到点仍在途的连接被我计成"超时中留"，所以每档"错误"恰好等于 CONC；服务端侧 `restarts=0→0`、`phase=Running`、dev 邻居全 Ready。判读只认错误分布里的 `http_5xx`/`connfail_*`/`eof_status`。
- **驱动不是瓶颈，但也不能不看**。`TIMEFORMAT` 实测：800 档 `real=60.04 user=4.60 sys=3.27` ⇒ 单核只用了 ≈8%，`user < real`（**不是**早期担心的"user≈real 单核到顶"）。所以这一档的数可以当网关侧观测用。
- **`mock_requests_total` 单 Pod 采样 ≠ 集群合计**。mock 是 6 副本，一次经 ClusterIP 的 `curl /metrics` 只命中一个 Pod 的计数器（800 档读到 9107，而驱动侧成功流 16658）——**不能据此说上游丢请求**。已在输出里固定标注。

### 21.4 800 档那个 42.81% 错误率：**我先读错了，再用一支可证伪的脚本纠正**
- 我的第一读法："800 并发把网关打出了 403" ⇒ 会写成"容量拐点在 500–800 之间"。
- 反证路径（`bodies/diag_perf_403.sh`，头注就写了**判据**：若是额度，"现在单发一条"也必须 403；若是限流，"现在重试就通"）：
  - H1 `users: id=2 quota=-826490 used_quota=100826490 req=41532 status=1`；`tokens: unlimited=true`；`logs=41532`（全部 `type=2` 消费）。
  - H2 现在单发一条：**http=403**，body 原文 `用户额度不足, 剩余额度: ＄-1.652980 … "code":"insufficient_user_quota"`。
  - H3 网关日志同一条 `relay error: 用户额度不足` + `403 … 9.46 ms`。
  - H4 `options` 只有 4 行，**没有任何 limit/quota/rate 配置** ⇒ 限流假设排除。
- 结论：**那是测试夹具的钱包被压测本身吃光**（`service/billing_session.go:388` → `model.GetUserQuota`），**不是网关容量**。四档累计 40591 条成功流 × 单条 ≈2422 ≈ 1e8，正好等于 `/api/setup` 给 root 的初始 `quota=1e8`。
- 处置（`bodies/topup_perf_quota.sh`，**只写 perf 库**：先 `select current_database()` 断言 `newapi_perf` 才允许 UPDATE）：`quota` 补到 **1.5e9**。两个顺带的实测收获：① `users.quota` 是 gorm `type:int` ⇒ **PG integer 上限 2147483647**，补额度不能凭感觉给；② **本部署未开 Redis ⇒ `GetUserQuota` 走 DB 直读，改完不重启立刻生效**（T2 单发 `http=200 ttfb=0.346`）。
- 重测（`bodies/run_perf_sse_800_confirm.sh`，InvokeId `t-ida70hyqkue4kcg`，同参 800×60s + 前后哨兵）：**成功流=16658、吞吐=277.6 rps、首字 P50/P95/P99=1499/1940/2105 ms、端到端 P50/P95=3.00/3.44 s，`http_403=0`，`restarts=0→0`，dev/pre 邻居全 Ready**。哨兵跑前 `200/0.347s`、跑后 `200/2.20s`（跑后那条慢是网关还在排自己最后的连接，不是新故障）。
- **这一档真正的上限是"并发数"自己给的**：`16658 ÷ 60s ≈ 277`，端到端 P50 3.0s ⇒ **277 ≈ 800 ÷ 3.0（Little 定律）**；而 3.0s ≈ mock 固有流长（300 ms 首字 + 52×30 ms ≈ 1.86 s）+ 排队。⇒ **没有测到系统天花板，只测到"800 并发能跑出 277 rps 且首字劣化到 1.5 s"**。要拿 C（单实例容量）必须固定副本数并继续加档直到 rps 不再随并发上升。
- **同参第二样本（InvokeId `t-ida70i0bi1td0cg`，轮换 key 之后跑 ⇒ 顺带证明驱动从 Secret 取新 key 端到端可用）**：`成功流=16540、吞吐=275.7 rps、首字 P50/P95/P99=1492/1944/2130 ms、端到端 P50/P95=3.00/3.45 s、`http_403=0`、`restarts=0→0`、邻居全 Ready`。与第一样本差 **0.7%（277.6 → 275.7）** ⇒ 800 档这两个数是**可复现**的，不是单次噪声。
  ⚠ **一个我没解释掉的观察（不吹成结论）**：mock 侧 `mock_errors_total` 从单 Pod 采样的 **15 → 299**（两次都只命中 6 副本中的 1 个，仍不同量级），而 mock 的 `ERROR_RATE=0`（§20.4 实测 env 形态）。**假设**：该计数在 mock 实现里把"客户端提前断开"也算 error——我们的驱动固定 `Connection: close` 且到点丢弃 800 条在途流 ⇒ 数量级正好对得上。**但这是假设，未验证**：要证必须 ① 按 Pod 逐个抓 `/metrics` 求和，② 读 mock 镜像里该计数器的定义（不在这份 fork 仓库内）。**在这一条闭合前，不许把 `mock_errors_total` 读成"上游故障率"**，也不许用它反推丢包。
- 归因两侧都不饱和：网关 Pod `requests.cpu=1 / limits.cpu=2`，档位结束即刻采样 **883m / 224Mi**（≈limits 的 44%，且这是 metrics-server 的**衰减窗口**，不是档内峰值，不能当"打满"读）；RDS `pgm-d9j9p421lzx4gw73` 同窗口 **CPU 峰值 47.99%（09:20Z）/ 34.40%（09:34Z）**，基线中位 **0.333%**；**连接使用率峰值 11.72%**（MaxConnections=400 ⇒ ≈47 条）。⇒ **本轮不构成"瓶颈在 DB 规格"**（任务 33 那条判读规则这次不触发）。取数脚本 `deploy/jakarta_pre/poll_rds_cpu_window.sh`（`CpuUsage` + `ConnectionUsage`；`ActiveConnections` 这个指标名不存在，猜名会拿 400 且 body 不是 JSON）。

### 21.5 副本数、凭据与我自己的另外两处错（都留证据，不销毁）
- **1 副本不是我干的**：`managedFields` 实测 `mgr=OneConsole-App-CS op=Update time=2026-10-19T08:18:25Z`（控制台侧），事件 `Scaled down replica set new-api-perf-648988c6f from 2 to 1`；我这一侧最后一次动作是 `mgr=kubectl-rollout … 08:50:25Z`（恢复 setup 用的 restart）。§20.3 的 `2/2 Running` 与本轮的 `1/1` 都是真的，只是**分母变了**——所以跨轮比 rps 必须带副本数一起写。我没有把副本改回 2：**控制台里有人正在操作同一套夹具，抢改别人的显式决定风险高于收益**，列为待负责人裁定（见 21.7-①）。
- **§18.7 我自己破了一次规**：`diag_perf_token.sh` 的 D0 为了判形态，把 `left(key,4)` 的**明文 4 个字符**打进了输出。规矩的存在理由恰恰是"任何取子串再打码的路径都会漏"。处置 = **轮换该令牌**（`bodies/rotate_perf_token.sh`：删旧 → 服务端生成新 key → 形态只用**计数**校验（`len=48 连字符=0 sk-前缀命中数=0`）→ 回写 Secret → 单发 SSE `200/0.343s/data=52`）。失效证据（`bodies/confirm_token_softdelete.sh`）：`id=2 alive=false deleted_at=2026-10-19 16:43:56+07`、`id=3 alive=true`、**有效令牌=1**、`Secret token_id=3` ⇒ 旧 key 已被 GORM 软删排除，应用侧查不到。
  - 顺带两个 schema 事实：**`tokens` 有 `deleted_at` 软删，`channels` 没有该列**（我按直觉给 channels 加了 `deleted_at` 条件 ⇒ `column "deleted_at" does not exist`；`[X3] 只有一条活渠道`这一项**改由 W2 的 `channels=1` + 那一条是 `mock-perf` 直接证**，没有靠这条报错蒙混）。另 `users` 是 `used_quota` 不是 `used`，`tokens` 是 `remain_quota`/`used_quota`。
  - ⚠ **同一支轮换脚本又给了我一课**：`fp()` 只读 `$1`，我却用 `… | fp` 管道喂 ⇒ `set -u` 报 `$1: unbound variable`，管道里的值被丢掉，算出来的是 **`md5(空串)=d41d8cd98f…`** ⇒ 那一行"指纹已变（d41d8cd98f → 2493e184da）"是**假证据**（比较对象根本是空串）。已把 `fp` 改成参数/管道两用，并**改用软删状态 + 新 key 能跑通 + token id 2→3** 三条实证据替代。教训与 §17.5/§20.6 同源：**函数契约要匹配调用方式，报错出现时先怀疑自己的取数，别把漂亮输出当验证。**
- 口令/key 的去向：全部只在节点侧生成、直接落 k8s Secret `perf-load-test-credentials`；命令体、台账、会话输出**不含明文值**（只出长度/计数/md5 前 10 位：`admin_password len=24 fp=0411609137`、`token_key len=48 fp=2493e184da`）。**待办**：perf 的 root 口令轮换（口令曾以明文活在会话内过一次 shell 变量，属 §18.7 敏感面）。

### 21.6 本轮新增/停用的脚本（都在 `deploy/jakarta_pre/`）
新增：`bodies/probe_mock_contract.sh`、`check_perf_load_inputs.sh`、`readback_perf_scale.sh`、`wire_perf_a_setup.sh`、`wire_perf_b_channel.sh`、`diag_perf_token.sh`、`fix_perf_channel_url.sh`、`run_perf_sse_staircase.sh`（7658B，贴着 ECS RunCommand 15000B 门禁的余量：包装层 kubeconfig 就占 ≈7.1KB）、`diag_perf_403.sh`、`topup_perf_quota.sh`、`run_perf_sse_800_confirm.sh`（7664B）、`readback_perf_resources.sh`、`rotate_perf_token.sh`、`readback_perf_final_state.sh`、`confirm_token_softdelete.sh`、`poll_rds_cpu_window.sh`、`find_rds_conn_metric.sh`。
停用：`bodies/wire_perf_relay.sh`（合并版，16519B 超门禁 + 内含已知错的 `base_url=…/v1`；**只加 SUPERSEDED 头注、不销毁**，正文里两处自曝仍是证据）。
驱动 bug 登记：第一版 python 驱动在非阻塞 `connect_ex` 刚返回就 `sendall` ⇒ `BlockingIOError`，异常路径不登记连接，外层 `while len(conns) < CONC` **死循环空转**（100 并发即挂；本地 `| tail` 还把输出全缓冲，看起来像"压测卡死"）。修法：connect 后先注册 **EVENT_WRITE**，可写事件里再发；补齐循环改"每 tick 定量、绝不 while 自旋"。挂住的那次用 `aliyun ecs StopInvocation` 收的。

### 21.7 未闭合（按需要负责人口径的程度排序）
1. **perf 副本数要不要回到 2**（现在 1/1，是控制台侧缩的）⇒ 决定 S2 后续读数的分母；我不抢改。
2. **1500 并发（原 S2 判据）与 S3 突发仍未测** ⇒ 任务 33 的 S2 在雅加达站记**「未达成」**，不是"通过"；要测 1500 需要先回答 ① 和额度预算（1500×10 min 级 ≈ 需 `quota` 远超 PG integer 上限 ⇒ **必须改用长流/短时长或每轮补额度**，不能靠一次补满）。
3. **ResourceQuota 保持"不动"**（本轮裁定），因此共池无上限这一事实继续有效：perf 再压更高档位时，**dev/pre 邻居会被一起带走**——本轮 800 档没有（邻居全 Ready），但那是"没到量"而不是"有护栏"。
4. 任务 45 的 MySQL 列（顺延 T+14）、Prepaid 续费（生产 PG 2026-10-28 / dev RDS 2026-11-12 / 日志 MySQL 2026-11-15）、仓库明文凭据脱敏与口令轮换（负责人 2026-10-19 早前口径「暂时不用管」，此处仅登记不执行）——继续携带。

## 22. pre / perf 接入共享日志库 `newapi_logs`（2026-10-20，**Secret 补第 5 键 + 4 个 Deployment 重启**）

### 22.1 变更与源值形态
负责人要求：参照 `newapi-dev` 的 `LOG_SQL_DSN`，给 `new-api-pre` / `new-api-perf` 的 `new-api-secrets` 补同一个键，三环境共用日志库。
- 源值实测（只出形态，不出值）：`postgres` @ `pgm-d9j9p421lzx4gw73…:6432`、db=`newapi_logs`、user=`newapi`、len=129、sha256=`459e8dd9ecea`。
  ⇒ **不是马尼拉 MySQL**，就是雅加达本地 PG 的 `newapi_logs` 库、走 6432 托管池；同 VPC，无需白名单/网络变更。
- 写入工具（新增）：`deploy/ops/bodies/sync_log_dsn.sh` —— `APPLY=0` 只读取证 / `APPLY=1` 才 patch；`RESTART=1` 才滚动重启；
  值经 600 临时文件 `--patch-file` 传入，**不进 argv、不进输出**；命名空间白名单只放 dev/pre/perf。
- 回读：pre / perf 的 `LOG_SQL_DSN` 与 dev **逐字同值**（sha256 `459e8dd9ecea`），两 ns 键面均为 5 个
  （`SQL_DSN` / `SQL_DSN_MIGRATE` / `SESSION_SECRET` / `REDIS_CONN_STRING` / `LOG_SQL_DSN`）。

### 22.2 生效判据（envFrom 只在容器创建时求值 ⇒ 必须重建 Pod）
- `rollout restart` 四个业务 Deployment：`pre-new-api-master` / `pre-new-api-slave` / `perf-new-api-master` / `perf-new-api-slave`，
  **`mock-upstream`(6) 明确跳过**；四次均 `successfully rolled out`。
- 运行中进程 `printenv LOG_SQL_DSN` 的 sha256 与 dev 同值（pre/perf 共 4 个 Pod 全 OK；`startTime=2026-10-20T04:58:59Z`、`restarts=0`）。
- master **全量**日志（非 tail 截断）：`using PostgreSQL as database` ×2 + `database migration started` ×2（= 主库 + 日志库各一次），
  `[FATAL]`/`panic` **0 条** ⇒ `InitLogDB` 成功（该函数失败会 `FatalLog` 退出，见 `model/main.go:268`），`migrateLOGDB()` 已在 `newapi_logs` 上跑过。
- 同 ns Service `/api/status` 两侧均正常返回。
- 证据 InvokeId：`t-ida70kuo8cd7xts`（写 Secret）· `t-ida70kup085x1c0`（重启）· `t-ida70kurfdvdc74` / `t-ida70kusndkhse8`（验证）。

### 22.3 顺带修掉的持久性坑（不修就会被下一次重跑静默回退）
- `deploy/ops/bodies/apply_pre_secret.sh` 原先用 `create secret --dry-run | apply` **只建 3 键**，且**显式拒绝**载荷里出现
  `LOG_SQL_DSN` / `REDIS_CONN_STRING` ⇒ 任何人重跑一次就把刚加的键删掉。已改为 **merge patch**（只覆盖托管的 3 键、其余保留），
  并加 K3b：目标缺 `LOG_SQL_DSN` 时自动从 dev 复制同源值。
- `deploy/jakarta_pre/README.md`、`deploy/jakarta_perf/README.md` 的「secret keys 4 个（缺 `LOG_SQL_DSN`）」已按实况改为 5 键。

### 22.4 需知
- 三环境写入**同一张 `logs` 表、无环境列区分** ⇒ 按负责人裁定执行，但按环境切分统计不可行是预期副作用。
- 日志库与 pre/perf 的主库**同一实例**（`pgm-d9j9p421lzx4gw73`）⇒ 任务 41 的 I-1 连接预算此后应把 pre/perf 的日志连接一并计入；本轮只做接线，未重算。
- 未改动：马尼拉正式环境的 `LOG_SQL_DSN`（仍指向已删除的 CK，属另一条待核准变更）、`mock-upstream`、任何 ResourceQuota。


## 23. 任务 33 · 压测第一轮：1500 并发 SSE 通过（2026-10-20，`new-api-perf`，k6 口径）

> 完整数据与未跑场景：`deploy/logs/perf_task33_20261020/README.md`；k6 脚本 `deploy/perf/k6/sse.js`。

**环境定版（用户 2026-10-20 裁定）**：不建独立节点池、复用 `np-jkt-dev-x4c`；控制台已建 `perf-new-api-master` / `perf-new-api-slave`（各 1 副本，镜像 `20261015-c62445555`）。本轮补了 `svc/perf-new-api-master`（原先只有 slave 有 Service）。库身份 psql 断定为 **`newapi_perf`**（42 表），`SQL_DSN`/`SQL_DSN_MIGRATE` 均 @6432 经池；Redis 与 dev 同实例、**db=2**（dev db=0）。

**端到端**：channel `mock-perf`（OpenAI → mock）已存在且启用；经 slave 打 `/v1/chat/completions`：非流式 200、SSE 52 chunks + `[DONE]`。

**容量结论（单副本恒定 VU×120s）**：100/300/600/900 VU 全绿（P95 TTFB 342→713ms，CPU 148→927m）；**1200 VU 破线（P95 949ms，CPU 1017m）⇒ 单副本 C ≈ 1000–1100 并发流**。
**1500 并发验收**：双副本并行各 750 VU —— master P95 **557ms** / slave P95 **626ms**，0% 5xx，合计 ≈689 rps ⇒ **S2 判据达成**（本环境无 ALB/NAT/真实上游开销，结论不外推到生产容量，仅作流水线验收与 C 基线）。


**与 §21（10-19 curl 驱动）读数的差异（必须一起看）**：同档位下本轮 k6 明显更好（900 VU P95 713ms vs §21 的 800 档 P95 1.94s）。差异来源**未闭环**，候选：客户端形态（k6 长连接连接池 vs curl 每请求新建连接/进程）、计时口径（`http_req_waiting` 不含建连 vs `time_starttransfer`）、窗口 120s vs 60s。本轮数据内部自洽（100→1200 单调劣化、0% 5xx），但**在补一次同驱动对照前，不把两组数混用**；C≈1000–1100 是 k6 口径下的结论。

**三条环境问题（待处置）**：① `LOG_SQL_DSN` 指向 dev 的 `newapi_logs` ⇒ perf 日志串进 dev 库（与坑 3 同类），建议改指 `newapi_perf`；② Redis 与 dev 同实例（db 隔离）⇒ **S6 只能 pod 侧断连**，不得停实例；③ 仓库 `new-api-perf.yaml` 仍带独立节点池占位，与实际控制台负载不一致，需对齐或废弃。

### 23.1 事故：channel 的 API 地址被改成网关自身域名 ⇒ 401 自环（2026-10-20，已修复）

**现象**：控制台把 `mock-perf` 的「API 地址」从 `http://mock-upstream.new-api-perf.svc.cluster.local` 改成 `https://perf.likha.hk` 后，请求报 `401 Invalid token`。

**根因**：channel 的 API 地址是**上游厂商地址**；`perf.likha.hk` 是 perf 网关**自己的公网入口**（`ingress/perf-route` → 同一 Service）⇒ 自环：客户端请求 → 网关 → 按 channel 转发给 `perf.likha.hk` → 回到同一网关 → 这次拿 channel 的密钥当客户 token（`key` 为空）→ 鉴权失败 401。若 channel key 恰好是有效 token，会退化成无限递归（请求量自乘），比 401 更危险。

**修复**：`channels.base_url` 改回 mock（id=3），等 `SYNC_FREQUENCY=30s` 缓存同步；复验：非流式 200（0.32s）、SSE 200（52 chunks / 1.83s）。**注意**：admin API 的 `PUT /api/channel/` 用 GET 读出的对象回写会回 `{"message":"Invalid parameters"}`（含只读字段），本轮改走库内 UPDATE，后续写一个只提交可变字段的 patch 更稳。

**附带核实**：公网入口本身健康 —— `https://perf.likha.hk/api/status → 200（ssl_verify=0）`、`http → 301`。若要做「经 ALB 公网路径」的压测，改 k6 的 `BASE=https://perf.likha.hk` 即可，**channel 保持指向 mock，不要填网关域名**。

**压测脚本归档（2026-10-20）**：一次性 /tmp 脚本已整理为 `deploy/perf/k6/`（`run.sh` 本机入口 + `bodies/{stage,dual1500,summary,readback}.sh` 节点侧 + `sse.js` + README）。
用法：`bash deploy/perf/k6/run.sh stage perf-new-api-slave 300 120s` / `dual1500` / `summary` / `readback`。
归档后回归实测：50 VU×20s → 550 请求、0% 5xx、P95 501ms、cpu_peak=62m，`summary`/`readback` 两动作输出正常。

**channel 局部更新脚本 + 公网 ALB 压测路径（2026-10-20）**：新增 `deploy/perf/channel_patch.sh`（本机入口）+ `deploy/perf/bodies/channel_patch.sh`（节点侧）。
根因：`PUT /api/channel/` 的 body 含 `status` 会被 `controller/channel.go:1134` 直接拒（`Invalid parameters`）；后端 `model.Channel.Update()` 是 GORM `Updates(struct)` ⇒ 只改非零字段，天然支持局部 patch；状态走 `POST /api/channel/:id/status`。
实测：`--show` 回读正常；`base_url` 改值→回改均成功（before/after 打印一致）；`--status 2/1` 禁用再启用成功并回读 `status=1`。
公网路径：`run.sh stage https://perf.likha.hk 20 20s` → 220 请求、0% 5xx、P95 486ms（k6 在集群内 → NAT → ALB → 网关）；30VU 复跑 330 请求、P95 352ms。`stage` 第一参含 `://` 即按 URL 直用。

**压测报告自动化 + 公网路径瓶颈定位（2026-10-20）**：`run.sh` 每次 stage/dual1500 自动落日志并生成单文件 HTML（`deploy/logs/perf_reports/index.html`，`report.py` 渲染，内联 CSS+SVG，无外网依赖）。
报告内容：摘要卡（最优通过档 / 单副本拐点 / 1500 所需副本）、明细表（RPS、P50/P95/P99 首字、端到端 P95、错误率、checks、CPU/内存峰值、下行 Mbps、PASS/FAIL）、趋势图、瓶颈判定（事实与推断分开）、理想 QPS/资源效率、完整公式段（Little 定律、每核吞吐、拐点插值、副本数、带宽利用率）。
**实测发现（重要）**：公网路径 `https://perf.likha.hk` 的瓶颈是 **dev NAT 的 EIP 仅 5 Mbps**（按流量计费）——120 VU 下行已 6.24 Mbps、150 VU 7.38 Mbps，600 VU 时 RPS 塌到 52、错误率 14.4%，而应用侧 0 条 5xx、CPU 仅 0.26 核 ⇒ 链路先饱和，不是网关容量。报告在该情形下**拒绝输出拐点**并提示改用内网直连。
**路由事实**：`perf.likha.hk` 的 Ingress 只指向 `svc/perf-new-api-slave`（1 副本）；内网 dual1500 才是双副本。

**报告与双副本口径修订（2026-10-20 晚）**：报告改存 `deploy/perf/perf_reports/`，文件名 = `perf_report_<参数摘要>_<启动时刻到秒>.html`（每次运行一份，不再覆盖 index.html）；标题改 `new-api · SSE 容量压测报告`、去掉任务编号；主题换绿色科技风（页头深绿渐变 + 绿色数据点），公式区代码与脚注加深底色/加粗边框提高对比；趋势图数据点**可点击**弹出该次运行明细（原生 JS，单文件无依赖）。
**双副本方式变更**：`dual1500` 不再使用 `perf-new-api-master`，改为 `kubectl scale deploy/perf-new-api-slave --replicas=2` 后单 Job 打 `svc/perf-new-api-slave`（kube-proxy 分摊）。实测：`ready=2/2`、VUS=80 小档通过，报告 `perf_report_dual-slave2-vu80-dur15s_20261020-175655.html`。

## 24. 任务 33 · S1–S10 全场景实测（2026-10-20，`perf-new-api-slave` ×2）

> 汇总与逐场景报告见 `deploy/perf/perf_reports/SUMMARY.md` 与同目录 12 份 HTML。
环境：slave 2 副本（未用 master）、mock 6 副本；S1–S5/S10 内网 ClusterIP，S9 公网 ALB。新增 k6 脚本：`s3_burst.js` / `s4_admin.js` / `s9_long.js`，执行器 `bodies/scenario.sh`（burst/admin/degrade/rolling/long），`run.sh` 文件动作 `burst/admin/degrade/rolling/long`。

| 场景 | 实测 | 判定 |
|---|---|---|
| S1 500 VU | 255.5 rps / 0% / P95 398ms | ✅ |
| S2 1500 VU（2 副本） | 701.6 rps / 0% / P95 578ms | ✅ |
| S3 突发 0→1500/30s | 604.3 rps / 0% / P95 540ms | ✅ |
| S4 800 QPS（默认限流） | 799.4 rps / **99.25% 429** | ❌ 限流拦截 |
| S4 800 QPS（限流放开） | 797.7 rps / 0% / P95 7.2ms | ✅ |
| S5 劣化 50%+5s | 50.99% 错误 / P95 5.34s / restarts 0 | ✅ 符合注入 |
| S9 12min 长流 | 12m04s 完成 / 0% | ✅ 600s 为空闲超时 |
| S10 滚动发布 | 0.14%（27/19096） | ❌ 未达 0 |
| S6 Redis | — | ⏭ 共用 Tair（db=2），停实例波及 dev/pre |
| S8 DB 切换 | — | ⏭ Basic 单机无备 |

**三条上线前待办**：① 管理面限流需按来源分桶/内部豁免，否则 800 QPS 目标不成立（默认 360/180s ≈ 2 rps/IP）；② S10 需 `maxUnavailable=0` + preStop + 就绪摘流，复测目标 0 错误；③ 文档把「ALB 600s 上限」改为**空闲超时**口径（实测连续流 12m 未被切）。
**副作用已复原**：测试期间临时放开的 `GLOBAL_API_RATE_LIMIT` 已删除并重启（CM 回读为空值），slave 2 副本 `ready=true restarts=0`。

**报告升级（2026-10-21）**：新增**完整报告** `deploy/perf/perf_reports/perf_report_ALL_latest.html`（每次运行后聚合 `perf/perf_reports` + 历史 `logs/perf_reports` 共 14 次运行重生成）。改进：① 趋势图按运行序号布点（14 个点全覆盖，不再只剩单点），悬停显示简卡、单击显示完整明细，深底亮字高对比；② 公式区新增「VU 是什么（Little 定律换算）」与 7 类 Job/动作的设计目的对照表；③ 新增「一次请求的链路耗时分解」堆叠图（上游首字 300ms / 网关+链路 / 流式吐字 1500ms / 传输余量，基于实测 P50）；④ 容量拐点只认内网稳态档，无破线档时最小二乘外推并标注（当前 **1,059 并发流/副本**、1500 需 **2 副本**）；⑤ 摘要卡拆出「管理面峰值 797.7 req/s / P95 7.2ms」，不再与 SSE 混算。

**报告二次优化（2026-10-21）**：① 修浮层白底浅字（全局 table 白底覆盖 → 强制透明 + 深底亮字）；② 链路耗时改模块级分解，数据取 k6 `http_req_{sending,connecting,tls_handshaking,waiting,receiving}` 的 **p90**；实测 200VU 档：发送 0.0ms / 连接 0.0ms / TLS 0.0ms / 网关+链路 41.9ms(2.2%) / mock 首字 300ms(15.4%) / 流式吐字 1500ms(77.2%) / 客户端接收余量 100ms，合计 1942ms；③ 条形图长标签移出到下方表格，消除文字重叠；④ `dual1500.sh` 补阶段指标过滤，`report.py` 用 `best_phase` 选档。

**第二轮全场景（2026-10-21，EIP 100Mbps）**：S1 500VU→251.9rps/0%/P95 433ms；公网 600VU→290.1rps/0%（上轮 5M 时 52rps/14.37%，带宽瓶颈消除）；S2 1500VU→639.2rps/0%/P95 792ms（贴线，CPU 0.84 核）；S3 突发→562rps/0%/P95 731ms；S4 管理面 800QPS（限流临时放开）→797.8rps/0%/P95 7.1ms；S5 劣化→50.99% 错误（与注入一致）；S9 长流 12m04s 完成未切断；**S10 滚动发布 0.00% 错误（上轮 0.14%）达标**。
容量：单副本拐点外推 **978 并发流**（内网稳态最小二乘），1500 并发需 2 副本、无余量，生产建议 3 副本。测试后已恢复默认限流（CM 键删除 + 重启，Pod ready=2/2 restarts=0）。完整报告 `deploy/perf/perf_reports/perf_report_ALL_latest.html`（23 次运行）。
