# Day2 任务 19 补：ALB 公网 IP 无证书直连 new-api 执行报告

- **日期**：2026-10-06（复核 08:45–09:05 GMT+8）
- **场景**：G5 证书未到位，需用 ALB 公网 IP 直连 `new-api-stable` 做验收
- **结论**：✅ **已通** — `http://8.212.161.49` / `http://8.212.183.7`（HTTP 80）
- 上下文：本文承接 2026-10-06 凌晨一轮排查（该轮末尾被用户打断，未收口）

---

## 一、最终链路（已验证）

```
Client(公网) → ALB alb-1riqckb1h8ezm0y7s9 (Internet, 8.212.161.49 / 8.212.183.7)
              → Listener lsn-ihrgkty2sjdy8s5p4h  :80 HTTP
              → ServerGroup sgp-fm7kdwz99wtzbffkfx  (HTTP, 健康检查 **关闭**)
                 成员：4 节点 Ecs + Port=32656，全部 Available
                 i-5ts9wk588cliiweawind 10.0.22.194
                 i-5tsaatp5w68w13n4z1w8 10.0.22.195
                 i-5tsawhljdqzwqhmadqv0 10.0.43.200
                 i-5tsfiz0wh6r2kymp6jwh 10.0.43.201
              → NodePort Service newapi-np  80:32656  (externalTrafficPolicy=Cluster)
                 selector app=new-api,track=stable → targetPort 3000
              → Pod new-api-stable ×4
```

**为什么走 NodePort 而不是直连 Pod IP**：Pod 重建后 IP 变化（见下文「Ip 型组失效」），NodePort 与 Pod IP 解耦，稳定。

## 二、实测证据（2026-10-06 09:00）

| 探针 | 结果 |
|---|---|
| `http://8.212.161.49/api/status` ×12 | 200 ×12（无抖动） |
| `http://8.212.183.7/api/status` ×6 | 200 ×6 |
| `http://8.212.161.49/` | 200, 1047 B, `<title>New API</title>` |
| Host 头 `ph-verify.internal.likha.hk` | 200 |
| NodePort 自测（节点本机 :32656） | 200 ×3 |
| **跨节点** NodePort 4 节点 × 5 | 200 ×20 **全通** |
| ClusterIP `172.21.15.220:80` | 200 ×3 |
| Pod IP :3000 ×4 | 200 ×8 |
| 443 / 8080 | ❌ conn-fail（无监听器） |

`/api/status` 返回真 new-api JSON（`data.chats` / `announcements` 等字段齐全）⇒ 确证打到 new-api-stable，非 kube-system 占位服务。

## 三、昨晚为何访问不通（根因）

1. **主因：跨节点 NodePort 缺 SG 放行**。ALB 转发到 4 节点任意一个，`externalTrafficPolicy=Cluster` 时该节点需再转发到别的节点上的 Pod。该路径需：
   - 节点 SG 入站放行 **来自 ALB SG**（`sg-5tsj1epvcjjv6jkg3zks`）的 32656；
   - 节点出站 → Pod，且 **Terway Pod 有独立网卡 + 独立 SG**（`sg-5tsaatp5w68vyqszezja`），节点 SG 放行 **不等于** Pod 可达。
   - 上轮末尾才补齐两组规则 ⇒ 本次复测生效。
2. **干扰项：`new-api-direct` 实验 Deployment**（用户截图中的红箭头对象）。为上轮绕开跨节点问题试探 hostNetwork / hostPort 方案所建，**已删除**（`kubectl get deploy new-api-direct` → NotFound）。
3. **旁证：`sgp-1zdipho1kpupp43v4m`（Ip 型组）成员含失效 Pod IP**：
   - 组内 `10.0.43.218` / `10.0.22.219` 已不存在（Pod 重建后 IP 变更）
   - 当前实际 Pod IP：`10.0.22.205` / `10.0.22.218` / `10.0.43.202` / `10.0.43.215`
   - ⇒ Ip 型直连 Pod 方案天然脆弱，**不采用**。

