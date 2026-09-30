# Part 2b · Day 2 泳道 B（应用与入口线）

## Day 2 · 泳道 B：Deployment、ALB、GTM 与异地备集群

> 参数基线（§2.1，全泳道统一）：业务域名 `www.likha.hk`、运维域名 `ops.likha.hk`、通配证书 `*.likha.hk`；主 region `ap-southeast-6`（**仅 6a/6b 两个可用区**）、备 region `ap-southeast-1`（不部署任何数据库）；马尼拉 VPC `10.0.0.0/16`、新加坡 VPC `10.1.0.0/16`；K8s 1.35 + Terway；应用命名空间 `new-api`（备站同名，staging `new-api-staging`、压测 `new-api-perf`）；服务端口 `3000`；镜像前缀 `registry-vpc.ap-southeast-6.aliyuncs.com/newapi/new-api`（EE 实例前缀为实例名，以 §4.2 核实为准，下文以 `${ACR_MNL_PREFIX}`/`${ACR_SG_PREFIX}` 占位）。节点池机型 **g9i.2xlarge**（g8i 未上架马尼拉，2026-09-25 实测）。所有密钥/DSN 一律 `${PLACEHOLDER}`，真实值只存在于 KMS/ExternalSecret。

### Day 2 · 任务 19｜马尼拉 ALB + AlbConfig + 健康检查（人员A，2 人时，D2 上午 09:00–11:00）

**前置/状态**：任务 18 马尼拉 ACK（1.35 + Terway）就绪；`vsw-mnl-pub-a`（10.0.0.0/24, 6a）/`vsw-mnl-pub-b`（10.0.1.0/24, 6b）已建且 `AvailableIpAddressCount` 基线已记录；`*.likha.hk` 证书已签发并拿到 `${CERT_ID_ALB}`；SLS Project `sls-newapi-mnl` 可后置（见坑 5）。

**操作步骤（CLI-first）**：

1. 安装 ALB Ingress Controller 组件（随集群版本）：

```bash
aliyun cs POST /clusters/${CLUSTER_MNL_ID}/components/install --header "Content-Type=application/json" \
  --body '[{"name":"alb-ingress-controller","version":""}]'
kubectl -n kube-system get pods -l app=alb-ingress-controller   # 期望 Running
```

   控制台核对「复用已有 ALB / 新建」选择：【控制台】截图占位 `[图 D2-B-19a｜拍摄对象：ACK 组件管理 ALB Ingress Controller 配置页；打码：集群 ID、账号 UID]`

2. 写 `albconfig.yaml`。**监听器配置（超时/TLS/证书/跳转）由 AlbConfig CRD 独占，没有对应 Ingress 注解可用**，控制台手改会被 GitOps apply 覆盖（见坑 4）：

```yaml
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata: {name: mnl-alb}
spec:
  config:
    name: alb-newapi-mnl
    addressType: Internet
    zoneMappings:
    - {vSwitchId: ${VSW_MNL_PUB_A}}
    - {vSwitchId: ${VSW_MNL_PUB_B}}
    accessLogConfig: {logProject: sls-newapi-mnl, logStore: alb-access}
    tags: [{key: project, value: new-api}, {key: site, value: ph-mnl}]
  listeners:
  - port: 80
    protocol: HTTP
    httpDefaultActions:
    - type: Redirect
      redirectConfig: {host: www.likha.hk, https: on, port: "443"}
  - port: 443
    protocol: HTTPS
    securityPolicyId: tls_cipher_policy_1_2_strict_with_1_3
    caEnabled: false
    requestTimeout: 600   # 方案原口径 180s；ALB 硬上限 600s（P0-5），长任务走异步
    idleTimeout: 60       # 两包间静默上限；SSE 靠网关 ping 15–20s 保活（见坑 2）
    certificates: [{CertIdentifier: ${CERT_ID_ALB}}]
```

```bash
kubectl apply -f albconfig.yaml
kubectl get albconfig mnl-alb -o jsonpath='{.status.loadBalancer.dnsname}{"\n"}'
# 期望：alb-newapi-mnl-xxx.ap-southeast-6.alb.aliyuncs.com
```

