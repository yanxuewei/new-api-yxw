# ActionTrail 审计 + 备份桶生命周期 落地报告

- **执行时间**：2026-09-25 15:00–15:25 CST
- **账号 / 地域**：`5108890064395960`，主站 `ap-southeast-6`（马尼拉），备份站 `ap-southeast-1`（新加坡）
- **完成项**：上一轮 `OSS_Bucket落地_执行报告.md` 遗留清单中的 **第 2 项（备份桶生命周期）** 与 **第 4 项（ActionTrail 投递目标）**
- **结论**：两项均已落地并实测通过；另新增一条**审计防篡改护栏**。

---

## 一、任务 2 — 备份桶生命周期

对象 `oss-newapi-backup-sgp`（ap-southeast-1，ZRS，版本控制 Enabled）。原本无任何生命周期（`NoSuchLifecycle`）。

### 落地规则（3 条）

| 规则 ID | 前缀 | 转换 | 版本清理 | 碎片清理 |
| --- | --- | --- | --- | --- |
| `backup-data-tiering` | `rds-backup/` | 30 天 → IA，90 天 → Archive | 非当前版本 30 天过期 | — |
| `backup-audit-tiering` | `actiontrail/` | 30 天 → IA（**不沉 Archive**） | 非当前版本 30 天过期 | — |
| `backup-cleanup` | 全桶 | — | 删过期删除标记 | 分片上传 7 天中止 |

**为什么审计前缀不沉 Archive**：审计日志需支持 180 天合规查询，Archive 每次读取都要先 Restore（分钟级）。IA 已能覆盖成本优化，保留可检索性。

### 关键发现：降冷限制 = **双可用区 ZRS**，不是「所有 ZRS」

上一轮结论「ZRS 桶不能降冷」**范围过宽，本轮修正**。两处对照实测：

| 桶 | 地域 | AZ 数 | ZRS 降冷 |
| --- | --- | --- | --- |
| `oss-newapi-backup-sgp` | ap-southeast-1 | 3 | ✅ **接受**（30d IA / 90d Archive 已生效） |
| `oss-newapi-mnl` | ap-southeast-6 | 2（`6a`/`6b`） | ❌ `InvalidArgument: Invalid StorageClass` |

马尼拉测试使用**极简单条规则**（仅 `Transition 30d IA`）仍被拒，排除是 `IsAccessTime` / `AllowSmallFile` 等元素导致。测试后原规则已恢复（`newapi-version-cleanup` 校验在位）。

**对方案的后果**：冷数据分层需求**由备份桶直接承载，无需新建 LRS 冷桶**。上轮提出并让你三选一的方案 B（新建 LRS 冷桶）与方案 C（全改 LRS）**均作废**，方案 A 的主桶部分不变。

### 踩到的坑

`AbortMultipartUpload` **不允许跨规则重叠**：写成「两条前缀规则各带 + 兜底规则也带」会报 `InvalidRequest: Overlap for same action type AbortMultipartUpload`。该动作必须只在一条规则里出现（用兜底全桶规则承载即可）。

---

## 二、任务 4 — ActionTrail 审计落地

### 配置

| 参数 | 值 |
| --- | --- |
| 跟踪名称 | `newapi-audit-trail` |
| HomeRegion | `ap-southeast-6`（马尼拉） |
| TrailRegion | `All`（**全地域**，非仅主站） |
| EventRW | `All`（读 + 写事件，审计完整性所需） |
| 投递目标 | `oss://oss-newapi-mnl/actiontrail` |
| 投递角色 | `AliyunServiceRoleForActionTrail`（**系统自动创建**） |
| 状态 | `Enable` / `IsLogging=true` / `OssBucketStatus=true` |
| StartLoggingTime | `2026-09-25T07:04:29Z` |

**注意**：`CreateTrail` 成功后 `IsLogging` 仍为 `false`，**必须再调 `StartLogging`** 才真正开始投递。只建跟踪不开始记录 = 无日志。

### 落盘路径（实测，符合官方规范）

