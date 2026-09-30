#!/usr/bin/env python3
# ==============================================================================
# patch_kms_deprecated_20260930.py — KMS 弃用裁定（2026-09-30）的 v2.0 指南订正
# 范围：除任务 17 卡片登记块/横幅/§0.5 条目（另行手工改）外的全部 KMS/ExternalSecret
#       关联表述（任务 3/13/15/24/30/36/52、基线表、密钥纪律、泄露应急、附录、自检）。
# 幂等：逐对「new 已在 → 跳过；old 命中 1 次 → 应用；否则 FAIL 不落盘」。
# 用法：python3 deploy/patch_kms_deprecated_20260930.py --check|--apply
# ==============================================================================
import sys, shutil, time

FILE = "deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md"

PAIRS = [
("| 17  | RRSA+KMS+ExternalSecret+ConfigMap/Secret |",
 "| 17  | ConfigMap/Secret（手工注入；2026-09-30 裁定弃用 KMS/ExternalSecret） |",
 "任务清单"),
("KMS 凭据 `newapi/prod/session-secret`，**双区域同源一致**",
 "手工 Secret `new-api-secret`（双集群同值；2026-09-30 裁定弃用 KMS）",
 "基线表"),
("# 1. 私钥+证书链入 KMS 凭据（值从本地安全文件读，走 KMS 落库，绝不进 Git）",
 "# 1. ~~私钥+证书链入 KMS 凭据~~ ⏸ 2026-09-30 裁定 KMS 弃用：私钥**本地加密保管**（密码管理器/0600 文件）；ALB 直接引用 CAS 证书 ID（任务 19 `CERT_ID_ALB`），集群内不需要 tls secret",
 "任务3 步骤1"),
("期望输出：`{\"SecretName\": \"new-api/prod/tls-wildcard\", ...}`，无报错。（若马尼拉/新加坡 KMS 实例未开通，此步在 KMS 控制台创建同名凭据：【控制台】`[图 D1-A-3｜拍摄对象：KMS 凭据管理-new-api/prod/tls-wildcard 详情（凭据值页不截图）；打码：凭据值、账号 UID]`）",
 "⏸ **2026-09-30 裁定 KMS 弃用，本步取消**（原为 KMS 凭据管家建 tls-wildcard）。私钥本地加密保管；ALB 走 CAS 证书 ID，不需要集群内 tls secret——证书续期与 AlbConfig 同步见任务 38。",
 "任务3 期望输出"),
("| KMS 列表无该凭据 | `CreateSecret` 报错（KMS 实例/权限）→ 按报错开通或补 `kms:CreateSecret` 权限后重试 |",
 "| ~~KMS 列表无该凭据~~ | ⏸ 2026-09-30 裁定 KMS 弃用，本行取消（私钥本地加密保管，不入任何云端凭据库） |",
 "任务3 故障表"),
("（KMS/密钥管家托管，不写明文）",
 "（不写明文；CI secret 变量即托管处，KMS 已弃用）",
 "任务16 ACR"),
("私钥在 KMS new-api/prod/tls-wildcard；到期告警已建",
 "私钥本地加密保管（KMS 已弃用；ALB 引用 CAS 证书 ID）；到期告警已建",
 "G0 证书"),
("真实值只进**密钥管理服务（凭据管家）**，经 ExternalSecret 注入集群，严禁落盘 Git/CI 变量。",
 "真实值**只进本地加密保管（密码管理器 / 0600 临时文件，用完销毁）**，经**手工 `kubectl create secret`**（`new-api-secret`，helper：`deploy/task17_manual_secret.sh`）注入集群，严禁落盘 Git/CI 变量/镜像。（2026-09-30 裁定弃用 KMS/ExternalSecret，全文见 `deploy/KMS弃用_手工Secret注入_裁定_2026-09-30.md`）",
 "密钥纪律"),
("（密码一律来自本地环境变量/KMS，**不写明文**）",
 "（密码一律来自本地环境变量/密码管理器，**不写明文**；KMS 已弃用）",
 "任务13"),
("真实密码只进 KMS 凭据管家，经 ExternalSecret 注入：",
 "真实密码只进本地加密保管，经手工 Secret（`new-api-secret`）注入：",
 "任务15"),
("- [ ] 所有新增 Secret 均已入 KMS 凭据管家并经 ExternalSecret 注入，仓库/CI/ConfigMap 明文中无任何密码或完整 DSN。",
 "- [ ] 所有新增 Secret 均以手工 `kubectl create secret`（`new-api-secret`）注入（2026-09-30 裁定弃用 KMS/ExternalSecret），仓库/CI/ConfigMap 明文中无任何密码或完整 DSN。",
 "数据泳道收尾"),
("`SESSION_SECRET` 来源（同一 KMS Secret Key）",
 "`SESSION_SECRET` 来源（双集群同值手工 Secret）",
 "任务24 一致性"),
("任务 17 的 Namespace/ConfigMap/ExternalSecret 已 Ready；镜像已推 ACR",
 "任务 17 的 Namespace/ConfigMap 已就绪、手工 Secret `new-api-secret` 已注入（2026-09-30 裁定弃用 ExternalSecret/KMS）；镜像已推 ACR",
 "任务23 前置"),
("        # SQL_DSN / SESSION_SECRET 等经 secretKeyRef 注入 ExternalSecret 生成的 new-api-secret",
 "        # SQL_DSN / SESSION_SECRET 等经 secretKeyRef 注入手工创建的 new-api-secret（deploy/task17_manual_secret.sh）",
 "任务23 注释"),
("`new-api-config` ConfigMap 与 ExternalSecret 已建（`SESSION_SECRET` 等密钥仅经 KMS 注入，manifest 不出现明文）",
 "`new-api-config` ConfigMap 与手工 Secret `new-api-secret` 已建（`SESSION_SECRET` 等仅经 secretKeyRef 注入，manifest 不出现明文；2026-09-30 裁定弃用 ExternalSecret）",
 "任务30 前置"),
("2. `ExternalSecret` 在新加坡另建一份（键同名），`SQL_DSN` 指向**马尼拉 RDS 公网串**（`${SG_SQL_DSN_PLACEHOLDER}`）+ `sslmode=verify-full`；`SESSION_SECRET` 与主站引用同一 KMS 凭据：",
 "2. 手工 Secret `new-api-secret` 在新加坡集群另建一份（键同名，helper：`deploy/task17_manual_secret.sh --apply sg`，跨区通道建立后执行），`SQL_DSN` 指向**马尼拉 RDS 公网串**（`${SG_SQL_DSN_PLACEHOLDER}`）+ `sslmode=verify-full`；`SESSION_SECRET` 与主站**同值**（同一份本地加密保管源，双集群各自 kubectl apply）：",
 "任务30 SG Secret"),
("修复：统一 KMS 源，改后两侧 `kubectl rollout restart`。",
 "修复：统一手工 Secret 源（双集群同值），改后两侧 `kubectl rollout restart`。",
 "任务30 验证"),
("1. KMS 建版本位：`SESSION_SECRET`（当前值 A）与 `SESSION_SECRET_OLD`（轮换窗口内的旧值位）。写入新值前做长度/字符集校验（≥32 随机字节）：",
 "1. Secret 版本位（手工）：`SESSION_SECRET`（当前值 A）与 `SESSION_SECRET_OLD`（轮换窗口内的旧值位）。写入新值前做长度/字符集校验（≥32 随机字节）；**双集群都要改**（先备份当前 Secret 以便回滚）：",
 "任务36 步骤1"),
("（全部 Pod 认 A；KMS 改值不重启无影响，env 只在启动时读）",
 "（全部 Pod 认 A；Secret 改值不重启无影响，env 只在启动时读）",
 "任务36 T0"),
("T1   KMS 值改为 B（先不重启）",
 "T1   Secret 值改为 B（先不重启；双集群）",
 "任务36 T1"),
("3. 回滚方向唯一：把 KMS 改回 A + 全量 `rollout restart`，**不要改前端**。",
 "3. 回滚方向唯一：把 Secret 值改回 A + 全量 `rollout restart`，**不要改前端**。",
 "任务36 回滚"),
("# V3 轮转后 KMS 旧版本不可读（防误恢复）",
 "# V3 轮转窗口结束后清掉 SESSION_SECRET_OLD 键（手工 Secret 无版本位，防误恢复/回滚混淆）",
 "任务36 V3"),
("修复：立即 KMS 改回 A + 全量 `rollout restart`",
 "修复：立即把 Secret 值改回 A + 全量 `rollout restart`",
 "任务36 V1修复"),
("改进：每个 KMS Secret 有 owner + 轮换周期字段（网络与安全规划表已列，交接时复述）。",
 "改进：每个 Secret 键有 owner + 轮换周期字段（网络与安全规划表已列，交接时复述；手工 Secret 无平台审计，轮换日历必须落值班表）。",
 "安全核查 坑3"),
("| 会话在接管后依赖两侧同 SESSION_SECRET | 已统一 KMS 源 | 轮换 SOP 强制双 region 同步；任务 36 覆盖 |",
 "| 会话在接管后依赖两侧同 SESSION_SECRET | 双集群手工 Secret 同值 | 轮换 SOP 强制双集群同步；任务 36 覆盖 |",
 "接管表"),
("3. 从 KMS 拉取受影响 Secret 的访问记录 + 操作审计（ActionTrail）时间线，出事件报告。",
 "3. 时间线取证：ActionTrail（API 侧）+ 跳板机会话录制（OSS）+ kubectl events（手工 Secret 无 KMS 访问记录可拉，以「谁在何时改了 Secret」替代），出事件报告。",
 "泄露应急"),
("☐ 所有密钥/凭据均走 KMS + RRSA/ExternalSecret，正文一律 ${PLACEHOLDER}，无一处真实密钥值",
 "☐ 所有密钥/凭据均走手工 Secret（本地加密保管 → `kubectl create secret`，helper `deploy/task17_manual_secret.sh`），正文一律 ${PLACEHOLDER}，无一处真实密钥值（2026-09-30 裁定弃用 KMS）",
 "交付自检"),
]

def main():
    mode = next((a for a in sys.argv[1:] if a in ("--check", "--apply")), "--check")
    with open(FILE, encoding="utf-8") as f:
        text = f.read()
    fails, applied, done = [], 0, 0
    for i, (old, new, tag) in enumerate(PAIRS, 1):
        if new in text:
            done += 1
            print(f"  [{i:>2}] [已是最新] {tag}")
            continue
        n = text.count(old)
        if n == 1:
            applied += 1
            if mode == "--apply":
                text = text.replace(old, new)
            print(f"  [{i:>2}] [待应用] {tag}" if mode == "--check" else f"  [{i:>2}] [应用] {tag}")
        else:
            fails.append((i, tag, n))
            print(f"  [{i:>2}] [FAIL] {tag}（old 匹配 {n} 次，应为 1）")
    print(f"\n共 {len(PAIRS)} 对：已最新 {done}，本次应用 {applied}，异常 {len(fails)}")
    if fails:
        print("存在异常，不写文件。")
        sys.exit(1)
    if mode == "--apply":
        bak = FILE + ".bak-kmsdep-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(FILE, bak)
        with open(FILE, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"已写入：{FILE}\n备份：{bak}")

if __name__ == "__main__":
    main()
