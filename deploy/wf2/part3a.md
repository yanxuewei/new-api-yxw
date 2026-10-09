## Day 3 · 泳道 A：安全组、WAF、证书、密钥轮换与安全核查

> 本泳道基线（§2.1 实测修订版）：账号 `5108890064395960`（`export ALIYUN_PROFILE=ph-prod`）；业务域名 `www.likha.hk`、运维域名 `ops.likha.hk`、通配证书 `*.likha.hk`；主 region `ap-southeast-6`（仅 6a/6b）、备 region `ap-southeast-1`；马尼拉 VPC `vpc-5tst1tgeessxn1azwasg2`（10.0.0.0/16）、新加坡 VPC `vpc-t4nimmwvruexbnene0a3r`（10.1.0.0/16）；命名空间 `new-api`，服务端口 3000；kubectl 上下文 `mnl` / `sg`。
>
> **排期位移声明（贯穿全泳道）**：① 上游出口固定 EIP 共 **8 个（马尼拉 4 + 新加坡 4）**已在 Day 1 任务 6/12 建好并**当日提交**给各上游供应商（任务 56 为外部等待项，对方审批 1–3 天），本泳道卡 56 只做**生效登记确认**，不再包含提交动作；② RAM `ops-prod_group` 用户组、操作审计 ActionTrail 投递、OSS 审计桶（含 `backup-data-tiering` / `backup-audit-tiering` / `backup-cleanup` 三条规则、CRR→`oss-newapi-backup-sgp` 实测成功）均已在前序泳道落地，本泳道只做核查引用。
>
> **安全红线**：所有密钥、证书私钥、AK 一律以 `${PLACEHOLDER}` 指代，任何操作步骤与截图中不得出现可复用明文。

### Day 3 · 任务 22｜安全组与白名单逐条落地并核对（人员A，2 人时，09:00–11:00）

**前置/状态**：Day 1 泳道 A 已产出 VPC/vSwitch/NAT/EIP 与 ACK 集群；ALB `alb-newapi-mnl` 已建（任务 19）。本卡把 §8.1 规则表逐条落成真实安全组（马尼拉 3 个 + 新加坡 2 个），**每条规则必须带"用途"Description**（导出为 §12 证据）。注意 ACK 会自动建同集群 `sg-` 前缀安全组，动手前先确认要改的是哪一个。

**操作步骤（CLI-first）**：

1. 确认节点实际绑定的 SG（防"改了另一个安全组"）：

```bash
kubectl --context mnl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations}{"\n"}{end}' | grep -o 'sg-5[a-z0-9]*' | sort -u
```

期望输出（示例形态，ID 以实际为准）：

```
sg-5tfa1b2c3d4e5f6g7h8        # kubelet 托管 SG（容器服务 Kubernetes 版 ACK 内部，勿动）
sg-mnl-app-xxxx               # 本卡要固化的业务 SG
```

把三个业务 SG ID 固化为环境变量并写入 IaC：`SG_MNL_ALB` / `SG_MNL_APP` / `SG_MNL_DB`（新加坡 `SG_SG_ALB` / `SG_SG_APP`）。

> **✅ 已提前落地（2026-09-29，早于本卡排期 D5）**：5 个业务安全组 + **17 条可确定规则**已实建并复核，ID 见 **`deploy/sg_ledger.md`**，脚本 **`deploy/tasks/task22/sg_bootstrap.sh`**（幂等；`--verify` 随时核对现状，`--dry-run` 空跑）。
>
> | 变量 | 名称 | SG ID | Region |
> | --- | --- | --- | --- |
> | `SG_MNL_ALB` | `sg-mnl-alb` | `sg-5tsj1epvcjjv6jkg3zks` | ap-southeast-6 |
> | `SG_MNL_APP` | `sg-mnl-app` | `sg-5tsil3ca5dfkqefks1g9` | ap-southeast-6 |
> | `SG_MNL_DB` | `sg-mnl-db` | `sg-5tsawhljdqzwo2t0n4ut` | ap-southeast-6 |
> | `SG_SG_ALB` | `sg-sg-alb` | `sg-t4nbgfbh2cidnve88avf` | ap-southeast-1 |
> | `SG_SG_APP` | `sg-sg-app` | `sg-t4n0qnhy8mxq9g733r67` | ap-southeast-1 |
>
> **为什么提前建**：ACK 节点池**必须显式**指定 `scaling_group.security_group_ids`，否则 ACK 自建 `sg-` 前缀托管组（坑 2）；ID 先定死可杜绝"改了另一个安全组"的排查陷阱。本卡剩余实动作 = **步骤 1 的绑定确认 + V1–V4 出口复验 + 补 3 条延后规则**（`${DCDN_L2_IPS}` 因 DCDN 未开通【不适用】；GTM 探测段待任务 21；`sg-sg-app out 5432 → ${RDS_MNL_PUB}` 待任务 15 开 RDS 公网）。

2. 按下表逐条建规则（**入向用 `AuthorizeSecurityGroup`、出向用 `AuthorizeSecurityGroupEgress`**；组引用只在**同 VPC** 内可用）：

| SG | 方向 | 协议/端口 | 源/目的 | 用途 |
| --- | --- | --- | --- | --- |
| `sg-mnl-alb` | in | TCP 443 | `0.0.0.0/0` | 公网 HTTPS 入口（WAF 3.0 云原生接入为透明代理，ALB 仍是真实入口，见坑 1） |
| `sg-mnl-alb` | in | TCP 80 | `0.0.0.0/0` | 仅用于 301 跳转 |
| `sg-mnl-alb` | in | TCP 443 | `${DCDN_L2_IPS}` | **仅当启用全站加速 DCDN**；用 `DescribeDcdnL2Ips` 取，禁手工抄 |
| `sg-mnl-app` | in | TCP 3000 | `sg-mnl-alb`（组引用） | 只有负载均衡 ALB 能打业务端口 |
| `sg-mnl-app` | in | TCP 10250 | —— | kubelet 由 ACK 内部管理，**不要**对公网开 |
| `sg-mnl-app` | out | TCP 5432 | `sg-mnl-db` 或 RDS 网段 | 主库 |
| `sg-mnl-app` | out | TCP 6379 | Tair 内网 | 缓存 |
| `sg-mnl-app` | out | TCP 443 | `0.0.0.0/0` | 上游模型 API（IP 不可枚举，靠 NAT 网关 + 8 个固定 EIP 收敛） |
| `sg-mnl-db` | in | TCP 5432 | `sg-mnl-app` | 内网访问 RDS |
| `sg-sg-app` | out | TCP 5432 | `${RDS_MNL_PUB}` 公网 IP 段 | 备 region 读主库（目的地址精确放行） |

```bash
# 入向：只有入向用 AuthorizeSecurityGroup
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 3000/3000 \
  --Permissions.1.SourceGroupId ${SG_MNL_ALB} --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "from-alb-only"

# 出向：必须换 Egress API（AuthorizeSecurityGroup 只加**入向**规则，用它建出向会静默失败）
aliyun ecs AuthorizeSecurityGroupEgress --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \
  --Permissions.1.IpProtocol tcp --Permissions.1.PortRange 5432/5432 \
  --Permissions.1.DestCidrIp 10.0.64.0/20 --Permissions.1.NicType intranet \
  --Permissions.1.Policy accept --Permissions.1.Priority 1 --Permissions.1.Description "to-rds-pg-primary"
# 期望输出：{"RequestId": "..."}，无 Code 字段即成功
```

