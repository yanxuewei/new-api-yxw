# Day 2 · 任务 19｜马尼拉 ALB + AlbConfig + 健康检查 —— 执行/复核报告

- **卡片**：`deploy/docs/阿里云国际站菲律宾部署_详细操作指南-v2.0.md` §6.3 Day2 任务 19（单人，2 人时）
- **复核日期**：2026-10-05（只读复核，未做任何写操作）
- **复核执行环境**：macOS 宿主 + `deploy/ack_remote.sh`（云助手 → worker 内 kubectl，admin 私网 kubeconfig）
- **结论**：❌ **任务 19 未完成（部分交付）**。2026-09-30 已落地 ALB 骨架，但 V1b/V2/V3/V4 + HTTP→HTTPS 301 均未达标，且复核发现 3 项新问题（含 1 项阻断）。
  **⚠ 2026-10-06 更新（结论由「4 项未达标」改为「V2 已闭环，余 3 项待 G5 证书」）**：**V2 健康检查已销项**——`Ingress/new-api-verify` 后端经核准切到 `svc/new-api-stable`（任务 23 `--wire-alb`），经 ALB `GET /api/status → 200`、`GET / → 200`，ServerGroup `sgp-tqgwt413t19mum8oa9`（`HealthCheckEnabled=true`）4 条 ENI 全 `Available` 且与 `endpoints/new-api-stable` 逐一对应；阻断项 ③（控制器）10-05 22:08 重装后于 10-06 08:5x 复核确认活着（`lease/alb` `renewTime` 与节点侧 `date -u` 同秒 + `SuccessfullyReconciled`），**但 ③ 的原始判据已收回**（见 §三 更正框）。**仍阻塞**：V1b（`IdleTimeout/RequestTimeout` 60/600）、HTTP→HTTPS 301、V3 443+TLS 策略、V4 证书链/SNI —— 全部依赖 G5 证书（唯一硬阻塞）。证据 `deploy/logs/task23_wire-alb_20261006-082013/`、`deploy/logs/task23_ingress_be_20261006-085337/`。本卡仍**不计入闭合卡数**（V1b/V3/V4 未过）。
- **2026-10-05 22:12 更新**：3 项新问题中的**阻断项 ③「控制器未运行」已修复**（卸载 stale 记录 + 重装 v3.1.1，调谐恢复，见 §七）；G4 的 NS 已迁阿里云（DCV 可用）；**G5 证书仍为唯一硬阻塞** ⇒ 任务 19 保持"未完成"。

---

## 一、2026-09-30 实际落地内容（今日复核实测）

| 资源 | 实测值 | 判定 |
| --- | --- | --- |
| ALB 实例 | `alb-1riqckb1h8ezm0y7s9` / `alb-newapi-mnl` / **Active** / Internet / Standard | ✅ V1 |
| ALB DNS | `alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com` | ✅ |
| 双可用区 | `ap-southeast-6b`(vsw-5ts1dygyh2x0daspwny2r) + `ap-southeast-6a`(vsw-5ts9tgdq1xz3picjgoqyu) | ✅ V1b-1 |
| 访问日志 | `sls-newapi-mnl` / `alb_access`（`AccessLogConfig` 已生效） | ✅ |
| VPC / 标签 | `vpc-5tst1tgeessxn1azwasg2`；tags project=new-api / site=ph-mnl / env=prod / ack.aliyun.com=`cd57e40ce9a6…` | ✅ |
| AlbConfig | `mnl-alb`，creationTimestamp `2026-09-30T10:23:40Z`，finalizer `ingress.k8s.alibaba/resources`，status.loadBalancer.id 已回填 | ✅ V5 |
| 监听器 | **仅 1 个**：`lsn-ihrgkty2sjdy8s5p4h` port **80**/HTTP/Running | ⚠ 见 §三-④ |
| IngressClass | `alb` → AlbConfig `mnl-alb` | ✅ |
| 占位资源 | `Service/new-api-master`（ClusterIP，0 endpoints）+ `Ingress/new-api-verify`（class=alb，host `ph-verify.internal.likha.hk`，**9 项健康检查/排空注解齐全**），AGE 4d19h | ✅ V5 |
| Ingress 地址 | Ingress `status.loadBalancer.ingress` = ALB DNS（控制器 09-30 成功回填） | ✅ |
| ServerGroup | 仅 1 个：`sgp-fm7kdwz99wtzbffkfx`（`kube-system-fake-svc-80`，ServerCount=0，`HealthCheckEnabled=false`） | ⚠ 见 §三-④ |

