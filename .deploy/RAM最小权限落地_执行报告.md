# RAM 最小权限落地执行报告

- **账号**：`5108890064395960`（阿里云国际站）
- **地域**：`ap-southeast-6`（菲律宾·马尼拉）
- **执行时间**：2026-09-25 11:31 – 12:26 CST
- **操作方式**：阿里云 CLI v3.5.1（`~/.workbuddy/binaries/aliyun-cli/aliyun`）
- **对应文档**：`3.3 G9 · RAM 用户 / 最小权限 / MFA / ActionTrail（当日）`

---

## 一、执行结果总览

| 用户 | 类型 | 登录方式 | 已绑策略 | 状态 |
| --- | --- | --- | --- | --- |
| `admin` | 人类 | 控制台密码 + MFA | `newapi-admin-identity` + `newapi-enforce-mfa` | ✅ 已完成（MFA 已绑） |
| `ops` | 人类 | 控制台密码 + MFA | `newapi-ops-operator` + `newapi-enforce-mfa` | ✅ 已完成（MFA 已绑） |
| `cicd-push` | 程序 | AccessKey | `newapi-cicd-acr-push` | ✅ 可用 |
| `iac-terraform` | 程序 | AccessKey | `newapi-iac-terraform` | ✅ 可用 |
| `yanxuewei` | 遗留 | AccessKey | AdministratorAccess + 20 条系统策略 | ⚠️ **待降权** |

**截图 4 条要求完成度**

| # | 要求 | 状态 |
| --- | --- | --- |
| 1 | 建 4 个 RAM 用户，人类/程序登录方式分离 | ✅ 完成 |
| 2 | 建自定义策略并绑定 | ✅ 完成（5 条策略） |
| 3 | 强制 MFA（全局开关 + 逐用户绑定） | ✅ 逐用户已强制（`MFABindRequired=true`），admin/ops 虚拟 MFA 已绑定完成 |
| 4 | 补 Deny 兜底策略 | ✅ 已建（`newapi-enforce-mfa` v2），**但实测无法覆盖 AccessKey 调用**（详见第三节） |

**截图附加项 `ActionTrail`**：❌ 未配置 —— 账号内无 OSS Bucket、无 SLS Project 可投递，需先确认存储再开跟踪（见第五节）。

---

## 二、策略明细

| 策略名 | 版本 | 绑定 | 说明 |
| --- | --- | --- | --- |
| `newapi-admin-identity` | v1 | admin | RAM/STS/ActionTrail 全权 + 全服务只读。定位「身份与审计管理员」 |
| `newapi-ops-operator` | v2 | ops | ECS/VPC/ACK/RDS/SLB/ALB/WAF/DNS/CMS/SLS/OSS/CR/CEN/PVZ 读写；显式 Deny 账号级、账单写、`DeleteInstance`/`DeleteVpc`/`DeleteDBInstance`/`DeleteCluster`/`DeleteBucket` |
| `newapi-cicd-acr-push` | v1 | cicd-push | 仅 ACR：`GetRepository`/`ListRepository`/`PullRepository`/`PushRepository`/`GetNamespace`/`ListNamespace`，Resource 限定 `repository/newapi/*` 与 `repository/*/newapi/*` |
| `newapi-iac-terraform` | v1 | iac-terraform | IaC 最小集（含 `ram:Get*`/`ram:List*`）；显式 Deny 全部 RAM 写动作（`CreateUser`/`CreatePolicy`/`AttachPolicy`/`CreateAccessKey`/`BindMFADevice` 等）与 `account:*` |
| `newapi-enforce-mfa` | v2 | admin、ops | 未验证 MFA 时 `Deny NotAction`（放行 MFA 自管理动作） |

策略源文件：`/tmp/newapi_policies/*.json`（临时目录，如需长期留存请复制到仓库）

---

## 三、实测发现的 6 个坑（与截图原文的偏差）

| # | 截图写法 | 实测结果 | 处理 |
| --- | --- | --- | --- |
| 1 | 条件键 `acs:RAMMFAPresent` | 官方正确键名为 **`acs:MFAPresent`** | 已按正确键名实施 |
| 2 | `"Bool": {...}` | ✅ 支持 | 采用 |
| — | — | ❌ **`BoolIfExists` 阿里云不支持**（`The condition operator 'IfExists/Null' is not supported`） | 无法用 IfExists 语义 |
| 3 | 「Deny * 兜底」 | ⚠️ **`Deny *` 会把 `ram:BindMFADevice` 一起挡掉 → 用户永远绑不上 MFA，账号直接废掉** | 改用 `Deny NotAction`，白名单放行 11 个 MFA 自管理动作 |
| 4 | 同上 | ⚠️ `ops` 策略里的 `Deny ram:*` 会**覆盖**兜底策略的 NotAction 白名单 → 同样锁死 | 移除 `Deny ram:*`（Allow 段本就不含 ram，隐式拒绝已足够） |
| 5 | 「全局开关只覆盖控制台登录，不覆盖 AccessKey 调用」→ 暗示本条策略能补上 AK 缺口 | ❌ **实测不成立**：给探针用户绑定本策略后，用其 AK 连续 3 次调用 `sts:GetCallerIdentity` **全部成功**。原因：AK 调用时 `acs:MFAPresent` 键不存在，`Bool` 条件不匹配，而阿里云不支持 `BoolIfExists`/`Null`，没有纯策略手段可覆盖 | 兜底策略**仅约束控制台会话**。API 侧只能靠 IP + Action 白名单（已验证有效，见下） |

