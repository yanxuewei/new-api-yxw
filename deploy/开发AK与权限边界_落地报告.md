# 开发 AK 与权限边界 · 落地报告

> 执行时间：2026-09-25 22:24–22:45 CST
> 账号：`5108890064395960`　Region：`ap-southeast-1`（RAM 全局服务）
> 触发问题：**开发同学既要 AKSK 写代码，又需要 ops 权限管资源，怎么给？**

---

## 一、结论

**拆身份，不混装。** 人是控制台身份（密码+MFA），程序是 AK 身份（最小策略+边界），两者永不共用凭证。

已落地：

| 身份 | 主体 | 凭证 | 权限载体 |
| --- | --- | --- | --- |
| 人（运维） | `zhangzijun` / `xiangdong` | 控制台密码 + MFA，**无 AK** | `ops_group` |
| 程序（开发） | `dev-zhangzijun` / `dev-xiangdong` | AK，**无控制台登录** | `dev-program_group` |

`ops_group` 已收敛：能读生产、**不能写生产**。

---

## 二、为什么不能直接给「有 ops 权限的 AK」

| 理由 | 实测证据 |
| --- | --- |
| AK 绕过 MFA | `newapi-enforce-mfa` 用 `Bool`+`acs:MFAPresent`，对 AK 调用**完全不判定**（§3.3 已实测） |
| 长期凭证不过期 | 泄露即长期有效，轮转靠人 |
| 审计无法区分人/机 | ActionTrail 只记 AK，记不到「谁在用」 |

---

## 三、新建资源清单

**策略（Custom）**

| 策略名 | 作用 | 绑定 |
| --- | --- | --- |
| `newapi-dev-program` | 开发程序最小权限（生产只读 + 非生产可写 + 禁 ram/bss/account 写） | `dev-program_group` |
| `newapi-prod-boundary` | Deny 生产 RG 的**一切非只读**动作（`acs:ResourceGroupId` 条件） | `ops_group`、`dev-program_group` |
| `newapi-prod-oss-guard` | Deny 生产桶的写/删/桶配置（**ARN 维度，无条件**，30 个动作） | `ops_group`、`dev-program_group` |

**用户组**

| 组 | 成员 | 策略 |
| --- | --- | --- |
| `dev-program_group` | `dev-zhangzijun`、`dev-xiangdong` | `newapi-dev-program` + `newapi-prod-boundary` + `newapi-prod-oss-guard` |

**用户（程序身份，无 LoginProfile）**

| 用户 | AK | 凭据位置 |
| --- | --- | --- |
| `dev-zhangzijun` | `LTAI5tEQvPKSku..` Active | `~/.aliyun/newapi-dev-secrets.json` (600) |
| `dev-xiangdong` | `LTAI5tBrrYm8KL..` Active | 同上 |

**ops_group 最终策略（5 条）**

`newapi-ops-operator` + `newapi-enforce-mfa` + `newapi-audit-protect` + **`newapi-prod-boundary`** + **`newapi-prod-oss-guard`**

---

## 四、三层防御（同向叠加）

```
① newapi-dev-program      Allow 列表本就不含生产写 → 隐式拒绝
② newapi-prod-boundary    Deny 生产 RG 的一切非只读动作
③ newapi-prod-oss-guard   Deny 生产桶写删（ARN 维度，不依赖条件键）
        ↓
   生产写 → 三层都拦；任一层单独存在也拦得住
```

**关键设计**：`oss-guard` 必须含 `oss:PutBucketResourceGroup` —— 否则 ops 可**把桶移出生产资源组**来绕过 `boundary`。已含。

---

## 五、实测证据

### 5.1 策略生效性验证（boundary 用 `ics-terraform` 临时挂载，测完立即解绑）

| 阶段 | 生产桶写 | 生产 VPC 写 |
| --- | --- | --- |
| 基线（未绑） | ALLOW | ALLOW |
| 绑定 boundary 后 | **DENY** | **DENY** |
| 解绑后 | ALLOW（恢复） | ALLOW（恢复） |