## 二、V1–V5 验收逐项判定（2026-10-05）

| 验收项 | 判定 | 依据 |
| --- | --- | --- |
| V1 ALB 已创建 | ✅ | `ListLoadBalancers` → Active |
| V1b 双 AZ 绑定 | ✅ | `GetLoadBalancerAttribute.ZoneMappings` 含 6a+6b |
| V1b 超时 `IdleTimeout=60`/`RequestTimeout=600` | ❌ | 实测 **idle=15 / req=60**（默认值），且**无 443 监听**承载 600s |
| HTTP→HTTPS 301 跳转 | ❌ | AlbConfig 声明 Redirect，ALB 实测 `DefaultActions[0].Type=ForwardGroup`（无 301） |
| 访问日志 → SLS | ✅ | AccessLogConfig 已占位并生效 |
| V2 健康检查 `/api/status` 全绿 | ✅ **2026-10-06 闭环**（10-05 判 ❌） | 当时：占位 Service 0 endpoints（任务 18 未部署，卡内已知偏差②）；且 Ingress 注解未被物化为 ServerGroup 健康检查配置（唯一 SG `HealthCheckEnabled=false`）⇒ 卡内所述"0 后端下假通过"的隐患已确认。现在：后端切 `svc/new-api-stable`（4 副本）+ SG `sgp-tqgwt413t19mum8oa9` `HealthCheckEnabled=true` + 4 条 ENI `Available` + 经 ALB `200` ⇒ **非假通过的真验收**（`deploy/logs/task23_wire-alb_20261006-082013/`、`task23_ingress_be_20261006-085337/`）。⚠ 走的是 **HTTP:80**，443 侧仍待 G5 |
| V3 443 监听 + `tls_cipher_policy_1_2_strict_with_1_3` | ❌ | 无证书（见 §三-⑤） |
| V4 证书链 / SNI 反例 | ❌ | 同上 |
| V5 K8s 侧对象落地 | ✅ | AlbConfig/IngressClass/Service/Ingress 均在位 |

> **判定口径**：`WARN ≠ 通过`；本卡无 FAIL 计数意义（未走脚本收口），以"是否有 443 + 健康检查是否可验收"为准 ⇒ **未完成**。

> **同日更正（2026-10-05 晚，任务 18 执行后）**：上表 V2 的依据「任务 18 未部署」**已过时**——任务 18 已落地并跑通 AutoMigrate（`deploy/docs/Day2任务18_master迁移幂等_执行报告.md`）。但**结论不变**：master Pod 标签刻意用 `app=new-api-migrate`，不命中占位 `Service/new-api-master` 的 selector（实测 `endpoints/new-api-master ready=0`），目的是避开任务 18 卡片「坑 1｜master 迁移期被 ALB 引流」⇒ 占位 Service 依旧 0 后端，V2 健康检查**仍然不可验收**。master 上线不构成 ALB 后端，stable 就绪前该项保持 ❌。**→ 10-06 该项已由任务 23 `--wire-alb` 闭环，见上表。**

## 三、复核新发现（3 项）

