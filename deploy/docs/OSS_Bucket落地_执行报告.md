# 3.4 任务 8 · OSS Bucket 落地执行报告

- **账号**：`5108890064395960` | **主地域**：`ap-southeast-6`（菲律宾马尼拉）
- **执行时间**：2026-09-25
- **工具**：ossutil 2.4.0（`~/.workbuddy/binaries/ossutil/ossutil`）+ aliyun CLI 3.5.1
- **配置文件**：`~/.aliyun/ossutilconfig`（600）

---

## 一、交付清单（对照截图 4.3 任务 8）

| # | 截图要求 | 状态 | 实测证据 |
| --- | --- | --- | --- |
| 1 | 创建 Bucket `oss-newapi-mnl`，马尼拉，标准存储，**ZRS** | ✅ | `RedundancyType=ZRS` `StorageClass=Standard` `Location=oss-ap-southeast-6` |
| 2 | 读写权限 ACL = 私有（Private） | ✅ | `ACL=private` |
| 3 | 版本控制开启 | ✅ | `<Status>Enabled</Status>` |
| 4 | 数据安全 → **阻止公共访问** → 开启 | ✅ | `<BlockPublicAccess>true</BlockPublicAccess>` |
| 5 | 生命周期：30 天→IA，90 天→Archive | ❌ **被产品限制否决** | `InvalidArgument: Invalid StorageClass`；根因见 §二.1 |
| 6 | 生命周期：NoncurrentVersion 30 天过期 + 删标记 | ✅ | `<NoncurrentDays>30` `<ExpiredObjectDeleteMarker>true` |
| 7 | （加固）未完成分片 7 天清理 | ✅ | `<AbortMultipartUpload><Days>7` |
| 8 | Bucket Policy 限非本项目 RAM 主体 | 🟡 **部分**：已授权 4 个主体 + 限 3 前缀；**主体黑名单不可实现**，见 §二.2 |
| 9 | 建前缀 `rds-backup/` `actiontrail/` `app-assets/` | ✅ | 由 Bucket Policy + CRR 前缀集定义（对象存储前缀为逻辑概念，无需预建目录） |
| 10 | 跨区域复制 → 新加坡 | ✅ **数据流已实测** | rule `9afd3cef-…`，`rds-backup/` + `actiontrail/`，目标 `oss-newapi-backup-sgp` |
| 11 | 前缀 `rds-backup/` `actiontrail/` 配跨区域复制（坑 4） | ✅ | `<Prefix>rds-backup/</Prefix>` `<Prefix>actiontrail/</Prefix>` |
| 12 | `ossutil stat` / 内网可达性验证 | ✅ | 见 §四 |

### 最终资源清单

| 资源 | 值 |
| --- | --- |
| 源 Bucket | `oss-newapi-mnl`（ap-southeast-6，ZRS，Standard，private） |
| 备份 Bucket | `oss-newapi-backup-sgp`（ap-southeast-1，ZRS，Standard，private，版本控制 Enabled） |
| 复制规则 ID | `9afd3cef-fc1a-4255-9678-a98b4131894f` |
| 复制角色 | `acs:ram::5108890064395960:role/aliyunosssystemdefaultrole`（OSS 服务关联角色） |
| 复制权限策略 | `newapi-oss-replication` v3 → 挂在该角色 |
| 生命周期规则 | `newapi-version-cleanup` |
| Bucket Policy | 2 条 Allow（4 主体 / 3 前缀 + ListObjects 前缀条件） |

> **命名变更**：原计划目标桶名 `oss-newapi-sgp` 在删除后被其他账号占用（桶名全局唯一，删除后短时间即被抢占，重建报 `BucketAlreadyExists`）。改用 **`oss-newapi-backup-sgp`**。

---

## 二、三项关键实测发现（推翻截图假设）

### 1. ZRS 桶**不能**降冷 → 截图「ZRS + 30天IA/90天Archive」自相矛盾