## 四、当前资源现状

| 资源 | 状态 | 处置 |
|---|---|---|
| Listener `lsn-ihrgkty2sjdy8s5p4h` :80 | 在用，指向 `sgp-fm7kdwz99wtzbffkfx` | 保留（证书到位后改 443 + TLS） |
| ServerGroup `sgp-fm7kdwz99wtzbffkfx` | 4 节点 Ecs:32656，全 Available，健康检查**关闭** | 保留。⚠ 组名 `kube-system-fake-svc-80` **命名误导**，实为我方挂的 4 节点 |
| ServerGroup `sgp-tqgwt413t19mum8oa9` | ACK Ingress Controller 创建（`new-api-new-api-stable-80`，Eni 型 4 Pod IP），未挂监听 | 保留观察 |
| ServerGroup `sgp-1zdipho1kpupp43v4m` | Ip 型，2/4 成员失效，无监听引用 | **✅ 已删除**（详见 §八） |
| Deployment `new-api-direct` | 已删除 ✅ | — |
| Service `newapi-np` | NodePort 32656，正常 | 保留至证书到位 |

> **安全组现状（清理后）**
> - 节点 SG `sg-5tsil3ca5dfkqefks1g9`：12 → **9 条**
> - Pod SG `sg-5tsaatp5w68vyqszezja`：5 → **4 条**

## 五、风险与边界

1. **仅 HTTP，无 TLS**：`http(s)://IP` 中 https 不可用；此路径**仅供内部验收**，不得对外宣称上线。
2. **健康检查关闭**：ALB 会把流量送到不可用节点（当前 4 节点均正常，风险低）。若后续要长期用，建议开 TCP 健康检查而非 HTTP（Pod 全挂时四层仍通的问题，参见 `DCDN回源层切换_方案.md`）。
3. **ALB Ingress Controller 缺位**（任务 19 未闭合项）：集群内无 Controller Pod，但云端 addon 报 active v3.1.1，元数据≠实况。一旦重装 Controller，`sgp-fm7kdwz99wtzbffkfx` 可能被接管/覆盖 ⇒ **此直连通道属临时手段**。
4. **ServerGroup 命名污染**：`sgp-fm7kdwz99wtzbffkfx` 名为 `kube-system-fake-svc-80`，与其实际承载（new-api-stable 4 节点）不符，易误判。

## 六、后续（证书到位后）

1. 上传证书至 ALB → 建 443 监听（TLS）→ 停止使用 IP 直连。
2. 恢复 ALB Ingress Controller（需确认卸载级联删除 AlbConfig/ALB 风险后再执行）。
3. 删除 `newapi-np` NodePort Service 与 `sgp-1zdipho1kpupp43v4m`。
4. 清理上轮实验残留 SG 规则（描述含 `diag-intra-*` / `intra-vpc-*` / `task19`）。

## 七、直接可用网址

```
http://8.212.161.49
http://8.212.183.7
```

---

## 八、残留清理执行记录（2026-10-06 09:50–10:05，用户批准后实做）

### 8.1 已删除

| # | 对象 | 说明 |
|---|---|---|
| 1 | ServerGroup `sgp-1zdipho1kpupp43v4m` | Ip 型直连组，无监听引用，成员因 Pod 重建失效 |
| 2 | 节点 SG ingress `TCP 32656/32656 from 10.0.0.0/16` | `diag-intra-vpc-32656`（节点间 NodePort 诊断用） |
| 3 | 节点 SG ingress `TCP 3000/3000 from 10.0.0.0/16` | `diag-intra-vpc-3000`（节点上无 3000 监听，本无意义） |
| 4 | 节点 SG egress `UDP 1/65535 → 10.0.0.0/16` | `intra-vpc-udp` 诊断全开 |
| 5 | Pod SG ingress `UDP 1/65535 from 10.0.0.0/16` | `intra-vpc-udp-to-pods` 诊断全开 |

