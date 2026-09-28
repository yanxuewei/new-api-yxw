# RAM 用户组权限补全 执行报告（2026-09-25 21:10 · 账号 5108890064395960）

## 一、任务

截图①给了 4 个 RAM 用户已绑策略；截图②的 4 个用户组当时**策略 = 0、成员 = 0**（空壳）。
本任务：把这 4 个用户的策略**镜像到对应同名用户组**，让组成为权限承载单元。

## 二、映射与结果

| 用户 | 用户组 | 组绑定策略（全部 Custom 类型） | 成员 |
| --- | --- | --- | --- |
| `admin` | `admin_group` | `newapi-admin-identity` / `newapi-enforce-mfa` / `newapi-audit-protect` | `admin` |
| `ops` | `ops_group` | `newapi-ops-operator` / `newapi-enforce-mfa` / `newapi-audit-protect` | `ops` |
| `cicd-push` | `cicd-push_group` | `newapi-cicd-acr-push` / `newapi-audit-protect` | `cicd-push` |
| `iac-terraform` | `iac-terraform_group` | `newapi-iac-terraform` / `newapi-audit-protect` | `iac-terraform` |

**总操作量**：绑策略 10 次 + 加成员 4 次 = 14 次，全部 `[OK]`，无失败。

**同时补了成员关系**：组绑定策略**只对成员生效**——4 个组原本 0 成员，只绑策略等于摆设。用户与该同名组现已互为成员，策略立即生效。

**保留的差异（刻意为之）**：

- `cicd-push` / `iac-terraform` **不绑** `newapi-enforce-mfa` —— 与用户级现状一致（这两个是纯 AK 程序用户，MFA 策略对其 AK 调用本就无效，见 §3.3 实测结论 3：`acs:MFAPresent` 对 AK 调用完全无效）。
- `newapi-audit-protect` 为 4 个主体共有（审计防篡改护栏），因此 4 个组都有。

## 三、复核（可复现）

```bash
# 组侧
aliyun ram ListPoliciesForGroup --GroupName <g> --region ap-southeast-1
aliyun ram ListUsersForGroup    --GroupName <g> --region ap-southeast-1
# 用户侧（确认归属）
aliyun ram ListGroupsForUser    --UserName  <u> --region ap-southeast-1
```

实测回读：

```
admin_group      策略: newapi-admin-identity,newapi-audit-protect,newapi-enforce-mfa   成员: admin
ops_group        策略: newapi-audit-protect,newapi-enforce-mfa,newapi-ops-operator    成员: ops
cicd-push_group  策略: newapi-audit-protect,newapi-cicd-acr-push                      成员: cicd-push
iac-terraform_group 策略: newapi-audit-protect,newapi-iac-terraform                   成员: iac-terraform
```

原始快照：`.workbuddy/ram_group_out/ram_group_snapshot.json`

## 四、当前状态：用户级 + 组级**双绑**

策略以**并集**生效 → **最终权限未变**（零行为变化、零风险）：
`user(策略集) ∪ group(同策略集) = 同策略集`

**注意点**：

1. 双绑期间**无法通过改组策略来收敛权限**——用户级那份仍在生效。要让「组承载」真正成立，需**解除用户级绑定**（`DetachPolicyFromUser`）。
2. `newapi-enforce-mfa` 通过组下发同样只约束**控制台会话**；对 AK 调用（cicd-push / iac-terraform）依旧无效 → 程序用户只能靠 IP 白名单（§3.3 结论 4）。
3. 后续若把治理升级为**按资源组授权**（`acs:ResourceGroupId`），务必同时考虑这两层绑定：只改组策略不改用户策略 = 改了也没生效。

**建议（待用户确认后执行，非本次动作）**：

- 解除用户级策略，只保留 `admin_group` / `ops_group` / `cicd-push_group` / `iac-terraform_group` 四组承载 → 单点维护。
- 顺序：先确认组绑定 + 成员关系均已生效（本次已复核）→ 再 `DetachPolicyFromUser` → 立即用该用户身份验证关键动作仍通。

## 五、交付物

- `attach_group_policies.sh` —— 幂等脚本，`check` 预演 / `apply` 执行；重跑全 `[SKIP]` 已验证。
- 本报告。