3. 反例自查：任何入向 `0.0.0.0/0` 且端口非 80/443 的规则都要删（`RevokeSecurityGroup` 同参数撤销）：

```bash
aliyun ecs DescribeSecurityGroupAttribute --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \
  | jq -r '.Permissions.Permission[] | select(.Direction=="ingress" and .SourceCidrIp=="0.0.0.0/0") | [.PortRange,.IpProtocol,.Description] | @tsv'
# 期望输出：空（新加坡 SG_SG_APP 同查同删）
```

**验证方法**：

```bash
# V1 业务端口对公网不可达（从本地/其他云机器）
nc -vz ${NODE_PUBLIC_IP} 3000                                   # 期望 refused/timeout
curl -sS --max-time 5 http://${NODE_PUBLIC_IP}:3000/api/status  # 期望失败
# V2 ALB → Pod 通
curl -sS https://www.likha.hk/api/status | jq -e '.success'    # 期望 true
# V3 RDS 内网只对 app 组开放（从非 app 网段的 ECS 执行）
timeout 5 psql "host=${RDS_MNL_PRI} dbname=newapi user=newapi sslmode=require" -c 'select 1'   # 期望 timeout
# V4 出向：Pod 能到上游，但不能横向扫内网
kubectl --context mnl -n new-api run scan --image=busybox --rm -i --restart=Never -- \
  sh -c 'nc -vz 10.0.32.1 22 || echo blocked'                   # 期望 blocked
```

**不通过时修复**：
- V1 端口可达 → 诊断 `DescribeSecurityGroupAttribute` 逐条比对，多半是误改了 ACK 自动建的同前缀 SG（坑 2）→ 用步骤 1 查到真实绑定 SG 后重删；把 SG ID 固化进 IaC。
- V2 全断 → 诊断 `sg-mnl-alb` 是否被按方案原文误收敛成"WAF 回源段"（坑 1）→ 恢复 `0.0.0.0/0:443`。
- V4 内网可扫 → 检查 `sg-mnl-app` 是否残留 `0.0.0.0/0` 出向之外的入向放行 → 删规则并复测。
- RDS 连不通（SG 正确前提下）→ 核对 RDS 白名单分组是否含 app 网段（安全组与 RDS 白名单是两层）。

**坑**：
- **坑 1｜把 ALB 入向收敛成 WAF 回源网段在云原生接入模式下是错的（P0-6）。** 现象：照旧方案配"仅放行 WAF 回源段"。后果：WAF 3.0 透明代理不引入新源网段，真实流量全被挡 → 上线即全站 5xx。改进：云原生接入时 ALB 安全组**保留 `0.0.0.0/0:443`**，防护由 WAF 策略层做；只有全站加速 DCDN 才需要 `DescribeDcdnL2Ips` 白名单（且列表会变，做成定时同步）。
- **坑 2｜安全组改了不生效。** 现象：改完仍如旧。后果：误判"阿里云延迟"，其实改的是 ACK 自动建的另一个 `sg-` 安全组。改进：先 `kubectl get node -o jsonpath` 查实际绑定 SG 再改；ID 固化进 IaC。
- **坑 3｜出向 `0.0.0.0/0:443` 被安全评审判不合格。** 后果：无法整改只能挂例外记录。改进：文档**主动写明理由**（上游模型厂商 IP 不可枚举）+ 缓解措施（NAT 网关 8 个固定 EIP + 操作审计 ActionTrail + 出向流量 SLS 审计）。
- **坑 4｜新加坡→马尼拉 RDS 按"目的 IP 段"放行，但 RDS 公网 IP 会变。** 后果：接管日跨区 SQL 全断。改进：跨 region 无 SG 引用可用，只能①脚本定期解析同步 + 变更告警，或②走云企业网内网；列入月度巡检。
- **坑 5｜出向规则用错 API 会「静默全失败」（2026-09-29 实跑踩到）。** 现象：用 `AuthorizeSecurityGroup` 加出向规则，返回 `RequestId` 齐全看着成功，但规则**一条都没落**。后果：上线后 Pod 连不上 RDS / Tair / 上游，排查方向全错（会先去查网络 ACL、路由、DSN）。改进：**入向 `AuthorizeSecurityGroup`、出向 `AuthorizeSecurityGroupEgress`**，两者不是同一个 API；参数统一 `--Permissions.1.*`（flat 的 `--SourceGroupId/--PortRange/...` 已标 `Deprecated`）；判成功**不能只看 `"Code"` 字段**——CLI 失败输出是 `ERROR: SDK.ServerError` + 文本行 `ErrorCode:`（非 JSON）。另注：`Permissions.N.*` 路径下重复规则**不会**返回 `InvalidPermission.Duplicate`，而是静默去重，想区分「新增 / 已存在」必须**前置比对**（脚本已用 `RULE_SET` 预读）。
- **坑 6｜安全组查询失败被当成「不存在」→ 重复建组（2026-09-29 实跑踩到）。** 现象：脚本里 `2>/dev/null` 吞掉查询异常，`ensure_sg` 判定"没找到"就新建，VPC 里出现**两个同名 SG**（实跑多建了一个 `sg-mnl-app`，已撤销引用并删除）。后果：规则加在 A 组、实例挂 B 组，现象是"规则明明配了却不生效"，极难定位。改进：查询失败**必须中断报错，绝不猜**；名称过滤用精确 JMESPath `SecurityGroups.SecurityGroup[?SecurityGroupName=='x'].SecurityGroupId | [0]`，并对查询加重试。

### Day 3 · 任务 47｜ALB 安全组源收敛 + SNI 域名校验（人员A，1 人时，11:00–12:00）

**前置/状态**：任务 22（SG 基线）与任务 20（WAF 3.0 云原生接入）结论已出。本卡**复验 §8.1 结论并书面定稿**：ALB 入向到底收不收敛、未匹配 Host 的请求进不进得了业务后端。

**操作步骤（CLI-first）**：

1. 分叉判定（二选一并书面记录，不得两不做）：
   - **走 WAF 3.0 云原生接入（推荐）**：ALB 入向**保持** `0.0.0.0/0:443`，把"为什么没按方案原文收敛"写进变更单，并补齐三条缓解：WAF 防护策略 + CC 阈值（任务 20）+ `alb-access` SLS 访问日志审计。
   - **走 DCDN 回源**：取回源段并同步进 `sg-mnl-alb`：

```bash
aliyun dcdn DescribeDcdnL2Ips --RegionId ap-southeast-1 | jq -r '.L2IpArray.Ip[]' > /tmp/dcdn-l2.txt
wc -l /tmp/dcdn-l2.txt    # 期望非空（10–30 条网段）
```

   同步脚本进 crontab/函数计算，**每日比对差异并告警**（网段会变，见坑 1）。
2. SNI/域名校验落位：确认 ALB 监听上未匹配 `www.likha.hk` / `ops.likha.hk` 的 host **不命中默认后端**。ALB Ingress/服务器组层面配置兜底规则（无匹配 → 固定 404 动作），确认已生效：

```bash
aliyun alb ListListeners --LoadBalancerIds.1 ${ALB_MNL_ID} \
  | jq -r '.Listeners[] | [.ListenerPort,.ListenerProtocol,.DefaultActions[0].Type] | @tsv'
```

期望输出：

```
443    HTTPS    ForwardGroup
80     HTTP     Redirect
```

443 HTTPS 监听的默认动作必须指向**受控服务器组或固定响应**，而非"直接透传 stable"；若 host 路由规则由 Ingress 维护，则复核兜底 Ingress 存在：

