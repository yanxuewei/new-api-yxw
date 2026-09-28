# VPC + vSwitch 落地执行报告（对应操作指南 §2.2 / §4.1 / §5.2）

- 账号：`5108890064395960`；执行时间：2026-09-25 19:0x（GMT+8）
- 工具：`~/.workbuddy/binaries/aliyun-cli/aliyun`（v3.5.1）+ 幂等脚本 `create_vswitch.sh`
- 原始输出归档：`.workbuddy/vswitch_out/{vpcs,vswitches}_<region>.json`

## 一、结果总览（10 个 vSwitch / 2 个 VPC，全部 `Available`）

### 马尼拉 `ap-southeast-6` — VPC `vpc-newapi-mnl-prod` `vpc-5tst1tgeessxn1azwasg2` `10.0.0.0/16`

| vSwitch | vSwitchId | CIDR | AZ | 用途 | free IP |
| --- | --- | --- | --- | --- | --- |
| `vsw-mnl-pub-a` | `vsw-5ts9tgdq1xz3picjgoqyu` | `10.0.0.0/24` | `ap-southeast-6a` | ALB / NAT | 252 |
| `vsw-mnl-pub-b` | `vsw-5ts1dygyh2x0daspwny2r` | `10.0.1.0/24` | `ap-southeast-6b` | ALB / NAT | 252 |
| `vsw-mnl-app-a` | `vsw-5tswpyzfa8od6je95td1h` | `10.0.16.0/20` | `ap-southeast-6a` | Pod（Terway 真实 VPC IP） | 4092 |
| `vsw-mnl-app-b` | `vsw-5tshuvvtrqm97tnwe1ddm` | `10.0.32.0/20` | `ap-southeast-6b` | Pod | 4092 |
| `vsw-mnl-data-a` | `vsw-5tswufq2pi26l4ahoiu84` | `10.0.48.0/20` | `ap-southeast-6a` | RDS/Tair/日志库 | 4092 |
| `vsw-mnl-data-b` | `vsw-5tsxa8fupaf8xeyln0o7a` | `10.0.64.0/20` | `ap-southeast-6b` | RDS 备 | 4092 |

### 新加坡 `ap-southeast-1` — VPC `vpc-newapi-sg-prod` `vpc-t4nimmwvruexbnene0a3r` `10.1.0.0/16`

| vSwitch | vSwitchId | CIDR | AZ | 用途 | free IP |
| --- | --- | --- | --- | --- | --- |
| `vsw-sg-pub-a` | `vsw-t4ncxa4gqgamhl0o8e6yq` | `10.1.0.0/24` | `ap-southeast-1a` | ALB / NAT | 252 |
| `vsw-sg-pub-b` | `vsw-t4nhtsfk2z79e1ggvlhdz` | `10.1.1.0/24` | `ap-southeast-1b` | ALB | 252 |
| `vsw-sg-app-a` | `vsw-t4nbvsnvo4z52sumr9sck` | `10.1.16.0/20` | `ap-southeast-1a` | Pod | 4092 |
| `vsw-sg-app-b` | `vsw-t4n3dthz1ma6tp7bqor6h` | `10.1.32.0/20` | `ap-southeast-1b` | Pod | 4092 |

**与 §2.2 表逐行一致**：网段、AZ、用途、free IP 全部匹配文档期望值（`252 / 252 / 4092×4`、`252 / 252 / 4092×2`）。

## 二、标签（成本看板 R6/R39 依赖）

每个 vSwitch 已打 3 个标签：`project=new-api`、`site=ph-mnl|sg`、`env=prod`。
（`cost-center` 未填——文档标注「按财务」，待用户提供成本中心编号后补 `TagResources`。）

## 三、可用区实测

- 马尼拉 `DescribeZones` 返回 **仅 `ap-southeast-6a` / `ap-southeast-6b`**，与文档「只有这两个 AZ」一致；所有 vSwitch 已严格分属两 AZ（ALB 强制 ≥2 AZ 的前提已满足）。
- 新加坡 4 个 AZ（1a/1b/1c/1d），本次只用 1a/1b，与 §2.2 一致。