3. IngressClass + 占位 Service（stable Service 由任务 23 部署，此处建 `new-api-master` 不接流量的 Service）：

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata: {name: alb}
spec: {controller: ingress.k8s.alibabacloud/alb}
EOF
```

4. Ingress 健康检查注解（健康检查类配置走 Ingress annotation）：`healthcheck-enabled: "true"`、`healthcheck-path: "/api/status"`、`healthcheck-interval-seconds: "6"`、`healthcheck-timeout-seconds: "3"`、`healthy-threshold-count: "2"`、`unhealthy-threshold-count: "3"`、`healthcheck-method: "GET"`、`healthcheck-httpcode: "http_2xx"`。
   **降级路径事实**：当前仓库唯一可用状态接口为 `GET /api/status`（`router/api-router.go:26`）；`/healthz`、`/readyz`、`/metrics` 均未注册（P1-20），该缺口对应 **G8 代码补项**。G8 落地前健康检查只能用 `/api/status`；`/readyz` 上线后再切换——`/api/status` 不反映 DB 就绪，会把"进程活着但连不上库"的 Pod 判成健康。

**验证方法**：

```bash
# V1 ALB 实例与 AZ 绑定
aliyun alb GetLoadBalancerAttribute --LoadBalancerId ${ALB_MNL_ID} | jq -r '.DNSName, (.ZoneMappings[].ZoneId)'
# 期望：两个 AZ = ap-southeast-6a / 6b
# V2 超时参数落到 listener
aliyun alb GetListenerAttribute --ListenerId ${HTTPS_LISTENER_ID} | jq '{IdleTimeout,RequestTimeout}'
# 期望：{"IdleTimeout":60,"RequestTimeout":600}
# V3 TLS 策略
echo | openssl s_client -connect ${ALB_DNS}:443 -servername www.likha.hk 2>/dev/null | grep -E "Protocol|Cipher"
# 期望 TLSv1.2/1.3；弱版本反例：echo | openssl s_client -connect ${ALB_DNS}:443 -tls1_1 2>&1 | grep -Ei "alert|error"  # 期望握手失败
# V4 HTTP→HTTPS 跳转
curl -sSI --resolve www.likha.hk:80:${ALB_VIP} http://www.likha.hk/ | grep -Ei "^HTTP|^location"   # 期望 301 + Location https://www.likha.hk/
# V5 健康检查后端全绿
aliyun alb GetListenerHealthStatus --ListenerId ${HTTPS_LISTENER_ID} | jq -r '.ListenerHealthStatus[].ServerGroupInfos[].NonnormalServers'  # 期望 []
```

**不通过时修复**：
- AlbConfig 一直 `Progressing`、事件 `InvalidZoneMapping` → 诊断：只填 1 个 vSwitch 或 AZ 不被 ALB 支持 → 修复：ALB 强制 ≥2 AZ，马尼拉只能 6a+6b，确认两个 pub vSwitch 分属两 AZ。
- Pod 全不健康但本地 curl `/api/status` 正常 → 诊断：NodePort 未开放，或 Terway 模式 SG 未放行 ALB→Pod 网段 → 修复：ALB 走 Pod ENI 直连，在 `sg-mnl-app` 放行入向 3000，源为 `10.0.0.0/24,10.0.1.0/24`。
- `RequestTimeout` 设 1800 报 `InvalidParameter` → 诊断：超上限 → 修复：上限就是 600；长任务改异步 + 轮询（见坑 3 改进②）。
- 502 且 access log 有记录、上游 0 字节 → 诊断：Pod 被 SSE 长连接占满（Go 无 worker 概念，实际是 FD/内存）→ 修复：确认 §5.4 `nofile=200000` 生效。

**坑**：
- 坑 1｜`requestTimeout` 600 是天花板不是配置项。现象：模型回答 >10 分钟的请求 → 后果：ALB 切断、用户看到回答中途断流 → 改进：①15–20s SSE ping 保活（idleTimeout 侧）；②批量/视频类长任务走 `task` 异步接口 + 轮询；③产品文案/合同写明单请求上限（§12 口径）。
- 坑 2｜idleTimeout 与 SSE 关系搞反。现象：idleTimeout 是**两包之间**的静默间隔，设 60 而上游卡住不吐字 → 后果：60s 即断流 → 改进：网关 ping 间隔设 **15s**（4 倍余量），§11.1 压测用「并发 SSE 1500 + 上游静默 45s」实测。
- 坑 3｜ALB TLS 与 SNI。现象：未配 `securityPolicyId` 时默认可协商 TLS1.0 → 后果：安全核查不合格 → 改进：显式 `tls_cipher_policy_1_2_strict_with_1_3`；D6 任务 40 复核 SNI 域名校验。
- 坑 4｜复用已有 ALB 时 AlbConfig 覆盖 listener。现象：控制台手工加的转发规则被 GitOps apply 抹掉 → 后果：配置漂移不可追溯 → 改进：**ALB 只能通过 AlbConfig/Ingress 管理，禁止控制台改**；ActionTrail 加"谁改了 ALB"告警（§3.3）。
- 坑 5｜`accessLogConfig` 引用不存在的 SLS Project。现象：ALB 创建成功 → 后果：日志静默丢失、事后无证据 → 改进：先建 Project/Logstore（§9.2）再配，或先不配、D6 补上并回归 V1。

### Day 2 · 任务 23｜stable Deployment（4 副本 + PDB + HPA + 反亲和）（人员B，2 人时，D2 上午 09:00–11:00）

**前置/状态**：任务 18 节点池（g9i.2xlarge）就绪；`new-api-config` ConfigMap 与 ExternalSecret 已建（`SESSION_SECRET` 等密钥仅经 KMS 注入，manifest 不出现明文）；任务 19 的 IngressClass `alb` 已建；镜像 `${ACR_MNL_PREFIX}:<git-sha>` 已推 ACR（CI pin SHA，禁 `latest`）。

**操作步骤（CLI-first）**：

1. `kubectl --context mnl apply -f stable.yaml`，核心 manifest：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-api-stable, namespace: new-api}
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}
  selector: {matchLabels: {app: new-api, track: stable}}
  template:
    metadata:
      labels: {app: new-api, project: new-api, site: ph-mnl, track: stable, env: prod}
      annotations:
        checksum/config: "{{ sha of configmap }}"   # ConfigMap 变更即滚动
        prometheus.io/scrape: "true"                 # G8 落地前无实际作用，占位
    spec:
      serviceAccountName: new-api-app
      topologySpreadConstraints:                     # 反亲和：跨 AZ 硬约束 + 跨节点软约束
      - {maxSkew: 1, topologyKey: topology.kubernetes.io/zone, whenUnsatisfiable: DoNotSchedule,
         labelSelector: {matchLabels: {app: new-api}}}
      - {maxSkew: 1, topologyKey: kubernetes.io/hostname, whenUnsatisfiable: ScheduleAnyway,
         labelSelector: {matchLabels: {app: new-api}}}
      terminationGracePeriodSeconds: 60
      containers:
      - name: new-api
        image: ${ACR_MNL_PREFIX}:<git-sha>
        env: [{name: NODE_TYPE, value: "slave"}]
        envFrom: [{configMapRef: {name: new-api-config}}]
        ports: [{name: http, containerPort: 3000}]
        startupProbe:   {httpGet: {path: /api/status, port: 3000}, failureThreshold: 30, periodSeconds: 5}
        readinessProbe: {httpGet: {path: /api/status, port: 3000}, periodSeconds: 5, timeoutSeconds: 3, failureThreshold: 3}
        livenessProbe:  {httpGet: {path: /api/status, port: 3000}, periodSeconds: 15, timeoutSeconds: 5, failureThreshold: 5}
        lifecycle: {preStop: {exec: {command: ["sh","-c","sleep 15"]}}}
        resources: {requests: {cpu: "2", memory: 4Gi}, limits: {cpu: "4", memory: 8Gi}}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: pdb-new-api-stable, namespace: new-api}
spec: {minAvailable: 3, selector: {matchLabels: {app: new-api, track: stable}}}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: hpa-new-api-stable, namespace: new-api}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: new-api-stable}
  minReplicas: 4
  maxReplicas: 16
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 65}}
  behavior:
    scaleDown: {stabilizationWindowSeconds: 300, policies: [{type: Pods, value: 2, periodSeconds: 120}]}
    scaleUp:
      stabilizationWindowSeconds: 30
      policies: [{type: Percent, value: 100, periodSeconds: 60}, {type: Pods, value: 8, periodSeconds: 60}]
      selectPolicy: Max
```