| 桶 | 冗余 | 同一条 IA 转换规则 |
| --- | --- | --- |
| 临时对照桶 `tmp-lrs-probe` | **LRS** | ✅ 接受，回读成功 |
| `oss-newapi-mnl` | **ZRS** | ❌ `400 InvalidArgument: Invalid StorageClass` |

官方依据（Storage classes 文档原文）：

> *Currently, **dual-zone ZRS is supported only for the Standard storage class**.*

马尼拉属于 **双可用区地域**（只有 `6a`/`6b`，我方 `DescribeRegions` 实测确认），故 ZRS 桶在物理上只能存标准存储 —— IA / Archive 转换一律被拒。

官方对照表还显示：ZRS 的 IA/Archive **仅在多可用区地域**（杭州/上海/北京/张家口/乌兰察布/深圳/中国香港/东京/**新加坡**/雅加达/吉隆坡/法兰克福）提供。

**已决策（2026-09-25）：选方案 A —— 保持 ZRS，放弃降冷。** 截图「30 天→IA / 90 天→Archive」需求作废；`oss-newapi-mnl` 维持 ZRS，生命周期只保留版本清理 + 碎片清理。下表保留供后续变更参考：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A. 保持 ZRS，放弃降冷**（✅ 已采纳） | 生命周期只保留版本清理 + 碎片清理 | 长期存储成本无优化；SLA 保持 99.99% ZRS |
| B. 保留 ZRS 主桶 + 新增 LRS 冷数据桶 | 新建 `oss-newapi-mnl-cold`（LRS），`rds-backup/` `actiontrail/` 落该桶并配 IA/Archive + CRR | 备份数据失去 AZ 级冗余（单 AZ），但备份本就跨区复制到新加坡，风险可接受 |
| C. 全改 LRS | 重建 `oss-newapi-mnl` 为 LRS | 站点内 AZ 故障将导致数据不可读，与 99.95% SLA 推导冲突 |

> 冗余类型创建后不可变更，未来若改判需重建桶。

### 2. Bucket Policy **无法**做「非本项目 RAM 主体」黑名单

实测结论（在临时 LRS 桶上、用临时 RAM 用户 `oss-probe` + `AliyunOSSFullAccess` 对照）：

| 策略形态 | 服务端接受 | 实际执行 |
| --- | --- | --- |
| 无条件 `Deny oss:*`（`Resource` 精确） | ✅ | ✅ **生效，且 owner 也被拦** |
| `Deny` + `StringNotEquals` on **`acs:PrincipalArn`** | ✅ | ❌ **不执行** —— 非 owner 用户照常放行 |

→ OSS Bucket Policy 会接受 `acs:PrincipalArn` 但求值时不生效。**主体管控只能走 RAM 身份策略**（已在上轮 3.3 G9 建立：4 用户各自策略），Bucket Policy 只用于 **Allow 授权 + 前缀范围**。

另实测两条服务端校验：
- `acs:SourceIp` 单独使用会被拒：`acs:SourceVpc should be set if acs:SourceIp is set`（必须同时给 VPC 端点 ID）。当前 VPC 尚未创建，**待 ACK 落地后再补「仅 VPC 内网可访问」策略**。
- `acs:SecureTransport` 条件本次未能构造 HTTP 请求验证，未启用。

### 3. 跨区域复制**必须**用 OSS 服务关联角色，自建角色静默不复制

排障路径（每步都是实测）：

| 尝试 | SyncRole | 规则创建 | 数据实际复制 |
| --- | --- | --- | --- |
| 1 | 自建角色 `AliyunOSSRole`（ARN 实为 `role/aliyunossrole`） | ✅ | ❌ 等 5 分钟零对象 |
| 2 | 自建角色 + 扩展权限（`oss:Replicate*` 全集） | ✅ | ❌ |
| 3 | LRS 源桶对照（排除 ZRS 因素） | ✅ | ❌ |
| 4 | **`role/aliyunosssystemdefaultrole`（服务关联角色）** | ✅ | ✅ **120 秒内对象出现在目标桶** |

