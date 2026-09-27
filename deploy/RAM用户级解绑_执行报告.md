# RAM 用户级策略解绑 · 执行报告

> 执行时间：2026-09-25 21:29 CST（verify 21:30 / smoke 21:31）
> 账号：`5108890064395960`　Region：`ap-southeast-1`（RAM 为全局服务，仅此地域有 endpoint）
> 目标：解除 4 个用户的**用户级**策略绑定，权限改由**用户组单点承载**

---

## 一、结论

**解绑完成，权限零变化。** 10 条用户级绑定全部解除，4 个组策略与成员完好，AK 实测 8/8 用例解绑前后逐条一致。

现在 RAM 授权的**唯一来源是用户组**，维护点从 14 条降到 10 条（用户级 10 + 组级 10 → 仅组级 10），改权限只需动组。

| 项目 | 解绑前 | 解绑后 |
| --- | --- | --- |
| `admin` 直接绑定 | 3 | **0** |
| `ops` 直接绑定 | 3 | **0** |
| `cicd-push` 直接绑定 | 2 | **0** |
| `iac-terraform` 直接绑定 | 2 | **0** |
| 组级绑定 | 10（4 组） | 10（4 组，未动） |
| 策略挂载实体 | user + group | **仅 group** |

---

## 二、变更清单（10 条 `DetachPolicyFromUser`，全部 `[OK]`）

| 用户 | 解除的策略 | 类型 | 现由谁承载 |
| --- | --- | --- | --- |
| `admin` | `newapi-admin-identity` | Custom | `admin_group` |
| `admin` | `newapi-enforce-mfa` | Custom | `admin_group` |
| `admin` | `newapi-audit-protect` | Custom | `admin_group` |
| `ops` | `newapi-ops-operator` | Custom | `ops_group` |
| `ops` | `newapi-enforce-mfa` | Custom | `ops_group` |
| `ops` | `newapi-audit-protect` | Custom | `ops_group` |
| `cicd-push` | `newapi-cicd-acr-push` | Custom | `cicd-push_group` |
| `cicd-push` | `newapi-audit-protect` | Custom | `cicd-push_group` |
| `iac-terraform` | `newapi-iac-terraform` | Custom | `iac-terraform_group` |
| `iac-terraform` | `newapi-audit-protect` | Custom | `iac-terraform_group` |

**执行前的护栏**：脚本逐条比对「用户级策略是否被其所属组覆盖」，只有 `COVERED` 才解绑；`MISSING` 一律 `[SKIP]` 并告警（解绑它会立即降权）。本次 `total=10 covered=10 missing=0`。

---

## 三、权限零变化证据（AK 直连实测，解绑前后同跑同一组用例）

用 `cicd-push` / `iac-terraform` 的存量 AK 直连调用，**不依赖控制台会话**，因此能验证 AK 路径是否真的还继承组策略。

| 用户 | 用例 | 策略依据 | 期望 | 解绑前 | 解绑后 |
| --- | --- | --- | --- | --- | --- |
| cicd-push | `cr ListInstance` | Allow `cr:*Instance`，Res=`*` | ALLOW | ALLOW | ALLOW |
| cicd-push | `cr GetInstance` | Allow | ALLOW | ALLOW | ALLOW |
| cicd-push | `ram ListUsers` | 未授权 → 隐式拒绝 | DENY | DENY | DENY |
| iac-terraform | `vpc DescribeVpcs` | Allow `vpc:*` | ALLOW | ALLOW | ALLOW |
| iac-terraform | `ram CreateUser` | **显式 Deny** | DENY | DENY | DENY |
| iac-terraform | `actiontrail DescribeTrails` | 未授权 | DENY | DENY | DENY |
| iac-terraform | OSS `DeleteObject` `actiontrail/*` | `newapi-audit-protect` **显式 Deny** | DENY | DENY | DENY |
| iac-terraform | OSS `DeleteObject` `probe/*` | Allow `oss:*`，非审计前缀对照 | ALLOW | ALLOW | ALLOW |

**`SMOKE=PASS (8/8)` 两次，diff 仅耗时数字不同（0.51s vs 1.52s），权限判定完全一致。**

其中第 7 条最关键：`iac-terraform` 本身有 `oss:*` Allow，却对 `actiontrail/` 前缀被拒 → 证明 **`newapi-audit-protect` 的 Deny 在解绑后仍由组承载生效**，审计保护链没断。

