# Day 1 · 泳道 A（网络与出口线）任务卡

> 本分片为《阿里云国际站菲律宾部署_详细操作指南 v2.0》4 天压缩日历 · CLI-first 重写版的一部分。所有 ID/网段/配额为 2026-09-25 前实测确认值，与旧版 `-ch.md` 描述冲突时以本文件为准。

## 全局基线参数（每卡引用，勿改）

| 参数 | 实测值 |
| --- | --- |
| 账号 UID | `5108890064395960`（profile：`export ALIYUN_PROFILE=ph-prod`） |
| 业务/运维域名 | `api.likha.com` / `ops.likha.com`；通配证书 `*.likha.com` |
| 主 region / AZ | `ap-southeast-6`（菲律宾-马尼拉），**仅 6a/6b 两个可用区** |
| 备 region | `ap-southeast-1`（新加坡），不部署任何数据库 |
| 马尼拉 VPC | `vpc-newapi-mnl-prod` = `vpc-5tst1tgeessxn1azwasg2`，`10.0.0.0/16` |
| 新加坡 VPC | `vpc-newapi-sg-prod` = `vpc-t4nimmwvruexbnene0a3r`，`10.1.0.0/16`（与主站不重叠） |
| 马尼拉 vSwitch | pub-a `10.0.0.0/24`(6a)、pub-b `10.0.1.0/24`(6b)、app-a `10.0.16.0/20`(6a)、app-b `10.0.32.0/20`(6b)、data-a `10.0.48.0/20`(6a)、data-b `10.0.64.0/20`(6b) |
| 新加坡 vSwitch | pub-a `10.1.0.0/24`(1a)、pub-b `10.1.1.0/24`(1b)、app-a `10.1.16.0/20`(1a)、app-b `10.1.32.0/20`(1b) |
| K8s / CNI | 1.35（原 1.31 已 EOL）/ **Terway**（不可后期更换；Pod IP 是真实 VPC IP，节点与 Pod 共用 app 交换机） |
| 镜像前缀（实测） | `registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api`（马尼拉 VPC 内拉取域名） |
| 节点池机型（实测修订） | **`ecs.g9i.2xlarge`**——`ecs.g8i` 未在马尼拉上架（2026-09-25 实测），旧文档 g8i 描述作废 |
| 命名标签 | `project=new-api site=ph-mnl\|sg env=prod cost-center=<按财务> managed-by=console` |

**配额 API 实测坑（全局适用）**：调用配额中心查询/申请**必须**带 `--Dimensions.1.Key regionId --Dimensions.1.Value <regionId>`，不带会返回 cn-hangzhou 的配额（假数据）；申请参数拼写为 `--DesireValue`；审批通过状态值为 **`Agree`**。ECS vCPU 配额已批：马尼拉 50→64、新加坡 50→96，**分钟级生效**。

---

## Day 1 · 泳道 A：网络、出口、证书与镜像底座

### Day 1 · 任务 5｜马尼拉 VPC + 6 vSwitch（人员A，4 人时，S1）✅ 已完成，勿重做

**前置/状态**：无前置（泳道起点）。**本任务已于 2026-09-25 前落地**：`vpc-newapi-mnl-prod`=`vpc-5tst1tgeessxn1azwasg2`（10.0.0.0/16）与 6 个 vSwitch 均已创建（见基线表）。D1 只做 CLI 复核，**禁止再执行 `CreateVpc`/`CreateVSwitch`**（重复创建会因 `InvalidCidrBlock.Overlapped` 失败或产生垃圾资源）。

**操作步骤（CLI-first）**：

```bash
export ALIYUN_PROFILE=ph-prod
VPC_ID=vpc-5tst1tgeessxn1azwasg2
# 1. 复核 VPC 本体
aliyun vpc DescribeVpcs --RegionId ap-southeast-6 \
  | jq '.Vpcs.Vpc[]|select(.VpcName=="vpc-newapi-mnl-prod")|{VpcId,CidrBlock,Status}'
```

期望输出：

```json
{ "VpcId": "vpc-5tst1tgeessxn1azwasg2", "CidrBlock": "10.0.0.0/16", "Status": "Available" }
```

```bash
# 2. 复核 6 个 vSwitch：名称/可用区/CIDR/free IP 基线
aliyun vpc DescribeVSwitches --RegionId ap-southeast-6 --VpcId "$VPC_ID" --PageSize 20 \
  | jq -r '.VSwitches.VSwitch[]|"\(.VSwitchName)\t\(.ZoneId)\t\(.CidrBlock)\tfree=\(.AvailableIpAddressCount)"'
```