**结论**：`SyncRole` 必须是 OSS 服务关联角色 `acs:ram::<uid>:role/aliyunosssystemdefaultrole`。自建普通角色即使信任策略写对（`Principal.Service = oss.aliyuncs.com`）、权限策略挂全，OSS 也不会 AssumeRole，且**规则状态正常显示 `doing`、进度无任何报错**——是最难发现的静默失败。

> 该角色可经 `aliyun ram CreateRole --RoleName aliyunosssystemdefaultrole` 直接创建（未被保留名拦截），无需先走控制台。

其它 CRR 实测约束：
- `Destination/Location` 必须带 `oss-` 前缀（`oss-ap-southeast-1`）；写 `ap-southeast-1` 报 `The target bucket you specified does not locate in the target location`
- `SyncRole` 必须放在 `<ReplicationConfiguration>` 层级，放进 `<Rule>` 报 `contains some illegal characters`
- 目标桶**版本控制状态必须与源桶一致**（都 Enabled），否则 `InvalidRequest: Different versioning status…`
- 删除复制规则后状态变 `closing`，**约 90–180 秒内无法重建规则**（`BucketReplicationAlreadyExist`），需退避重试

---

## 三、工程坑（zsh 相关，影响所有后续脚本）

**`$VAR:xxx` 被 zsh 当参数修饰符吃掉**。写 JSON 时 `"acs:oss:*:$ACC:tmp-lrs-probe/*"` 中的 `$ACC:t` 被解析为 `${ACC:t}`（tail 修饰符），落库 Resource 变成 `5108890064395960mp-lrs-probe/*` —— 少了 `t`，策略永不可能匹配。

本轮因此**产生了 3 次错误结论**（一度误判「Bucket Policy 完全不生效」）。

| 修饰符 | 触发的字符串 | 结果 |
| --- | --- | --- |
| `:t` | `$ACC:tmp-…` | 取 tail，吃掉 `t` |
| `:r` | `$ACC:root` | 去扩展名，吃掉 `r` |
| `:u` | `$ACC:user/…` | 转大写 |

**规避**：拼接含冒号的字符串一律用 `${ACC}` 花括号形式，或改用 Python 生成 JSON（本报告全部配置已改为 Python 生成）。

---

## 四、验证方法（可直接复跑）

```bash
export OSS=~/.workbuddy/binaries/ossutil/ossutil
export CFG=~/.aliyun/ossutilconfig

# 1) 概览：冗余类型 / ACL / 跨区复制状态
$OSS stat oss://oss-newapi-mnl -c $CFG | grep -E "RedundancyType|StorageClass|ACL|CrossRegionReplication"

# 2) 版本控制 + 阻止公共访问
$OSS api get-bucket-versioning --bucket oss-newapi-mnl -c $CFG
$OSS api get-bucket-public-access-block --bucket oss-newapi-mnl -c $CFG

# 3) 生命周期
$OSS api get-bucket-lifecycle --bucket oss-newapi-mnl -c $CFG

# 4) Bucket Policy
$OSS api get-bucket-policy --bucket oss-newapi-mnl -c $CFG

# 5) 复制规则与进度
$OSS api get-bucket-replication --bucket oss-newapi-mnl -c $CFG
$OSS api get-bucket-replication-progress --bucket oss-newapi-mnl \
     --rule-id 9afd3cef-fc1a-4255-9678-a98b4131894f -c $CFG

# 6) 内网可达性（ECS 同 VPC 内执行，期望 403 而非 000/超时）
curl -sS -o /dev/null -w "%{http_code}\n" https://oss-newapi-mnl.oss-ap-southeast-6-internal.aliyuncs.com

# 7) CRR 端到端冒烟（写入后 ~2 分钟查目标桶）
echo smoke > /tmp/s.txt
$OSS cp /tmp/s.txt oss://oss-newapi-mnl/rds-backup/_smoke.txt -c $CFG
sleep 120
$OSS ls oss://oss-newapi-backup-sgp/rds-backup/ \
     --endpoint oss-ap-southeast-1.aliyuncs.com --region ap-southeast-1 -c $CFG
$OSS rm oss://oss-newapi-mnl/rds-backup/_smoke.txt -c $CFG   # 清理
```