### ③ ALB Ingress Controller 已不在集群内运行（**阻断项，新发现**；⚠ 本节的**判据**已于 10-06 收回，见下方更正框）
> **⚠ 判定方法更正（2026-10-06 08:5x 只读复核，证据 `deploy/logs/task23_albctrl_20261006-085148/`、`deploy/logs/task23_goatscaler_20261006-085256/`）**
> 本节把"用户面查不到 alb workload"当成"控制器未运行"的证据，这条推理**无效**：ALB Ingress Controller 跑在 **ACK 托管控制面**，用户面本就看不到它的 Pod/Deployment。10-06 复核同一位置仍是 `pods -A` 计 alb = **0**、`deploy/ds/sts -A` 计 alb = 0，但 `lease/kube-system/alb` 与 `lease/alb-gateway` holder = **`controlplane-alb-84bb75d758-l8q7g_…`**、`renewTime=2026-10-06T00:52:57Z` 与节点侧 `date -u`（`00:52:58Z`）**同秒**，`EndpointSlice alb-ingress-controller-4dprp`（`7.8.229.211`/`7.8.72.26`）两条 `ready=true`，`ingress/new-api-verify` + `albconfig/mnl-alb` 均有 `SuccessfullyReconciled` ⇒ 组件在**控制面**活着。
> **对本节实况的影响**：① 10-05 的**结论仍成立**（调谐确实死掉：④ 的声明 vs 实测不符、无新调谐产物），重装也确实把它恢复了；② 但"443 不会被 reconcile ⇒ **修复须重装组件**"这一步的依据（看不见 workload）应换成"有无调谐产物"；③ 本卡 §四 与卡片正文里的同类表述已连正文改正，今后核查托管组件一律按 **lease holder + `renewTime` 同秒 → EndpointSlice IP/AGE → 调谐产物（events + 云侧对象变化）** 三级取证。同一方法顺带查明弹性组件实名是 **`ack-goatscaler`** 且活着（详见任务 23 报告 §十三-③/⑤、指南任务 42 卡 10-06 复核）。

- `kubectl get pods -A`（48 个 Pod 全量枚举）+ `get deploy/sts/ds -A` → **无任何 alb 组件实例**；`kube-system` 只剩一个 headless `Service/alb-ingress-controller`(443) 与陈旧 `EndpointSlice alb-ingress-controller-2vr6n`（IP `7.8.75.74` / `7.8.167.212` 已无对应 Pod；v1 Endpoints `resourceVersion=469`，属建簇初期残留对象）。⚠ 按上方更正框：这组观测**只能证明 EndpointSlice 陈旧**（IP 无对应 Pod 是真信号），"无 workload"本身不构成缺席证据。
- 云端 `aliyun cs ListClusterAddonInstances` 仍报 `alb-ingress-controller active v3.1.1` ⇒ **元数据与实际运行态不一致**（addon 记录未刷新）。
- 后果：① 证书就绪后 **443 监听不会被自动 reconcile**；② Ingress 上的健康检查/排空注解**无人消费**；③ AlbConfig 变更不再生效。
- 修复路径（**未执行，须先确认**）：重装/修复 `alb-ingress-controller` 组件。⚠ ACK 组件**卸载**存在级联清理 AlbConfig 及由其托管的 ALB 的已知行为（AlbConfig 带 `ingress.k8s.alibaba/resources` finalizer）⇒ 不可贸然 uninstall；建议 `InstallClusterAddons` 幂等重装优先，并在操作前对 AlbConfig + Ingress 做本地快照。

### ④ 80 监听器与 AlbConfig 声明不符
- AlbConfig spec：`listeners[0] = {port: 80, protocol: HTTP, httpDefaultActions:[Redirect → host www.likha.hk, https on, port 443]}`。
- ALB 实测：`ListenerDescription=ingress-auto-listener-80`、`DefaultActions[0].Type=**ForwardGroup**` → `sgp-fm7kdwz99wtzbffkfx`（`kube-system-fake-svc-80`，`ServerCount=0`）、`IdleTimeout=15` / `RequestTimeout=60` / `ConnectTimeout=5` / GzipEnabled=true。
- 研判：与 ③（控制器缺失）自洽 —— **listener 停留在控制器首次创建时的 auto-listener 状态**，声明中的 Redirect 与超时从未被 reconcile 到位。

### ⑤ G4/G5 相比 09-30 记录**更差**（域名侧硬阻塞）
- `dig NS likha.hk @8.8.8.8` → **NXDOMAIN**（新域 `likha.hk` 在公网 DNS 中不存在，连 NS 都没有）。
- `dig NS likha.com @8.8.8.8` → `ns21/ns22.domaincontrol.com`（GoDaddy）；`dig A www.likha.com` → `likhaaa.myshopify.com` / `shops.myshopify.com` / `23.227.38.74`（Shopify 托管）。
- `aliyun alidns DescribeDomains` → **TotalCount=0**（阿里云云解析无任何域名）。
- `aliyun cas ListUserCertificateOrder` → **TotalCount=0**（`--region ap-southeast-1` 与 `--region cn-hangzhou` 均 0）。
  - ⚠ CLI 坑：`cas` 命令 **不带 region 默认走 ap-southeast-6 会报 `unknown endpoint for region ap-southeast-6`**（CAS 在该地域无端点）→ 必须显式 `--region`，否则会被误读成"查询失败"。