```bash
kubectl --context mnl -n new-api get ingress -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.rules[*].host}{"\n"}{end}'
# 期望：存在 catch-all 行（host 为 * 或空），其后端为固定 404 服务
```

3. DCDN 分支每日差异比对（定时任务核心逻辑，手工先跑一遍确认脚本正确）：

```bash
comm -13 <(aliyun ecs DescribeSecurityGroupAttribute --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_ALB} \
  | jq -r '.Permissions.Permission[] | select(.SourceCidrIp!="0.0.0.0/0") | .SourceCidrIp' | sort) \
  <(sort /tmp/dcdn-l2.txt)
# 期望：空输出；非空即"回源段已变但 SG 未同步"，触发告警并补差集
```

**验证方法**（反例口径保留，必须非 200）：

```bash
# V1 伪造 Host 不应命中 stable
curl -sSk -o /dev/null -w "%{http_code}\n" --resolve evil.com:443:${ALB_VIP} https://evil.com/api/status
# 期望 404/421，绝不能 200
# V2 合法 Host 正常
curl -sS -o /dev/null -w "%{http_code}\n" https://www.likha.hk/api/status    # 期望 200
# V3 ALB 入向复核（与任务 22 步骤 3 同一条 jq，双卡互证）
aliyun ecs DescribeSecurityGroupAttribute --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_ALB} \
  | jq -r '.Permissions.Permission[] | select(.Direction=="ingress") | [.PortRange,.SourceCidrIp] | @tsv'
# 期望：0.0.0.0/0 仅出现在 443/80 两行（云原生接入分支）
```

**不通过时修复**：
- V1 返回 200 → 诊断监听默认证书服务器组/Ingress 兜底规则缺失 → 增加 catch-all host 指向固定 404 后端；这是跨租户串数据级风险，未修复前不得进任务 38 核查第 7 项。
- DCDN 分支 V2 间歇 5xx → 诊断回源段与 SG 差异 `comm -23 <(sort /tmp/dcdn-l2.txt) <(sg规则)` → 补差集放行并修定时任务。
- 收敛误做（照旧方案删了 0.0.0.0/0:443）→ 立即 `AuthorizeSecurityGroup` 恢复，全站 5xx 每多一分钟都是真实资损。

**坑**：
- **坑 1｜DCDN 回源网段抄一次就完事。** 现象：某日 DCDN 扩容新节点段。后果：支付回调与静态资源全量 5xx。改进：每日同步任务 + 差异告警（与任务 48 渠道 IP 同步共用一条 cron 告警链路）。
- **坑 2｜只验 SNI 正确方向，不验伪造 Host。** 后果：任何人拿 ALB VIP 填 Host 头即可绕过域名体系直达业务。改进：本卡 V1 反例为硬性验收项，非 200 才算过。
- **坑 3｜书面结论缺失。** 现象：安全评审问"为何 ALB 对公网全开"。后果：现场说不出缓解链被开不符合项。改进：收敛决策（三分支：云原生不收敛 / DCDN 收敛 / 混合）+ 三条缓解写入 §12 证据并截图归档：`[图 D3-A-47｜拍摄对象：ALB 监听转发规则页（含 catch-all 404 规则）与 sg-mnl-alb 入向规则列表；打码：账号 UID、ALB 实例 ID 后四位可保留]`

### Day 3 · 任务 20｜WAF 3.0 接入 + CC 策略 + 回调源 IP 白名单（人员A，2 人时，13:30–15:30）

**前置/状态**：任务 22/47 的 ALB SG 结论已定（云原生接入 → 不收敛）。Web应用防火墙 WAF 3.0 实例（企业版，国际站）已购买；`waf-newapi-mnl` SLS Logstore 已由日志泳道建好。**关键认知**：本接入为**透明代理模式，不改 DNS、不产生回源网段（P0-6）**。

**操作步骤（CLI-first）**：

1. 实例与已接入资源核对（CLI 可查）：

```bash
aliyun waf-openapi DescribeInstance --RegionId ap-southeast-1
```

期望输出：

```
{"InstanceId": "waf_v2intl_public_cn-xxxxxxxx", "Edition": "enterprise_edition", ...}
```

（国际站实例统一在 `ap-southeast-1` 管理；已接入 ALB 后复查防护对象：）

```bash
aliyun waf-openapi DescribeDomains --RegionId ap-southeast-1 --InstanceId ${WAF_INSTANCE_ID} \
  | jq -r '.Domains[]? | .Domain'
# 期望：www.likha.hk 出现在防护域名列表（透明代理接入同样注册为防护对象）
```

2. 【控制台】接入管理 → 云原生接入 → ALB 页签 → 新增监听，选中 `alb-newapi-mnl` 的 443：
   `[图 D3-A-20｜拍摄对象：WAF 3.0 接入管理-云原生接入-ALB 页签（alb-newapi-mnl 已接入状态）；打码：账号 UID、证书 ID]`
3. CC 限速与业务限流**对齐应用侧**：应用默认 `GLOBAL_API_RATE_LIMIT=360 / 180s`（`common/init.go:123-125`），WAF CC 规则必须**宽于**应用限流（否则用户看到的是 WAF 403 而非应用 429，日志侧无法归因）。建议 WAF 单 IP：`1800 req/60s` 触发人机校验。【控制台】防护规则页，`[图 D3-A-20b｜拍摄对象：CC 防护规则详情（1800 req/60s + 人机校验动作）；打码：无敏感值，保留规则 ID]`
4. 支付回调路径例外规则（与任务 48 联动）：`/api/user/pay_notify/*`、`/api/epay/notify` 加**精确匹配 + POST only + 签名校验**三层豁免，跳过 CC 与部分托管规则；严禁豁免整个 `/api`。
5. 开启 WAF 日志投递日志服务 SLS（`waf-newapi-mnl`，保留 ≥30 天）。复验：

```bash
aliyun sls GetLogs --ProjectName sls-newapi-mnl --LogStoreName waf-log --From $(($(date +%s)-600)) --To $(date +%s) --Line 1
# 期望：至少 1 条含 matched_host 字段的日志（有测试流量即可）
```

**验证方法**：

```bash
# V1 WAF 已介入
curl -sSI https://www.likha.hk/api/status | grep -Ei "waf|server"
# V2 攻击特征被拦
curl -sS -o /dev/null -w "%{http_code}\n" "https://www.likha.hk/api/user/login?username=admin%27%20OR%20%271%27%3D%271"
# 期望 405/403（WAF 拦截），而不是 200/401
# V3 CC 触发阈值（测试机执行；验完必须从白名单移除测试 IP）
for i in $(seq 1 2000); do curl -s -o /dev/null -w "%{http_code} " https://www.likha.hk/api/status; done; echo
# 期望尾部出现连续 403/405
# V4 回调不被拦（真实签名回调或渠道沙箱）
curl -sS -o /dev/null -w "%{http_code}\n" -X POST "https://www.likha.hk${NOTIFY_PATH}" --data-binary @/tmp/signed-notify.txt   # 期望非 403
```

**不通过时修复**：
- V2 返回 200/401 → 诊断 `aliyun waf-openapi DescribeDefenseRules --InstanceId ${WAF_INSTANCE_ID} --Query {"resource":"www.likha.hk"}` 确认托管规则组是否启用 → 未启用则开启正常防护模式（观察模式=只记不拦，接入初期易忘切）。
- V3 无拦截 → CC 规则未绑定防护对象/域名，或阈值仍宽于 1800 → 核对规则生效域名与优先级；若 CC 先于应用 429 触发说明阈值设得过紧，回调放宽到应用限流的 3–5 倍。
- V4 被拦 → 例外规则路径写成 contains 而非精确匹配反向漏配，或方法未限定 POST 导致规则未命中 → 修正为精确路径匹配；同时检查源 IP 是否恰在渠道段外（转任务 48 处理）。
- SLS 无日志 → 日志投递开关未开或 RAM 授权 `AliyunServiceRoleForWaf` 缺失 → 控制台补授权。