2. Service（ALB 后端走 Terway Pod ENI）：

```yaml
apiVersion: v1
kind: Service
metadata: {name: new-api-stable, namespace: new-api}
spec:
  type: ClusterIP
  selector: {app: new-api, track: stable}
  ports: [{port: 80, targetPort: http}]
```

3. **GitOps 里不要写 `spec.replicas`（当 HPA 存在时）**：每次 sync 会把 replicas 重置回 4、杀掉刚扩容的实例（HPA + ArgoCD/Flux 经典事故）。做法：`ignoreDifferences: [{group: apps, kind: Deployment, jsonPointers: [/spec/replicas]}]`，或干脆不写 replicas。

**验证方法**：

```bash
# V1 副本与分布
kubectl -n new-api get deploy,pods -l track=stable -o wide
kubectl get pods -l app=new-api -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort | uniq -c
# 期望：6a 与 6b 各 ≥2
# V2 零停机滚动
kubectl -n new-api rollout status deploy/new-api-stable --timeout=10m   # 同时压测侧统计：期望 5xx=0（允许 ≤2 个连接重置）
# V3 PDB 生效
kubectl -n new-api get pdb pdb-new-api-stable    # 期望 ALLOWED DISRUPTIONS = 0（4 副本时）
kubectl drain ${NODE} --ignore-daemonsets --delete-emptydir-data --force
# 期望：仅 1 个 Pod 被驱逐，其余 3 个保持 Running；drain 后新 Pod 能被调度（节点池还有 3 台）
# V4 HPA 触发
kubectl -n new-api run cpu-burn --image=polinux/stress --rm -it --restart=Never -- stress --cpu 8 --timeout 300s
kubectl -n new-api get hpa -w                    # 期望 TARGETS >65%、REPLICAS 增长
kubectl -n new-api describe hpa hpa-new-api-stable | tail -20   # 看有无 FailedGetResourceMetric
```

**不通过时修复**：
- HPA `FailedGetResourceMetric` → 诊断：metrics-server 未装或可观测监控 Prometheus 版未接 → 修复：装 `ack-arms-metrics-adapter`/metrics-server；HPA 临时用 CPU（resource）而非自定义指标。
- rollout 时 5xx → 诊断：`maxUnavailable>0` 或 preStop 时间不足 → 修复：`maxUnavailable: 0` + `sleep 15` + readiness 正确；再查 Service endpoint 摘除延迟。
- `drain` 卡住超时 → 诊断：PDB minAvailable 太严 + 集群无空余容量 → 修复：先扩容再 drain（§10.6 cluster-autoscaler 必须在 D6 前完成的原因之一）。
- Pod 全挤单 AZ 且 `DoNotSchedule` 导致 Pending → 诊断：该 AZ 节点已满 → 修复：扩节点池 `max_size`，或用 `minDomains` 精细控制。

**坑**：
- 坑 1｜HPA CPU 利用率按 **request** 口径。现象：limit 4C 用到 3C，按 request 2C 算是 150%，提前扩容 → 后果：扩容时机失真 → 改进：request=limit（Guaranteed，容量可预测，推荐），或明确"65% of request"是有意保守。
- 坑 2｜Go 容器 GOMAXPROCS/内存 limit。现象：`GOMAXPROCS` 默认取宿主机核数（老版本），4C limit 按 8C 起 worker → 后果：CPU throttle 严重、延迟尖刺 → 改进：显式 `GOMAXPROCS=4`（Go 1.25 container-aware 默认可用），压测里验 `container_cpu_cfs_throttled_periods_total`。
- 坑 3｜SSE 连接数 = 长连接 FD。现象：4 副本 × 每副本 N 千并发 → 后果：FD 与内存先于 CPU 打满 → 改进：§11.1 压测以并发 SSE 1500 为主指标；`nofile=200000` 必须已生效（§7.1）。
- 坑 4｜preStop 与 ALB 摘除竞态。现象：ALB 后端健康摘除是秒级到十秒级，15s sleep 通常够；但 Terway 下若 vServer group 静态注册，Pod IP 变化不会自动摘 → 后果：发布期间打到已死 Pod → 改进：确认 ALB Ingress Controller 自动同步后端（`kubectl get events` 看 `UpdateLoadBalancer`）；压测发布场景必测。
- 坑 5｜`/api/status` 作 readiness 会"过早 ready"。现象：该接口不查 DB，Pod 刚起、连接池未 warm 就放流量 → 后果：首批请求偶发失败 → 改进：G8 补 `/readyz`（查 DB+Redis）；临时用 `startupProbe` + 初始延迟 + 预热 Job。