期望输出（6 行，网段与基线表完全一致）：

```text
vsw-mnl-pub-a   ap-southeast-6a 10.0.0.0/24   free=25x
vsw-mnl-pub-b   ap-southeast-6b 10.0.1.0/24   free=25x
vsw-mnl-app-a   ap-southeast-6a 10.0.16.0/20  free=409x
vsw-mnl-app-b   ap-southeast-6b 10.0.32.0/20  free=409x
vsw-mnl-data-a  ap-southeast-6a 10.0.48.0/20  free=409x
vsw-mnl-data-b  ap-southeast-6b 10.0.64.0/20  free=409x
```

```bash
# 3. 把 free IP 基线写入台账（后续每里程碑对比用），例如：
aliyun vpc DescribeVSwitches --RegionId ap-southeast-6 --VpcId "$VPC_ID" --PageSize 20 \
  | jq -r '.VSwitches.VSwitch[]|"\(.VSwitchName) \(.AvailableIpAddressCount)"' >> .deploy/wf2/vsw-free-ip-baseline.txt
```

4. 流日志（VPC 控制台 → 流日志）投递 SLS：**马尼拉是否可选待核实**；不可选则跳过并记为残余风险。此步仅控制台可做：
   【控制台】`[图 D1-A-5｜拍摄对象：专有网络 VPC 详情页-流日志开通入口（马尼拉）；打码：账号 UID、资源组 ID]`

**验证方法**：上述第 1、2 步输出逐字段比对基线表；验收标准（方案 AB 列）：**网段与「网络与安全规划」完全一致**。free 参考值 pub ≈252、app/data ≈4092，明显偏低说明有别的资源占用。

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| VPC 查不到 / CIDR 不是 10.0.0.0/16 | 确认 profile 指向账号 5108890064395960；确系误建 → 无资源占用时删除重建（`DeleteVSwitch`/`DeleteVpc`） |
| 某个 vSwitch 缺失或网段填错（/20 写成 /24） | vSwitch CIDR **不可修改** → 无资源时删除重建 |
| 删不掉 vSwitch | 已被 NAT/ACK/RDS 占用 → 按依赖顺序先删资源再删交换机 |
| free IP 明显少于预期 | 有别的资源占用 → 重算 Pod 容量，不要硬上 |

**坑**：

- **坑 1｜网段规划错要连带重建整栈**：vSwitch 一旦有资源就删不掉。现象：D2 之后发现规划错。后果：重建 NAT/ALB/ACK/RDS，返工 1–2 天。改进：动手前把 §2.2 网段表在评审纪要签认一次（本卡已按实测 ID 固化）。
- **坑 2｜节点与 Pod 共用 vSwitch + Terway**：现象：`/20`（约 4000 IP）耗尽时新 Pod 永久 `ContainerCreating`、报 `no available ip addresses`。后果：HPA/扩容全线失效，最容易在压测或故障切换当天爆发。改进：app 段保持 `/20` 为下限（**不要缩到 /22**）；本卡第 3 步记基线、每里程碑复核；告警把「vSwitch 可用 IP < 200」设为 P2。
- **坑 3｜与新加坡网段重叠**：现象/后果：将来接云企业网/VPC 对等时地址冲突，只能重划网段（≈重建集群）。改进：10.0.0.0/16 vs 10.1.0.0/16 已错开，建第二个 VPC 前再核对一次（见任务 12 复核）。
- **坑 4｜「开启 DNS 主机名解析」**（方案 R4）在国际站英文文档未见对应开关。改进：以控制台 VPC 详情页实际项为准，找不到就跳过，不影响主链路，别为它卡住 D1。

### Day 1 · 任务 12｜新加坡 VPC + vSwitch + NAT + EIP（人员A，2 人时，S1）

**前置/状态**：依赖任务 5 复核通过。**VPC `vpc-newapi-sg-prod`=`vpc-t4nimmwvruexbnene0a3r`（10.1.0.0/16）已建**，本卡以复核为主；NAT 网关与 4 个 EIP 为本卡新建。

**操作步骤（CLI-first）**：

```bash
# 1.（复核）VPC 与 vSwitch 已落地，网段按基线表
aliyun vpc DescribeVpcs --RegionId ap-southeast-1 \
  | jq '.Vpcs.Vpc[]|select(.VpcName=="vpc-newapi-sg-prod")|{VpcId,CidrBlock,Status}'
```

期望输出：

```json
{ "VpcId": "vpc-t4nimmwvruexbnene0a3r", "CidrBlock": "10.1.0.0/16", "Status": "Available" }
```