**坑**：
- **坑 1｜WAF 拦截后客户端拿到的不是应用错误码。** 后果：SDK 无法区分"安全拦截"与"参数错误"，投诉定位困难。改进：配置 WAF 自定义响应为 JSON + 专用 code，写进客户端文档。
- **坑 2｜CC 按 IP 计数，用户在同一企业 NAT 出口后。** 后果：一家公司全员误伤。改进：CC 维度加 `UA + path`；企业客户提供带审批的 IP 白名单入口。
- **坑 3｜回调豁免写成 `Path contains "/api"`。** 后果：攻击者借豁免路径绕过防护。改进：精确路径 + POST only + 签名校验三层，缺一不可。
- **坑 4｜WAF 日志不投递 = 事后无证据。** 后果：M5 安全证据链缺失。改进：接入即开 SLS 投递，本卡已把 GetLogs 抽样列为硬性验收。

### Day 3 · 任务 40｜证书正式部署到 ALB / WAF / DCDN + SNI 校验（人员A，1.5 人时，15:30–17:00）

**前置/状态**：任务 22（通配符证书已在数字证书管理服务（原 SSL 证书）下单并签发；国际站无免费 DV（P0-7），为付费 DigiCert/GlobalSign 通配符 + 托管自动续期）；ALB/WAF 已就绪。证书私钥**只**存在于数字证书管理服务/KMS，本地无落盘（核查 #38-1 联动）。

**操作步骤（CLI-first）**：

1. 确认证书覆盖域名并取 CertId：

```bash
aliyun cas DescribeUserCertificateDetail --CertId ${CERT_ID} | jq -r '.CommonName, .Sans'
```

期望输出：

```
*.likha.hk
www.likha.hk,ops.likha.hk,*.likha.hk
```

2. 部署到负载均衡 ALB 监听：**在 AlbConfig 里声明式管理**（GitOps 仓库 `certificates:` 段引用 CertId），不要在控制台手工挂载；WAF / 全站加速 DCDN 侧在各自控制台或 OpenAPI 绑定**同一 CertId**。下发后确认监听实际证书：

```bash
kubectl --context mnl get albconfig alb-newapi-mnl -o jsonpath='{.spec.listeners[*].certificates}' ; echo
aliyun alb GetListenerAttribute --ListenerId ${ALB_HTTPS_LISTENER} | jq -r '.Certificates[].CertificateId'
```

期望输出（两处一致且等于 `${CERT_ID}`）：

```
${CERT_ID}    # AlbConfig 声明的 CertId
${CERT_ID}    # 监听实际生效的 CertId
```

3. DCDN（如启用）绑定：`aliyun dcdn SetDomainServerCertificate --DomainName media.likha.hk --CertId ${CERT_ID} --SSLProtocol on`（期望返回 RequestId 无 Code）。

**验证方法**：

```bash
# V1 SNI 正确（同 IP 多域名场景）
echo | openssl s_client -connect ${ALB_VIP}:443 -servername www.likha.hk 2>/dev/null | openssl x509 -noout -dates -subject
# 期望 subject 含 *.likha.hk；notAfter 在未来
echo | openssl s_client -connect ${ALB_VIP}:443 -servername nonexistent.likha.hk 2>&1 | grep -Ei "alert|error"
# 期望有握手拒绝输出（未下发默认证书外域名不被静默命中）
# V2 证书链完整（Android/老客户端友好）
curl -sSIv https://www.likha.hk/api/status 2>&1 | grep -E "SSL certificate|issuer"
nmap --script ssl-enum-ciphers -p 443 www.likha.hk | tail -20    # 期望 grade A，无 SHA1/弱套件
# V3 到期与自动续期
aliyun cas DescribeUserCertificateList --ShowSize 50 | jq -r '.CertificateList[] | [.Name,.Fingerprint,.AfterDate] | @tsv'
# 期望 AfterDate ≥ 今天 + 25 天；<30 天必须已有告警（通配符签发周期最长约 199/200 天）
```

**不通过时修复**：
- V1 返回旧证书 → 诊断 AlbConfig 未同步（只换了数字证书管理服务里的证书，坑 1）→ 触发 GitOps sync 或由同步 Job 调 `UpdateListenerAttribute`，**禁止**控制台手工替换。
- V1 伪造域名返回了业务证书 → ALB 监听仅一张默认证书且 SNI 未隔离 → 与任务 47 的 catch-all 404 规则合并整改（同一次变更单）。
- V2 链不完整（缺中间 CA）→ 重新上传含全链的 PEM（不含私钥！）→ 复测。
- V3 临近到期 → 确认托管自动续期任务与 DNS 验证 TXT 记录仍有效；告警必须打到值班通道（§10.8）。

**坑**：
- **坑 1｜只换数字证书管理服务里的证书，没同步 AlbConfig。** 后果：ALB 继续用旧证书，到期日全站 HTTPS 报错。改进：证书部署纳入 GitOps（CertManager + `cert-manager-alibabacloud-dns01-webhook`，或 KMS → 外部同步 Job 调 `UpdateListenerAttribute`）。
- **坑 2｜通配符不覆盖多级。** `*.likha.hk` **不覆盖** `a.b.likha.hk`。后果：将来 `cdn.www.likha.hk` 直接握手失败。改进：域名规划统一二级。
- **坑 3｜按国内站经验"等免费 DV 签发"。** 后果：国际站无免费 DV（P0-7），流程卡死。改进：付费通配符 + 托管续期，预算已入任务 52 成本表。
- **坑 4｜证书私钥落盘在本地。** 后果：审计不过、泄露风险。改进：私钥只在数字证书管理服务/密钥管理服务（凭据管家）；导出仅限轮换窗口并即时销毁，任务 38 第 1 项会 `gitleaks` 扫仓验证。

### Day 3 · 任务 48｜支付回调源 IP 白名单 + 签名校验验证（人员B，1.5 人时，09:00–10:30）

**前置/状态**：任务 20 的 WAF 精确路径豁免已配置。支付渠道（Epay/Stripe/PayPal/支付宝国际…）官方回调 IP 段已从其文档取得（多数会变），落成 ConfigMap + 定时同步任务。**三层防线**：WAF 豁免（任务 20）→ 应用侧源 IP 白名单 → 签名校验，缺一不可。

**操作步骤（CLI-first）**：

1. 应用侧白名单 ConfigMap（禁止 `0.0.0.0/0`）：

```yaml
data:
  NOTIFY_IP_ALLOWLIST: "${EPAY_NOTIFY_CIDRS},${STRIPE_WEBHOOK_IPS}"   # 从渠道文档同步，逗号分隔 CIDR
```

```bash
kubectl --context mnl -n new-api apply -f deploy/configmap-notify-allowlist.yaml
kubectl --context mnl -n new-api rollout restart deploy/new-api-stable
kubectl --context mnl -n new-api rollout status deploy/new-api-stable --timeout=180s
```

期望输出：

```
configmap/new-api-notify-allowlist configured
deployment.apps/new-api-stable restarted
deployment "new-api-stable" successfully rolled out
```

复核 Pod 内实际读到的白名单（防 ConfigMap 挂了没 mount）：