```
oss://oss-newapi-mnl/actiontrail/AliyunLogs/Actiontrail/<region>/<YYYY>/<MM>/<DD>/
    Actiontrail_<region>_<YYYYMMDDHHMMSS>_1002_<事件数>_<字节数>_<md5>.gz
```

首批实测文件（4 个事件 / 1146 B）：

```
actiontrail/AliyunLogs/Actiontrail/ap-southeast-6/2026/09/25/
  Actiontrail_ap-southeast-6_20260925070451_1002_4_1146_8d2a62c7317236ee7bf50184a428d8a9.gz
```

路径按 **UTC** 分区，跨午夜事件可能落在前一天目录。

### 内容验证（解压后）

首批 4 条事件（**自证式**：记录的就是本次建跟踪的调用）：

| eventTime (UTC) | eventName | 主体 | sourceIp |
| --- | --- | --- | --- |
| 07:04:51 | `DescribeTrails` | `yanxuewei` | 120.229.15.128 |
| 07:04:50 | `AssumeRole` | `actiontrail.aliyuncs.com` | Internal |
| 07:04:50 | `GetTrailStatus` | `yanxuewei` | 120.229.15.128 |
| 07:04:50 | `GetBucketLocation` | `aliyunserviceroleforactiontrail` | — |

`AssumeRole` + `GetBucketLocation` 两条即投递链路健康检查的痕迹，可作日常巡检信号。

### 多地域采集已验证

`TrailRegion=All` 生效：源桶同时出现 `ap-southeast-6/` 与 `ap-southeast-1/` 两个目录（后者来自本次对新加坡桶的 OSS 操作），证明非主站地域的事件同样被采集。

### 端到端链路（实测闭环）

```
API 调用 → ActionTrail（Manila trail，全地域）
        → oss://oss-newapi-mnl/actiontrail/        （本地主副本，15:05 / 15:10 / 15:15 持续落盘）
        → CRR（规则 9afd3cef…，前缀 actiontrail/）
        → oss://oss-newapi-backup-sgp/actiontrail/ （跨区灾备副本，已同步 5 个对象）
```

投递连续性已跨策略变更窗口复验：15:14 收窄策略后，15:15:03 / 15:15:06 仍有新文件落盘，未中断。

---

## 三、新增护栏 — 审计对象防篡改

**发现的缺口**：原 Bucket Policy 把 `actiontrail/` 前缀也授给了 4 个业务 RAM 主体，且 `ops` 身份策略含 `oss:*`（允许 `DeleteObject`）。**被审计的主体可以删改审计日志**，审计链形同虚设。

### 处置

| 动作 | 内容 |
| --- | --- |
| 新建策略 | `newapi-audit-protect` v1 |
| 拒绝动作 | `PutObject` / `PutObjectAcl` / `PutObjectTagging` / `DeleteObject` / `DeleteObjectVersion` / `DeleteObjectTagging` / `InitiateMultipartUpload` / `UploadPart` / `UploadPartCopy` / `AbortMultipartUpload` |
| 拒绝资源 | `oss-newapi-mnl/actiontrail/*` + `oss-newapi-backup-sgp/actiontrail/*`（**两个地域都锁**） |
| 绑定 | `admin` / `ops` / `cicd-push` / `iac-terraform`（attach=4） |
| 同步收窄 | Bucket Policy 移除 `actiontrail/`，用户前缀仅剩 `rds-backup/` `app-assets/` |

### 实测（用 `iac-terraform` 程序 AK，该用户持有 `oss:*` Allow + 本 Deny）

| 操作 | 结果 |
| --- | --- |
| 列举 `actiontrail/` | ✅ 允许（读取不受影响） |
| 删 `actiontrail/…` | ❌ `403 AccessDenied` |
| 写 `actiontrail/probe.txt` | ❌ `403 AccessDenied` |
| 写 + 删 `rds-backup/probe-ok.txt` | ✅ 允许（对照，业务不受影响） |

### 顺带修正一条既有结论

上轮认为「Bucket Policy 无主体黑名单能力」。本轮对照测试进一步明确：**Bucket Policy 对同账号 RAM 用户整体不生效**（仅约束跨账号 / 匿名访问）——用未挂拒绝策略的 `yanxuewei` 做同样删除操作，未被拦截。