```bash
aliyun vpc DescribeVSwitches --RegionId ap-southeast-1 --VpcId vpc-t4nimmwvruexbnene0a3r --PageSize 20 \
  | jq -r '.VSwitches.VSwitch[]|"\(.VSwitchName)\t\(.ZoneId)\t\(.CidrBlock)\tfree=\(.AvailableIpAddressCount)"'
# 期望 4 行：vsw-sg-pub-a 1a 10.1.0.0/24 / vsw-sg-pub-b 1b 10.1.1.0/24
#            vsw-sg-app-a 1a 10.1.16.0/20 / vsw-sg-app-b 1b 10.1.32.0/20
# 缺哪个补哪个（CreateVSwitch 参数同任务 5 模式），并记录 free 基线
```

```bash
# 2. 建公网 NAT 网关（国际站现行名「公网 NAT 网关」；"Enhanced NAT Gateway" 是旧称，不要照抄"增强型"）
SG_PUB_A=$(aliyun vpc DescribeVSwitches --RegionId ap-southeast-1 --VpcId vpc-t4nimmwvruexbnene0a3r \
  | jq -r '.VSwitches.VSwitch[]|select(.VSwitchName=="vsw-sg-pub-a").VSwitchId')
NAT_SG=$(aliyun vpc CreateNatGateway --RegionId ap-southeast-1 \
  --VpcId vpc-t4nimmwvruexbnene0a3r --VSwitchId "$SG_PUB_A" \
  --Name nat-sg-prod --NetworkType internet --InstanceChargeType PostPaid \
  | jq -r '.NatGatewayId')
echo "NAT_SG=$NAT_SG"
```

期望输出：`nat-sg-...` 非空；约 1 分钟后 `DescribeNatGateways` 中该实例 `Status=Available`。

```bash
# 3. 创建 4 个弹性公网 IP：eip-sg-upstream-01..04，按使用流量计费（AI 网关流量波动大）
for i in 01 02 03 04; do
  aliyun vpc AllocateEipAddress --RegionId ap-southeast-1 \
    --Name eip-sg-upstream-$i --Bandwidth 100 --InternetChargeType PayByTraffic \
    | jq -r '\(.AllocationId + " " + .EipAddress)'
done
```

期望输出：4 行 `<eip-xxx> <公网IP>`。**国际站没有国内站的「共享流量包 DTP」**，等价物是 CDT（云数据传输），先查地域支持再承诺抵扣；可预测成本再评估共享带宽。

```bash
# 4. 逐个绑定到 NAT 网关
for id in $EIP_IDS; do
  aliyun vpc AssociateEipAddress --RegionId ap-southeast-1 \
    --AllocationId "$id" --InstanceType NatGateway --InstanceId "$NAT_SG"
done
```

```bash
# 5. SNAT 条目：粒度选交换机（覆盖 app 段与 pub 段），条目内可勾多 EIP 成池
SNAT_TABLE=$(aliyun vpc DescribeNatGateways --RegionId ap-southeast-1 --NatGatewayId "$NAT_SG" \
  | jq -r '.NatGateways.NatGateway[0].SnatTableIds.SnatTableId[0]')
for vsw in $SG_APP_A $SG_APP_B $SG_PUB_A $SG_PUB_B; do
  aliyun vpc CreateSnatEntry --RegionId ap-southeast-1 --SnatTableId "$SNAT_TABLE" \
    --SourceVSwitchId "$vsw" --SnatIp "$EIP_POOL_CSV" --SnatEntryName snat-sg-$vsw
done
# 若页面/API 只允许单 EIP/条 → 建 4 条条目各绑 1 个 EIP
```

**验证方法**：

```bash
# 在 SG 节点/私有子网 ECS 上多次执行
for i in $(seq 1 8); do curl -s -m5 https://ifconfig.me; echo; done | sort | uniq -c
# 期望：计数只落在 4 个已登记 eip-sg-upstream-01..04 的 IP 上
```

控制台辅助确认：NAT 网关状态「可用」、绑定 EIP 数 = 4、SNAT 条目覆盖 app/pub 段。

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| 出口出现非池内 IP | 有旧单 EIP 条目或节点被分配了公网 IP（Terway 下会绕过 NAT）→ 删多余条目；节点池**不勾选分配公网 IP** |
| `curl` 超时/返回 `000` | 私有 vSwitch 没有 SNAT 条目覆盖（按交换机建时漏了 app 段）→ 补条目 |
| EIP 绑不上 | 达到单 NAT 网关 EIP 上限（文档口径 10–20，4 个远小于下限）或 EIP 已被别的资源占用 → `DescribeEipAddresses` 核状态 |
| 网段与新加坡既有 VPC 重叠 | `InvalidCidrBlock.Overlapped` → 换 /16 或清理旧 VPC（先确认无资源占用） |