## 四、Pod 网段容量基线（§2.2 坑 2，M1 门禁证据）

| 段 | free IP | 说明 |
| --- | --- | --- |
| `vsw-mnl-app-a/b` | 4092 / 4092 | Terway 每 Pod 一个真实 VPC IP；**告警阈值：free < 200 设 P2** |
| `vsw-mnl-data-a/b` | 4092 / 4092 | RDS/Tair/CH 用 |
| `vsw-mnl-pub-a/b` | 252 / 252 | ALB/NAT，正常 |
| `vsw-sg-app-a/b` | 4092 / 4092 | 备站 Pod |

基线已随本次执行记录（见原始 JSON）；§12 每里程碑复核 `AvailableIpAddressCount`。

## 五、执行脚本（可重复执行）

`create_vswitch.sh`（幂等）：

```bash
bash create_vswitch.sh            # 全量：马尼拉 6 + 新加坡 4
bash create_vswitch.sh mnl|sg     # 单站点
bash create_vswitch.sh baseline   # 仅打印可用 IP 基线并归档 JSON
```

- 幂等逻辑：按 `VpcName` / `VSwitchName` 先查后建，已存在则 `[SKIP]`，不覆盖、不改网段（**vSwitch CIDR 创建后不可修改**）。
- 已内建 VPC `Available` 轮询（最长 60s），避免 VPC 未就绪时建 vSwitch。

## 六、踩坑记录（可长期复用）

1. **日志与返回值必须分离**：脚本里 `info` 打 stdout、返回值也 `printf` 到 stdout，`VPC_ID=$(ensure_vpc ...)` 会把日志一起吞进去 → `VpcId` 参数变成多行字符串，API 报 `Forbidden.VpcNotFound`（第 1 次执行踩中，马尼拉 6 个 vSwitch 全失败）。**修复**：日志一律 `>&2`，返回值走 stdout。
2. **`CreateVSwitch` 支持 `--Tag.N.Key/Value`**（N 从 1 起），实测生效；标签不是可选装饰，成本看板依赖它。
3. **`aliyun vpc DescribeVpcs --VpcId` 的返回仍是 `Vpcs.Vpc[0]` 数组**，不能用 `.0.` 路径解析。
4. 第 1 次执行虽然报了 6 个 vSwitch 失败，但 **VPC 已建成**（脚本先建 VPC 后建 vSwitch），重跑即靠幂等逻辑 `[SKIP]` 复用——**印证幂等设计价值**。

## 七、资源组归属（19:55 补充，已归位）

### 现状（执行前）

| 资源组 | ID | 资源数 | 说明 |
| --- | --- | --- | --- |
| 默认资源组 | `rg-acfnssmgwnsb5oa` | 6 | 系统默认，不可删 |
| `rg-ph-mnl` | `rg-aek4nyivmmsb6iy` | 0 | 2026-09-25 12:03 建 |
| `rg-sg` | `rg-aek4zvb3ldoiyua` | 0 | 2026-09-25 12:04 建 |

**问题**：本报告 §一 的 12 个资源（2 VPC + 10 vSwitch）创建时**未带 `--ResourceGroupId`**，全部落在**默认资源组**。

### 归位结果（已完成）

| 资源 | 资源组 |
| --- | --- |
| `vpc-newapi-mnl-prod` + 6 个 mnl vSwitch | `rg-aek4nyivmmsb6iy`（rg-ph-mnl） |
| `vpc-newapi-sg-prod` + 4 个 sg vSwitch | `rg-aek4zvb3ldoiyua`（rg-sg） |

**手段**：`aliyun vpc MoveResourceGroup --ResourceType vpc --ResourceId <VpcId> --NewResourceGroupId <rg>`
→ **VPC 迁移会级联其下 vSwitch**，无需逐个处理、无需重建、无停机。