## 四、本次为执行通道修复的问题（前置）

- `deploy/ack_remote.sh`：`base64 -w0 <file>` 在 **BSD/macOS** 上不可用（报 `invalid argument`，**静默产出空 Body**，远端只回显 BODY START/END 而无内容）→ 已改为 python3 编码 + 空值校验。此坑之前在 WSL（GNU base64）下不会触发。

## 五、待办与解除条件

| # | 事项 | 解除条件 | 状态 |
| --- | --- | --- | --- |
| 1 | 修复/重装 `alb-ingress-controller`（③） | ~~先确认卸载副作用 → 幂等重装~~ **✅ 2026-10-05 22:08 完成**（卸载 + 重装 v3.1.1；控制器回归、调谐恢复 —— 新建 ServerGroup + :80 规则，见 §七） | ✅ 已完成 |
| 2 | 闭环 G4：`likha.hk` 解析落地（NS 指向阿里云云解析或至少域名可解析） | `dig NS likha.hk` 有应答 + `alidns DescribeDomains` 可见域名 | ⏸ 阻塞（NXDOMAIN） |
| 3 | 闭环 G5：购买/签发 `*.likha.hk` 通配符证书并完成 DCV | `cas ListUserCertificateOrder` TotalCount≥1 且拿到 `CertIdentifier` | ⏸ 阻塞 |
| 4 | 以 `CERT_ID_ALB=<id>` 回跑 `bash deploy/task19_alb_mnl.sh`（EXEC_MODE=ack-remote） | 443 监听 + TLS 策略 + 301 跳转 + 超时 60/600 全部到位 | ⏸ 依赖 1/2/3 |
| 5 | 健康检查真实验收（V2） | 任务 18/23 部署后 Pod 就绪，`/api/status`（G8 后切 `/readyz`）全绿 | ✅ **2026-10-06 闭环**（后端 `new-api-stable`、经 ALB 200、SG 健康检查 `true`；`/readyz` 仍属 G8 后续替换） |
| 6 | 任务 23 落地前删除占位资源 | `bash deploy/task19_alb_mnl.sh --cleanup` | ⏸ 后置 |

## 六、证据

- 本地只读命令输出（本次）：`aliyun alb ListLoadBalancers / GetLoadBalancerAttribute / ListListeners / GetListenerAttribute / ListServerGroups --ServerGroupIds.1`、`aliyun ram GetRole AliyunServiceRoleForAlb`（已存在，CreateDate `2026-09-30T08:50:51Z`）、`aliyun ecs DescribeSecurityGroups`（`sg-5tsaatp5w68w2st9r1pn sg-mnl-alb-edge`、`sg-5tsj1epvcjjv6jkg3zks sg-mnl-alb`、`sg-5ts4en91lowbzluabchr ALB_SYSTEM_SECURITY_GROUP-alb-1riqckb1h8ezm0y7s9`）。
- 集群内只读命令（经 `deploy/ack_remote.sh mnl`）：`kubectl get albconfig -A -o wide`、`get ingressclass`、`-n new-api get svc,ingress -o wide`、`describe ingress new-api-verify`、`get endpoints`、`get pods/deploy -A`、`get endpointslice -n kube-system`。
- 脚本产物时间戳：AlbConfig `2026-09-30T10:23:40Z` / ALB `2026-09-30T10:23:46Z`（相差 6s，控制器创建）→ 佐证 09-30 确有控制器在运行，其后消失。

## 七、2026-10-05 22:06–22:12：阻断项 ③ 修复（卸载 + 重装）+ G4 复测（含云写）

**触发**：用户要求"复核任务 19 是否完成；未完成则继续"。
**决策依据**：官方《如何安装、升级和卸载 ALB Ingress Controller》——**卸载组件不会释放已存在 AlbConfig 对应的 ALB 实例**（只是失去调谐能力）；先取本地快照再动。