```bash
kubectl --context mnl -n new-api exec deploy/new-api-stable -- printenv NOTIFY_IP_ALLOWLIST
# 期望：非空、仅含渠道 CIDR，绝不含 0.0.0.0/0
```

2. 取真实客户端 IP 的正确姿势（OWASP 口径）：ALB/WAF 链路上**不信 `X-Forwarded-For` 第一跳**——按可信跳数从右往左取第 N 个（N=可信代理数），或由 ALB 注入 `X-Real-IP`、应用只信它。确认应用配置项与该取值模式一致。
3. 渠道 IP 段同步任务接入 crontab/函数计算，变更即告警（与任务 47 共用告警链路）。
4. 幂等复核：`out_trade_no` 唯一约束 + `INSERT ... ON CONFLICT DO NOTHING`（多副本下内存 map 幂等不成立）。

**验证方法**（V1–V5 全过才算完）：

```bash
# V1 合法源 + 合法签名 → 200 且入账
psql "${DSN_APP_READONLY}" -c "select status from orders where out_trade_no='TEST-48-1'"   # 期望已更新为已支付
# V2 合法源 + 错签名 → 4xx 且不入账
psql "${DSN_APP_READONLY}" -c "select id,status from orders where out_trade_no='TEST'"      # 期望 status 未变
# V3 非法源 + 合法签名 → 拒绝（IP 层挡，期望 403）
# V4 无签名 → 拒绝
# V5 WAF 不拦回调（真实渠道沙箱跑一次全链路，期望 200）
```

**不通过时修复**：
- V1 403 → 诊断出口源 IP 是否命中 WAF 拦截（转任务 20 V4）还是应用白名单未含该段（`kubectl exec` 打印实际解析到的 clientIP）→ 修同步任务。
- V3 竟放行 → **资金级漏洞**：应用取了 XFF 第一跳（坑 1）→ 立即改为可信跳数/X-Real-IP 并回归 V1–V4。
- 重放同一回调入账两次 → 唯一约束缺失或幂等在内存 → 补 DB 约束迁移后重测。
- 渠道 IP 变更导致某天全量失败（表现"用户扣款成功但未到账"）→ 查同步任务日志与"回调 4xx 比例"告警是否触发；临时人工加段 + 事后修同步。

**坑**：
- **坑 1｜只看 `X-Forwarded-For` 第一跳取客户端 IP。** 后果：伪造头即绕过 IP 白名单 → 伪造回调完成支付，资金级漏洞。改进：可信跳数从右取第 N 个，或 ALB 注入 `X-Real-IP` 且应用只信它。
- **坑 2｜回调白名单忘了随渠道 IP 变更同步。** 后果：支付某日开始全量失败。改进：定时同步 + 变更告警 + §10.8 增加"回调 4xx 比例"告警。
- **坑 3｜幂等只做在应用层（内存 map）。** 后果：多副本下重复入账。改进：DB 唯一约束 + `ON CONFLICT DO NOTHING`。
- **坑 4｜回调处理里同步调用上游模型补发额度。** 后果：上游慢 → 渠道超时重投 → 重复入账放大。改进：回调只做"记账 + 入队"，发放异步。

### Day 3 · 任务 55｜SESSION_SECRET 双密钥轮换方案与演练（人员B，2 人时，10:30–12:30）

**前置/状态**：目标：**轮换期间不踢任何人下线，且不出现"两个密钥都不认"的窗口**。背景认知：`SESSION_SECRET` 同时派生 Access Token、Refresh Token 摘要与 Security Proof——它一失效三者全失效，等价于全站登出，因此必须双密钥过渡。密钥存于密钥管理服务（凭据管家）`new-api/prod/SESSION_SECRET`；**多区域（马尼拉/新加坡）值必须一致**，否则接管即全员掉线。当前仓库只读单个 `SESSION_SECRET`（`common/init.go:50-55`，为空/`random_string` 会 `log.Fatal`），G8 真双密钥代码落地前，先按本卡"重叠窗口"运维方案演练。

**操作步骤（CLI-first）**：

1. KMS 建版本位：`SESSION_SECRET`（当前值 A）与 `SESSION_SECRET_OLD`（轮换窗口内的旧值位）。写入新值前做长度/字符集校验（≥32 随机字节）：

```bash
NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')   # 仅演示；实际由密管系统生成并直接写入，终端不回显
aliyun kms PutSecretValue --SecretName new-api/prod/SESSION_SECRET --SecretData '${NEW_SECRET}' --VersionId $(uuidgen)
aliyun kms ListSecretVersionIds --SecretName new-api/prod/SESSION_SECRET | jq -r '.SecretVersions.SecretVersionInfo[] | [.VersionId,.CreatedDate] | @tsv'
```

期望输出：

```
f3a1...-uuid-B    2026-09-27T06:12:44Z   # 新版本（B）
9c27...-uuid-A    2026-09-20T02:03:11Z   # 旧版本（A），窗口期内保留在 SESSION_SECRET_OLD 位
```

2. 重叠窗口滚动（时间线 T0–T6，**只有 T6 不可逆**）：

```
T0   SESSION_SECRET = A                        （全部 Pod 认 A；KMS 改值不重启无影响，env 只在启动时读）
T1   KMS 值改为 B（先不重启）
T1+  分批滚动 stable：先 1 个 Pod → 观察 → 全量
     ⚠ 滚动期间 A/B Pod 混跑，同一用户可能命中不同 Pod → "偶发 401"是预期现象，不是故障；
       必须在变更窗口内执行并挂公告，否则会被立案为登录 Bug
T2   加 ALB 会话保持（源 IP 哈希 60s）+ 调 canary 权重，缩小混跑窗口
T3   全量 B 且稳定 30 分钟 → A 彻底失效（旧 token 需重登）
T4   备 region（新加坡）同样滚一遍——主备密钥必须一致，三步（主滚完+备滚完+复验）同挂一个变更单
T5   复验下方 V1–V4 含接管链路
T6   T+24h 自动清空 SESSION_SECRET_OLD，密钥面回到 1（唯一不可逆点；此前任意时刻可回滚）
```

3. 回滚方向唯一：把 KMS 改回 A + 全量 `rollout restart`，**不要改前端**。
4. 真双密钥为推荐落地形态（写入 G8 需求）：`secrets := []string{os.Getenv("SESSION_SECRET"), os.Getenv("SESSION_SECRET_OLD")}`，签发只用 `[0]`，验签按顺序尝试非空项。

**验证方法**：

```bash
# V1 重叠窗口：旧 token 在滚动后仍可用
curl -sS -H "Authorization: Bearer ${OLD_TOKEN}" https://www.likha.hk/api/user/self | jq -e '.success'   # 期望 true
# V2 新签发 token 立即可用，且 A/B 两拨 Pod 都认
# V3 轮转后 KMS 旧版本不可读（防误恢复）
aliyun kms GetSecretValue --SecretName new-api/prod/SESSION_SECRET --VersionId ${OLD_VERSION_ID}   # 期望报错或按策略拒绝
# V4 审计：轮换动作在操作审计 ActionTrail 有记录（事件名 PutSecretValue），且变更单号可关联
aliyun actiontrail LookupEvents --StartTime $(date -u -v-1d +%FT%TZ) --EventName PutSecretValue --MaxResults 10 | jq '.Events | length'
```