### Day 2 · 任务 28｜新加坡 PH 备 Deployment + Secret（人员B，2 人时，D2 上午 11:00–13:00）

**前置/状态**：任务 24 新加坡 ACK（常态 2 节点，g9i.2xlarge）就绪；任务 22 跨区 DSN 路径已定（§6.1，`sslmode=verify-full`，若走路径 C 则 `verify-ca` 并在文件注释留风险编号）；ACR 双地域同步完成，`${ACR_SG_PREFIX}:<git-sha>` 与主站**同 SHA**；**两地域 `SESSION_SECRET` 必须一致（KMS 同源），轮换 SOP 强制双 region 同步**。

**操作步骤（CLI-first）**：

1. `kubectl --context sg apply -f standby.yaml`，备站 Deployment 常态 **2 副本**（源文件口径）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-api-ph-standby, namespace: new-api, annotations: {config-version: "1"}}
spec:
  replicas: 2
  strategy: {type: RollingUpdate, rollingUpdate: {maxUnavailable: 0, maxSurge: 1}}
  selector: {matchLabels: {app: new-api, site: ph, track: standby}}
  template:
    metadata:
      labels: {app: new-api, project: new-api, site: ph, track: standby, env: prod}
    spec:
      serviceAccountName: new-api-app
      topologySpreadConstraints:
      - {maxSkew: 1, topologyKey: topology.kubernetes.io/zone, whenUnsatisfiable: DoNotSchedule,
         labelSelector: {matchLabels: {app: new-api}}}
      terminationGracePeriodSeconds: 45
      containers:
      - name: new-api
        image: ${ACR_SG_PREFIX}:<git-sha>       # 与主站同一 SHA，SG VPC 域名拉取
        ports: [{containerPort: 3000}]
        env:
        - {name: NODE_TYPE, value: "slave"}     # 红线：备地域固定 slave
        - {name: SQL_MAX_OPEN_CONNS, value: "150"}
        envFrom: [{configMapRef: {name: new-api-config}}]
        readinessProbe: {httpGet: {path: /api/status, port: 3000}, initialDelaySeconds: 10, periodSeconds: 5, timeoutSeconds: 3, failureThreshold: 3}
        livenessProbe:  {httpGet: {path: /api/status, port: 3000}, periodSeconds: 15, timeoutSeconds: 5, failureThreshold: 5, initialDelaySeconds: 40}
        lifecycle: {preStop: {exec: {command: ["sh","-c","sleep 15"]}}}
        resources: {requests: {cpu: "2", memory: 4Gi}, limits: {cpu: "4", memory: 8Gi}}
```

2. `ExternalSecret` 在新加坡另建一份（键同名），`SQL_DSN` 指向**马尼拉 RDS 公网串**（`${SG_SQL_DSN_PLACEHOLDER}`）+ `sslmode=verify-full`；`SESSION_SECRET` 与主站引用同一 KMS 凭据：

```bash
kubectl --context sg apply -f external-secret-sg.yaml
kubectl --context sg get externalsecret new-api-secret -o jsonpath='{.status.conditions[*].reason}'
# 期望：Ready
```

3. 备站 Service（供任务 25 Ingress 后端）：`type: ClusterIP`，selector `{app: new-api, site: ph, track: standby}`，port 80 → 3000。

**验证方法**：

```bash
# V1 副本分布
kubectl --context sg -n new-api get pods -l app=new-api -o wide
# 期望：2 副本分属 1a/1b 两可用区
# V2 备地域只读不写：不能建表（权限已由 §5.5 强制）
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'psql "$SQL_DSN" -c "create table _sg_probe(id int)"'
# 期望：permission denied
# V3 跨区链路与连接健康
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c \
  'psql "$SQL_DSN" -Atc "select count(*), max(state) from pg_stat_activity where usename='"'"'newapi_sg'"'"'"'