**结论：`acs:ResourceGroupId` 条件键对 OSS 对象操作与 VPC API 均真实生效。** 且验证过程零副作用（用「删除不存在的对象」「幂等修改相同属性」），VPC 属性事后核对未变，`iac-terraform` 用户级绑定已还原为空。

### 5.2 开发程序身份权限边界（AK 直连，两人各 14 用例）

`SMOKE=PASS (14/14)` × 2

| 类别 | 用例 | 结果 |
| --- | --- | --- |
| 身份 | `sts GetCallerIdentity` | ALLOW |
| 生产只读 | `vpc DescribeVpcs` / `DescribeVSwitches` / `DescribeEipAddresses`、`ecs DescribeInstances`、`cr ListInstance` | ALLOW |
| 审计只读 | `actiontrail DescribeTrails` / `LookupEvents` | ALLOW |
| **生产写** | `vpc ModifyVpcAttribute`（生产 VPC） | **DENY** |
| **生产桶写** | OSS `DeleteObject` on `oss-newapi-mnl` / `oss-newapi-backup-sgp` | **DENY** |
| 非生产 | OSS `DeleteObject` on `oss-newapi-nonprod` | ALLOW |
| RAM | `ram ListUsers` / `ram CreateAccessKey` | **DENY** |

### 5.3 纵深对照（逐层解绑）

| 状态 | 生产桶写 | 生产 VPC 写 |
| --- | --- | --- |
| 三层齐全 | DENY | DENY |
| 解绑 `boundary`（留 oss-guard + 最小策略） | DENY | DENY |
| 再解绑 `oss-guard`（只剩最小策略） | DENY | DENY |
| 恢复三层 | DENY | DENY |

**这是预期行为，不是失效** —— 因为 ① 最小策略本身就不授生产写。对照证明「纵深」成立：单层失效不会导致放开。

---

## 六、关键实测发现（修正了之前的错误认知）

| # | 发现 | 说明 |
| --- | --- | --- |
| 1 | **`acs:ResourceGroupId` 真实生效** | 对 OSS 对象操作、VPC API 均已实测拦截。此前担心"该条件键对 OSS 不判定"不成立 |
| 2 | **`NotAction` 白名单可用通配** | `*:Describe*` / `*:List*` / `*:Get*` / `*:Query*` 生效。实测：生产 VPC/ECS 读放行、写被拦 |
| 3 | **`Error Code: Access denied by bucket policy` 是误导文案** | OSS 在 **RAM 策略**拒绝时也会返回该文案。**不能据此判断是 Bucket Policy 拦截** |
| 4 | **Bucket Policy 对同账号 RAM 用户不排他**（前次结论确认正确） | 实测 dev 用户读生产桶 5/5 ALLOW（含非白名单前缀），说明 Allow 型 Bucket Policy 不与 RAM 交叉判定 |
| 5 | **部分 API 的资源存在性校验先于鉴权** | `vpc DeleteVSwitch` / `ecs DeleteInstance` 对不存在的 ID 返回「资源不存在」而非 `AccessDenied`。**不能用「不存在的资源 ID」做权限探测** |
| 6 | **探测脚本不能用文本子串判定** | `actiontrail LookupEvents` 返回的审计事件正文里含 `AccessDenied` 字样（正是测试自身产生的事件）→ 误判为 DENY。必须按结构化字段（`error_code` / `<Code>` / `Error Code:`）判定 |

---

## 七、ops_group 收敛后的能力边界

| 能做 | 不能做 |
| --- | --- |
| 读全部生产资源（ECS/VPC/RDS/OSS/CMS/SLS/CR 的 Describe/List/Get） | 改任何生产资源（ECS/RDS/VPC/OSS…） |
| 全量读写**非生产**（`rg-nonprod`）资源 | 改/删生产 OSS 桶及对象 |
| 看日志、看监控、跑诊断 | 删生产桶、改桶策略/生命周期/复制规则 |
| — | 操作 RAM / 账号 / 账单 |