**每步删完立即复测 ALB**：`200×6/6` 全保持，无一步中断。

### 8.2 明确保留（当前链路命脉，删则访问即断）

| SG | 规则 | 作用 |
|---|---|---|
| 节点 SG | ingress `TCP 32656` ← SourceGroupId `sg-5tsj1epvcjjv6jkg3zks` | ALB → 节点 32656 |
| 节点 SG | egress `TCP 1/65535 → 10.0.0.0/16` | 节点 → Pod（kube-proxy DNAT 后） |
| Pod SG | ingress `TCP 1/65535 from 10.0.0.0/16` | Pod 收节点转发流量 |
| Pod SG | ingress `TCP 3000` ← ALB SG | 预留：Eni/Ip 直连型组配套 |
| 节点 SG | ingress `TCP 3000` ← ALB SG（`from-alb-only`）· ingress 10250 · egress 443/6379/5432 | 原有资产，不动 |

### 8.3 删后回归验证（DNS 未受影响）

**担心点**：删 Pod SG 的 UDP 全开规则会破坏集群内 UDP 53（CoreDNS）。

**实测结论**：**未受影响**。CoreDNS 日志显示删除后仍持续收到 UDP 查询并 NOERROR，**且含跨节点流量**（`10.0.43.211` → 落在 `10.0.22.194` 节点的 coredns；`10.0.22.196` → 落在 `10.0.43.201` 节点的 coredns）⇒ **集群内 Pod 东西向流量不受 Pod SG 约束**，Pod SG 无需为东西向开洞。

（new-api 镜像为精简 alpine，无 `nslookup`/`curl`，Pod 内主动探测不可用，故以 CoreDNS 服务端日志为准。）

### 8.4 ★ 本次踩坑：ECS 安全组 API 参数形态

- `RevokeSecurityGroup` / `AuthorizeSecurityGroup` 在 **ap-southeast-6 用扁平参数**，**不是** `SecurityGroupRule.N.*` 数组。
- 误用数组参数的报错是 **`InvalidIpProtocol.ValueNotSupported`**（看起来像值写错，实为参数名不被识别）。**且 `aliyun_rpc.py --dry` 打印的请求参数完全正确、签名通过（有 RequestId）** ⇒ 不能靠"参数打印正确"判定参数名有效。
- CLI 直接给出线索：`--SecurityGroupRule.1.Direction` → `"is not a valid parameter or flag"`。**遇到 CLI 说参数名非法，先信 CLI。**
- 本地域不存在 `RevokeSecurityGroupIngress`（只有 `RevokeSecurityGroup` / `RevokeSecurityGroupEgress`）。
- **零风险探针**：真实 SG + 不存在的规则（`PortRange=19999/19999 --SourceCidrIp=10.99.0.0/16`）→ 回 `InvalidSecurityGroupRule.RuleNotExist`，即证明参数层已过且不会误删。

脚本：`deploy/task19/cleanup_residue.sh`（首版，含数组参数 → 已废弃）· `deploy/task19/cleanup_residue2.sh`（**可用版**，逐条删 + 每步复测 + 失败自动回滚）。

---

## 九、ALB Ingress Controller 存活判定 + 双路径（2026-10-06 10:22–10:45）

### 9.1 ★ 更正旧结论：Controller **没挂**

**2026-10-05 复核曾判「Controller 已无实例 ⇒ 组件挂、addon 元数据不可信」—— 该结论错误。**

真相：`alb-ingress-controller v3.1.1` 是 **ACK 托管形态**，webhook 与 reconcile 跑在**托管平面**，**不以 Pod 形式出现在用户集群**。集群内无 Pod 属正常。