**坑**：

- **坑 1（本卡特有）｜这 4 个 EIP 有双重身份**：① 上游白名单；② **必须是马尼拉 RDS 公网白名单里唯一的来源**（§6.1）。现象：忘了第二层。后果：RDS 白名单只加了马尼拉 EIP → 备 region Pod 连不上主库，M4 直接挂。改进：**8 个 EIP（mnl 4 + sg 4）列在同一张台账**，标注「已进 RDS 白名单？」「已交供应商？」「生效确认时间」。
- 任务 5 的坑 2/坑 3（地址耗尽、网段重叠）对新加坡 vSwitch 同样适用；app 段保持 `/20` 下限并记录 free 基线。

### Day 1 · 任务 6｜马尼拉 NAT 网关 + 上游出口 EIP 池 4 个（人员A，2 人时，S2）

**前置/状态**：任务 5 复核通过（`vsw-mnl-pub-a` 已存在）。本卡新建 `nat-mnl-prod` + `eip-mnl-upstream-01..04`；是全案对外依赖最重的一张卡（上游白名单的地基）。

**操作步骤（CLI-first）**：

```bash
# 1. 建公网 NAT 网关（地域马尼拉，网络类型=公网，可用区 6a，关联 vsw-mnl-pub-a）
MNL_PUB_A=$(aliyun vpc DescribeVSwitches --RegionId ap-southeast-6 --VpcId vpc-5tst1tgeessxn1azwasg2 \
  | jq -r '.VSwitches.VSwitch[]|select(.VSwitchName=="vsw-mnl-pub-a").VSwitchId')
NAT_MNL=$(aliyun vpc CreateNatGateway --RegionId ap-southeast-6 \
  --VpcId vpc-5tst1tgeessxn1azwasg2 --VSwitchId "$MNL_PUB_A" \
  --Name nat-mnl-prod --NetworkType internet --InstanceChargeType PostPaid \
  | jq -r '.NatGatewayId')
echo "NAT_MNL=$NAT_MNL"
```

期望输出：`nat-5...` 非空；数分钟后 `aliyun vpc DescribeNatGateways --RegionId ap-southeast-6 --NatGatewayId "$NAT_MNL" | jq -r '.NatGateways.NatGateway[0].Status'` 输出 `Available`。

```bash
# 2. 创建 4 个弹性公网 IP（按使用流量计费）
for i in 01 02 03 04; do
  aliyun vpc AllocateEipAddress --RegionId ap-southeast-6 \
    --Name eip-mnl-upstream-$i --Bandwidth 100 --InternetChargeType PayByTraffic \
    | jq -r '\(.AllocationId + " " + .EipAddress)'
done
# 把 4 个 EipAddress 立即登记进 EIP 台账（版本控制，见坑 1）
```

```bash
# 3. 绑定 NAT 网关 ×4
for id in $EIP_IDS; do
  aliyun vpc AssociateEipAddress --RegionId ap-southeast-6 \
    --AllocationId "$id" --InstanceType NatGateway --InstanceId "$NAT_MNL"
done
# 4. SNAT 条目：粒度=交换机，覆盖 app 段与 pub 段；条目内多 EIP 成池；
#    若只允许单 EIP/条 → 建 4 条条目各绑 1 个 EIP（命令同任务 12 第 5 步，换 region/VPC）
```

带宽规格：NAT ≥200Mbps、EIP ≥100Mbps 并留 3× 余量（见坑 3）。EIP 计费选**包年包月**或配余额/到期双告警（见坑 2）。

**验证方法**：

```bash
# 在马尼拉集群节点/私有子网 ECS 上多次执行，期望只出现 4 个已登记 EIP
for i in $(seq 1 12); do curl -s -m5 https://ifconfig.me; echo; done | sort | uniq -c
```

期望输出：

```text
      3 47.x.x.1
      3 47.x.x.2
      3 47.x.x.3
      3 47.x.x.4
```

计数只落在 4 个已知 IP 上，且与台账一致。控制台辅助：NAT 状态「可用」、SNAT 条目覆盖 app/pub 段、绑定 EIP 数 = 4。

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| 出口出现**非池内 IP** | 有旧的单 EIP 条目，或**节点被分配了公网 IP**（Terway 下会绕过 NAT）→ 删多余条目；节点池**不勾选分配公网 IP** |
| `curl` 超时 `000` | 私有 vSwitch **没有 SNAT 条目覆盖**（按交换机建时漏了 app 段）→ 补条目 |
| EIP 绑不上 | 达到单 NAT 网关 EIP 上限（文档口径 10–20，4 个远小于下限）或 EIP 已被别的资源占用 |