**不通过时修复**：
- V1 失败（旧 token 401）→ 诊断：代码不支持双密钥且 Pod 未全部滚完，或该 Pod 读到空值崩溃重启（`log.Fatal`）。修复：立即 KMS 改回 A + 全量 `rollout restart`（回滚方向唯一）；再排查 `common/init.go` 读取路径。
- V2 部分 Pod 认新不认旧且已滚完 → 备 region 未同步（坑 1）→ 补滚 + 复验接管链路。
- V4 无审计事件 → ActionTrail 投递被误删（前序泳道已落地，查 `DescribeTrails`）→ 恢复投递后再演练一轮。
- 滚动期间 401 持续超窗 → 会话保持未生效 → 核对 ALB 监听一致性哈希配置。

**坑**：
- **坑 1｜主备两 region 不同时轮换。** 后果：接管瞬间全员掉线（比常规混跑更隐蔽，平时看不出来）。改进：轮换 SOP = 主站滚完 + 备站滚完 + 复验接管链路，三步一个变更单；接管演练必须覆盖"刚轮换完"状态。
- **坑 2｜把 `_OLD` 长期留着。** 后果：密钥面翻倍、泄露概率上升。改进：SOP 第 4 步清空 `_OLD`，T+24h 自动执行。
- **坑 3｜轮换时写成空值或 `random_string`。** 后果：`log.Fatal` 全站起不来（`common/init.go:50-55`）。改进：KMS 写入前长度/字符集校验（≥32 随机字节），CI 加 lint。
- **坑 4｜顺带把 `SYNC_FREQUENCY` 一起改。** 后果：一次变更两件事，出问题难归因。改进：一个变更单只做一件事。

### Day 3 · 任务 56｜上游供应商 IP 白名单提交与生效确认（人员B，1 人时，13:30–14:30）

**前置/状态**：**排期位移（重要）**：本任务是**外部等待项**，提交动作已在 **Day 1** 任务 6/12 泳道产物（8 个固定 EIP：马尼拉 4 + 新加坡 4）建好当日即向各渠道提交（对方审批 1–3 天），本卡**只做生效登记与确认**，不含提交。不做完，Day 4 起所有渠道调用被上游 403，而应用侧看到的往往只是"随机超时/连接失败"。

**操作步骤（CLI-first）**：

1. 汇总 8 个 EIP，登记进白名单跟踪表：

```bash
for r in ap-southeast-6 ap-southeast-1; do
  aliyun vpc DescribeEipAddresses --RegionId "$r" --PageSize 50 \
    | jq -r --arg r "$r" \
      '.EipAddresses.EipAddress[]
       | select(.Name | test("^eip-(mnl|sg)-upstream"))
       | [$r, .IpAddress, .Name, .Status, .Bandwidth] | @tsv'
done
```

期望输出（恰好 8 行，每地域 4 行，`Status=InUse`，`Bandwidth` 与任务 52 规格一致，节选形态）：

```
ap-southeast-6   <EIP_MNL_1>   eip-mnl-upstream-1   InUse   100
ap-southeast-6   <EIP_MNL_2>   eip-mnl-upstream-2   InUse   100
...（马尼拉共 4 行）
ap-southeast-1   <EIP_SG_1>    eip-sg-upstream-1    InUse   100
...（新加坡共 4 行）
```

任一行 `Status!=InUse` 或行数不足 8，先修 SNAT 绑定再谈白名单：

```bash
aliyun vpc DescribeSnatTableEntries --RegionId ap-southeast-6 --SnatTableId ${SNAT_TABLE_MNL} \
  | jq -r '.SnatTableEntries.SnatTableEntry[] | [.SourceVSwitchId,.SNatIp] | @tsv'
# 期望：app 交换机 10.0.16.0/20、10.0.32.0/20 均在条目中，SNatIp 覆盖全部 4 个马尼拉 EIP
```

2. 对照 Day 1 提交的逐渠道台账（OpenAI/Anthropic/Google/Azure/自建网关…），每家登记：提交时间、工单号、**生效确认时间**、联系人；对不支持 IP 白名单的渠道（多数头部模型厂商**不做**入向白名单）书面确认"不适用"；真正需要白名单的是企业专属渠道、Azure OpenAI（`ipRules`）与自建/私有化上游。Azure OpenAI 类自助渠道用其 API 加规则后立即验。

**验证方法**：

```bash
# 从两个地域的 Pod 网段分别打上游探活（不消耗 token 的轻接口）
for ctx in mnl sg; do
  kubectl --context $ctx -n new-api run wl-probe-$ctx --image=curlimages/curl --rm -i --restart=Never -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code} %{time_total}\n" https://api.openai.com/v1/models'
done
```

期望输出（每行一个地域）：

```
401 0.31
401 0.29
```

非 `000` 即为通路；`401/403`（无 key）也属正常，说明**未被上游 IP 拦截**。出口 IP 分布复核（连续 40 次，4 个 EIP 应大致均匀出现且全部在白名单内）：

```bash
kubectl --context mnl -n new-api run eip-dist --image=curlimages/curl --rm -i --restart=Never -- \
  sh -c 'i=0; while [ $i -lt 40 ]; do curl -s https://ifconfig.me; echo; i=$((i+1)); done' | sort | uniq -c
```

**不通过时修复**：
- 探活 000/超时 → 诊断 EIP 是否 `InUse`、SNAT 条目是否覆盖 app 网段（`aliyun vpc DescribeSnatTableEntries`）→ 修 SNAT；与白名单无关先排自己。
- 稳定 403 且已收到对方"已生效"工单回复 → 对方只加了部分 IP → 按坑 2 核对 4 个是否全加；未确认的渠道**先不进流量**（G0 出口条件）。
- 生效但间歇失败 → 多次 curl 统计命中的出口 IP 分布（`for i in $(seq 1 40); do curl -s https://ifconfig.me; echo; done`），确认 8 个 EIP 均匀出现且都在白名单内。

**坑**：
- **坑 1｜以为"EIP 提交了就生效"。** 后果：对方审批 1–3 天，Day 4 起全渠道失败被当成我方故障。改进：本卡排期位移到 Day 1 提交、Day 3 只确认；"8 个 EIP 逐一确认生效"是 G0 出口条件之一。
- **坑 2｜把 NAT 网关 SNAT 池当成固定出口。** 后果：4 个 EIP 轮询、白名单只加 1 个 → **25% 概率成功**的间歇故障，本项目最难定位。改进：一律 4 个全加，并用出口 IP 分布统计验证。
- **坑 3｜上游按"来源 IP 信誉"限流且两个地域共享配额。** 后果：接管后新加坡流量叠加，QPS 超限被整体降速。改进：上游配额盘点按 **8 个 EIP 合计峰值 QPS** 与上游确认（并入任务 52）。

### Day 3 · 任务 52｜带宽与规格量化 + 成本量化表（人员B，2 人时，14:30–16:30）

**前置/状态**：任务 56 已确认 8 个固定 EIP；Day 1 配额已批（ECS vCPU 马尼拉 64 / 新加坡 96，状态 `Agree`）。本卡把流式网关的带宽硬瓶颈算成数、把全部资源填成美元月成本表（国际站计价，**必须填实际购买页价格**），供 Day 4 报价与告警阈值使用。

**操作步骤（CLI-first）**：

1. 带宽估算（以 1,000 并发 SSE 为口径）：

| 项 | 估算式 | 取值 |
| --- | --- | --- |
| 单路下行稳态 | 30 tokens/s × ~4 B/token ≈ 120 B/s + SSE 头开销 | 0.5 KB/s |
| 1,000 并发 | 0.5 KB/s × 1000 ≈ 4 Mbps（含上行、图片/base64、突发保守放大） | **40 Mbps** |
| NAT 网关 | ≥ 200 Mbps | 需工单确认默认上限 |
| 单 EIP 峰值 | ≥ 100 Mbps | 用 CDT（云数据传输）/共享带宽包统一计费 |
| 负载均衡 ALB | 峰值连接 + 新建连接 + 处理数据量三取最大 | 1,000 并发 + 500 CPS ≈ 3–4 LCU，留 10× 余量 |

