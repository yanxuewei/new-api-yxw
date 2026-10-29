# 安全组台账（SG Ledger）· new-api 菲律宾/新加坡

> 状态：**业务安全组已提前落地（2026-09-29，早于任务 22 排期 D5）**。
> 落地脚本：`deploy/tasks/task22/sg_bootstrap.sh`（幂等，支持 `--verify` / `--dry-run` / `--office-cidr`）。
> 依据：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` §8.1 / 任务 22；`deploy/aliyun/ph/security-groups.md`。
> 提前落地的理由：ACK 节点池**必须显式**指定 `scaling_group.security_group_ids`，否则 ACK 会自建 `sg-` 前缀托管组（任务 22 坑 2）；把 ID 先定死可杜绝"改了另一个安全组"的排查陷阱。

## 1. SG ID 台账（回填 IaC / 节点池）

| 变量 | 名称 | SG ID | Region | VPC | 资源组 |
| --- | --- | --- | --- | --- | --- |
| `SG_MNL_ALB` | `sg-mnl-alb` | `sg-5tsj1epvcjjv6jkg3zks` | ap-southeast-6 | `vpc-5tst1tgeessxn1azwasg2` | `rg-aek4nyivmmsb6iy` |
| `SG_MNL_APP` | `sg-mnl-app` | `sg-5tsil3ca5dfkqefks1g9` | ap-southeast-6 | 同上 | 同上 |
| `SG_MNL_DB` | `sg-mnl-db` | `sg-5tsawhljdqzwo2t0n4ut` | ap-southeast-6 | 同上 | 同上 |
| `SG_SG_ALB` | `sg-sg-alb` | `sg-t4nbgfbh2cidnve88avf` | ap-southeast-1 | `vpc-t4nimmwvruexbnene0a3r` | `rg-aek4zvb3ldoiyua` |
| `SG_SG_APP` | `sg-sg-app` | `sg-t4n0qnhy8mxq9g733r67` | ap-southeast-1 | 同上 | 同上 |

其余在册 SG：`sg-5tshna0oeautlmbvgefd`（`created_by_rds`，RDS 托管，勿动）。

## 2. 已落地规则（**2026-09-29 基线，17 条**，全部带用途 Description；2026-10-06 收口后现为 **24 条**，增删明细见 §7）

### `sg-mnl-alb`（2 条，全入向）

| 方向 | 端口 | 源 | 用途 |
| --- | --- | --- | --- |
| in | TCP 443 | `0.0.0.0/0` | `pub-https-ingress` |
| in | TCP 80 | `0.0.0.0/0` | `http-301-only` |

### `sg-mnl-app`（6 条：1 入向 + 5 出向）

| 方向 | 端口 | 源/目的 | 用途 |
| --- | --- | --- | --- |
| in | TCP 3000 | `sg-5tsj1epvcjjv6jkg3zks`（组引用） | `from-alb-only` |
| out | TCP 5432 | `10.0.64.0/20` | `to-rds-pg-primary`（RDS 实测 10.0.69.77） |
| out | TCP 5432 | `10.0.48.0/20` | `to-rds-pg-primary-az-a` |
| out | TCP 6379 | `10.0.48.0/20` | `to-tair-cache`（Tair 实测 10.0.54.118） |
| out | TCP 6379 | `10.0.64.0/20` | `to-tair-cache-az-b` |
| out | TCP 443 | `0.0.0.0/0` | `to-upstream-api-via-nat`（上游 IP 不可枚举，靠 NAT + 8 EIP 收敛） |

### `sg-mnl-db`（5 条，全入向）

| 方向 | 端口 | 源 | 用途 |
| --- | --- | --- | --- |
| in | TCP 5432 | `sg-5tsil3ca5dfkqefks1g9`（组引用） | `from-app-only` |
| in | TCP 5432 | `47.84.184.246/32` | `from-sg-nat-eip`（新加坡 NAT 出口池） |
| in | TCP 5432 | `47.84.29.162/32` | 同上 |
| in | TCP 5432 | `47.84.83.76/32` | 同上 |
| in | TCP 5432 | `47.84.126.214/32` | 同上 |

### `sg-sg-alb`（2 条，全入向）

| 方向 | 端口 | 源 | 用途 |
| --- | --- | --- | --- |
| in | TCP 443 | `0.0.0.0/0` | `pub-https-ingress` |
| in | TCP 80 | `0.0.0.0/0` | `http-301-only` |

### `sg-sg-app`（2 条：1 入向 + 1 出向）

| 方向 | 端口 | 源/目的 | 用途 |
| --- | --- | --- | --- |
| in | TCP 3000 | `sg-t4nbgfbh2cidnve88avf`（组引用） | `from-alb-only` |
| out | TCP 443 | `0.0.0.0/0` | `to-upstream-api-via-nat` |

## 3. 必须延后（依赖未产生的值，禁手工抄）

| # | 规则 | 卡在哪 | 何时补 |
| --- | --- | --- | --- |
| 1 | `sg-mnl-alb` in 443 ← `${DCDN_L2_IPS}` | DCDN 服务**未开通**（`DcdnServiceNotFound`）→ 按坑 1 走 WAF 3.0 云原生接入，本条**不适用** | 若改走 DCDN 回源再取 |
| 2 | `sg-mnl-alb` in ← GTM 探测源 IP 段 | GTM 未建（`DescribeGtmInstances` 为空） | 任务 21 之后，同时加 WAF 白名单 |
| 3 | `sg-sg-app` out 5432 → `${RDS_MNL_PUB}/32` | RDS 只有 Private 地址（10.0.69.77），公网地址未开 | 任务 15 之后 |
| 4 | `sg-mnl-alb-edge`（22/443）、`sg-mnl-ack-api`（6443） | 需企业办公出口 IP 段（截图有、指南 §8.1 无，属运维入口补充项） | CIDR 确认后跑 `--office-cidr` |

## 4. 剩余动作（安全组之外）

- [ ] 任务 11：ACK 马尼拉节点池 body 加 `scaling_group.security_group_ids: ["sg-5tsil3ca5dfkqefks1g9"]`
- [ ] 任务 24：ACK 新加坡节点池 body 加 `scaling_group.security_group_ids: ["sg-t4n0qnhy8mxq9g733r67"]`
- [ ] 两集群级 `is_enterprise_security_group` 保持 `false`
- [ ] RDS 白名单分组绑 `sg-mnl-app`（安全组与 RDS 白名单是**两层**）
- [ ] 任务 22 出口复验 V1–V4（需节点就绪，V2/V4 还需 ALB 与工作负载）

## 5. CLI 口径纠错（2026-09-29 实测，指南原文有误）

| 项 | 原指南写法 | 实测正确写法 |
| --- | --- | --- |
| 出向规则 | `aliyun ecs AuthorizeSecurityGroup` | **`aliyun ecs AuthorizeSecurityGroupEgress`**（前者只加持入向规则，用它建出向**静默失败**） |
| 参数形式 | `--IpProtocol/--PortRange/--SourceGroupId/--Policy/--Priority/--Description` | 全部标 `Deprecated` → 用 **`--Permissions.1.*`** |
| 出向组引用 | 计划用 `sg-mnl-db` 组引用 | Egress API 支持 `Permissions.N.DestGroupId`，但**托管实例（RDS/Tair）的 SG 由云产品自管、默认不可换** → 出向改用 `DestCidrIp`；真正控制点是数据层侧入向组引用 |
| 重复规则返回 | 会报 `InvalidPermission.Duplicate` | `Permissions.N.*` 路径下**不报错、静默去重** → 只能前置比对（脚本已用 `RULE_SET` 预读） |
| 名称查询安全 | —— | 查询失败**绝不能**当"不存在" → 否则重复建组（实际踩过一次，已清理） |

## 6. 踩坑记录（写脚本时踩到，已修）

1. **`AuthorizeSecurityGroup` 建出向无效**：v1 用它加 6 条出向规则，全部静默失败，规则一条没落。
2. **错误检测只认 JSON `"Code"`**：aliyun CLI 失败输出是 `ERROR: SDK.ServerError` + 文本 `ErrorCode: xxx`，非 JSON → 把失败当成功。
3. **`2>/dev/null` 吞异常**：查询报错被当成"安全组不存在" → 重复建了一个 `sg-mnl-app`（`sg-5tsaatp5w68vyeysqnol`，已撤销引用并删除）。
4. **`IFS=$'\t' read` 拆 TSV 不可用**：tab 属 IFS 空白字符，连续 tab（空字段）会被折叠 → 列错位；改为让 jq 直接 `join("|")` 拼出整条 key。

---

## 7. 2026-10-06 收口（任务 22 出口）——现网 = 24 条规则

> 完整报告：`deploy/docs/Day3任务22_安全组_执行报告.md`；证据：`deploy/logs/task22_20261006-134417/`

### 7.1 本次新增（3 条，补卡内"5432 与 6432"缺口）

| SG | 方向 | 端口 | 目标 | 用途 |
| --- | --- | --- | --- | --- |
| `sg-mnl-app` | out | 6432 | 10.0.64.0/20 | `to-rds-pg-pool` |
| `sg-mnl-app` | out | 6432 | 10.0.48.0/20 | `to-rds-pg-pool-az-a` |
| `sg-mnl-db` | in | 6432 | ← `sg-mnl-app`（组引用） | `from-app-pool-6432` |

### 7.2 复核登记（09-29 之后由任务 19 调试加入的规则，本次一并入账）

- `sg-mnl-app`：in `32656 ← sg-mnl-alb`（`alb-to-nodeport-32656-newapi`）；in `10250 ← 10.0.0.0/16`；out `1/65535 → 10.0.0.0/16`（`intra-vpc-tcp`）
- `sg-sg-app`：in `10250 ← 10.1.0.0/16`
- 集群级 SG（mnl `sg-5tsaatp5w68vyqszezja`）：`TCP 3000 ← sg-mnl-alb`、`TCP 1/65535 ← 10.0.0.0/16`、`TCP 6443 ← 10.0.0.0/16`、`ICMP ← 0.0.0.0/0`（后两条为保留项）

### 7.3 现网规则计数（业务 5 组 = 24 条）

| SG | 规则数 | 备注 |
| --- | --- | --- |
| `sg-mnl-alb` | 2 | in 80/443 ← 0.0.0.0/0（**ALB 实际未绑定本组**，`SecurityGroupIds=null`；预留） |
| `sg-mnl-app` | 11 | in 3（3000←alb / 32656←alb / 10250←VPC）+ out 8（5432×2 / 6432×2 / 6379×2 / 443 / 1-65535→VPC） |
| `sg-mnl-db` | 6 | in 5432←app、6432←app、5432←4×SG EIP（**未绑定 RDS 实例**，白名单为实际生效层） |
| `sg-sg-alb` | 2 | in 80/443 ← 0.0.0.0/0 |
| `sg-sg-app` | 3 | in 3000←alb、10250←VPC + out 443（`normal` 型出向默认放行） |

### 7.4 例外清单（反例自查保留项，2026-10-06 全账号扫描 = 7 命中，需裁定 0）

1. 集群级 ICMP：mnl `sg-5tsaatp5w68vyqszezja`、sg `sg-t4nevyfflaeo3tdvi510`（坑 7；**禁止删除**）
2. **云产品自管**：`ALB_SYSTEM_SECURITY_GROUP-alb-1riqckb1h8ezm0y7s9` ×5 条 `ALL -1/-1 ← 0.0.0.0/0`（`alb_system_policy`，ALB 服务维护）——审计脚本已固化该判定（`deploy/tasks/task22/sg_object_audit.sh`，云产品自管不再报"待裁定"；同时修掉 `$TOTAL` 全角空格导致的 `set -u` 崩溃）

### 7.5 回收与验证

- `deploy/ops/ops-access.sh --gc`：撤销 `sg-mnl-alb-edge` 2 条**过期临时 SSH**（`temp-ssh-exp=1790686620`，fanyan，09-29 到期）→ 现 0 条 ✅
- V1 ✅ 4 节点无公网 IP ｜ V3 ✅ 跳板机→RDS 5432/6432/6379 全 BLOCKED ｜ V4 ✅ 跨节点 22/网关 22/5432 blocked，10250 open（规则内）｜ V5 ✅ 业务组零命中
- V2 ✅（HTTP:80，随任务 19 ALB 切流销项；443 待 G5）
- 附注（非缺口）：同节点内 pod→节点 primary IP:22 可连（同实例 ENI 间不受 SG 约束）；跨实例一律不可达

### 7.6 仍未决（不阻塞出口）

1. 办公出口 CIDR → `sg-mnl-alb-edge` 长期 22/443；`sg-mnl-ack-api`（6443）复核为**暂不需要**（私网端点 + 集群级 6443←VPC 已就位）
2. GTM 探测源 IP 段 → 任务 21 后同步
3. DCDN 回源段 → 不适用（WAF 云原生接入，坑 1）
4. `sg-sg-app` out 5432/6432 → 判定无需（normal 出向默认放行）
5. RDS 绑定安全组维持现状（`EcsSecurityGroupRelation=[]`，白名单两层不变）