# 期望：连接数 ≤ 150 × 2 = 300（含池化后实际值）
# V4 会话互通（SESSION_SECRET 一致性的真实验收）：主站登录 token 直接打备站接口
curl -s -H "Authorization: Bearer ${MNL_TOKEN_PLACEHOLDER}" https://<SG_ALB_DNS>/v1/dashboard/billing/subscription | jq -e '.success'
# 期望：true
```

**不通过时修复**：
- Pod 起来但 readiness 不过 → 诊断：跨区 DSN 握手失败（TLS/白名单）→ 修复：回 §6.1 V1–V3 定位，不要先怀疑应用。
- V4 返回 401 → 诊断：两集群 `SESSION_SECRET` 不同 → 修复：统一 KMS 源，改后两侧 `kubectl rollout restart`。
- 频繁重启（`Liveness probe failed: timeout`）→ 诊断：PG 慢时 `/api/status` 也慢 → 修复：加大 `timeoutSeconds`/`failureThreshold`；根治要补 `/healthz`（不查库），即 G8。
- 备站把表结构改了 → 诊断：`NODE_TYPE` 非 slave（§6.2 坑 1）→ 修复：立刻回滚 + 数据核对；这是最高优先级修复项。

**坑**：
- 坑 1｜镜像 tag 用 `latest`。现象：接管时新加坡跑与主站不同代码 → 后果：schema 不一致 → 全站 SQL 错 → 改进：**两集群必须同 SHA**，CI 双推（§4.6 ACR 双地域同步），GitOps pin SHA。
- 坑 2｜`topologySpread` 用默认 `ScheduleAnyway`。现象：2 副本落在同一可用区 → 后果：可用区故障备站全灭 → 改进：用 `DoNotSchedule`（已在 manifest），§12 以"两可用区各 1 副本"为验收项。
- 坑 3｜liveness 绑定重依赖 DB 的探针。现象：主库抖动 → 后果：全 Pod 被 kill → 重启风暴（K8s 经典事故）→ 改进：liveness 用纯进程存活探针；G8 未落地前 `failureThreshold: 5` + `timeoutSeconds: 5` 保底，§13 预案写"主库故障时先关 liveness 自动重启"。
- 坑 4｜`preStop sleep 15` 与 `terminationGracePeriodSeconds: 45` 的关系。现象：15s 只是给 endpoint 摘除传播留时间 → 后果：Go 侧 SIGTERM 处理不当时 SSE 被硬切 → 改进：new-api 有 graceful shutdown，但 SESSION/SSE 的 drain 时长必须 < grace period。
- 坑 5｜把 `new-api-ph-standby` 挂进主站 ALB 后端。现象：常态流量跨区走马尼拉→新加坡→马尼拉 RDS → 后果：延迟翻倍且成本上升 → 改进：备站只接 **GTM 备地址池**（新加坡 ALB），常态零流量。

### Day 2 · 任务 25｜新加坡 ALB + Service/Ingress（PH 备）（人员A，1.5 人时，D2 上午 11:00–12:30）

**前置/状态**：任务 24 SG 集群就绪且已装 `alb-ingress-controller`；`vsw-sg-pub-a`（10.1.0.0/24, 1a）/`vsw-sg-pub-b`（10.1.1.0/24, 1b）已建；任务 28 备站 Deployment/Service 已就绪；SG 侧证书与主站同源（`${CERT_ID_SG}`）。

**操作步骤（CLI-first）**：

1. SG 侧 AlbConfig 与马尼拉**同构**（`alb-newapi-sg`，两 AZ 交换机）；超时参数与任务 19 同源：`idleTimeout: 60`、`requestTimeout: 600`（方案原口径 180s，ALB 硬上限 600s，P0-5），差别只在**常态不接任何公网 DNS**，只用 ALB 的 DNS 名称做内部验收：

```bash
kubectl --context sg apply -f albconfig-sg.yaml
kubectl --context sg get albconfig sg-alb -o jsonpath='{.status.loadBalancer.dnsname}{"\n"}'
# 期望：sg ALB DNS 名称（不进公网解析）
```

2. SG 侧 IngressClass（两集群各自独立，都要建）+ 备站 Ingress：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: new-api-ph-standby
  namespace: new-api
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: "/api/status"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  ingressClassName: alb
  rules:
  - host: sg-standby.internal.likha.hk      # 仅用于 SNI 路由与验收，不上公网
    http:
      paths: [{path: /, pathType: Prefix, backend: {service: {name: new-api-ph-standby, port: {number: 80}}}}]
```

**验证方法**：

```bash
curl -sS --resolve sg-standby.internal.likha.hk:443:${SG_ALB_VIP} \
  https://sg-standby.internal.likha.hk/api/status | jq -e '.success'
# 期望：true
# 主站 token 打备站业务接口（SESSION_SECRET 一致性复验，§7.4 V4）
curl -s -H "Authorization: Bearer ${MNL_TOKEN_PLACEHOLDER}" --resolve sg-standby.internal.likha.hk:443:${SG_ALB_VIP} \
  https://sg-standby.internal.likha.hk/v1/dashboard/billing/subscription | jq -e '.success'
# 期望：true
aliyun alb GetListenerAttribute --ListenerId ${SG_HTTPS_LISTENER_ID} --region ap-southeast-1 | jq '{IdleTimeout,RequestTimeout}'
# 期望：{"IdleTimeout":60,"RequestTimeout":600}
```

**不通过时修复**：
- `IngressClass is invalid` → 诊断：SG 集群未装 `alb-ingress-controller` 或未建 `IngressClass alb` → 修复：两集群各自独立安装/创建，逐一核对 `kubectl --context sg get ingressclass alb`。
- 健康检查全不绿 → 诊断：同任务 19 的 SG 侧 `sg-sg-app` 入向 3000 放行问题 → 修复：对照 §6.3 修复表放行 ALB→Pod 网段（`10.1.0.0/24,10.1.1.0/24`）。

**坑**：
- 坑 1｜把备站 Ingress host 写成 `www.likha.hk`。现象：GTM 或本地 hosts 指错 → 后果：公网流量进备站，且证书/SNI 与主站混用 → 改进：备站 host 一律加 `.internal.` 段，并在 CI 里禁止 `www.likha.hk` 出现在 SG 集群 manifest。
- 坑 2｜新加坡 ALB 未挂 WAF。现象：接管后无 L7 防护 → 后果：切换即裸奔 → 改进：D6 同步给 SG ALB 接 WAF（云原生模式），规则从主站导出模板保持一致——这也是 §1.1#6"规则差异导致切换后行为不一致"的根治。
- 坑 3｜SG 侧 listener 同样只能由 AlbConfig 独占配置（无 Ingress 注解可用），禁止控制台改，与主站同规。