**坑**：

- **坑 1（全案对外依赖最重）｜上游白名单建立在「出口 IP 固定且完整」之上**。现象：新增/替换任一 EIP 未同步给供应商。后果：**偶发 403 / connection reset，失败率 ≈ 1/N（4 个 EIP 就是 25%）**，极难复现的「部分模型偶尔失败」，排查数天，客户看到随机错误。改进：① EIP 清单做成**版本控制台账**（§6.5，与任务 12 合并为 8 EIP 一张表）；② 上线前 **8 个 EIP 全部提交并取得供应商书面生效确认**；③ 监控按**出口源 IP 维度**打标签统计 4xx，一眼看出哪个 EIP 被拒。
- **坑 2｜欠费导致 EIP 被回收后重新分配给别人**。后果：白名单里出现「别人的 IP」，你的新 IP 未加白 → 上游全拒。改进：EIP 走**包年包月**，或余额/到期双告警（§3.2）。
- **坑 3｜NAT 吞吐与 EIP 峰值带宽没显式设值**。AI 网关是**大下行**（1000 并发 ≈ 40 Mbps，方案 R39），叠加非流式大响应更高。后果：流式回答卡顿、超时雪崩。改进：NAT ≥200Mbps、EIP ≥100Mbps 留 3× 余量；**压测必须用真实响应体大小**，不要只打小 mock（否则容量结论全废，任务 33 白做）。
- **坑 4｜用 DNAT 把节点暴露公网做调试**。后果：绕过 NAT 收敛面，节点直接可被扫。改进：**禁止 DNAT**，运维访问走 §8.5。

### Day 1 · 任务 3｜证书就绪与部署预置（人员A，1 人时，S2）

**前置/状态**：通配证书 `*.likha.com` 已于 G5（§3.7）签发。D1 只做三件事：① 私钥入密钥管理服务 KMS（不入 Git/ConfigMap）；② 建好到期告警；③ 备好「部署到 ALB/WAF/DCDN」的任务模板但**不执行**（资源还没建）。**为什么不能提前部署**：v2.0 的时序错误就是「D1 部署证书，但 ALB/WAF 在 D3/D5 才建」→ 部署任务找不到资源、后续靠手工补，最终 D6 才发现某处还在用自签/旧证书。

**操作步骤（CLI-first）**：

```bash
# 1. 私钥+证书链入 KMS 凭据（值从本地安全文件读，走 KMS 落库，绝不进 Git）
aliyun kms CreateSecret --SecretName "new-api/prod/tls-wildcard" \
  --SecretData "$(cat ${CERT_PEM} ${INTERMEDIATE_PEM} ${KEY_PEM})" \
  --VersionId v1 --Description "*.likha.com TLS chain + private key"
```

期望输出：`{"SecretName": "new-api/prod/tls-wildcard", ...}`，无报错。（若马尼拉/新加坡 KMS 实例未开通，此步在 KMS 控制台创建同名凭据：【控制台】`[图 D1-A-3｜拍摄对象：KMS 凭据管理-new-api/prod/tls-wildcard 详情（凭据值页不截图）；打码：凭据值、账号 UID]`）

```bash
# 2. 本地核验证书有效期与覆盖域名
openssl x509 -in ${CERT_PEM} -noout -enddate -ext subjectAltName
# 期望：notAfter ≥ 今天 + 30 天；SAN 同时含 *.likha.com 与 likha.com
# 若缺裸域 SAN：api.likha.com 不受影响，但 D3 配 ALB 默认域名时须另签
```

3. 到期告警：数字证书管理服务（原 SSL 证书）→ 证书消息提醒，勾选到期提醒（30/15/7 天三档）；云监控配告警联系人组指向运维值班。此步以控制台为准：
   【控制台】`[图 D1-A-3b｜拍摄对象：数字证书管理服务-到期告警配置页；打码：联系人手机号/邮箱]`

4. 部署任务模板预置（**不执行**）：在 `deploy/cert/` 建 `targets.yaml`，资源 ID 留 `TODO-D3/D5` 占位：

```yaml
# deploy/cert/targets.yaml（模板，仅登记，不下发）
- target: alb        # ALB 监听证书     → D3 建 ALB 后执行
- target: waf        # WAF 域名证书     → D5 接 WAF 后执行
- target: dcdn       # DCDN HTTPS 证书  → 如启用 DCDN 后执行
```