| 判活方法 | 结果 | 是否可用 |
|---|---|---|
| 节点侧 `TCP connect 7.8.229.211:9443` | TCP-FAIL | ❌ **误导**。`7.8.x` 为托管平面地址，仅 apiserver 可达 |
| `kubectl get pods -A \| grep -i alb` | 空 | ❌ **误导**。托管形态本无 Pod |
| **`kubectl annotate ... --dry-run=server`** | **成功** | ✅ **权威判据**（apiserver 真调到 webhook） |
| 托管资源 CreateTime | `2026-10-06T00:20:16Z` | ✅ 组由它创建（晚于最后一批 Pod `00:10:22Z`） |
| 监听器/规则来源 | 见下 | ✅ 均为 Controller 自动创建 |

**dry-run 实证**：
```
ingress.networking.k8s.io/new-api-verify annotated (server dry run)
albconfig.alibabacloud.com/mnl-alb        annotated (server dry run)
```
⇒ **webhook 后端活着**（webhook `failurePolicy: Fail`，若后端死则这两个 dry-run 必报错）。

### 9.2 ★ 同一 ALB 80 端口有两条并存出口

监听器 `lsn-ihrgkty2sjdy8s5p4h`（80，`ListenerDescription="ingress-auto-listener-80"`）：

| 入口条件 | 目标服务器组 | 类型 | HPA 扩缩容同步 |
|---|---|---|---|
| 规则 `rule-0f7ru4csbcn41ygmb4`（`rule-80-1`，Priority 1，Available）<br>Host = `ph-verify.internal.likha.hk` + Path `/*` | **`sgp-tqgwt413t19mum8oa9`**（Weight 100） | **Eni（Pod IP）** | **✅ 会自动同步** |
| 其他 / 无 Host → `DefaultActions` | `sgp-fm7kdwz99wtzbffkfx` | **Ecs（节点:32656）** | 无需同步（与 Pod IP 解耦） |

**两条路径实测均 200**（带/不带 Host 各 5 / 3 次）。

### 9.3 `sgp-tqgwt413t19mum8oa9` 的自动同步机制

- **归属**：由 Ingress `new-api-verify` → backend **`new-api-stable:80`** 派生；命名 `<ns>-<svc>-<port>`；Tags 含集群 ID `cd57e40ce9a634c1698c2f5c5e09bd93c`；`ServiceName=new-api-new-api-stable-80`。
- **机制**：Controller watch Service `new-api-stable` 的 **EndpointSlice**（`new-api-stable-sbwkk`，4 个 ready IP）→ **Pod 增减即自动 `AddServers` / `RemoveServers`**。
- **当前一致**：组 4 成员 = EndpointSlice 4 个 ready IP（`10.0.22.205` / `10.0.22.218` / `10.0.43.202` / `10.0.43.215`）。
- **摘除保护已开**：`ConnectionDrainConfig{ConnectionDrainEnabled=true, ConnectionDrainTimeout=120}`（缩容先 drain 120s 再摘）。
- **健康检查**：`HealthCheckEnabled=true`、HTTP GET `/api/status`、interval 6s、healthy 2 / unhealthy 3 ⇒ Pod 未就绪不转发。
- **⚠ 未实测**：「Pod 变 → 组变」这一步是**基于 Controller 标准行为的推断**，未在集群内触发滚动更新/扩容验证。
  低风险验证法：`kubectl -n new-api scale deploy/new-api-stable --replicas=5` → 看组是否变 5 条 → 再回 4。

### 9.4 与 HPA 的关系

- `hpa-new-api-stable`：`Deployment/new-api-stable`，**min=4 / max=15 / 当前 4**，目标 CPU 65%（当前 0%）。
- **服务器组层**：扩容出的新 Pod 只要 Ready，会被 Controller 同步进 `sgp-tqgwt413t19mum8oa9`；缩容时走 120s drain。
- **⚠ 真正瓶颈在节点层，不在服务器组**：Pod 扩到节点资源不足时需扩节点；节点池为**按量付费（`instance_charge_type: PostPaid`，2026-10-06 用户裁定）** ⇒ **扩容随用随计费、缩容可退**，但 ⚠ **按量配额余量为 0**（马尼拉 `postpay_c` = 64 = `max_size` 8×8），扩节点前须先提额（F13 + 任务 11 坑 7b）。