### Day 2 · 任务 21｜GTM 实例 + 访问池 + 健康探测，先只挂马尼拉（人员A，2 人时，D2 下午 14:00–16:00）

**前置/状态**：任务 19 马尼拉 ALB DNS 名称已取得；任务 25 新加坡 ALB 已建（但**D8 前不入池**）；`www.likha.hk` 托管在云解析 DNS；**P1-8：马尼拉仅 2 个可用区，3AZ 容灾不可行**，本任务按双 AZ 口径配置。

**操作步骤（CLI-first）**：

1. 创建 GTM 实例 `gtm-newapi-ph`。国际站只有**标准版（Standard）/ 旗舰版（Ultimate）**两档（P1-19），购买开通仅控制台可做：【控制台】截图占位 `[图 D2-B-21a｜拍摄对象：全局流量管理 GTM 实例购买/接入域名页；打码：账号 UID、接入域名完整串]`
2. 配置访问池与策略（**池间语义 = 主备 + 自动切换，不是多主池按延迟分摊**）：【控制台】截图占位 `[图 D2-B-21b｜拍摄对象：GTM 地址池列表 + 访问策略（主池 pool-mnl / 备池留空）；打码：接入域名]`
   - 主池 `pool-mnl` = 马尼拉 ALB 的 DNS 名称；备池 `pool-sg` **暂不加入**（备 region 未通过 M4 前不得进池；D8 起**常驻但权重 0**，由"自动切换"或人工切池接管）。
   - **`pool-sg` 绝不能填入主地址池集合**，否则 GTM 按延迟/权重把菲律宾用户分摊到新加坡（RTT 30–45ms，比马尼拉 5–15ms 慢 2–3 倍）。
   - 可用 IP 最小数量阈值 = **1**：马尼拉 ALB 多 AZ 只有 2 个 IP，阈值设 2 会让单 AZ 抖动把主池整池判不可用 → 误切跨区。
   - 健康探测 `GET /api/status`，间隔 15s、超时 5s、连续 3 次失败判定不可用；切换 **TTL = 60s**（`Ttl=60`，越小切换越快但 DNS 查询压力越大）。
3. 云解析 DNS 把业务域名 CNAME 到 GTM 接入域名：

```bash
aliyun alidns AddDomainRecord --DomainName likha.hk --RR www --Type CNAME --Value ${GTM_ACCESS_CNAME}
```

**切换延迟三层模型（别把 60s 当成 RTO，图 10 口径）**：第 1 层 GTM 判定与摘除，最坏约 3×15s 加判定开销合计 ≤60s；第 2 层递归 DNS 缓存，理论 60s、实际 5–30 分钟（取决于运营商与公共 resolver 是否尊重 TTL），不可控，靠 TTL 尽量小 + 客户端 SDK 连接池定期重建 + 应用层 5xx/超时后强制重新解析压住；第 3 层客户端已建立的长连接与 SSE 流不会迁移，直到超时或主动重连——这一层是 RTO 的真实上限。**该口径必须写进 SLA 与演练报告**：对外承诺"切换时间"用第 3 层实测值（D8 接管演练记录），不引用"60 秒"；这也是 §11.2 接管演练"回切后要等稳定 15 分钟"的原因。

**验证方法**：

```bash
# V1 CNAME 链正确
dig +short CNAME www.likha.hk @8.8.8.8 ; dig +short www.likha.hk @8.8.8.8
# 期望：先 GTM 接入域名，再解析到 ALB DNS
# V2 TTL 与预期一致
dig www.likha.hk +noall +answer | awk '{print $2}'    # 期望 60
# V3 健康探测在 GTM 侧全绿（控制台核对），并用真实探测断言
curl -sS https://www.likha.hk/api/status | jq -e '.success == true and .version != ""'
# V4 故障发现（演练窗口内；备池未挂，表现为"探测告警"而非切换——这一步只验"能不能发现"）
kubectl --context mnl -n new-api scale deploy/new-api-stable 0
# 期望：GTM 在 ≤60s 判定异常并告警
kubectl --context mnl -n new-api scale deploy/new-api-stable 4
```

**不通过时修复**：
- `dig` 无 CNAME 链 → 诊断：云解析记录未生效或同名 A 记录冲突 → 修复：删除冲突 A 记录，CNAME 生效前不要开始 V4 演练。
- 探测抖动、频繁误切 → 诊断：GTM 探测源 IP 被 WAF/CC 拦（坑 4）→ 修复：GTM 探测 IP 段加入 WAF 白名单与安全组。
- DB 故障时 GTM 不切换 → 诊断：`/api/status` 不反映 DB → 修复：把"RDS 健康"作为独立告警 + 人工切换预案（§13.4）；G8 后换探测路径（坑 2）。

