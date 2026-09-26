# ops-prod_group 落地执行报告

**日期**：2026-09-25 22:58
**目标**：为「需要动生产的人类运维」建立独立权限载体，不污染 `ops_group`（非生产边界）
**结论**：组已建成，3 条策略就位，实测 6/6 PASS，**成员暂空（决定暂不加人，留备）**

---

## 一、为什么不能复用现有组（决策依据）

用户原始问题：「运维同学可以动生产，应该配到哪个用户组下？」

四个现成组**全部不可用**：

| 组 | 内容 | 否决理由 |
| --- | --- | --- |
| `ops_group` | ops-operator + enforce-mfa + audit-protect + **prod-boundary** + **prod-oss-guard** | **Deny 恒胜 Allow** —— 加任何 Allow 策略都救不回生产写 |
| `admin_group` | admin-identity（含 `ram:*`）+ enforce-mfa + audit-protect | 权限过大。运维不该有 `ram:CreateUser` / `ram:CreatePolicy` |
| `power_user_group` | `PowerUserAccess`（托管策略），0 成员 | 账号级 `*:*`、无 MFA 强制、无审计保护、不受资源组边界约束 |
| `super_group` | 20 条托管含 `AdministratorAccess` | 未降权遗留，不应再加人 |

### 曾评估的三个方案

| | A. 新建 ops-prod_group | B. 只解 ops_group 的 boundary | C. 改 boundary 加 MFA 例外 |
| --- | --- | --- | --- |
| 形态 | 常驻生产写（独立组） | 常驻生产写（共享组） | `Condition Bool acs:MFAPresent:false` |
| 生产写条件 | 控制台 + MFA | 控制台 + MFA | 未 MFA 才拒 |
| 风险 | 需多维护一个组 | ① `ops_group` 含 2 名开发同学（`zhangzijun`/`xiangdong`）→ 开发直接拿生产写，上一轮「开发控制台无生产写」模型作废<br>② 丢「能否动生产」这条边界，以后无法区分 | ⚠️ **`acs:MFAPresent` 对 AK 调用不判定**（已实测）→ 条件不匹配 → Deny 不触发 → **AK 绕过** |
| 结论 | ✅ **用户选中** | ❌ 边界语义崩塌 | ❌ 有实测依据的安全漏洞 |

---

## 二、已创建资源

| 对象 | 值 |
| --- | --- |
| 组名 | `ops-prod_group` |
| Comments | `new-api prod ops (human): full ops write incl. production, MFA enforced` |
| CreateDate | 2026-09-25T14:58:23Z |
| 成员 | **空 —— 决定暂不加人，留备**。将来加入者保留原 `ops_group` 身份（权限并集） |

### 挂载策略（3 条）

| 策略 | 作用 |
| --- | --- |
| `newapi-ops-operator` | 全服务读写（`ecs/vpc/cs/rds/slb/alb/waf/alidns/cms/log/sls/oss/cr/cen/pvtz:*` + kms/tag 读 + bss 读 + `sts:GetCallerIdentity`）；**自带显式 Deny 列表**（见下） |
| `newapi-enforce-mfa` | 未通过 MFA 的控制台会话 → 除 11 个 MFA 自助动作外全 Deny |
| `newapi-audit-protect` | Deny OSS `actiontrail/` 前缀写删 |

### 刻意**不**挂（护栏已验证）

| 策略 | 为何排除 |
| --- | --- |
| `newapi-prod-boundary` | `Deny NotAction[*:Describe*,*:List*,*:Get*,*:Query*]` + `acs:ResourceGroupId ∈ [rg-ph-mnl, rg-sg]` → 会把生产写全挡 |
| `newapi-prod-oss-guard` | 无条件 Deny 生产桶 30 个写删动作 → 同样挡掉生产桶写 |

脚本内置护栏：`apply` 结束前强制检查这两条是否被误挂，命中即报 `[FAIL]`。

---

## 三、权限粒度：可读可改，不可销毁

`newapi-ops-operator` 的 Deny 列表（显式 Deny，优先级最高）：

```
account:*
bss:Modify*  bss:Pay*  bss:Create*
ecs:DeleteInstance
vpc:DeleteVpc  vpc:DeleteVSwitch
rds:DeleteDBInstance
cs:DeleteCluster
slb:DeleteLoadBalancer
oss:DeleteBucket
```

⇒ 生产运维能改配置、改安全组、调路由、重启实例，但**删不掉实例 / 库 / 集群 / 桶**。这是刻意保留的防呆层。

⚠️ **注意未覆盖项**：`oss:DeleteObject` **不在** Deny 列表 → 生产桶**对象级**删除被允许（这是与 `ops_group` 的关键差异，`ops_group` 由 `prod-oss-guard` 拦住对象删除）。

---

## 四、实测（PROBE 6/6 PASS）

方法：`iac-terraform`（唯一有 AK 的用户）临时挂 `newapi-ops-operator` 模拟新组组合，测完解绑还原。