**附：IP 白名单实测**（替代方案验证）

给探针用户绑定 `Deny + NotIpAddress acs:SourceIp`（白名单故意不含本机 IP 101.47.158.119）：

| 调用 | 结果 |
| --- | --- |
| `ram:ListUsers` | ❌ 被拒 `NoPermission` → **条件对 AK 调用生效** ✅ |
| `sts:GetCallerIdentity` | ✅ 成功（该接口对 IP 条件豁免） |

结论：**程序用户的 API 侧管控，IP 白名单可行，MFA 策略不可行**。

**附：RAM 限流现象**

高频连续 RAM 写操作会间歇性返回 `NoPermission`（**不是** `Throttling`，无任何限流提示），冷却 20–60 秒后自动恢复。本次执行中触发 3 次。自动化脚本必须带退避重试，否则会误判为权限配置错误。

---

## 四、安全基线设置

`SetSecurityPreference` 已固化：

| 项 | 值 | 含义 |
| --- | --- | --- |
| `AllowUserToManageAccessKeys` | `false` | 用户不能自建 AK，防止绕过审计 |
| `AllowUserToManageMFADevices` | `true` | 保留自助绑 MFA 能力（必须为 true） |
| `EnableSaveMFATicket` | `false` | 不记住 MFA，每次登录都验证 |
| `AllowUserToChangePassword` | `true` | 允许改密 |
| `LoginSessionDuration` | `6` 小时 | 如需更严格可降至 1–2 |

**注**：RAM 控制台 Settings → Security 的「要求所有控制台用户绑定 MFA」**未提供 OpenAPI**，CLI 无法开启。已用 `CreateLoginProfile --MFABindRequired true` 做逐用户等效强制（粒度更细）。

---

## 五、待办事项

### 1. MFA 已绑定完成 ✅

**绑定状态**（`GetUserMFAInfo` 确认）：

| 用户 | SerialNumber | 类型 | 状态 |
| --- | --- | --- | --- |
| `admin` | `acs:ram::5108890064395960:mfa/newapi-admin-mfa` | VMFA | ✅ 已绑定 |
| `ops` | `acs:ram::5108890064395960:mfa/newapi-ops-mfa` | VMFA | ✅ 已绑定 |

**后续重复执行 `bind_mfa.sh` 会报 `EntityAlreadyExists.User.MFADevice`** —— 这是幂等提示而非故障。脚本已改造：

| 命令 | 行为 |
| --- | --- |
| `bash bind_mfa.sh status` | 查询 admin/ops 绑定状态（新增） |
| `bash bind_mfa.sh admin <码1> <码2>` | 调用前先查状态；已绑同设备 → 直接报 `[OK] 无需重复绑定`（exit 0） |
| 同上（已绑其他设备） | 报 `[WARN]` + 给出 `UnbindMFADevice` 换绑命令 |
| 调用瞬间竞态命中 | 捕获 `EntityAlreadyExists` → 回读真实状态报 `[OK]` |

**绑定过程踩到的坑**：首次提交的 `admin 740510 024432` 报 `CheckAuthenticationCodeFail`。本地按 seed 复算定位根因：

```
T=677064 窗口:  admin -> 740510   ops -> 024432
```

- **码1 与码2 来自不同设备条目** —— `740510` 是 admin 的，`024432` 是 **ops** 的
- 两码均为 240 秒前的窗口 → 早已过期
- **根因**：两个二维码的 label 相同（均为账号名），认证器 App 里出现**两条一模一样的条目**，取码时在两条目间切换导致混取

**App 侧配置建议（避免后续登录取错码）**：

1. 删除 App 里的两条重复条目
2. 改用 **Base32 手工添加**，把名称显式改成 `newapi-admin-mfa` / `newapi-ops-mfa`
3. 密钥见 `~/.aliyun/newapi-ram-secrets.json` 的 `virtual_mfa` 段

**校验工具**（随时核对手机上的码是否正确）：

```bash
bash mfa_check.sh 123456
```

输出会指出该码属于 admin 还是 ops、以及手机时间是否偏移（已用你提交的两码验证：正确识别为 `admin / ops`，偏移 `-240s`）。

---

### 2. 程序用户加 IP 白名单（需你提供出口 IP）