**坑**：
- 坑 1｜GTM 切换 ≠ 客户端立即切换。现象：运营商/公共 DNS 缓存 5–30 分钟 → 后果：实际 RTO 由 TTL 与递归 DNS 共同决定 → 改进：SLA 口径写清"DNS 层切换 ≤60s，端到端受客户端缓存影响"（§12 排除项）；应用/SDK 支持 443 失败后按域名重解析。
- 坑 2｜健康探测用 `/api/status`，但它不反映 DB。现象：DB 挂了 GTM 仍判健康 → 后果：不切换 → 改进：G8 补 `/readyz` 后**必须把探测路径换成 `/readyz`**；此前用独立 RDS 告警 + 人工预案兜底。
- 坑 3｜备池提前加入但节点 0 副本/未 warm。现象：切换过去 → 后果：直接 5xx，比不切更糟 → 改进：**强制门禁**：M4 接管演练通过（§11.3）才允许备池入池（入池后常驻低权重 0）。
- 坑 4｜GTM 探测源 IP 未加白名单。现象：探测被 WAF/CC 拦 → 后果：误判不可用 → 频繁抖动切换 → 改进：GTM 探测 IP 段加入 WAF 白名单与安全组。

### Day 2 · 任务 53｜配置热更新跨节点收敛验证 SYNC_FREQUENCY=30（人员B，1 人时，D2 下午 14:00–15:00，前移）

**前置/状态**：任务 23（马尼拉 4 副本）与任务 28（新加坡备站）均 Running；`new-api-config` 已设 `SYNC_FREQUENCY=30`（代码默认 60，`common/init.go:110`，方案要求 30）；prod `MEMORY_CACHE_ENABLED=false`；Redis/Tair 连通。

**操作步骤（CLI-first）**：

1. 核对配置已下发：

```bash
kubectl --context mnl -n new-api get cm new-api-config -o jsonpath='{.data.SYNC_FREQUENCY}'; echo    # 期望 30
```

2. 在管理后台（`ops.likha.hk`）改一个可观测配置（如某渠道名称/权重/倍率），断言所有副本（含新加坡备站）在 ≤ SYNC_FREQUENCY 内读到新值：

```bash
for ctx in mnl sg; do
  for p in $(kubectl --context $ctx -n new-api get pods -l app=new-api -o name); do
    echo -n "$ctx/$p : "; kubectl --context $ctx -n new-api exec ${p#pod/} -- sh -c \
      'wget -qO- "http://localhost:3000/api/status" | head -c 200'; echo
  done
done
```

3. 更硬的验证：改**渠道状态**（禁用某渠道）后，连续打该渠道 100 次，统计仍被路由到的比例随时间下降。

**验证方法**：

```bash
# 验收：30s 后各马尼拉副本一致；60s 后新加坡备站一致
# 禁用渠道后路由比例：
# 期望：t<30s 仍有残留命中；t≥30s（马尼拉）与 t≥60s（新加坡）降为 0
```

**不通过时修复**：
- 副本间配置长期不一致 → 诊断：Redis 配置版本号与实际内容不一致（写成功、缓存未失效）→ 修复：验证里必须包含"改价 → 计费结果变化"的端到端断言，而不只是看 `/api/status`；必要时手动失效对应 Redis 键并重启单副本复测。
- 收敛依赖不到 Redis → 诊断：`MEMORY_CACHE_ENABLED=true` 时 Pod 各自为政 → 修复：prod 恒 false（§6.2 坑 2），此条作为 §12 架构证据。

**坑**：
- 坑 1｜`MEMORY_CACHE_ENABLED=true` 时收敛不依赖 Redis。现象：Pod 各自为政 → 后果：跨副本配置永久不一致 → 改进：prod 恒 false；这条要在 §12 里作为**架构证据**。
- 坑 2｜Redis 里配置版本号与实际内容不一致（写成功、缓存未失效）。现象：部分副本永远读到旧渠道配置 → 后果："改价不生效"类投诉 → 改进：验证必须包含"改价 → 计费结果变化"的端到端断言。
- 坑 3｜把 SYNC_FREQUENCY 改成 5s 想"更快收敛"。现象：每副本每 5s 全量拉配置 → 后果：DB QPS × 副本数放大，HPA 扩容后打爆 DB → 改进：不要低于 15s；扩容后重测 DB QPS。

### Day 2 · 任务 45｜staging / perf 环境 + 三数据库矩阵（人员B，3 人时，D2 下午 15:00–18:00，前移，并行度富余时启动）

**前置/状态**：任务 23 完成（复用 prod 镜像 SHA）；主站 RDS PostgreSQL 可建库（`${PG_ADMIN_DSN_PLACEHOLDER}`）；ClickHouse 决策树 A0/A/B/C 已在 D3 前拍板（P0-1，见坑 4）；泳道 B 前 6 卡无阻塞项，并行度富余时才启动本卡。

**操作步骤（CLI-first）**：

1. **落点**：马尼拉主站 ACK 集群的独立命名空间 `new-api-staging` / `new-api-perf`；RDS PostgreSQL 复用主实例的**独立 schema/独立库**（不新建实例，避免与"新加坡不部署数据库"红线冲突，§3.12 G13）：

```bash
kubectl --context mnl create ns new-api-staging new-api-perf
psql "${PG_ADMIN_DSN_PLACEHOLDER}" -c 'CREATE DATABASE newapi_staging TEMPLATE newapi_owner_dev OWNER newapi_staging_app;'
psql "${PG_ADMIN_DSN_PLACEHOLDER}" -c 'CREATE DATABASE newapi_perf    TEMPLATE newapi_owner_dev OWNER newapi_perf_app;'
```

   用**空模板 + 首启 AutoMigrate 建表**，而不是 `TEMPLATE newapi`（拷生产结构会把生产数据一起带来）。

2. 三数据库矩阵（AGENTS.md 要求 SQLite/MySQL >= 5.7.8/PostgreSQL >= 9.6 三库同时可用并验证；new-api 主库不支持 ClickHouse，`model/main.go:145`）：