2. 带宽类配额核验（**必须带 regionId 维度**，否则返回 cn-hangzhou 假数据）：

```bash
aliyun quotas ListProductQuotas --ProductCode nat --Dimensions.1.Key regionId --Dimensions.1.Value ap-southeast-6 \
  | jq -r '.Quotas[] | [.QuotaActionCode,.QuotaValue] | @tsv'
```

期望输出（节选）：

```
qnat_bandwidth    200
qnat_eip_count    20
```

配额 ≥ 上表需求即可；不足走 `--DesireValue` 申请并确认状态 **`Agree`**。成本行抽样核价（以实际账单反查单价，防"估算占位过夜"）：

```bash
aliyun bssopenapi QueryInstanceBill --BillingCycle $(date +%Y-%m) --PageSize 50 \
  | jq -r '.Data.Items.Item[] | select(.ProductCode=="nat" or .ProductCode=="alb") | [.ProductCode,.InstanceID,.PretaxAmount] | @tsv'
```

3. 成本量化表（月度 USD；单价一律取购买页/QueryBill 实价，不许估算占位过夜）：ECS 马尼拉 `g9i.2xlarge`×4–8（已批 64 vCPU）、ECS 新加坡 ×2–12（已批 96 vCPU，**接管时 6× 弹性极高**）、RDS PostgreSQL 16C64G 高可用×1、Tair 4GB 主备×2、ClickHouse（§4.5 选定方案）、**跨区公网 SG→MNL RDS 出方向 GB（常被忽略：接管后所有 SQL 走公网）**、NAT 网关+共享带宽×2、ALB LCU×2、WAF 企业版+请求数×2、全站加速 DCDN 流量 GB、SLS 写入+存储、OSS（标准+低频+归档+跨区域复制）、GTM 旗舰版/云解析 DNS 付费版、Grafana（新加坡）、通配符证书 ×2/年。每行标注弹性敏感度（高/中/低）。
4. 成本看板（任务 39）：标签 `project=new-api site=ph-mnl|sg env=prod cost-center=<按财务>` 全量打，预算告警 80%，月度复核。

**验证方法**：

```bash
aliyun bssopenapi QueryBill --BillingCycle $(date +%Y-%m) \
  | jq -r '.Data.Items.Item[] | [.ProductCode,.PretaxAmount] | @tsv' | head
# 期望：能按标签聚合出与上表一致的产品行；压测后 NAT 流量曲线与估算偏差 <50%
aliyun quotas ListApprovalRequests | jq -r '.QuotaApplications.QuotaApplication[] | [.QuotaActionCode,.Status] | @tsv'
# 期望：本泳道申请的审批状态均为 Agree
```

**不通过时修复**：
- QueryBill 聚合缺产品行 → 资源未打 `site/env` 标签 → 批量补标（`aliyun tag TagResources`）后下月复核；预算看板以标签为准。
- NAT 曲线偏差 ≥50% → 检查是否漏算图片/base64 突发或健康探测风暴 → 修正估算式并重谈带宽包规格。
- 配额查询值与预期不符 → 十有八九是忘带 `--Dimensions.1.Key regionId` 拿到了杭州数据（全局坑，见基线声明）→ 重查。

**坑**：
- **坑 1｜低估跨区流量。** 后果：接管后**全部** SQL 走马尼拉 RDS 公网，读写双向 GB 级，账单失控。改进：压测时实测 `pg_stat_activity` + NAT 出流量，算出接管后单位时间费用写进 SLA 成本附注。
- **坑 2｜按量 + 无预算告警。** 后果：一次 CC 攻击把 DCDN/WAF 请求数打到天价。改进：预算 80% 告警 + WAF 频控 + 账单"异常突增"日巡检（移交运维项 §11.6）。
- **坑 3｜国际站没有国内站的共享流量包 DTP。** 后果：照旧方案找 DTP 抵扣入口找不到。改进：等价物是 CDT（云数据传输），先查地域支持再承诺抵扣（Day 1 任务 6 已核实）。

### Day 3 · 任务 38｜上线前安全核查（OWASP / 白名单 / 密钥 / 审计）15 项（人员A+B，各 2 人时，17:00–19:00）

**前置/状态**：本泳道其余 8 卡完成；前序已落地项直接引用复核：RAM `ops-prod_group` 用户组、操作审计 ActionTrail 投递 OSS 审计桶、备份桶规则 `backup-data-tiering` / `backup-audit-tiering` / `backup-cleanup`、CRR→`oss-newapi-backup-sgp`（实测成功）。**注意：桶为同城冗余 ZRS，原"30d→IA / 90d→Archive"分层规则被 ZRS 限制否决——第 11 项核查口径已按此改写。** 任一项不通过 → 不签 M3 完成。分工：人员A 负责 #1–#8、#13–#15，人员B 负责 #9–#12；所有证据统一归档 §12 对应目录。

**操作步骤（CLI-first）**：15 项核查清单如下，每项都要留证据，不通过不得签 M3。敏感项（#1/#8/#9/#11）由 A、B 双人独立执行、结果互检（four-eyes）：

| # | 项 | 方法（CLI 为主） | 通过标准 | 结果 |
| --- | --- | --- | --- | --- |
| 1 | 无硬编码密钥 | `gitleaks detect --log-opts="--all"`（或 `git log -p --all \| grep -Eic "LTAI[0-9A-Za-z]{16}\|BEGIN .*PRIVATE KEY"`）+ 镜像扫描 | 0 命中；历史命中已做**密钥轮换 + BFG 清洗** | [ ] |
| 2 | 依赖漏洞 | ACR 企业版镜像扫描 + `govulncheck ./...` + `npm audit --omit=dev` | Critical=0；High 有豁免单 | [ ] |
| 3 | Secret 权限边界 | `kubectl --context mnl auth can-i --as-group newapi-viewer get secrets -n new-api` | 拒绝（`no`） | [ ] |
| 4 | 容器逃逸面 | `kubectl -n new-api get deploy -o json \| jq` 查 securityContext | `runAsNonRoot`、`readOnlyRootFilesystem`、`drop:[ALL]`、禁 `privileged` 全满足（写 `/app/logs` 用 emptyDir） | [ ] |
| 5 | 传输加密 | `nmap --script ssl-enum-ciphers -p 443 www.likha.hk` + 响应头抽查 | 全站 HTTPS + HSTS（`max-age=31536000; includeSubDomains`）+ TLS1.2+，grade A | [ ] |
| 6 | SQL 注入面 | `grep -rn "\.Raw(\|\.Exec(" --include='*.go'` 查拼接 | 全参数化、无拼接；ClickHouse 同样参数化 | [ ] |
| 7 | 越权 | 水平（`/api/user/:id` 类）/垂直（普通号访问 admin）用例各 ≥10 条 | 全部 403/404 | [ ] |
| 8 | 认证与令牌 | 复核 §6.2 与任务 55：bcrypt/argon2 成本、`access_token` 熵、登录限速、会话固定 | SESSION_SECRET 双密钥演练 V1–V4 全过；`0.0.0.0/0` 入向仅 80/443（任务 22 jq 为空）；伪造 Host 非 200（任务 47 V1） | [ ] |
| 9 | 回调伪造 | 任务 48 V1–V4 | 4/4 通过 | [ ] |
| 10 | 审计链路 | `aliyun actiontrail DescribeTrails` 确认投递 OSS 审计桶已落地（前序泳道完成）；`aliyun oss api get-bucket-logging --bucket oss-prod-newapi-audit` 复核 | 事件可查 ≥180 天（P1-17），抽样能查到 90 天前事件 | [ ] |
| 11 | 备份加密与访问 | `aliyun oss stat oss://oss-prod-newapi-backup-mnl \| grep -i acl` + RDS TDE 开关 + `ossutil api get-bucket-lifecycle --bucket oss-prod-newapi-backup-mnl` | bucket 禁公共读；已落地三条规则 `backup-data-tiering` / `backup-audit-tiering` / `backup-cleanup`；**旧"30d→IA/90d→Archive"口径作废——ZRS 冗余不支持该分层转换，不得以此判不通过** | [ ] |
| 12 | 日志脱敏 | `aliyun sls GetLogs` 抽查 app/waf/rds-audit Logstore | 不出现完整 token/API Key/密码（`redact` 生效） | [ ] |
| 13 | CORS | `curl -sSI -H "Origin: https://evil.example" https://www.likha.hk/api/status \| grep -i access-control` | `Access-Control-Allow-Origin` 白名单，禁 `*` + credentials | [ ] |
| 14 | 镜像签名/来源 | 部署 manifest 抽查 | ACR 企业版 + 仅 VPC 内网域名拉取 + 禁 `latest`，全 SHA 摘要 | [ ] |
| 15 | 供应链 | 查 CI 配置 | `go.sum`/`bun.lock` 入仓且不跳过校验，构建脚本来源固定 | [ ] |