### 9.5 ⚠ 须收口的不一致

`AlbConfig mnl-alb` 声明 `listeners[0]: port=80 → httpDefaultActions=[Redirect to www.likha.hk:443]`，但实际 80 default 为 ForwardGroup（见 9.2）。
**风险**：若某天 Controller 按 AlbConfig reconcile 回 Redirect，而 `likha.hk` 公网**不存在**（NS NXDOMAIN）⇒ **直连 IP 通道立即失效**。
**建议**：删除该 AlbConfig 的 `listeners` 段，或改为与现状一致的 ForwardGroup。

### 9.6 仍未闭合（任务 19 遗留）

- `IdleTimeout=15` / `RequestTimeout=60`，未达 60 / 600 目标（V1b ❌）。
- 443 + TLS（V3/V4 ❌，等 G5 证书）。
- AlbConfig 声明与现实不一致（见 9.5）。

## 十、nodePort 固化（2026-10-06 11:46，用户批准）

### 10.1 为何要固化

`newapi-np` 的 `nodePort=32656` 原先由 k8s 从默认范围 **30000–32767 随机分配**。但 ALB 服务器组 `sgp-fm7kdwz99wtzbffkfx` 的后端是**写死的「节点 IP:32656」**，ALB 侧不会跟随 Service 端口变化。

⇒ 只要该 Service 被删除后重新 `apply`（或任何导致重建的操作），k8s 极可能分配新端口 → **服务器组 4 个后端全部失效，ALB 立即 502/超时，且现象隐蔽（ALB 侧看起来一切正常）**。

### 10.2 已做

| 动作 | 结果 |
|---|---|
| `kubectl patch svc newapi-np` 显式补 `nodePort: 32656` + `externalTrafficPolicy: Cluster` | `service/newapi-np patched (no change)` —— 值本就相同，零风险 no-op |
| 回读确认 | `NodePort extPolicy=Cluster port=80 target=3000 nodePort=32656` ✅ |
| 节点本地自测 `10.0.22.194:32656/api/status` | `200 × 3/3` ✅ |
| 本机 ALB 复测（两 IP × 6） | `200 × 12/12` ✅ **无断流** |
| 落库存档 `deploy/manifests/newapi-np.yaml` | ✅ 含固化值 + 完整注释 |
| 更新 `task_alb_url/bodies/06-create-nodeport.sh` | ✅ 显式带 `nodePort`，并加断言：非 32656 直接打 `FAIL` |
| manifest 双重校验（`--dry-run=client` + `--dry-run=server`） | 均 `configured`，与线上值逐字段一致 ✅ |

### 10.3 效果

- **重建幂等**：现在 `kubectl apply -f manifests/newapi-np.yaml` 不会改变 nodePort，ALB 后端永远指向 32656。
- **失败可发现**：06 脚本内置断言，若哪天 32656 被其他 Service 占用导致漂移，脚本会当场报 `FAIL` 而不是静默劣化。
- **唯一权威副本**在仓库里（`deploy/manifests/newapi-np.yaml`），不依赖集群里那份的状态。

### 10.4 剩余注意

- 32656 属 k8s 默认 NodePort 区间的**低段**，若集群后续有大量 NodePort Service 存在撞号可能。当前集群仅此一个 NodePort，无实际风险；如撞号，需改服务组后端端口（不能只改 Service）。
- 该固化**不改变**任务 19 未闭合项：443+TLS、超时 60/600、AlbConfig 不一致（§9.5/9.6）。