模板（已验证有效）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Deny",
      "Action": ["*"],
      "Resource": ["*"],
      "Condition": {
        "NotIpAddress": {
          "acs:SourceIp": ["<CI 出口 IP>/32", "<Terraform 机 IP>/32"]
        }
      }
    }
  ]
}
```

⚠️ 绑定后该 AK **只能**在白名单 IP 使用，本机 + CI + Terraform 运行机的 IP 必须全部列出。

### 3. ActionTrail 审计跟踪

前置条件缺失：账号内 OSS Bucket 数 0、SLS Project 数 0，无可投递目标。需先确认存储方案（SLS 约 ¥0.1/GB 起，或 OSS 归档），再执行：

```bash
aliyun actiontrail CreateTrail --Name newapi-audit \
  --SlsProjectArn acs:log:ap-southeast-6:5108890064395960:project/<project> \
  --SlsWriteRoleArn acs:ram:5108890064395960:role/aliyunactiontraildefaultrole \
  --EventRW Write --TrailRegion ap-southeast-6
```

### 4. ⚠️ 高优先级：`yanxuewei` 账号降权

现状：`AdministratorAccess` + 19 条系统策略（ECS/RDS/SLB/OSS/RAM/VPC/BSS/CDN/OTS/PTS 全权）+ 已配 AccessKey。

这与本次最小权限治理**直接矛盾** —— 任何人拿到这台机器的 AK 就等于拿到整个账号。建议二选一：

- **方案 A（推荐）**：删除 `AdministratorAccess` 等 19 条系统策略，改绑 `newapi-admin-identity`；管理操作改走 `admin` 用户（已强制 MFA）
- **方案 B**：保留但轮转 AK，且该 AK 只用于本地脚本，不进 CI

```bash
# 查看当前 AK
aliyun ram ListAccessKeys --UserName yanxuewei --region ap-southeast-6
```

---

## 六、凭据存放位置（本机）

| 文件 | 权限 | 内容 |
| --- | --- | --- |
| `~/.aliyun/newapi-ram-secrets.json` | `600` | admin/ops 控制台密码、cicd-push/iac-terraform AK、MFA 设备密钥 |
| `~/.aliyun/mfa/newapi-admin-mfa.png` | `600` | admin MFA 二维码 |
| `~/.aliyun/mfa/newapi-ops-mfa.png` | `600` | ops MFA 二维码 |
| `~/.aliyun/config.json.bak` | `600` | CLI 配置备份（含 yanxuewei AK） |

**控制台密码（首次登录用）**

| 用户 | 密码 |
| --- | --- |
| `admin` | `Kw2-1cuoLsVtYqmj` |
| `ops` | `Pt5%l2MZRnEq5Npt` |

⚠️ **MFA 已绑定完成，现在请立即：**

1. **修改 admin/ops 控制台密码**（上面的密码已在对话与本文件中明文出现）
2. **把 `virtual_mfa` 段的 seed 备份进密码管理器**，然后从 `newapi-ram-secrets.json` 中删除 —— MFA seed 泄露 = MFA 失效
3. **删除 `~/.aliyun/mfa/` 两张二维码 PNG** —— 内容等同 seed，绑定后不再需要
4. **把两个 AK 移入 CI 的 Secret 管理**，从本机明文中删除
5. 删除 `~/.aliyun/config.json.bak`

注意：第 2 步删除 seed 后 `mfa_check.sh` 将无法工作（它依赖 `virtual_mfa` 段）—— 属预期，校验工具只在绑定期需要。

---

## 七、回滚

```bash
# 删除用户（需先解绑策略 + 删 AK）
aliyun ram ListPoliciesForUser --UserName admin --region ap-southeast-6
aliyun ram DetachPolicyFromUser --PolicyName newapi-admin-identity --PolicyType Custom --UserName admin --region ap-southeast-6
aliyun ram DeleteUser --UserName admin --region ap-southeast-6

# 删除策略
aliyun ram DeletePolicy --PolicyName newapi-admin-identity --region ap-southeast-6
```

---

## 八、附：截图内容 vs 实际执行的完整对照

| 截图要求 | 实际执行 |
| --- | --- |
| 建 admin / ops / cicd-push / iac-terraform | ✅ 4 个，Comments 标注 `newapi-*` |
| 人类用户勾 Console Password Sign-On | ✅ `CreateLoginProfile` + 随机 16 位强密码 + `MFABindRequired=true` |
| 程序用户勾 OpenAPI Access Key，二者不同开 | ✅ 仅 cicd-push/iac-terraform 有 AK；admin/ops 无 AK |
| ops → 自定义策略（Describe* + 部署写权限） | ✅ 采用服务级 Allow + 破坏性动作 Deny（比逐条 Describe* 更可维护，且经 Deny 收紧） |
| cicd-push → 仅 ACR 推送，Resource 限 `newapi/*` | ✅ 按截图实施 |
| iac-terraform → 最小集，含 `ram:Get*` 不含 `ram:CreateUser` | ✅ 含 `ram:Get*`/`List*`，显式 Deny 全部 RAM 写 |
| 开启「要求所有控制台用户绑定 MFA」 | ⚠️ 无 OpenAPI，改为逐用户 `MFABindRequired=true` |
| 每用户 Bind Virtual MFA Device | ✅ admin/ops 均已绑定（`GetUserMFAInfo` 确认） |
| Deny 兜底策略 | ⚠️ 已建并修正两处锁死缺陷；**实测不覆盖 AK 调用** |