| 用例 | 期望 | 基线 | 挂载后 |
| --- | --- | --- | --- |
| 生产 VPC 幂等写 `ModifyVpcAttribute` | ALLOW | ALLOW | ALLOW |
| 生产 VPC 只读 `DescribeVpcs` | ALLOW | ALLOW | ALLOW |
| 生产桶 写对象 `probe/` | ALLOW | ALLOW | ALLOW |
| 生产桶 删对象 `probe/` | ALLOW | ALLOW | ALLOW |
| 生产桶 读 `rds-backup/` | ALLOW | ALLOW | ALLOW |
| 审计前缀写 `actiontrail/`（audit-protect） | DENY | DENY | DENY |

**基线 = 挂载后完全一致** → `newapi-ops-operator` 不引入任何额外限制，符合设计。

### 未做破坏性实测（有意）

`oss:DeleteBucket` / `vpc:DeleteVpc` 等**不可逆动作未做实测** —— 判定器一旦误判即真删生产资源。这类保护由策略正文明列 Deny 静态保证。

另：早前已实测 `vpc DeleteVSwitch` / `ecs DeleteInstance` 的**资源存在性校验先于鉴权**，用不存在 ID 探测会返回「资源不存在」而非 `AccessDenied` → 无法用该方式验证销毁类 Deny。

### 测后还原核对

| 项 | 结果 |
| --- | --- |
| 生产桶 `probe/` 前缀 | 无残留（已清理） |
| 马尼拉 VPC 描述 | `new-api Philippines(Manila) prod`（原值，幂等写未改） |
| 马尼拉 vSwitch | 6/6 完好，AZ/CIDR 未变 |
| `iac-terraform` 用户级绑定 | 空（已还原） |
| `iac-terraform_group` 策略 | `[newapi-audit-protect, newapi-iac-terraform]`（未变） |

---

## 五、最终组格局

```
admin_group          [admin-identity, audit-protect, enforce-mfa]                        ← 账号管理
ops_group            [audit-protect, enforce-mfa, ops-operator, prod-boundary, prod-oss-guard]
                                                                                         ← 非生产运维（生产只读）
ops-prod_group       [audit-protect, enforce-mfa, ops-operator]                          ← 生产运维（本组，待加人）
dev-program_group    [dev-program, prod-boundary, prod-oss-guard]                        ← 开发程序身份（AK）
iac-terraform_group  [audit-protect, iac-terraform]                                      ← IaC（CI）
cicd-push_group      [audit-protect, cicd-acr-push]                                      ← 镜像推送（CI）
power_user_group     [PowerUserAccess]  ← 0 成员空壳
super_group          [20 条托管含 AdministratorAccess] ← yanxuewei，未动
```

### 人的身份模型（现在）

```
开发同学（zhangzijun / xiangdong）  → ops_group       生产只读，非生产读写
专职生产运维                        → ops-prod_group  生产读写（不可销毁）
                                   ↑ 也可同时属 ops_group（权限取并集）
```

---

## 六、回滚

```bash
bash ram_ops_prod_group.sh rollback
```

顺序：移除全部成员 → 解绑 3 条策略 → 删组。组有成员时 `DeleteGroup` 会失败，脚本已先清成员。

---

## 七、遗留 / 待办

| # | 事项 | 说明 |
| --- | --- | --- |
| 1 | 成员：**暂不加人**（2026-09-25 决定） | 组与策略已就位、护栏已验证。需要时执行 `aliyun ram AddUserToGroup --GroupName ops-prod_group --UserName <u> --region ap-southeast-1` |
| 2 | 将来加入者**保留 `ops_group` 身份**（已定） | 权限取并集 = 非生产写 + 生产写 = 全量运维。两组并存不冲突 |
| 3 | MFA 前置 | `enforce-mfa` 生效期间，未绑 MFA 的人登录后除自助动作全 Deny → 进组前先绑 MFA（`bind_mfa.sh`） |
| 4 | 与 IaC 的关系 | 上一轮定「生产变更走 `iac-terraform`」。本组是**有意例外**（应急手工通道），日常仍应优先 IaC；每次手工变更需补回 Terraform |
| 5 | 无临时提权机制 | 当前为常驻生产写。若需更严，可改为「审批 → 加组 → 到期移除」流程 |
| 6 | `power_user_group` 空壳 | 仍 0 成员，建议清理或明确用途 |
| 7 | `super_group` | `yanxuewei` 的 `AdministratorAccess` 按用户要求未动 —— 审计链唯一可绕过点 |

---

## 八、脚本

`ram_ops_prod_group.sh`（幂等）

| 子命令 | 作用 |
| --- | --- |
| `check` | 预演：组是否存在、待挂策略、边界策略是否误入 |
| `apply` | 建组 + 挂 3 条策略 + 护栏校验 |
| `verify` | 复核本组与全局组视图 |
| `probe` | 用 `iac-terraform` 临时承载模拟组合实测生产写，测完自动还原 |
| `rollback` | 移除成员 → 解绑策略 → 删组 |
| `all` | `apply` + `verify` |

证据归档：`.workbuddy/ops_prod_group_probe.txt`
