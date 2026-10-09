# KMS 弃用 → 手工 Secret 注入（裁定与执行记录）

> **裁定日期**：2026-09-30 · **裁定人**：项目负责人
> **裁定**：**KMS / 凭据管家 / ExternalSecret / ack-secret-manager 链路整体弃用（太贵），改为手工 Secret 注入**。
> **权威口径**：本文件 + `deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md`（已全面订正）。
> **状态**：✅ 已执行完毕（云端清理 + 文档回写 + helper 脚本交付）。

---

## 一、理由

1. **成本**：国际站凭据管家必须先购买 **KMS 软件密钥管理实例**（月费固定，远超 7 个凭据的价值）；本账号实测 `kms ListKeys/ListSecrets` 均为 0——从未开通，也就没有沉没成本。
2. **组件不可用（次要但坐实）**：`ack-secret-manager` **不在 `ap-southeast-6` 集群 addon 目录**（`DescribeClusterAddonsVersion` 全量核对无任何 secret 类组件；CSI driver 同样不可用），ExternalSecret 连 CRD 都装不上。
3. **规模匹配**：只有 7 个凭据、2 个集群、低频轮换。手工注入 + 补偿控制（见 §三）完全够用，KMS 的自动轮换/审计能力属于超配。

## 二、云端清理（2026-09-30 已执行，证据齐全）

| 对象 | 动作 | 复核 |
|---|---|---|
| RAM 角色 `new-api-rrsa-kms-mnl` / `-sg`（09-29 所建，信任策略绑定集群 OIDC + SA 三元组） | DetachPolicy + DeleteRole | `GetRole` → `EntityNotExist.Role` ✅ |
| 自定义策略 `new-api-kms-readonly`（v1/v2 两个版本，14 个 Secret ARN） | DeletePolicyVersion(v1) + DeletePolicy | `GetPolicy` → `EntityNotExist.Policy` ✅ |
| SA `new-api-app` 的注解 `pod-identity.alibabacloud.com/role-name` | `kubectl annotate ... role-name-` 移除 | `get sa -o jsonpath` 无该注解 ✅ |
| 集群 RRSA 开关 / `ack-pod-identity-webhook` addon / ns `injection` label | **保留**（无害；开关随建簇参数，保留避免集群级变更） | — |
| `deploy/task17_rrsa.sh` | 头部标记 **⛔ 已废弃**（KMS 弃用）；如未来重启 KMS 路线可复跑重建角色 | — |

## 三、替代方案：手工 Secret 注入（本裁定落地物）

**交付物**：`deploy/task17_manual_secret.sh` —— 在目标集群 `new-api` 命名空间创建/更新 generic Secret **`new-api-secret`**（7 键，键名与原策略 ARN 严格一致，**Pod 侧 secretKeyRef / 任务 23 manifest 零改动**）：

```
SQL_DSN  SQL_DSN_MIGRATE  REDIS_CONN_STRING  SESSION_SECRET
SESSION_SECRET_OLD  PAYMENT_PRIVATE_KEY  TLS_WILDCARD
```

**操作模型**：
```bash
VALUES_FILE=./newapi.values bash deploy/task17_manual_secret.sh --apply mnl   # 值文件 0600，用完脚本自动 shred
bash deploy/task17_manual_secret.sh --check                                   # 复核 7 键齐全性
```

**补偿控制（手工方案相对 KMS 失去的能力 → 替代做法）**：

| KMS 原有能力 | 手工方案的补偿 |
|---|---|
| 自动轮换（RDS 型 6h–365d） | 轮换日历落值班表（owner + 周期字段，任务 52/55）；SESSION_SECRET 走双密钥窗口（任务 36 SOP：Secret 键改值 + 双集群 rollout restart） |
| 访问审计 | 无 KMS 访问记录可拉 → 时间线 = ActionTrail（API 侧）+ 跳板机会话录制（OSS）+ kubectl events（泄露应急已改写） |
| 集中保管/不落盘 | 值源 = **本地加密保管（密码管理器 / 0600 临时文件，用完 shred）**；git 全历史扫描纳入例行（卡片验证④，实测 17 处命中均为教学占位/噪声） |
| 双区域同源 | **双集群各自 apply 同一份本地值源**（SESSION_SECRET/SESSION_SECRET_OLD/PAYMENT_PRIVATE_KEY/TLS_WILDCARD 同值；SQL_DSN 按站点——备站 = 马尼拉公网串 + verify-full） |
| 权限最小化（RRSA 只读单凭据） | Secret 级 RBAC：`new-api` ns 内 ServiceAccount 已最小；无跨 ns 泄露面 |

**红线（不变）**：值**绝不**进 Git / CI 变量 / 镜像 / ConfigMap / shell 历史 / 命令行参数；`${PLACEHOLDER}` 纪律照旧。

## 四、受影响任务清单（均已在 v2.0 指南订正）

| 任务 | 原表述 | 现口径 |
|---|---|---|
| 任务 3（证书预置） | 私钥+证书链入 KMS 凭据 | 私钥**本地加密保管**；ALB 直接引用 CAS 证书 ID（任务 19 用 `CERT_ID_ALB`），集群内不需要 tls secret |
| 任务 10/24（建簇） | 记录 RRSA 参数供任务 17 | RRSA 参数留档；**最终未用于凭据链**（保留开关，无害） |
| 任务 13（RDS 账号） | 密码进 KMS | 密码进本地加密保管 → 手工 Secret |
| 任务 15（RDS 连接串） | 真实密码只进凭据管家经 ExternalSecret | 只进本地保管经手工 Secret |
| 任务 17（本卡） | RRSA 角色 + KMS 凭据 + ExternalSecret | **手工 Secret 注入**（§三）；RRSA 角色已删 |
| 任务 19/23（ALB/Deployment） | ExternalSecret 生成 new-api-secret | `new-api-secret` 由 helper 脚本手工创建（manifest 零改动） |
| 任务 24/30（备区） | SG 集群同构 ExternalSecret、统一 KMS 源 | SG 集群手工建同名 Secret（同值/按站点），跨区通道建立后执行 |
| 任务 36/55（双密钥轮换/演练） | KMS 改值 + 版本位 | Secret 键改值（patch/重建）+ 双集群 rollout restart；窗口结束清 `SESSION_SECRET_OLD` 键 |
| 任务 52（成本表） | KMS 实例费用行 | 删除该行；**省下**软件密钥管理实例月费 |
| 泄露应急（§13） | 从 KMS 拉访问记录 | ActionTrail + 会话录制 + kubectl events 取时间线 |
| G0 门禁 / 数据泳道收尾 / 交付自检 | Secret 均入 KMS | Secret 均手工注入且值不入 Git |

## 五、未完成 / 挂账

1. **凭据值本身**：仍待数据泳道提供（值不因 KMS 弃用而免除）。值齐后：`VALUES_FILE=... bash deploy/task17_manual_secret.sh --apply mnl` → `--check` → 部署任务 23 时做 Pod 注入 smoke。
2. **新加坡集群**：同构 Secret 待跨区通道建立（跳板机私网不可达，任务 46 限制）；helper 已预留 `--apply sg`（当前拒绝执行并提示）。
3. **任务 36/55 双密钥演练**：演练时按新 SOP（Secret 键改值）重写证据。

## 六、回滚（如未来重启 KMS 路线）

复跑 `deploy/task17_rrsa.sh --apply`（重建角色/策略）→ 购 KMS 实例 → 建凭据 → 恢复 ExternalSecret 组件选型。手工 Secret 与 KMS 可并存过渡（Secret 名不变）。
