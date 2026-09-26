# new-api 菲律宾部署 · 项目长期约定

## 云账号与凭据

- 账号 `5108890064395960`；主 region `ap-southeast-6`（马尼拉，仅 6a/6b 两 AZ），备 region `ap-southeast-1`（新加坡）。
- 工具：`aliyun` CLI `~/.workbuddy/binaries/aliyun-cli/aliyun`（已在 `~/.zshrc` 注入 PATH，非交互 shell 需 `zsh -i -c`）；OSS 必须用 `ossutil` v2 `~/.workbuddy/binaries/ossutil/ossutil`（配置 `~/.aliyun/ossutilconfig`，600）。
- **RAM 服务用 `--region ap-southeast-1`；RMS `resourcemanager` 必须 `--region ap-southeast-1`**（ap-southeast-6 无 endpoint）。

## 资源组口径（2026-09-25 定稿）

| 资源组 | ID | 内容 |
| --- | --- | --- |
| 默认 | `rg-acfnssmgwnsb5oa` | 仅系统遗留，**禁止**放 new-api 资源 |
| `rg-ph-mnl` | `rg-aek4nyivmmsb6iy` | 马尼拉**生产** |
| `rg-sg` | `rg-aek4zvb3ldoiyua` | 新加坡**生产**（备站） |
| `rg-nonprod` | `rg-aek4hk3prqgqjcy` | staging + perf + 压测（一切非生产） |
| `rg-shared` | `rg-aek3yypouljf4ry` | 跨站共享（ACR `cri-avfqy9xkqi5bj8ee` / ActionTrail / CMS） |

**规则：生产 vs 非生产 = 权限边界（RG 维度）；站点 ph-mnl|sg = 标签 `site` + K8s 命名空间维度。**

铁律：
1. 资源组**必须在创建时指定**（`CreateVpc --ResourceGroupId`；`CreateVSwitch` 无此参数，但**继承所属 VPC 的组**）→ 顺序：先把 VPC 放进目标组，再建 vSwitch。
2. **vSwitch 不可单独换组**（`MoveResources` 报 `UnsupportedOperation`）；迁 VPC 会**级联**其下 vSwitch。
3. OSS 换组用 `ossutil api put-bucket-resource-group`；ACR 用 `aliyun cr ChangeResourceGroup --ResourceRegionId`（**不是** `--RegionId`）。
4. 一旦启用「按资源组授权」，RG 迁移与策略变更**必须同批发布**。
5. `resourcemanager ListResources` **不索引 vSwitch** → 控制台「资源数量」低估，盘点走 `vpc DescribeVSwitches`。

## RAM 治理口径

- 4 个主体 = 4 个用户 = 4 个同名组：`admin`/`admin_group`、`ops`/`ops_group`、`cicd-push`/`cicd-push_group`、`iac-terraform`/`iac-terraform_group`。
- 策略（全 Custom）：`newapi-admin-identity`、`newapi-ops-operator`、`newapi-cicd-acr-push`、`newapi-iac-terraform`、`newapi-enforce-mfa`（仅 admin/ops）、`newapi-audit-protect`（4 者共有）。
- `newapi-enforce-mfa` **只约束控制台会话**，对 AK 调用无效 → 程序用户靠 IP 白名单。
- **2026-09-25 21:29 起改为「仅组级承载」**：已 `DetachPolicyFromUser` 解除 4 用户全部 10 条用户级绑定，`ListEntitiesForPolicy` 现在 `user=- role=-` 只剩 group。AK 实测解绑前后 8/8 用例一致，权限零变化。
- **铁律：禁止再对用户直接 `AttachPolicyToUser`** —— 会退回「两层漂移」（改了组没改用户级 → 改了没生效 / 删了没收敛）。临时提权用临时组。
- 幂等脚本：`bind_mfa.sh` / `mfa_check.sh` / `attach_group_policies.sh` / `ram_user_detach.sh`（`check|apply|verify|rollback|smoke`；回滚清单在 `.workbuddy/ram_detach/rollback_manifest_*.tsv`）。

### 生产边界与开发程序身份（2026-09-25 22:45 定稿）

- **人/程序双身份**：`zhangzijun` / `xiangdong` = 控制台身份（在 `ops_group`，**无 AK**）；`dev-zhangzijun` / `dev-xiangdong` = 程序身份（在 `dev-program_group`，**无 LoginProfile**，纯 AK）。
- 边界策略两条：
  - `newapi-prod-boundary` = `Deny NotAction[*:Describe*,*:List*,*:Get*,*:Query*]` + `Condition acs:ResourceGroupId ∈ [rg-ph-mnl, rg-sg]` → **生产只读、写全挡**。
  - `newapi-prod-oss-guard` = 无条件 Deny 生产桶 30 个写删动作。**必须含 `oss:PutBucketResourceGroup`**，否则可把桶移出生产 RG 绕过 boundary。
- 绑定：`ops_group` = 5 条（+上述两条）；`dev-program_group` = 3 条（`newapi-dev-program` + 上述两条）。
- **`iac-terraform_group` 故意不绑边界** —— terraform 要管生产桶配置。
- 三层防御**同向叠加**（最小策略不授生产写 + RG 层 + ARN 层）→ 任一层单独存在也拦得住，逐层解绑对照实测恒为 DENY。
- 代价：云 API 层生产变更只能走 IaC；K8s 层 kubectl 运维走 RBAC，不受影响。

### ops-prod_group：人类生产运维组（2026-09-25 22:58 定稿）