### 4 条资源组实测硬结论（重要，决定后续所有资源怎么建）

1. **vSwitch 不能单独转移**：`resourcemanager MoveResources`（Service=vpc, ResourceType=vswitch）返回
   `UnsupportedOperation.MoveResources: This resourceType does not support move resources.`
2. **但 VPC 转移会级联 vSwitch**：`vpc MoveResourceGroup --ResourceType vpc` 执行后，该 VPC 下**全部 vSwitch 同步换组**。迁移 vSwitch 的唯一可用路径 = 迁其父 VPC。
3. **`CreateVpc` 支持 `--ResourceGroupId`；`CreateVSwitch` 不支持该参数**——但新建 vSwitch 会**自动继承所属 VPC 的资源组**（实测：VPC 在 rg-ph-mnl 时新建的 vSwitch 直接落在 rg-ph-mnl）。
   ⇒ 正确姿势：**先把 VPC 放到目标资源组，再建 vSwitch**。
4. **资源组必须在"创建时"决定，事后补救能力有限**：非 VPC 类资源（如已建的 OSS 桶、ACR 实例）需各自的路子；vSwitch 一旦被 NAT/ALB/ACK 占用就删不掉 → 只能连带父 VPC 迁移或返工。

### 资源组划分约定（2026-09-25 20:35 **定稿**，5 个组上限）

| 资源组 | ID | 放什么 | 不放什么 |
| --- | --- | --- | --- |
| 默认资源组 | `rg-acfnssmgwnsb5oa` | 仅系统遗留（不可删） | 任何 new-api 新资源 |
| `rg-ph-mnl` | `rg-aek4nyivmmsb6iy` | **马尼拉生产**（prod） | staging / perf / 压测 / 新加坡 |
| `rg-sg` | `rg-aek4zvb3ldoiyua` | **新加坡生产**（备站 prod） | 马尼拉资源 / 非生产 |
| `rg-nonprod` | `rg-aek4hk3prqgqjcy` | **staging + perf + 压测**（全环境非生产，**含未来非生产站点**） | 生产 |
| `rg-shared` | `rg-aek3yypouljf4ry` | 跨站点共享：ACR EE 实例、ActionTrail、CMS 拨测等 | 站点专有资源 |

**决策演进**：20:10 曾定「按站点收敛，staging/perf 也进 rg-ph-mnl」；20:35 用户改回 **生产 / 非生产分离**（更稳妥）。最终口径 = **RG 按「生产 vs 非生产」划边界，站点维度交给标签**。

**为什么这样更靠谱（关键收益）**：

- 生产与非生产是**权限边界**问题：「谁能动生产」是必须拦住的线；「谁能动马尼拉」通常不是。
- 边界落到 RG 后，RAM 授权可以**按资源组授权**（`acs:ResourceGroupId` 条件），一条策略表达「ops 对 rg-nonprod 可写、对 rg-ph-mnl/rg-sg 只读」——不必再逐个资源写 ARN 条件。
- 非生产（staging/perf/压测）是**高危高频操作区**（反复建删、打流量、注入故障），单独一组把爆炸半径锁在组内。
- 站点维度不丢：`site=ph-mnl|sg` 标签 + 命名空间（`new-api` / `new-api-staging` / `new-api-perf`）继续承担筛选与计费维度。

**代价 / 必须配套**：

- ⚠️ **换组会立刻改变权限**：一旦启用「按资源组授权」，任何 RG 迁移都必须与策略变更**同批发布**。当前 `newapi-*` 策略仍是 ARN 维度，尚未踩这个坑。
- 非生产资源**必须显式指定** `--ResourceGroupId rg-aek4hk3prqgqjcy`，否则落默认组（vSwitch 不可事后单独转移，只能返工）。顺序：**先建 nonprod VPC 并放进 rg-nonprod → 再建其 vSwitch**。
- 建议配套两条：① RAM 策略新增 `newapi-nonprod-operator`（RG 维度）；② 标签策略强制 `env` 键，防止打错。