**验证方法**：15 项全 `[x]` 且证据（命令输出/截图）入 §12 归档；豁免项必须写明风险接受人 + 到期复审日。第 10/11 项为**引用复核**（前序泳道已落地），只需重新执行验证命令确认现状，不重复建设。

关键项的取证命令示例（其余项按表内方法执行）：

```bash
# #3 Secret 权限边界
kubectl --context mnl auth can-i --as-group newapi-viewer get secrets -n new-api    # 期望：no
# #4 容器逃逸面
kubectl --context mnl -n new-api get deploy new-api-stable -o json \
  | jq -r '.spec.template.spec | .securityContext, [.spec.containers[].securityContext] ' \
  | grep -Ei 'runAsNonRoot|readOnlyRootFilesystem|"ALL"'
# 期望：runAsNonRoot=true、readOnlyRootFilesystem=true、capabilities.drop 含 ALL，全文无 privileged: true
# #5 传输加密（HSTS 响应头）
curl -sSI https://www.likha.hk/api/status | grep -i strict-transport-security
# 期望：max-age=31536000; includeSubDomains
# #11 备份桶三条规则与 ACL
aliyun oss stat oss://oss-prod-newapi-backup-mnl | grep -i acl                      # 期望 ACL: private
ossutil api get-bucket-lifecycle --bucket oss-prod-newapi-backup-mnl \
  | grep -o 'backup-data-tiering\|backup-cleanup'                                   # 期望：规则 ID 命中
```

【控制台】留证截图：`[图 D3-A-38｜拍摄对象：操作审计 ActionTrail 事件查询页（PutSecretValue 事件）+ OSS 审计桶生命周期规则列表页；打码：账号 UID、请求 IP]`

**不通过时修复**（任一项不过 → **不签 M3 完成**，按表内"通过标准"回改）：
- #1 命中 → 立即轮换涉事 AK/私钥（**轮换才是修复，删历史不是**）→ BFG 清洗 → 复扫。
- #8 发现非 80/443 的公网入向 → 回任务 22 撤销 → 全表重跑。
- #10 查不到 90 天前事件 → ActionTrail 投递目标桶或生命周期 `backup-cleanup` 配置过激误删 → 核对两条规则 TTL 边界后重投。
- #11 若有人以"未做 IA/Archive 分层"判不通过 → 按新口径驳回（ZRS 限制），改查加密与 ACL 本身。
- #13 CORS 回了 `*` 且带 credentials → 回应用配置改白名单回显（仅回显已登记的 Origin），并复测任务 20 V1 确认 WAF 未改写该头。
- 任何一项修复后 → 仅复验该项 + 其关联卡（D 日只复验增量，不重跑全表）。

**坑**：
- **坑 1｜安全核查排在压测之后。** 后果：改配置引发回归，工期塌。改进：本卡固定在 Day 3 完成，Day 4 只复验增量。
- **坑 2｜只看控制台开关，不看实际行为。** 例：声明"禁公共读"但某对象被单独设为公共读。改进：逐 bucket `stat` + 抽样对象 HEAD。
- **坑 3｜`runAsNonRoot` 与 new-api 镜像默认用户冲突。** 后果：Pod 起不来或 `/data` 权限拒绝。改进：Dockerfile `chown` 数据目录 + `USER 10001`，先灰度一副本验证。
- **坑 4｜密钥扫描只扫 HEAD。** 后果：历史 commit 里的 AK 仍可被 clone 走。改进：扫 `--all`，命中即轮换。
- **坑 5｜证据只存截图、不存命令输出。** 后果：无法复现核查时的真实状态，M5 评审要求重跑全表。改进：每项证据 = 命令 + 原始输出 + 时间戳，截图仅作补充。

### Day 3 · 泳道 A 出口检查清单

```
[ ] 任务 22：马尼拉 3 + 新加坡 2 安全组逐条落地且带用途注释；入向 0.0.0.0/0 非 80/443 jq 为空；V1–V4（公网不可达 3000 / ALB→Pod 通 / RDS 仅 app 组 / Pod 禁内网横扫）全过
[ ] 任务 47：收敛决策书面定稿（云原生=保持 0.0.0.0/0:443 + 三条缓解；DCDN=每日 L2 段同步）；伪造 Host 返回 404/421 绝非 200
[ ] 任务 20：WAF 3.0 云原生接入 ALB 完成（不改 DNS、无回源段）；CC 1800 req/60s 宽于应用 360/180s；回调精确路径+POST 豁免；SLS waf-log 投递有日志；攻击特征 405/403
[ ] 任务 40：同一 CertId 部署 ALB(AlbConfig 声明式)/WAF/DCDN；SNI 正反例、证书链 grade A、AfterDate ≥ 今天+25 天且续期告警在位
[ ] 任务 48：NOTIFY_IP_ALLOWLIST 无 0.0.0.0/0；可信跳数取 IP；V1–V5 全过；out_trade_no DB 级幂等
[ ] 任务 55：双密钥演练完成（重叠窗口 T0–T6 全程可回滚，T6 唯一不可逆点）；主备一致；KMS 旧版本不可读；ActionTrail 可关联变更单；G8 真双密钥需求已立项
[ ] 任务 56：8 个固定 EIP（马尼拉 4 + 新加坡 4，Day 1 已提交）逐渠道生效登记完成；不支持白名单渠道有书面"不适用"结论；两地域探活非 000
[ ] 任务 52：带宽表（1000 并发 SSE → 40 Mbps / NAT ≥200 Mbps / EIP ≥100 Mbps）与月度 USD 成本表填实价；配额带 regionId 维度复核为 Agree；预算 80% 告警在位
[ ] 任务 38：15 项核查全 [x]（第 10/11 项按已落地口径引用复核；IA/Archive 旧口径已废止）；证据入 §12；豁免单有风险接受人+复审日
[ ] 未通过项 → 不签 M3；仅复验增量，不重跑全表
```