**为什么必须留模板**：v2.0 旧时序在 D1 空跑部署任务找不到资源，后续靠手工补，D6 才发现某处仍用自签/旧证书；模板化让 D3/D5 执行时逐项销账。

**验证方法**：

```bash
aliyun kms ListSecrets | jq -r '.SecretList[].Name' | grep new-api/prod/tls-wildcard
# 期望输出：new-api/prod/tls-wildcard
aliyun kms DescribeSecret --SecretName "new-api/prod/tls-wildcard" \
  | jq '{SecretName,CreationDate,VersionId}'   # 期望 VersionId=v1，时间与操作记录一致
```

+ 数字证书管理服务（CAS）中该证书状态「已签发」；`openssl x509 -in cert.pem -noout -enddate` 与页面一致且 notAfter ≥ 今 + 30 天。

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| KMS 列表无该凭据 | `CreateSecret` 报错（KMS 实例/权限）→ 按报错开通或补 `kms:CreateSecret` 权限后重试 |
| 本地 notAfter 与页面不一致 | 拿了旧版本文件 → 从 CAS 重新下载当前「已签发」记录对应文件，重灌 KMS 并升版本 |
| 证书状态非「已签发」 | G5 未真正闭环 → 回到 §3.7 完成签发/DCV，本卡其余步骤可先行 |
| SAN 不含 `likha.com` 裸域 | 签单时只填了通配 → 追加覆盖域名重新签发；D1 记录阻塞项，不阻塞本卡其余步骤 |
| 到期告警收不到 | 联系人未验证邮箱/手机 → 完成验证并重发测试通知 |

**坑**：

- **坑｜私钥 `kubectl create secret generic` 后误提交 Git**。现象：仓库里出现 base64 私钥。后果：仓库可读即可解密会话/冒充站点。改进：只允许 KMS + 注入；CI 加 **gitleaks/密钥扫描门禁**（`skill security-scan-gates`），「密钥不落 Git」列为上线一票否决。

### Day 1 · 任务 16｜双地域 ACR 企业版 + CI 推镜像（人员B，1 人时，S2，与 A 卡并行）

**前置/状态**：两地域 VPC 已存在（任务 5 复核 / 任务 12 复核）。**ACR 企业版实例已建**，本卡以复核为主：`acr-newapi-mnl`（马尼拉）/ `acr-newapi-sg`（新加坡），命名空间 `newapi`，实测马尼拉 VPC 拉取前缀 `registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api`。

**操作步骤（CLI-first，复核路径）**：

```bash
# 1. 两地域实例存在且 RUNNING
aliyun cr ListInstance --RegionId ap-southeast-6 --InstanceName acr-newapi-mnl \
  | jq -r '.Instances[]|"\(.InstanceName)\t\(.InstanceId)\t\(.InstanceStatus)"'
aliyun cr ListInstance --RegionId ap-southeast-1 --InstanceName acr-newapi-sg \
  | jq -r '.Instances[]|"\(.InstanceName)\t\(.InstanceId)\t\(.InstanceStatus)"'
# 期望各 1 行，InstanceStatus=RUNNING
```

```bash
# 2. VPC 访问已关联（不关联则 VPC 域名解析不通）
aliyun cr GetInstanceEndpoint --RegionId ap-southeast-6 --InstanceId $MNL_INST --ModuleName Registry \
  | jq -r '.Endpoints[]|{EndpointType,Domains:(.Domains[].Domain)}'
# 期望含 vpc 端点域名 registry-vpc.ap-southeast-6.aliyuncs.com（与实测镜像前缀一致）
```

3. 访问凭证：CI 用固定密码走 CI secret 变量 `${ACR_PASS}`（KMS/密钥管家托管，不写明文）；缺失时到「实例 → 访问凭证」设置：
   【控制台】`[图 D1-A-16｜拍摄对象：容器镜像服务 ACR 企业版实例-访问凭证页；打码：固定密码、账号 UID]`
4. 命名空间 `newapi` 已建且勾选**自动创建仓库**；缺则补（控制台或 `aliyun cr CreateNamespace`）。
5. 镜像同步规则：⚠ **规则要求源实例为高级版/旗舰版规格** → 实操以**新加坡（高级版）为源、马尼拉（基础版）为目标**；规则**只同步新推送**，历史镜像需 `CreateRepoSyncTask` 或 OSS 拷贝补齐。

```bash
# 6. CI 推镜像（tag 必须为 git sha，禁止 latest）
IMG=registry.ap-southeast-1.aliyuncs.com/newapi/new-api:${GIT_SHA}
docker build -t "$IMG" .
docker login --username=${ACR_USER} --password=${ACR_PASS} registry.ap-southeast-1.aliyuncs.com
docker push "$IMG"
```