| 组合 | SQLite | MySQL 8 | PostgreSQL 15 | ClickHouse（仅 `LOG_SQL_DSN`） |
| --- | --- | --- | --- | --- |
| 目的 | 单文件默认路径 | 兼容老部署 | **本次生产** | 日志库 |
| 实例 | Pod 内 emptyDir | 复用 RDS MySQL（临时）或 ACK 内 `bitnami/mysql` | 主站 RDS `newapi_perf` | 见 §4.5 决策树 |
| 用例 | 安装/升级 | 全回归 | 全回归 + 压测 | 写日志 + TTL + 降级 |

3. staging 部署（复制任务 23 manifest，改 namespace/名称）；**staging 的 `SESSION_SECRET` 必须与 prod 不同**（见坑 1）；perf 环境用 2×`g9i.xlarge` 独立节点池（`taint: dedicated=perf:NoSchedule`），压测流量不污染 prod：

```bash
kubectl --context mnl apply -n new-api-staging -f staging.yaml
kubectl --context mnl apply -n new-api-perf -f perf.yaml
```

**验证方法**：

```bash
# V1 三库分别跑同一镜像的冒烟
for db in sqlite mysql pg; do
  kubectl -n new-api-staging run smoke-$db --image=${ACR_MNL_PREFIX}:<git-sha> --env=DB=$db \
    --rm -i --restart=Never -- sh -c 'sleep 5; wget -qO- http://localhost:3000/api/status'
done
# 期望：三份 JSON 都含 "success":true 且 "version" 与镜像 tag 一致
# V2 压测基线
hey -z 60s -c 200 -m POST -H "Authorization: Bearer ${TOKEN_PLACEHOLDER}" -D body.json https://www.likha.hk/v1/chat/completions
# 记录 p50/p95/p99、错误率、上游 429 次数
# V3 环境隔离
kubectl -n new-api-staging get deploy -o jsonpath='{..image}' | tr ' ' '\n' | sort -u
# 期望：与 prod 同一 SHA，不出现 latest
```

**不通过时修复**：
- staging Pod readiness 不过 → 诊断：跨库 DSN/权限错误（`newapi_staging_app` 无建库权限但 AutoMigrate 需要 DDL）→ 修复：给 staging/perf 专用账号授予各自库的 owner 权限；prod 账号权限保持不变。
- V1 SQLite 冒烟失败 → 诊断：CGO/镜像内 SQLite 驱动缺失 → 修复：回归 CI 三库并行必跑（坑 3），修镜像后重测。
- V2 压测打满主库连接 → 诊断：`SQL_DSN` 指错库 → 修复：见坑 2 核对流程。

**坑**：
- 坑 1｜staging 用生产 `SESSION_SECRET`。现象：staging 里签的 token → 后果：在生产可用（越权/额度盗用）→ 改进：**必须不同**；但两个地域的 prod 之间必须相同（§6.2 坑 3）——两者不要混淆。
- 坑 2｜perf 压测打生产 RDS。现象：压测把主库连接打满 → 后果：直接影响 SLA → 改进：压测前核对 `SQL_DSN` 的 dbname 是 `newapi_perf`；用 `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1` 实时看连接来源。
- 坑 3｜SQLite 矩阵被跳过。现象：一次依赖升级破坏 SQLite 路径 → 后果：社区版用户安装失败（回归风险）→ 改进：CI 里三库并行必跑，SQLite 用例可只跑冒烟。
- 坑 4｜ClickHouse 决策未定就排矩阵（P0-1）。现象：矩阵第四列空转 → 后果：D4 卡住 → 改进：§4.5 决策树 A0/A/B/C 必须 D3 前拍板，本表按选定方案填。

### Day 2 · 泳道 B 出口检查清单

- [ ] 马尼拉 ALB：双 AZ（6a+6b）绑定、`IdleTimeout=60`/`RequestTimeout=600`、TLS1.2 strict + 1.3、HTTP→HTTPS 301、健康检查 `/api/status` 全绿（任务 19 V1–V5）。
- [ ] stable：4 副本 6a/6b 各 ≥2、PDB `minAvailable: 3`、HPA 4→16 可触发、rollout 零 5xx（任务 23 V1–V4）。
- [ ] 新加坡备站：2 副本双 AZ、同 SHA、`NODE_TYPE=slave`、V2 建表被拒、V4 主站 token 备站可用（SESSION_SECRET 一致性验收）。
- [ ] 新加坡 ALB：仅 `sg-standby.internal.likha.hk` 内部验收，公网 DNS 零挂载。
- [ ] GTM：`Ttl=60`、`www.likha.hk` CNAME 链正确、主池仅 `pool-mnl`、备池未入池、可用 IP 阈值 = 1、V4 故障发现 ≤60s（告警不切换）。
- [ ] SYNC_FREQUENCY=30：马尼拉副本 30s 收敛、新加坡备站 60s 收敛、"改价→计费"端到端断言通过。
- [ ] staging/perf：三库冒烟通过、perf 独立节点池带 taint、staging `SESSION_SECRET` 与 prod 不同。
- [ ] G8 缺口登记：`/healthz`、`/readyz`、`/metrics` 未注册（`router/api-router.go:26` 仅 `/api/status`），ALB/GTM/readiness 三处探测路径切换全部挂 G8 跟踪项。
- [ ] 泳道 A 交接口：D3 GTM 备池入池以 M4 接管演练通过为强制门禁；D6 前 SG ALB 接 WAF、ALB 访问日志 SLS 回归。