**代价（必须接受）**：云 API 层的生产变更从此**只能走 `iac-terraform`（IaC）**。紧急手工修补需临时解绑边界 —— 建议做成「临时组 + 到期回收」而不是改策略。

> K8s 层的生产运维（kubectl 看 Pod、重启）**不受影响** —— 那走 RBAC，不走 RAM。

---

## 八、未做 / 待办

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | **`zhangzijun` / `xiangdong` MFA 未绑定** | `MFABindRequired=True` 已设，登录会被强制引导绑定；绑完前 `newapi-enforce-mfa` 会 Deny 除 11 个 MFA 自助动作外的一切 |
| 2 | 非生产 OSS 桶尚未创建 | `newapi-dev-program` 已预留 `oss-newapi-nonprod`、`oss-newapi-dev-*` 的写权限；**建桶时须放进 `rg-nonprod`** |
| 3 | 开发 AK 真正用途未确认 | 当前给的是「只读环境 + 日志 + 非生产 OSS 写 + newapi 命名空间镜像推拉」。若实际只需调 OSS SDK，可再收窄 |
| 4 | `power_user_group`（`PowerUserAccess`）**0 成员** | 空壳，建议删除或明确用途 |
| 5 | `super_group` 给 `yanxuewei` `AdministratorAccess` + `AliyunRAMFullAccess` | 按你要求未动；**审计链唯一可绕过点** |
| 6 | `admin_group` 未加 boundary | 有意为之：admin 本就只有读 + RAM/ActionTrail 管理权，无生产写权限 |
| 7 | AK 分发 | `~/.aliyun/newapi-dev-secrets.json` 为明文。**须通过安全通道交给本人**（勿走 IM/邮件），并约定轮转周期 |

---

## 九、回滚

```bash
AL=~/.workbuddy/binaries/aliyun-cli/aliyun
R=ap-southeast-1

# ① 撤销 ops_group 收敛
$AL ram DetachPolicyFromGroup --GroupName ops_group --PolicyName newapi-prod-boundary   --PolicyType Custom --region $R
$AL ram DetachPolicyFromGroup --GroupName ops_group --PolicyName newapi-prod-oss-guard  --PolicyType Custom --region $R

# ② 撤销开发程序身份（AK 先删、再删用户）
$AL ram DeleteAccessKey --UserName dev-zhangzijun --AccessKeyId <AKID> --region $R
$AL ram DeleteAccessKey --UserName dev-xiangdong  --AccessKeyId <AKID> --region $R
$AL ram RemoveUserFromGroup --UserName dev-zhangzijun --GroupName dev-program_group --region $R
$AL ram RemoveUserFromGroup --UserName dev-xiangdong  --GroupName dev-program_group --region $R
$AL ram DeleteUser --UserName dev-zhangzijun --region $R
$AL ram DeleteUser --UserName dev-xiangdong  --region $R

# ③ 删组与策略
$AL ram DeleteGroup  --GroupName dev-program_group --region $R
$AL ram DeletePolicy --PolicyName newapi-dev-program    --PolicyType Custom --region $R
$AL ram DeletePolicy --PolicyName newapi-prod-boundary  --PolicyType Custom --region $R
$AL ram DeletePolicy --PolicyName newapi-prod-oss-guard --PolicyType Custom --region $R
```

---

## 十、交付物

| 文件 | 说明 |
| --- | --- |
| `ram_dev_program_onboard.sh` | 开发程序身份开户，幂等，`check` / `apply` / `verify` |
| `probe_boundary_v2.sh` | boundary v2 生效性验证（临时挂载 + 自动回滚） |
| `probe_rg_condition.sh` | `acs:ResourceGroupId` 条件键验证（首轮） |
| `probe_dev_program.sh` | 开发 AK 权限边界全量验证，`smoke` / `crosscheck`（三层对照） |
| `.workbuddy/dev_program_probe.txt` | 原始实测输出 |
| `.workbuddy/boundary_v2_probe.txt`、`.workbuddy/rg_condition_probe.txt` | 原始实测输出 |
| `~/.aliyun/newapi-dev-secrets.json` | 开发 AK（600，明文，需安全分发） |