→ 因此主体级管控**唯一落点是 RAM 身份策略的 `Deny`**，本轮即按此实现，且实测有效。OSS 对该拒绝返回的报文是 `Message: Access denied by bucket policy`，**措辞具误导性**，排查时不要据此判断管控层级。

---

## 四、本轮无法完成项

| 项 | 状态 | 说明 |
| --- | --- | --- |
| 历史 90 天事件回填 | ❌ 未开通 | `CreateDeliveryHistoryJob` 返回 `NotSupportDeliveryHistoryJob: Your account does not allow you to use deliveryHistoryJob feature. Submit a ticket to get customer support.` 需提工单开通，非配置问题 |
| 回填替代路径 | ✅ 可用 | `LookupEvents` 正常（已实测返回事件 + `NextToken` 分页），可脚本化导出近 90 天事件到 OSS；仅缺「一键回填」能力 |

---

## 五、云上资源变更清单

| 类型 | 名称 | 动作 |
| --- | --- | --- |
| ActionTrail 跟踪 | `newapi-audit-trail` | 新建 + StartLogging |
| RAM 服务关联角色 | `AliyunServiceRoleForActionTrail` | 系统自动创建 |
| RAM 策略 | `newapi-audit-protect` v1 | 新建，attach=4 |
| OSS 生命周期 | `oss-newapi-backup-sgp` | 新增 3 条规则 |
| OSS Bucket Policy | `oss-newapi-mnl` | 收窄（移除 `actiontrail/`） |
| OSS 对象 | `oss-newapi-mnl/actiontrail/**` | 首次落盘（ActionTrail 写入） |
| OSS 对象 | `oss-newapi-backup-sgp/actiontrail/**` | 首次落盘（CRR 复制） |

未新增 / 未删除任何 RAM 用户、Bucket 或角色。

---

## 六、遗留事项

1. **`yanxuewei` 未纳入防篡改**（按你要求本轮不动）— 它是当前审计链**唯一可绕过点**：挂 `AdministratorAccess`，可删改 ActionTrail 日志与策略。治理闭环的最后一块。
2. **历史回填待开工单** — 开通后可补 90 天事件基线。
3. **主桶审计日志无法降冷** — 马尼拉 2 AZ 的 ZRS 只能存标准存储，`actiontrail/` 主副本将长期按 Standard 计费（备份副本已在 30 天后转 IA）。若成本敏感，可评估把跟踪直投新加坡桶（3 AZ 可降冷），代价是失去本地副本 + 跨区流量费。
4. **VPC 内网限制策略待补** — 需等 ACK 建出 VPC 端点，追加 `Deny` + `NotIpAddress acs:SourceIp` + `acs:SourceVpc`。
5. **Insights 事件未开** — 当前仅管理事件（`EventRW=All`）。Insights 需单独申请访问权限，开通后可覆盖风险 API 调用识别。

---

## 附：复现命令

```bash
ALIYUN="$HOME/.workbuddy/binaries/aliyun-cli/aliyun"
OSS="$HOME/.workbuddy/binaries/ossutil/ossutil"
CFG="$HOME/.aliyun/ossutilconfig"
SG=(--endpoint oss-ap-southeast-1.aliyuncs.com --region ap-southeast-1)

# 跟踪状态
$ALIYUN actiontrail GetTrailStatus --region ap-southeast-6 --Name newapi-audit-trail

# 审计对象（源 + 目标）
$OSS ls -r oss://oss-newapi-mnl/actiontrail/ -c $CFG
$OSS ls -r oss://oss-newapi-backup-sgp/actiontrail/ "${SG[@]}" -c $CFG

# 备份桶生命周期
$OSS api get-bucket-lifecycle --bucket oss-newapi-backup-sgp "${SG[@]}" -c $CFG

# 事件查询（近 90 天）
$ALIYUN actiontrail LookupEvents --region ap-southeast-6 --MaxResults 20
```

> zsh 注意：数组必须写成 `"${SG[@]}"`。zsh **不做**变量分词，`$SG` 会被当成单个参数，报 `unknown flag: --endpoint ... --region ...`。