7. 集群免密拉取：ACK 组件管理安装 **`aliyun-acr-credential-helper`**，配置目标 namespace 列表（含 `new-api`）。

**验证方法**：

```bash
# 两地域各自用 VPC 域名拉一次（验收 AB 列要求）
kubectl run pulltest-mnl --rm -it --restart=Never \
  --image=registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api:<sha> -- sh -c 'echo ok'
kubectl --context sg run pulltest-sg --rm -it --restart=Never \
  --image=<sg-inst>-registry-vpc.ap-southeast-1.aliyuncs.com/newapi/new-api:<sha> -- sh -c 'echo ok'
# 期望均输出 ok，不出现 ImagePullBackOff
```

+ 在新加坡推一个新 tag，1–3 分钟后在马尼拉实例「镜像仓库」能看到同 tag（复制规则生效）。

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| `no such host` | VPC 访问未关联（复核第 2 步）→ 关联对应 VPC 后等 DNS 生效 |
| `401 Unauthorized` | 未装 credential-helper，或 helper 的 namespace 列表漏了 `new-api` |
| `manifest unknown` | 镜像只在另一地域，复制规则未生效 / **是规则创建前推的历史镜像**（规则只同步新推送）→ `CreateRepoSyncTask` 补历史 |
| `x509: certificate signed by unknown authority` | 端点用了 IP 或 http；企业版的 VPC 域名证书合法，别绕 |

**坑**：

- **坑 1｜镜像前缀**：旧方案写 `registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api` 被怀疑是个人版公共域名（企业版通常 `<实例名>-registry[-vpc].<region>.aliyuncs.com`）。**2026-09 实测确认**：当前马尼拉拉取前缀即为 `registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api`，以 `GetInstanceEndpoint` 输出为准。后果（若照抄错域名）：拉取失败，D2 就卡住。改进：所有清单里镜像前缀**做成变量**，从 ACR 实例/端点 API 取实际域名。
- **坑 2｜跨区拉镜像**（新加坡节点用马尼拉域名）。后果：走公网产生流量费 + 首次拉取分钟级，**HPA 扩容时 Pod 起不来**。改进：每地域用自己的 VPC 域名 + 复制规则保证同镜像。
- **坑 3｜用 `latest` tag**。后果：回滚无法定位版本，方案 R31「秒级归零/回滚」变成空话。改进：**tag = git sha**（方案 R16），CI 拒绝推 latest。
- **坑 4｜指望个人版免密拉取**。credential-helper 面向企业版；个人版仅支持 **2024-09-08 前创建**的实例。改进：直接上企业版，别省这笔钱换 D2 阻塞。

### Day 1 · 任务 1、2｜G0 收口 + 域名 NS 复核 + 预建解析（人员A，1+1 人时，S3）

**前置/状态**：任务 5/12/6/3/16 复核全部通过；本卡是 D1 收口卡。**任务 1：逐条打勾 §3.13 的 G0 表；任一未过 → D1 中止。**

**操作步骤（CLI-first）**：

```bash
# 1.（任务 1）配额复核：必须带 regionId 维度，否则返回 cn-hangzhou 配额（假数据）
aliyun quotas ListProductQuotas --Product ecs --QuotaCategory Common \
  --Dimensions.1.Key regionId --Dimensions.1.Value ap-southeast-6 \
  | jq '.Quotas[]|select(.QuotaActionCode|test("vcpu"))|{QuotaDescription,TotalQuota,ApplicableUnit}'
```

期望输出：马尼拉 ECS vCPU 配额 `TotalQuota=64`（申请 50→64 已批）。新加坡同理应为 `96`（50→96）。状态核验：

```bash
aliyun quotas GetQuotaApplication --ApplicationId $APP_ID   # 期望 Status=Agree（不是 "Agreed"/"Approved"）
```

```bash
# 2.（任务 1）可用区/机型复核：节点池机型实测为 ecs.g9i.2xlarge（g8i 未在马尼拉上架）
aliyun ecs DescribeZones --RegionId ap-southeast-6 | jq -r '.Zones.Zone[].ZoneId'
# 期望：ap-southeast-6a / ap-southeast-6b（仅这两个）
aliyun ecs DescribeAvailableResource --RegionId ap-southeast-6 --DestinationResource InstanceType \
  --InstanceType ecs.g9i.2xlarge | jq -r '.AvailableZones.AvailableZone[].StatusCategory'
```

3.（任务 1）其余 G0 项（账号实名/结算、RAM 最小权限、ActionTrail、成本标签）按 §3.13 表逐项打勾，证据链接进台账。