**执行铁律（来自 §七 实测）**：目标资源组必须在**创建时**指定；VPC 类先定 VPC 组再建 vSwitch；非 VPC 类资源（OSS/ACR 等）各自走 `Put*ResourceGroup` / `ChangeResourceGroup`。

### OSS / ACR 归位（20:28 已完成）

默认资源组已清空（`ListResources --ResourceGroupId rg-acfnssmgwnsb5oa` → `count=0`）。

| 资源 | 原生手段 | 目标组 | 结果 |
| --- | --- | --- | --- |
| `oss-newapi-mnl` | `ossutil api put-bucket-resource-group` | `rg-ph-mnl` `rg-aek4nyivmmsb6iy` | ✅ |
| `oss-newapi-backup-sgp` | 同上 | `rg-sg` `rg-aek4zvb3ldoiyua` | ✅ |
| `cri-avfqy9xkqi5bj8ee-registry` | 同上 | `rg-shared` `rg-aek3yypouljf4ry` | ✅ |
| ACR 实例 `acr-newapi-mnl`（`cri-avfqy9xkqi5bj8ee`，Enterprise_Basic，ap-southeast-6） | `aliyun cr ChangeResourceGroup` | `rg-shared` `rg-aek3yypouljf4ry` | ✅ |

**实测命令形态**：

```bash
# OSS（v2 语法：--resource-group-configuration 接受 JSON 字符串）
ossutil api put-bucket-resource-group --bucket <bucket> \
  --resource-group-configuration '{"ResourceGroupId":"rg-xxx"}' \
  --region <region> --endpoint oss-<region>.aliyuncs.com -c ~/.aliyun/ossutilconfig

# ACR
aliyun cr ChangeResourceGroup --ResourceRegionId ap-southeast-6 \
  --ResourceId cri-avfqy9xkqi5bj8ee --ResourceGroupId rg-xxx
```

**迁移后回归验证**（关键，不能只看接口返回空就算成功）：

- 3 个桶 `get-bucket-resource-group` 逐个回读，ID 与目标一致。
- ACR `ListInstance` 回读：`ResourceGroupId` 已更新，且自动标签 `acs:rm:rgId` 同步为 `rg-shared`。
- **CRR 复制规则未受影响**：`oss-newapi-mnl` 的 `<Status>doing</Status>`，两条前缀 `rds-backup/` + `actiontrail/` 仍在。
- RAM 策略未受影响：现有 `newapi-*` 策略全部是 **ARN 维度的 Allow/Deny**，不含 `acs:ResourceGroupId` 条件 ⇒ 换组不破权限。（若将来把授权改成「按资源组授权」，换组就会瞬间改变权限，届时必须同步改策略。）

**注意**：RMS `ListResources` **不索引 vSwitch**（`rg-ph-mnl` 只列出 OSS+…VPC，6 个 vSwitch 不在列表内）。所以控制台「资源数量」列对 vSwitch 是低估的，不能拿它当盘点依据 —— vSwitch 盘点走 `DescribeVSwitches`。

---

## 八、遗留 / 下一步

| 项 | 状态 |
| --- | --- |
| §4.1 步骤 4：VPC Flow Log → SLS | **未做**（依赖 SLS Project，且马尼拉是否可选待核；不可选则记残余风险） |
| `cost-center` 标签 | 待用户给成本中心编号后 `TagResources` 补打 |
| 路由表 / 自定义路由 | 使用 VPC 默认路由表（本次未建自定义） |
| 安全组（`sg-mnl-app` 等） | 未建，属 D1 后续任务 |
| NAT / EIP / ALB | 未建，属 §5.1 |
| Terraform 纳管 | 脚本 `create_vswitch.sh` 为 CLI 版；IaC 用户后续需 `terraform import` 这 12 个资源 |