第 7/8 条用「删除不存在的对象」构造，**零副作用**（Deny 先于对象存在性判定，Allow 侧删除不存在的 key 也为空操作）。

---

## 四、交叉验证（3 层）

1. **用户级已空** — `ListPoliciesForUser` 对 4 个用户全返回空。
2. **组级完好** — `ListPoliciesForGroup`：admin_group=3、ops_group=3、cicd-push_group=2、iac-terraform_group=2；`ListUsersForGroup` 各 1 名成员。
3. **挂载实体反查** — `ListEntitiesForPolicy` 对所有 6 条策略：`user=-  role=-`，只剩 group。
   - `newapi-enforce-mfa` → `ops_group, admin_group`
   - `newapi-audit-protect` → 4 组全挂
4. **旁证**：AK 未受影响（cicd-push / iac-terraform 各 1 个 `Active` AK；admin / ops 本就无 AK，为控制台用户）。

---

## 五、回滚

```bash
bash ram_user_detach.sh rollback     # 读最近一次 apply 的清单，把 10 条策略绑回用户级
```

清单：`.workbuddy/ram_detach/rollback_manifest_20260925_212947.tsv`（10 行，含 user/policy/type）。

回滚后恢复「双绑」状态。若只回滚部分策略，用户级会与组级取**并集**，权限不会低于当前。

> 注意：`iac-terraform` 的策略里 `ram:AttachPolicyToUser` / `ram:DetachPolicyFromUser` 是**显式 Deny** —— 它无法自助改绑，必须用管理身份操作。这是有意设计。

---

## 六、解绑后的维护规则（新格局）

| 要改什么 | 改哪里 | 生效范围 |
| --- | --- | --- |
| 某角色权限增删 | 只改对应组的策略 | 组内全部成员 |
| 加人 | `AddUserToGroup` | 立即继承组权限 |
| 减人 | `RemoveUserFromGroup` | 立即失去组权限，**无残留用户级授权** |
| 临时提权 | **不要**再往用户级绑 —— 会重新引入第二维护点；改为新建临时组 + 设过期时间 |

**新铁律：禁止再对用户直接 `AttachPolicyToUser`。** 一旦恢复用户级绑定，就退回「两层漂移」状态 —— 组策略改了但用户级旧策略仍在，会出现「改了没生效 / 删了没收敛」。

后续若升级为**按资源组授权**（`acs:ResourceGroupId`），只需改 4 条组策略，不再需要用户级同步。

---

## 七、残留风险

| # | 风险 | 状态 |
| --- | --- | --- |
| 1 | `yanxuewei` 账号未降权（用户明确要求不动） | **审计链唯一可绕过点**，未处置 |
| 2 | `newapi-enforce-mfa` 对 AK 调用无效（`Bool`+`acs:MFAPresent` 不覆盖 AK） | 已知，程序用户靠 IP 白名单兜底 |
| 3 | admin / ops 无 AK → 本次无法直连验证其权限，只能靠「策略集合相同」推导 | 逻辑等效，未实测 |
| 4 | 解绑后若误删组成员关系 → 该用户瞬间**零权限** | 无残留用户级绑定作缓冲，属预期行为 |

---

## 八、本次新踩坑

**`GROUPS` 是 bash 内建只读数组**（当前进程所属组 GID，macOS `staff`=20）。脚本里 `GROUPS="admin_group ops_group ..."` 赋值被**静默忽略**，`$GROUPS` 展开成首元素 `20` → 组策略文件名变成 `group_20_pol.json`、读取全空 → 预演误判 **10/10 MISSING**。

已改名 `USER_GROUPS` 并在脚本顶注明。护栏（MISSING 即跳过）在此错误下**保住了系统**：没有执行任何解绑，`ok=0 skip=10`。

> 教训：预演结果与上一轮人工核对结论矛盾时，先怀疑工具/脚本，别怀疑数据。

---

## 九、交付物

- `ram_user_detach.sh` — 幂等，支持 `check` / `apply` / `verify` / `rollback` / `smoke`
- `.workbuddy/ram_detach/rollback_manifest_20260925_212947.tsv` — 回滚清单
- `.workbuddy/ram_detach_smoke_before.txt` / `_after.txt` — 前后实测原始输出
- `.workbuddy/ram_detach/` — 全部原始 JSON 证据
