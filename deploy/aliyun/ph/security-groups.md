# G6 配置模板 · 安全组逐条表（对应指南 §3.8 / §8.1 任务 22，出口核对见 §8.6）

> 状态：**模板定稿，D5 执行（先关门再放应用：#22 → #23 → #20 → #21 → #46）**。
> 每条规则必须有 `--Description`（用途），导出进 §12 验收证据。
> 原则：**用组引用（SourceGroupId）而不是 IP 段**，可维护性最高；SG ID 固化进 IaC。
> ⚠ 坑 2：ACK 会自动建 `sg-` 前缀的同集群安全组，改规则前先 `kubectl get node -o jsonpath='{..annotations}'` 确认实际绑定的 SG。

## 1. 马尼拉（3 个 SG）

### `sg-mnl-alb`（ALB / 公网入口层）

| 方向 | 协议/端口 | 源/目的 | 用途 | 备注 |
| --- | --- | --- | --- | --- |
| in | TCP 443 | `0.0.0.0/0` | 公网 HTTPS 入口 | **WAF 云原生接入是透明代理、不产生回源网段，此条保留全网开放是有意设计**（P0-6/坑 1），防护由 WAF 策略层做 |
| in | TCP 80 | `0.0.0.0/0` | 仅用于 301 跳转 | |
| in | TCP 443 | `${DCDN_L2_IPS}` | **条件规则：仅当启用 DCDN** | 用 `aliyun dcdn DescribeDcdnL2Ips` 取，禁手工抄；网段会变，做每日定时比对告警；未启用 DCDN 则本条为"不适用" |
| in | — | GTM 探测源 IP 段 | GTM 健康探测 | 同时加 WAF 白名单，防误判抖动切换（§8.4 坑 4） |

### `sg-mnl-app`（Pod / 节点，Terway：Pod IP 直接在此组）

| 方向 | 协议/端口 | 源/目的 | 用途 | 备注 |
| --- | --- | --- | --- | --- |
| in | TCP 3000 | `sg-mnl-alb`（组引用） | 只有 ALB 能打业务端口 | Terway 下 ALB 走 Pod ENI 直连，源即 ALB 所在 vSwitch 网段对应的组 |
| in | — | — | kubelet 10250 **不对公网开** | 由 ACK 内部管理 |
| out | TCP 5432 | `sg-mnl-db` | 主库 | |
| out | TCP 6379 | Tair 内网 | 缓存 | |
| out | TCP 443 | `0.0.0.0/0` | 上游模型 API | **主动写明评审口径**（坑 3）：上游 IP 不可枚举；缓解=NAT 固定 EIP 池 + ActionTrail + SLS 出向流量审计 |
| out | 22/其他内网段 | — | 禁止横向 | V4 验证项 |

### `sg-mnl-db`（RDS/Tair/日志库）

| 方向 | 协议/端口 | 源/目的 | 用途 |
| --- | --- | --- | --- |
| in | TCP 5432 | `sg-mnl-app` | 内网访问 RDS（PgBouncer 收敛后仅放行池 Pod 网段，见 impl_deploy §7.4.5.6） |
| in | TCP 5432 | 新加坡 NAT EIP（4 个 /32） | 备 region 公网接管链路，白名单组独立命名、不复用 default（§6.1） |

## 2. 新加坡（2 个 SG）

### `sg-sg-alb`：规则同 `sg-mnl-alb`（常态只承接 GTM 健康探测与内部验证流量）

### `sg-sg-app`

| 方向 | 协议/端口 | 源/目的 | 用途 | 备注 |
| --- | --- | --- | --- | --- |
| out | TCP 5432 | `${RDS_MNL_PUB}` 解析出的公网 IP | 备 region 读主库 | **目的地址精确放行**；EIP 被换 = 接管能力静默失效（§6.1 坑 2），换 EIP 必须同步改本条 |
| out | TCP 443 | `0.0.0.0/0` | 上游模型 API | 同主站口径 |

## 3. 建规则 CLI 示例

```bash
aliyun ecs AuthorizeSecurityGroup --RegionId ap-southeast-6 --SecurityGroupId ${SG_MNL_APP} \
  --IpProtocol tcp --PortRange 3000/3000 --SourceGroupId ${SG_MNL_ALB} \
  --Policy accept --Priority 1 --Description "from-alb-only"
```

## 4. 验证（D5 执行，照抄 §8.1）

```bash
# 反例自查：任何入向 0.0.0.0/0 且端口非 80/443 的规则都要删（期望输出为空）
aliyun ecs DescribeSecurityGroupAttribute --SecurityGroupId ${SG_MNL_APP} \
  | jq -r '.Permissions.Permission[] | select(.Direction=="ingress" and .SourceCidrIp=="0.0.0.0/0") | [.PortRange,.IpProtocol,.Description] | @tsv'

nc -vz ${NODE_PUBLIC_IP} 3000                                              # 期望 refused/timeout（V1）
curl -sS https://api.likha.com/api/status | jq -e '.success'               # 期望 true（V2 ALB→Pod 通）
timeout 5 psql "host=${RDS_MNL_PRI} dbname=postgres user=newapi sslmode=require" -c 'select 1'  # 非 app 网段执行，期望 timeout（V3）
kubectl -n new-api run scan --image=busybox --rm -it --restart=Never -- \
  sh -c 'nc -vz 10.0.32.1 22 || echo blocked'                              # 期望 blocked（V4）
```

## 5. 待回填占位符

| 占位符 | 来源 |
| --- | --- |
| `${SG_MNL_ALB}` / `${SG_MNL_APP}` / `${SG_MNL_DB}` / `${SG_SG_ALB}` / `${SG_SG_APP}` | D5 建组后回填实际 ID 并同步 IaC |
| `${DCDN_L2_IPS}` | 仅启用 DCDN 时，`DescribeDcdnL2Ips` 定时同步 |
| `${RDS_MNL_PUB}` | §6.1 任务 15 开公网地址后 |
| GTM 探测源 IP 段 | §8.4 任务 21 创建后从 GTM 文档/控制台取 |