```bash
# 4.（任务 2）域名 NS 复核：重跑 §3.6 的 dig
dig +short NS likha.com
# 期望：两行阿里云分配的 NS（ns*.aliyuncs.com），与云解析 DNS 控制台一致
```

5.（任务 2）云解析 DNS → 公网权威解析 → 预建记录（控制台或 `aliyun alidns AddDomainRecord`）：

| 主机记录 | 类型 | 值 | TTL |
| --- | --- | --- | --- |
| `api` | CNAME | GTM（全局流量管理）接入域名（§8.1 产出；未产出前先占位再改） | **60** |
| `ops` | CNAME/A | 堡垒机/VPN 入口 | 600 |
| `static` | CNAME | DCDN 加速域名（如启用） | 600 |

【控制台】`[图 D1-A-2｜拍摄对象：云解析 DNS-likha.com 记录列表（三行预建记录）；打码：堡垒机公网 IP]`

**验证方法**：

```bash
dig +short api.likha.com          # 期望：解析到 GTM 接入域名/占位值
dig SOA likha.com +short          # 改记录后期望 SOA 序列号递增
```

**不通过时修复**：

| 症状 | 诊断 → 修复 |
| --- | --- |
| 配额查询数值异常（如仍是 50 或查不到） | 漏带 `--Dimensions.1.Key regionId` → 补维度重查；`Status` 非 `Agree` → 用 `--DesireValue`（注意此拼写）重申并等审批 |
| `g8i` 查无库存/不可售 | 实测 g8i 未在马尼拉上架 → 节点池机型统一改 `ecs.g9i.2xlarge`，同步修订 §4.10 及清单 |
| NS 不是阿里云 | 域名未改 NS → 到域名注册控制台改 DNS 服务器，等 TTL 传播；期间勿在第三方继续加记录 |
| `dig +short api` 为空 | 记录未保存/主机记录写成 `api.likha.com`（应为 `api`）→ 修正记录名 |

**坑**：

- **坑｜TTL 太长导致切换演练「通过不了」**：GTM 目标 ≤60s 切换，但 `api` 记录 TTL=600 时客户端会缓存 10 分钟。后果：演练时观察到「解析早该切了但用户还在打老地址」，误判为 GTM 故障，浪费半天。改进：`api` 记录 **TTL 60**；演练报告里区分「GTM 池切换时间」与「客户端恢复时间」两个指标，**对外承诺用后者**（§8.1）。
- **坑｜配额 API 不带 region 维度**：后果：拿到 cn-hangzhou 数值做容量决策，马尼拉实际不足，D2 建集群才爆。改进：本卡命令模板已固化 `--Dimensions.1.Key regionId`，评审时检查所有配额截图/脚本是否带维度。

---

### Day 1 · 泳道 A 出口检查清单

全部打勾方可进入 D2；任一项不过 → 当日修复或按预案降级，不留到 D2。

```
☐ 马尼拉 VPC vpc-5tst1tgeessxn1azwasg2 + 6 vSwitch 网段与基线表一致，free IP 基线已写入台账
☐ 新加坡 VPC vpc-t4nimmwvruexbnene0a3r + 4 vSwitch 复核通过，网段与主站不重叠
☐ nat-mnl-prod 状态「可用」，eip-mnl-upstream-01..04 全部绑定，12 次出口探测只命中 4 个池内 IP
☐ nat-sg-prod + eip-sg-upstream-01..04 同上（8 次探测）；8 个 EIP 同列一张台账（RDS 白名单/供应商加白双身份已标注）
☐ 禁止 DNAT 已确认；节点池不分配公网 IP 已写入任务 10 交底
☐ 证书 *.likha.com 状态「已签发」，notAfter ≥ 今+30 天；私钥在 KMS new-api/prod/tls-wildcard；到期告警已建；部署模板备好未执行
☐ ACR 双地域企业版 RUNNING、VPC 端点已关联、同步规则（SG→MNL）生效、两地域 VPC 域名 kubectl 拉取均输出 ok
☐ 镜像 tag=git sha 且 CI 拒绝 latest；credential-helper 覆盖 new-api namespace
☐ G0 表全部通过（含配额：马尼拉 vCPU=64、新加坡=96，Status=Agree）；机型统一 ecs.g9i.2xlarge
☐ likha.com NS 指向阿里云；api/ops/static 三条记录已预建，api TTL=60
```

> 泳道 B（数据与存储：任务 4/7/8/9 等）出口项见分片 `part1a.md`，两线并绿才算 D1 完成（M1 前半）。