- `ops-prod_group` = `newapi-ops-operator` + `newapi-enforce-mfa` + `newapi-audit-protect`，**刻意不挂** boundary / oss-guard → 生产**可读写**（唯一能手工动生产的组）。
- 语义分工：`ops_group` = 非生产运维（生产只读）；`ops-prod_group` = 生产运维（可写不可销毁，靠 `newapi-ops-operator` 自带 Deny 列表拦 `DeleteInstance`/`DeleteVpc`/`DeleteVSwitch`/`DeleteDBInstance`/`DeleteCluster`/`DeleteLoadBalancer`/`DeleteBucket`）。
- ⚠️ **`oss:DeleteObject` 不在 ops-operator 的 Deny 列表** → 本组可删生产桶对象；`ops_group` 由 `prod-oss-guard` 拦住。这是两组的实质差异。
- 决策否决项：① 复用 `ops_group` 不可行（Deny 恒胜 Allow，加 Allow 无救）；② `power_user_group` 不适（账号级 `*:*`、无 MFA 强制）；③ 改 boundary 加 `Condition Bool acs:MFAPresent:false` **不可行且危险** —— `acs:MFAPresent` 对 AK 不判定 → 条件不匹配 → Deny 不触发 → AK 绕过。
- 实测：`iac-terraform` 临时挂 `newapi-ops-operator` 模拟，基线 = 挂载后完全一致（生产 VPC 写 / 生产桶写删读 ALLOW；`actiontrail/` 前缀写 DENY）→ ops-operator 不引入额外限制。测后已还原。
- 幂等脚本 `ram_ops_prod_group.sh`（`check|apply|verify|probe|rollback|all`），内置护栏：apply 结束检查两条边界策略是否误挂。
- 与 IaC 的关系：本组是**有意例外**（应急手工通道），日常优先 `iac-terraform`，手工变更需补回 Terraform。
- **成员暂空（2026-09-25 决定：暂不加人，留备）**。将来加入者**保留原 `ops_group` 身份**（权限取并集 = 非生产写 + 生产写 = 全量运维）。加入前须先绑 MFA。

## 网络基线（§2.2，勿改）

`vpc-newapi-mnl-prod` `10.0.0.0/16` + 6 vSwitch（pub `10.0.0.0/24`·`10.0.1.0/24`；app `10.0.16.0/20`·`10.0.32.0/20`；data `10.0.48.0/20`·`10.0.64.0/20`）；
`vpc-newapi-sg-prod` `10.1.0.0/16` + 4 vSwitch（pub `10.1.0.0/24`·`10.1.1.0/24`；app `10.1.16.0/20`·`10.1.32.0/20`）。
Terway 每 Pod 占一个真实 VPC IP；app 段免费 IP 基线 4092，**低于 200 告警 P2**。

## 踩坑必记（重复踩过）

- **变量后紧跟中文/全角标点会被 bash 3.2 吞进变量名** → 一律写 `${VAR}`（踩过 `$VAR，`、`$cur_rg（`）。
- bash 3.2 + `set -u`：`local x y` 里未赋值的名字引用即报 unbound → 写 `local y=""`。
- **函数日志与返回值不能同走 stdout**：`ID=$(f)` 会把日志吞进变量 → 一律日志 `>&2`。
- zsh 不做变量分词：数组参数必须 `"${ARR[@]}"`；`$ACC:t` 之类被当参数修饰符 → 用 `${ACC}`。
- CLI 只传 `--endpoint` 不够，VPC 类**必须传 `--region`**。
- **`GROUPS` 是 bash 内建只读数组**（进程所属组 GID，macOS=`20`）：赋值被静默忽略，`$GROUPS` 展开成首元素 → 组名变 `20`、文件读空。踩过导致预演误判 10/10 MISSING。同类禁用名：`UID`、`EUID`、`PPID`、`RANDOM`、`SECONDS`、`PIPESTATUS`、`FUNCNAME`、`BASH_*`、`LINENO`、`OPTARG`、`HOSTNAME`。
- 预演结论与上一轮人工核对**矛盾**时，先怀疑脚本/工具，别怀疑数据。

## 云端权限探测铁律（2026-09-25 实测）

- **判定权限结果严禁用输出文本子串匹配**。`actiontrail LookupEvents` 返回的审计事件正文里就含 `AccessDenied`（正是测试自身产生的事件）→ 误判。必须按结构化字段判定：
  - aliyun CLI v3 错误：JSON **顶层** `error_code`；成功响应里可能有 `"Code":"success"` / `IsSuccess:true`（需忽略）
  - ossutil：错误走 **stderr 纯文本**，格式 `Error Code: AccessDenied.`（**不是 XML**）
  - XML 兜底：`<Code>xxx</Code>`
- **`Error Code: Access denied by bucket policy` 是 OSS 的误导文案** —— RAM 策略拒绝时也返回它，不能据此判定是 Bucket Policy 拦截（用 `get-bucket-policy` 实际内容确认）。
- **不能用「不存在的资源 ID」做权限探测**：`vpc DeleteVSwitch`、`ecs DeleteInstance` 的**资源存在性校验先于鉴权**，返回「资源不存在」而非 `AccessDenied`。改用**幂等写**（把属性改成当前值，零副作用）。
- `acs:ResourceGroupId` 条件键**已实测对 OSS 对象操作与 VPC API 生效**（基线 ALLOW → 绑定 DENY → 解绑 ALLOW）。
- `NotAction` 支持 `*:Describe*` / `*:List*` / `*:Get*` / `*:Query*` 通配，可用作只读白名单。
- 很多"读"API 有必填参数（`cms DescribeMetricList`、`vpc DescribeRouteTables`），不能当无参读用。