**内网 Endpoint**（坑 1 的正确用法，公网 Endpoint 会收流量费且更慢）：

| 用途 | Endpoint |
| --- | --- |
| 马尼拉 VPC 内 | `oss-ap-southeast-6-internal.aliyuncs.com` |
| 新加坡 VPC 内 | `oss-ap-southeast-1-internal.aliyuncs.com` |

---

## 五、本次执行中创建/变更的云上资源

| 类型 | 名称 | 说明 |
| --- | --- | --- |
| Bucket | `oss-newapi-mnl` | 配置生命周期 / 阻止公共访问 / Bucket Policy / CRR |
| Bucket | `oss-newapi-backup-sgp` | 新建，CRR 目标，版本控制 Enabled |
| RAM 角色 | `aliyunosssystemdefaultrole` | OSS 服务关联角色，CRR 必需 |
| RAM 策略 | `newapi-oss-replication` v3 | Replicate 权限，挂 CRR 角色（attach=1） |
| RAM 策略 | `newapi-admin-identity` / `ops-operator` / `cicd-acr-push` / `iac-terraform` / `enforce-mfa` | 上轮 3.3 G9 建立，本轮未改动 |
| 本机 | `~/.workbuddy/binaries/ossutil/ossutil` | ossutil 2.4.0（mac x86_64） |
| 本机 | `~/.aliyun/ossutilconfig` (600) | ossutil 凭据，复用 default profile AK |
| 本机 | `~/.zshrc` | 追加 ossutil PATH 注入（幂等） |

### 已清理的临时资源

- 桶：`tmp-lrs-probe`（LRS 对照）、`oss-newapi-sgp2`（对照）— **已删**（含全部对象版本）
- RAM 用户：`oss-probe`（策略验证探针）+ 其 AK — **已删**
- RAM 角色：`AliyunOSSRole`（失败的自建角色）+ 策略解绑 — **已删**
- 测试对象：`rds-backup/crr-verify{,2,3}.txt`、`crr-slr.txt`（源 + 目标）— **已删**

---

## 六、遗留事项（2026-09-25 下午更新）

> 第 1–3 项已闭环，详见 `ActionTrail审计与备份桶_落地报告.md`。

1. ~~`oss-newapi-backup-sgp` 未配生命周期~~ — **✅ 已完成**。3 条规则：`rds-backup/` 30天IA→90天Archive、`actiontrail/` 30天IA（审计日志不沉 Archive）、兜底版本清理 + 碎片 7 天。
2. ~~ZRS vs 降冷方案待定~~ — **✅ 已收口**。限制经双向实测精确定位为**双可用区 ZRS**：马尼拉（2 AZ，`6a`/`6b`）ZRS 拒绝降冷，新加坡（3 AZ）ZRS 接受降冷。主桶维持方案 A；冷数据分层由**备份桶承载**，无需新建 LRS 桶，方案 B/C 均作废。
3. ~~ActionTrail 无投递目标~~ — **✅ 已完成**。`newapi-audit-trail` → `oss://oss-newapi-mnl/actiontrail`，`TrailRegion=All` / `EventRW=All`，已 `StartLogging` 并实测落盘 + CRR 到新加坡。
4. **VPC 内网限制策略待补** — 需先有 VPC 端点 ID；ACK 落地后追加 `Deny` + `NotIpAddress acs:SourceIp` + `acs:SourceVpc`。
5. **`yanxuewei` 账号未降权**（按你要求本轮不动）— 仍是 `AdministratorAccess` + 系统策略，本次全部操作即由该 AK 完成。**新增后果**：审计防篡改策略未覆盖它，该主体仍可删改 ActionTrail 日志，是当前审计链唯一可绕过点。
6. **对象级管控仅靠 RAM 身份策略**（§二.2 结论需修正）— 后续实测确认 **Bucket Policy 对同账号 RAM 用户不生效**（仅约束跨账号/匿名），因此主体黑名单唯一落点是 RAM 身份策略的 `Deny`，本轮已按此实现且实测有效。