### 7.1 执行序列（全部证据在 `deploy/logs/task19_recheck_20261005-215814/`）

| 步骤 | 命令/API | 结果 |
| --- | --- | --- |
| 快照 | `ack_remote.sh mnl body_snapshot.sh` | AlbConfig/IngressClass/Ingress/Service 全量 YAML → `snapshot_before_reinstall.out` |
| 升级（试） | `cs UpgradeClusterAddons v3.1.1` | 任务 `T-6ac3adaeb451ea0108000263` success 但**空操作**（`parameters.can_upgrade=false`，集群内零变化）⇒ 同版本升级不具修复能力 |
| 卸载 | `cs UnInstallClusterAddons` | 任务 `T-6ac3aed78de2a001030002a9`（22:06 提交）；组件记录移除，`ReconcileAddon` 清理陈旧 headless svc/rolebinding |
| 重装 | `cs InstallClusterAddons v3.1.1` | 任务 `T-6ac3af17b44e950103000293`，22:08 success，addon 回 `active v3.1.1` |
| 负向断言 | `alb ListLoadBalancers` / `kubectl get albconfig -A` | ALB 仍**恰 1 个**（`alb-1riqckb1h8ezm0y7s9`，全程 Active）；AlbConfig 仍**恰 1 个**（`mnl-alb`）⇒ 未重建、未产生新实例 |

### 7.2 控制器回归实证（修复生效）

- `kube-system` 重建 `Service/alb-ingress-controller`（headless，443）+ 新 EndpointSlice `alb-ingress-controller-4dprp`（9443，IP `7.8.229.211` / `7.8.72.26`，ACK 托管面形态；集群内不可见 Pod 属**预期**，勿误判为"又没起来"）。
- LeaderElection lease `alb` / `alb-gateway` 均有 holder；事件 `SuccessfullyReconciled albconfig/mnl-alb`、`ingress/new-api-verify` 恢复刷新。
- **调谐产物（新）**：ServerGroup `sgp-a04zqm3iujzi7yoq51`（`new-api-new-api-master-80`，`HealthCheckEnabled=true`）+ :80 规则 `rule-80-1`（Host `ph-verify.internal.likha.hk` + Path `/*` → ForwardGroup 该组）⇒ Ingress 的 9 项健康检查注解开始被消费。

### 7.3 G4/G5 复测

| 项 | 复测结果 | 判定 |
| --- | --- | --- |
| G4 NS | `dig NS likha.hk @8.8.8.8` → `ns7.alidns.com` / `ns8.alidns.com`；`alidns DescribeDomains` → `likha.hk`（TotalCount=1） | ✅ NS 侧闭环（DCV 可走云解析）；遗留 `www.likha.hk` 无记录（任务 1/2） |
| G5 证书 | `cas ListUserCertificateOrder --region ap-southeast-1 --ShowSize 50` → `TotalCount=0` | ❌ 未闭环（唯一硬阻塞；⚠ 余额 0 可能挡下单） |

### 7.4 仍未闭环（任务 19 不计闭合）

1. **:80 Redirect 未落**：`DefaultActions` 仍 `ForwardGroup → sgp-fm7kdwz99wtzbffkfx`（fake-svc，0 后端；`curl -sSI --resolve www.likha.hk:80:8.212.161.49` = **502**）、`IdleTimeout=15`/`RequestTimeout=60`。研判：现网 `AlbConfig.spec` 只声明 80（09-30 `--without-tls` 降级版），Redirect 目标 443 不存在故未收敛。
2. **443 / TLS 策略 / 60/600 超时 / V3 / V4**：全部等待 `${CERT_ID_ALB}`。
3. **V2 健康检查**：占位 Service 仍 0 endpoints（master Pod 标签刻意不命中），验收归任务 23。⇒ **10-06 已由任务 23 闭环**（后端切 `new-api-stable` + 经 ALB 200 + SG 健康检查 `true`）。

**解除动作（单一）**：G5 签发 `*.likha.hk` → 取得 `CertIdentifier` → 以 `CERT_ID_ALB=<id>` 重放 `task19_alb_mnl.sh`（80 Redirect + 443 + 超时 + TLS 策略）→ 逐项验收 V1b/301/V3/V4。

