## 6. 阶段 D：D3 落地（任务 15、17、19、24、50、56）

> D3 的六件事互相独立度很高：**人员B** 走数据线（#15 → #17 → #50），**人员A** 走接入与备地域线（#19 → #24 → #56）。全部落在 S5–S6 两个时段（各 4 人时上限）。

### 6.1 任务 15｜开启 RDS 公网地址并把白名单收死（数据线的门槛）

这一步是整个方案里**最容易做成"看似安全、实则裸奔"**的一步：公网地址一开，默认白名单组若是 `default` 且被人填成 `127.0.0.1`，等于"任何人都连不上"；若填成 `0.0.0.0/0`，等于"任何人都能连"。两种都是错的，且都不会有任何告警。

#### 操作步骤

**Step 1 — 申请公网地址**

控制台 `ApsaraDB RDS → Instances → (rds-mnl-newapi) → Database Connection`，点 **Apply for Public Endpoint**。 CLI 等价：

```bash
aliyun rds AllocateInstancePublicConnection \
  --RegionId ap-southeast-6 \
  --DBInstanceId ${RDS_MNL_ID} \
  --ConnectionStringPrefix ${RDS_MNL_ID}pub \
  --Port 5432
```

国际站公网地址后缀通常是 `.pg.rds.aliyuncs.com`（PG 高可用版），记下**完整地址**：

```bash
aliyun rds DescribeDBInstanceNetInfo --DBInstanceId ${RDS_MNL_ID} \
  | jq -r '.DBInstanceNetInfos.DBInstanceNetInfo[] | [.IPType,.ConnectionString,.Port] | @tsv'
# 期望两行：Inner / Public
```

**Step 2 — 先做 TLS 证书的地址绑定决策（P0-4，务必在开 SSL 之前定）**

RDS 的服务器证书 **CN/SAN 只绑定"开启 SSL 时所选的那个连接地址"**。所以顺序必须是：*先决定新加坡用哪个地址连，再开 SSL*。

```bash
aliyun rds DescribeDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} | jq '{ssl_enabled:.SSLEnabled,conn_str:.ConnectionString,ca:.CAType}'
```

**图 9｜跨区 TLS 路径决策（P0-4，决定 M4 能否过）**

```mermaid
flowchart TD
  Q0["先回答 谁来连马尼拉 RDS<br/>新加坡 ACK 里的备 region 应用"] --> Q1{"开 SSL 时<br/>ConnectionString 能选公网地址吗"}
  Q1 -->|能| PA["路径 A 推荐<br/>证书绑公网串 新加坡 verify-full 直连公网"]
  Q1 -->|已绑到内网串| Q2{"能否重签<br/>换绑到公网串"}
  Q2 -->|能| PA
  Q2 -->|不能或不想承担跨区专线费| PB["路径 B 走 CEN<br/>新加坡用内网串 verify-full"]
  Q2 -->|应急且来不及| PC["路径 C 降级 verify-ca<br/>只验签发链 不验主机名"]
  PA --> V["握手成功<br/>可作为 M4 容灾证据"]
  PB --> V
  PC --> RISK["残余风险书面记录<br/>架构负责人签字 否则任务 38 挂"]
  PB --> COST["新增 CEN 实例与跨区带宽费<br/>需财务确认 工期 +0.5 天"]
  V --> LAYER{"链路中是否有 PgBouncer 或 Database Proxy"}
  LAYER -->|有| TW["分层策略<br/>应用到池 verify-ca 池到 RDS verify-full<br/>证书由 RDS 内网串出具"]
  LAYER -->|无| DONE["单段 verify-full 即可"]
```

> **失败长这样**：`server certificate for "pgm-xxx.pg.rds.aliyuncs.com" does not match host name "pgm-xxxo..."`。根因永远是同一句话——**证书 CN/SAN 绑的是"开 SSL 那一刻选的那个连接地址"**。所以顺序不能反：先定地址，再开 SSL。一旦绑错，只能关 SSL 重开或走路径 B/C。

三条可选路径（按推荐度）：

| 路径 | 做法 | 适用 | 代价 |
| --- | --- | --- | --- |
| **A（推荐）** | 开 SSL 时 `ConnectionString` 选**公网地址**；新加坡侧 `sslmode=verify-full` 直连公网 | 只有新加坡一个备 region | 内网地址走同一条连接串的应用需要额外配一份证书；证书与地址绑定后**换地址必须重签** |
| B | 走 **CEN（云企业网）** 打通马尼拉 VPC ↔ 新加坡 VPC，新加坡用**内网地址** + verify-full | 网络团队接受跨区专线成本 | 引入 CEN 实例+跨区带宽费（impl_deploy.md 7.10 未计入），需财务确认；工期 +0.5 天 |
| C | 新加坡侧 `sslmode=verify-ca`（只验签发链、不验主机名） | 应急 | **必须书面记录残余风险并让架构负责人签字**，否则安全核查（任务 38）会挂 |

开 SSL（以路径 A 为例，务必选公网串）：

```bash
aliyun rds ModifyDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} \
  --ConnectionString ${RDS_MNL_PUB} --Port 5432 --SSLEnabled 1 --CaEnabled 0
# 换证书/换地址用同一命令重复调用（CARequired 参数在部分版本为必填，报参数错就补 --CaEnabled 0 --RequireUpdate yes）
aliyun rds DescribeDBInstanceSSL --DBInstanceId ${RDS_MNL_ID} | jq '.SSLEnabled'   # 期望 1
```

**Step 3 — 白名单：只放新加坡 4 个 NAT EIP**

```bash
# 3.1 建独立白名单组，名字与用途绑定，禁止复用 default
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName sg_standby_eip \
  --SecurityIps "${SG_EIP_01}/32,${SG_EIP_02}/32,${SG_EIP_03}/32,${SG_EIP_04}/32" \
  --WhitelistNetworkType MIX

# 3.2 把 default 组显式设为不可命中（不是 127.0.0.1 那种"看起来安全"）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName default --SecurityIps "127.0.0.1"

# 3.3 主站内网侧使用 SG 绑定的白名单组（ACK Pod 用 vSwitch app 网段）
aliyun rds ModifySecurityIps --DBInstanceId ${RDS_MNL_ID} \
  --DBInstanceIPArrayName mnl_vpc --SecurityIps "10.0.32.0/20,10.0.48.0/20,10.0.64.0/20,10.0.80.0/20"
```

**Step 4 — 强制 TLS 只允许（PG 侧参数）**

RDS PG 可通过参数 `rds_force_transitions_readonly`（无关）；这里要的是 **`log_connections` + 拒绝明文**。国际站 RDS PG 可控参数里勾选：

```bash
aliyun rds DescribeParameters --DBInstanceId ${RDS_MNL_ID} \
  | grep -Ei "ssl|force" 
# 若存在 requires_ssl / rds_enable_ssl 类可改参数，设为 1；不可改则记录为"仅靠客户端 sslmode + 白名单"两层控制
```

#### 验证方法

```bash
# V1 公网 TLS 握手（在 NEW加坡任一集群节点或同 region ECS 上执行）
openssl s_client -connect ${RDS_MNL_PUB}:5432 -starttls postgres -servername ${RDS_MNL_PUB} 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# 期望：CN 或 SAN 中【包含】${RDS_MNL_PUB}

# V2 白名单正例：新加坡 NAT 出口能连
psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=verify-full sslrootcert=./apsaradb-ca.pem" \
  -c "select current_setting('server_version'), inet_server_addr(), now();"

# V3 白名单反例：非白名单 IP 必须被丢
timeout 8 psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=disable" -c "select 1"
# 期望：timeout / connection refused，绝不能返回 1 行结果

# V4 明文必须被拒（若第 4 步生效）
psql "host=${RDS_MNL_PUB} port=5432 dbname=postgres user=newapi_sg sslmode=disable" -c "select 1"
# 期望：FATAL: no pg_hba.conf entry for host ... no SSL
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| `server certificate for "pgm-xxx.pg.rds.aliyuncs.com" does not match host name "pgm-xxxpub..."` | SSL 开在内网串上（P0-4 命中） | 用 Step 2 路径 A：`ModifyDBInstanceSSL --ConnectionString <公网串>` 重签，再 `DescribeDBInstanceSSL` 复核；无法改则临时 `verify-ca` 并走 C 的签字流程 |
| `timeout` 且 `nc -vz` 也不通 | NAT SNAT 条目未覆盖新 Pod 网段，或 EIP 不是登记的那 4 个 | 在**新加坡节点上**跑 `for i in 1 2 3 4 5; do curl -s https://ifconfig.me; echo; done`，把真实出口 IP 补进白名单组 |
| 连上但 `inet_server_addr()` 返回的内网地址 | 你连的其实是 VPC 内另一条链路 | 说明走的是 CEN/对等，属好事；但要在验收记录里写清"实际路径"，否则 M4 证据链口径不一致 |
| 白名单改了 10 分钟仍不生效 | 控制台改的是**只读实例**的白名单 | 主实例 `DescribeDBInstances` 里核对 `DBInstanceId`，只读实例白名单不继承 |

#### 坑与注意事项

- **坑 1｜"127.0.0.1 = 禁止一切"是错觉。** 现象：安全组/白名单填 `127.0.0.1` 后主站应用连不上。后果：D3–D4 排障方向全错，误以为 RDS 故障。改进：白名单必须**按用途分命名组**（`mnl_vpc` / `sg_standby_eip`），每组都有明确 owner；在 §12 验收里要求"贴白名单组截图，而不是贴 default 组"。
- **坑 2｜NAT EIP 会被换。** 现象：某天开始新加坡突然连不上主库。后果：备 region 静默失去接管能力，直到真正切换时才发现（RTO 直接爆）。改进：§11.3 的**备 region → 马尼拉 RDS TCP 拨测**必须绑定"连接失败率"告警；EIP 解绑/重绑列入变更审批（§8.5 运维访问面）。
- **坑 3｜`AllocateInstancePublicConnection` 的地址串一旦释放不能再拿回。** 后果：应用配置、RDS 证书、上游白名单全要重配。改进：**永不释放公网串**；不需要外网访问时把白名单清空即可，而不是释放地址。
- **坑 4｜把公网串写进 Git 的 ConfigMap 明文。** 后果：Git 历史不可撤销，安全核查（任务 38）直接判不合格。改进：DSN 只进 **KMS 凭据管家**，见 §6.2。
- **坑 5｜白名单加了但没加 `/32`。** 后果：填 `47.x.x.x` 被规范成 `47.x.x.0/24`，意外放行整段。改进：一律显式 `/32`，并用 `DescribeDBInstanceIPArrayList` 复核 CIDR 掩码。

### 6.2 任务 17｜Namespace / ConfigMap / Secret（KMS + RRSA + ExternalSecret）

这是"密钥不落 Git"这条红线真正落地的地方，也是后面所有 Deployment 的公共前提。

#### 操作步骤

**Step 1 — Namespace 与资源配额**

```yaml
# k8s/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: new-api
  labels: {project: new-api, site: ph-mnl, env: prod}
---
apiVersion: v1
kind: ResourceQuota
metadata: {name: new-api-quota, namespace: new-api}
spec:
  hard: {requests.cpu: "48", requests.memory: 96Gi, limits.cpu: "64", limits.memory: 128Gi}
```

配额数字来自 §2.1 基线（4 副本 × request 2C/4G，留 4 倍 HPA 余量）。**注意 ResourceQuota 超了不会报错给 Deployment，只会让 Pod 卡在 `Forbidden: exceeded quota`**，所以先设后部署。

**Step 2 — ConfigMap（非敏感运行参数）**

```yaml
# k8s/base/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: new-api-config, namespace: new-api}
data:
  TZ: "Asia/Manila"
  NODE_TYPE: "slave"            # ⚠ 见坑 1，绝不能留空（master Deployment 单独覆盖）
  MEMORY_CACHE_ENABLED: "false" # prod 硬约束：多副本本地缓存会导致额度/配置不一致
  SYNC_FREQUENCY: "30"          # 方案要求 30；代码默认 60（common/init.go:110）必须显式覆盖
  SQL_MAX_OPEN_CONNS: "150"     # 与 §5.6 连接数预算一致；代码默认 1000（model/main.go:212）
  LOG_SQL_MAX_OPEN_CONNS: "50"
  GLOBAL_API_RATE_LIMIT: "360"  # 与代码默认一致，显式写出避免误解
  GLOBAL_API_RATE_LIMIT_DURATION: "180"
  SESSION_MAX_AGE: "2592000"
  ERROR_LOG_LEVEL: "warn"
  LOG_DIR: "/app/logs"
```

**Step 3 — ExternalSecret（KMS 凭据管家 → Secret）**

前置：§5.7 已建 RRSA 角色 + ACK 装了 `ack-secret-manager` / CSI Secrets Store Provider。

```yaml
apiVersion: alibabacloud.com/v1alpha1
kind: ExternalSecret
metadata: {name: new-api-secret, namespace: new-api}
spec:
  refreshInterval: 1h
  smSecret:
    name: new-api-secret          # 生成的 K8s Secret 名
    des:
      nameTemplate: "new-api-secret"
    fetch:
    - key: aone/newapi/prod/SQL_DSN
    - key: aone/newapi/prod/LOG_SQL_DSN
    - key: aone/newapi/prod/REDIS_CONN_STRING
    - key: aone/newapi/prod/SESSION_SECRET
    - key: aone/newapi/prod/SESSION_SECRET_OLD   # 双密钥轮换用，见 §9.9
    - key: aone/newapi/prod/PAYMENT_PRIVATE_KEY
---
apiVersion: secretsstore.csi.alibabacloud.com/v1alpha1
kind: SecretProviderClass    # 仅当走 CSI 直挂模式时使用；与 ExternalSecret 二选一
```

**Step 4 — Pod 侧引用**

```yaml
envFrom:
- configMapRef: {name: new-api-config}
env:
- name: SQL_DSN
  valueFrom: {secretKeyRef: {name: new-api-secret, key: SQL_DSN}}
serviceAccountName: new-api-app     # 与 RRSA 角色绑定的 SA
```

**Step 5 — 应用（新加坡集群同构，仅 `site`/`NODE_TYPE`/DSN 不同）**

```bash
kubectl apply -f k8s/base/namespace.yaml -f k8s/base/configmap.yaml -f k8s/base/externalsecret.yaml
kubectl -n new-api get externalsecret new-api-secret \
  -o jsonpath='{.status.conditions[*].type}{"\n"}'   # 期望 True / Ready
```

#### 验证方法

```bash
# V1 Secret 已生成且键齐全
kubectl -n new-api get secret new-api-secret \
  -o jsonpath='{.data}' | jq 'keys'
# 期望：SQL_DSN / LOG_SQL_DSN / REDIS_CONN_STRING / SESSION_SECRET / SESSION_SECRET_OLD / PAYMENT_PRIVATE_KEY

# V2 密钥确实来自 KMS（改 KMS 值 → 1 个 refresh 周期内 K8s 侧跟随）
#   控制台改 aone/newapi/prod/SESSION_SECRET 末尾加 "-t"，等 60s：
kubectl -n new-api get secret new-api-secret -o jsonpath='{.data.SESSION_SECRET}' | base64 -d
# 期望：以 -t 结尾（验完改回）

# V3 Pod 内环境变量正确且无明文外泄
kubectl -n new-api exec deploy/new-api-stable -- env | grep -Ei "NODE_TYPE|MEMORY_CACHE|SYNC_FREQ|SQL_MAX" | sort
# 期望与 ConfigMap 完全一致

# V4 RRSA 生效（Pod 内能拿到 STS）
kubectl -n new-api exec deploy/new-api-stable -- sh -c \
  'ls -l "$ALIBABA_CLOUD_OIDC_TOKEN_FILE" && env | grep ALIBABA_CLOUD_ROLE'
# 期望：token 文件存在、role arn 非空

# V5 Git 无密钥扫描（任务 38 的前置）
git log -p --all | grep -Eci "LTAI[0-9A-Za-z]{16}|-----BEGIN (RSA|EC) PRIVATE KEY-----"
# 期望 0
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| ExternalSecret 一直 `Ready=False`，事件里 `Forbidden` | RRSA 角色缺 `kms:GetSecretValue`，或 Resource 未包含该 Secret 名 | 补策略到具体 Secret ARN（不要给 `*`）；确认 SA annotation `pod-identity.alibabacloud.com/role-name` |
| Secret 生成了但 Pod 里读到旧值 | Pod 不感知 Secret 轮转（env 引用只在启动时注入） | 加 `checksum/config` annotation 触发滚动，或 `kubectl -n new-api rollout restart deploy/new-api-stable` |
| `exceeded quota` 卡 Pending | ResourceQuota 与 request/limit 口径不一致 | 按 §2.1 重算；limit 也要计入 quota，不要只算 request |
| V2 不跟随 | `refreshInterval` 太长或 KMS 凭据被托管到其他实例 | 调成 5m 验证；确认 `SecretsManager` 实例与集群同 region |

#### 坑与注意事项

- **坑 1｜`NODE_TYPE` 留空 = 全集群变成 master（重大隐患）。** 代码事实：`common/init.go:89` 是 `IsMasterNode = os.Getenv("NODE_TYPE") != "slave"` —— **字符串不等判断**，空值、`Slave`、`SLAVE`、带空格全部被判定为 master。后果：stable 副本会并发改表结构 + 并跑 master-only 定时任务，出现重复扣费/重复对账/迁移死锁，属**资金级事故**。改进：① ConfigMap 里**显式写死** `NODE_TYPE: "slave"`；② 加 OPA/Kyverno 或 `kubectl --dry-run` CI 规则：`env.NODE_TYPE` 缺失或 != "slave" 则拒绝合入；③ §11.6 上线检查表逐条打勾。
- **坑 2｜`MEMORY_CACHE_ENABLED=true` 留到多副本环境。** 后果：额度、渠道权重、系统配置在多 Pod 间不一致，用户看到"余额随机跳变"。改进：prod 恒为 `false`（impl_deploy.md 已列），只在单副本 staging 允许 true。
- **坑 3｜`SESSION_SECRET` 两集群不一致。** 后果：GTM 切到新加坡后**全员登录态失效 + 已签发令牌 401**，接管等于雪崩。改进：两集群必须指向**同一 KMS Secret Key**（不是"复制同样的值"），并在 §9.9 演练双密钥轮换。
- **坑 4｜把 ConfigMap 改了以为生效。** 后果：`SYNC_FREQUENCY` 仍是 60，配置跨节点收敛变慢，D7 任务 53 验证不过。改进：**ConfigMap/Secret 任何变更 → `rollout restart`**，写进 Runbook。
- **坑 5｜KMS 凭据版本与 `SESSION_SECRET_OLD` 混用。** 后果：轮换窗口内新旧密钥都失效。改进：轮换时只把"旧值"复制到 `_OLD` 键，新值写主键（见 §9.9）。
- **坑 6｜国际站 KMS 实例是 region 级。** 新加坡 Pod 读马尼拉的 Secret 要走公网/跨区，且要单独授权。改进：两 region 各建 KMS 实例，用**同一份 Secret 内容**双写（或只在新加坡存"备 region 需要的键"），并在 §9.5 带宽成本里计入跨区调用次数。

### 6.3 任务 19｜马尼拉 ALB + AlbConfig + 健康检查

#### 操作步骤

**Step 1 — 装组件**（ACK 控制台 → 组件管理 → **ALB Ingress Controller**，版本随集群；确认已选"复用已有 ALB"还是"新建"）。

**Step 2 — AlbConfig CRD**

```yaml
apiVersion: alibabacloud.com/v1
kind: AlbConfig
metadata: {name: mnl-alb}
spec:
  config:
    name: alb-newapi-mnl
    addressType: Internet
    zoneMappings:
    - vSwitchId: ${VSW_MNL_PUB_A}
    - vSwitchId: ${VSW_MNL_PUB_B}
    accessLogConfig:
      logProject: sls-newapi-mnl
      logStore: alb-access
    tags:
    - {key: project, value: new-api}
    - {key: site, value: ph-mnl}
  listeners:
  - port: 80
    protocol: HTTP
    httpDefaultActions:
    - type: Redirect
      redirectConfig: {host: api.likha.com, https: on, port: "443"}
  - port: 443
    protocol: HTTPS
    securityPolicyId: tls_cipher_policy_1_2_strict_with_1_3
    caEnabled: false
    requestTimeout: 600          # ⚠ 方案写 180；硬上限 600，见 P0-5
    idleTimeout: 60
    certificates:
    - CertIdentifier: ${CERT_ID_ALB}
```

```bash
kubectl apply -f albconfig.yaml
kubectl get albconfig mnl-alb -o jsonpath='{.status.loadBalancer.dnsname}{"\n"}'
```

**Step 3 — IngressClass + Ingress**

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata: {name: alb}
spec: {controller: ingress.k8s.alibabacloud/alb}
```

`stable` Service（NodePort 或 Terway ENI 直连模式，ACK 推荐 **Terway + `serviceType: ClusterIP` + 后端走 Pod ENI**）由 §8.4 部署；此处先建 `new-api-master` 不接流量的 Service。

**Step 4 — 健康检查**

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/healthcheck-enabled: "true"
    alb.ingress.kubernetes.io/healthcheck-path: "/api/status"
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "6"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "3"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
    alb.ingress.kubernetes.io/healthcheck-method: "GET"
    alb.ingress.kubernetes.io/healthcheck-httpcode: "http_2xx"
```

> **当前本仓库只有 `GET /api/status` 可用**（`router/api-router.go:26`）。`/healthz`、`/readyz`、`/metrics` **未注册**（P1-20）。G8 未完成前健康检查必须用 `/api/status`；`/readyz` 上线后再切，因为 `/api/status` 不反映 DB 就绪，会把"进程活着但连不上库"的 Pod 判成健康。

#### 验证方法

```bash
# V1 ALB 实例与 AZ 绑定
aliyun alb GetLoadBalancerAttribute --LoadBalancerId ${ALB_MNL_ID} | jq -r '.DNSName, (.ZoneMappings[].ZoneId)'
# 期望：两个 AZ = ap-southeast-6a / 6b

# V2 超时参数真的落到 listener
aliyun alb GetListenerAttribute --ListenerId ${HTTPS_LISTENER_ID} | jq '{IdleTimeout,RequestTimeout}'
# 期望：{"IdleTimeout":60,"RequestTimeout":600}

# V3 TLS 策略
echo | openssl s_client -connect ${ALB_DNS}:443 -servername api.likha.com 2>/dev/null | grep -E "Protocol|Cipher"
# 期望 TLSv1.2/1.3；再用弱版本反例：
echo | openssl s_client -connect ${ALB_DNS}:443 -tls1_1 2>&1 | grep -Ei "alert|error"   # 期望握手失败

# V4 HTTP→HTTPS 跳转
curl -sSI --resolve api.likha.com:80:${ALB_VIP} http://api.likha.com/ | grep -Ei "^HTTP|^location"
# 期望 301 + Location https://api.likha.com/

# V5 健康检查后端全绿
aliyun alb ListServerGroups --ServerGroupNames.1 new-api-stable | jq '.ServerGroups[0].HealthCheck'
aliyun alb GetListenerHealthStatus --ListenerId ${HTTPS_LISTENER_ID} | jq -r '.ListenerHealthStatus[].ServerGroupInfos[].NonnormalServers'  # 期望 []
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| AlbConfig 一直 `Progressing`，事件 `InvalidZoneMapping` | 只填了 1 个 vSwitch，或 vSwitch 所在 AZ 不被 ALB 支持 | ALB **强制 ≥2 AZ**；马尼拉只能 6a+6b，确认两个 pub vSwitch 分属两 AZ |
| Pod 全不健康但 `/api/status` 本地 curl 正常 | 健康检查打到 **NodePort 未开放** / Terway 模式下 SG 未放行 ALB → Pod 网段 | Terway：ALB 走 Pod ENI 直连，需要在 `sg-mnl-app` 放行入向 3000 源为 ALB 所在 vSwitch 网段（`10.0.0.0/24,10.0.1.0/24`） |
| `RequestTimeout` 设 1800 报 `InvalidParameter` | 超上限 | 上限就是 **600**；长任务改异步 + 轮询（见坑 3） |
| 502 且 access log 有记录、上游 0 字节 | Pod 被 SSE 长连接占满 worker | 提高 `GIN` 侧并发（Go 无 worker 概念，实际是 FD/内存），确认 §5.4 nofile=200000 生效 |

#### 坑与注意事项

- **坑 1｜`requestTimeout` 600 是天花板，不是配置项。** 后果：模型回答 >10 分钟的请求必被 ALB 切断，用户看到"回答中途断流"。改进：① 15–20s SSE ping 保活（`idle_timeout` 侧）；② 长任务（批量、视频类）走 `task` 异步接口 + 轮询；③ 在产品文案/合同里写明单请求上限（§12 口径）。
- **坑 2｜idleTimeout 与 SSE 的关系搞反。** `idleTimeout` 是**两包之间**的静默间隔。后果：设 60 却每 20s 才 ping 一次是安全的，但如果上游卡住不吐字，60s 就断。改进：网关 ping 间隔设 **15s**（留 4 倍余量），并在 §11.1 压测里用 `并发 SSE 1500 + 上游静默 45s` 场景实测。
- **坑 3｜ALB 的 TLS 证书与 SNI。** 未配 `securityPolicyId` 时默认可协商 TLS1.0（部分老客户端）→ 安全核查判不合格。改进：显式 `tls_cipher_policy_1_2_strict_with_1_3`；D6 任务 40 再复核 SNI 域名校验。
- **坑 4｜复用已有 ALB 时 AlbConfig 会把 listener 覆盖。** 后果：手工在控制台加的转发规则被 GitOps apply 抹掉。改进：**ALB 只能通过 AlbConfig/Ingress 管理**，禁止控制台改；ActionTrail 里加"谁改了 ALB"告警（§3.3）。
- **坑 5｜`accessLogConfig` 引用不存在的 SLS Project。** 后果：ALB 创建成功但日志静默丢失，事后无证据。改进：先建 Project/Logstore（§9.2）再配；或先不配、D6 补上并回归 V1 检查。

### 6.4 任务 24｜新加坡 ACK 集群 + 常态 2 节点节点池

#### 操作步骤

**Step 1 — 集群（与马尼拉同构，差异项只有 region 与网段）**

```bash
cat <<'EOF' > create-cluster-sg.json
{"name":"ack-newapi-sg","cluster_spec":"ack.pro.small","region_id":"ap-southeast-1","kubernetes_version":"1.35.0-aliyun.1",
 "vpcid":"${VPC_SG_ID}","vswitch_ids":["${VSW_SG_APP_A}","${VSW_SG_APP_B}"],
 "container_cidr":"10.1.128.0/17","service_cidr":"10.1.0.0/20",
 "ip_stack":"ipv4","network":"terway-eniip","node_cidr_mask":"25",
 "snat_entry":false,"endpoint_public_access":false,"deletion_protection":true,
 "timezone":"Asia/Singapore","proxy_mode":"ipvs",
 "addons":[{"name":"terway-eniip"},{"name":"csi-plugin"},{"name":"csi-provisioner"},
           {"name":"ack-pod-identity-webhook"},{"name":"alb-ingress-controller"},
           {"name":"managed-coredns"},{"name":"arms-prometheus"},{"name":"logtail-ds"}]}
EOF
envsubst < create-cluster-sg.json > create-cluster-sg.rendered.json   # 替换 ${VPC_SG_ID} 等占位
aliyun cs CreateCluster --header "Content-Type=application/json" --body "$(cat create-cluster-sg.rendered.json)"
```

关键差异说明：`snat_entry:false` —— **新加坡出网必须走已登记的 NAT EIP 池**，让 ACK 自动建 NAT 会产生 4 个白名单外的出口 IP（上游与 RDS 全部拒连）。`endpoint_public_access:false` —— API Server 只留内网端点（任务 46 的运维访问面）。

**Step 2 — 节点池（常态 2 / 自动伸缩 2–12）**

```bash
cat <<'EOF' > nodepool-sg.json
{"nodepool_info":{"name":"np-sg-ph-standby"},
 "scaling_group":{"instance_types":["ecs.g8i.2xlarge","ecs.g8a.2xlarge","ecs.g7.2xlarge"],
   "vswitch_ids":["${VSW_SG_APP_A}","${VSW_SG_APP_B}"],"system_disk_category":"cloud_essd","system_disk_size":100,
   "data_disks":[{"category":"cloud_essd","size":300}],"desired_size":2,"min_size":2,"max_size":12,
   "instance_charge_type":"PostPaid","internet_max_bandwidth_out":0,
   "multi_az_policy":"BALANCE",
   "tags":[{"key":"site","value":"sg"},{"key":"env","value":"prod"}]},
 "kubernetes_config":{"runtime":"containerd","cpu_policy":"none"},
 "auto_scaling":{"enable":true,"health_check_type":"NODE","scale_unsupported":false}}
EOF
envsubst < nodepool-sg.json > nodepool-sg.rendered.json
aliyun cs CreateClusterNodePool --ClusterId ${ACK_SG_ID} --body "$(cat nodepool-sg.rendered.json)"
```

**Step 3 — 与马尼拉的一致性检查（最容易漏的一步）**

新加坡集群的 `SESSION_SECRET` 来源、镜像 tag、`NODE_TYPE=slave`、`site=ph` 标签必须与主站一致 —— 备集群不是"另一套系统"，是同一系统的第二份算力。

#### 验证方法

```bash
# V1 集群与节点
kubectl --context sg get nodes -o wide
# 期望 2 节点 Ready，REGION=ap-southeast-1，AZ 分属两区
kubectl --context sg get cm -n kube-system cluster-info -o jsonpath='{.data.kubernetesVersion}'

# V2 出口 IP 仍在登记池内（核心！）
kubectl --context sg run egress-probe --image=curlimages/curl --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s https://ifconfig.me; echo; done' | sort -u
# 期望：只出现 4 个已提交上游的 SG EIP

# V3 镜像拉取走新加坡 VPC 域名
kubectl --context sg get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' \
  | head -1 | xargs -I{} kubectl --context sg debug node/{} -it --image=busybox -- sh -c \
  'wget -qO- http://registry-vpc.ap-southeast-1.aliyuncs.com/v2/ || echo reachable'

# V4 Terway 未与主站冲突：确认两集群 Service CIDR 不重叠
kubectl --context sg cm -n kube-system get eni-config -o jsonpath='{.data}' | tr ',' '\n' | grep -Ei "cidr|mask"
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| V2 出现陌生 IP | ACK 建了第二个 NAT，或 Pod 走 ECI/公网网卡 | 删掉自动建的 NAT 或把 SNAT 条目指向 `nat-sg-prod`；确认集群创建时 `snat_entry=false` |
| 节点池 `desired_size=2` 但只起 1 台 | 96 vCPU 配额未批复 / 单 AZ 无库存 | §3.4 复核配额；机型列表至少 3 个候选；必要时先 `desired_size=1` 保工期，D5 补 |
| `endpoint_public_access` 想改回 true | 已建集群无法直接开公网端点 | 用 **EIP 绑定 API Server SLB**（`ModifyCluster --api_audience`）或走堡垒机；不要为了图快改 SG 放行 0.0.0.0/0 |
| CNI 装错（选了 flannel） | 创建时 body 写 `network:"flannel"` | **不可热切**，只能重建集群。备集群重建成本低（无状态），立刻重建并记入坑库 |

#### 坑与注意事项

- **坑 1｜`snat_entry:true` 的默认值。** 控制台默认勾选"为 VPC 配置 SNAT"。后果：多出一个未登记的出口 EIP，上游 429/拒连、RDS 白名单失配，且**故障时表现为间歇性失败**，极难定位。改进：创建集群用 CLI body 显式 `false`；CI 里加 `aliyun vpc DescribeNatGateways` 断言"每 region 只有 1 个 NAT"。
- **坑 2｜两集群 SA/KMS/RRSA 角色串用。** 后果：新加坡 Pod 用马尼拉的 RRSA 角色拿不到 Secret（信任策略里的 OIDC provider 是 region+cluster 维）。改进：`ack-pod-identity-webhook` 注入的 `OIDC_PROVIDER_ARN` 必须在 Pod env 里核对（§6.2 V4）。
- **坑 3｜常态 2 副本 + 冷备节点池被误当成"热备"。** 后果：接管时要等节点扩容 + Pod 拉起（90–180s），RTO 从秒级掉到分钟级，M4 验收不过。改进：`desired_size=2` 常备运行、`NODE_TYPE=slave` 且**保持连接池 warm**（§10.7 Tair/DB 预热）；GTM 备地址池只在压测通过后加入（任务 36）。
- **坑 4｜节点标签与污点未统一，导致主备反亲和失效。** 改进：两集群统一标签 `site`/`env`/`track`，`topologySpreadConstraints` 用 `labelKeys: [app]` + `whenUnsatisfiable: DoNotSchedule`（软约束会让 4 副本全挤一个 AZ）。

### 6.5 任务 50｜PITR 备份恢复演练（记录真实 RPO/RTO）

方案把它排在 D3 是对的：**必须在工作负载还没复杂时**测出恢复基线。

#### 操作步骤

1. 确认备份链完整：`DescribeBackupPolicy` 的 `EnableBackupLog=1`、`PreferredBackupTime` 落在业务低谷（马尼拉 UTC+8，本地凌晨 2–4 点 = `18:00Z-20:00Z`）。
2. 在主库写入可追踪哨兵：

```sql
CREATE TABLE IF NOT EXISTS ops_drill_marker (id serial primary key, note text, ts timestamptz default now());
INSERT INTO ops_drill_marker(note) VALUES ('pitr-drill-before');
SELECT pg_switch_wal();   -- 强制归档 WAL，缩短可恢复延迟
```

3. 控制台 **Backup and Restoration → Restore to a new instance**，时间点选 `now()`；规格选最低配（演练用，**成本按小时计，验完立即释放**）。
4. 记录三个时间点：发起恢复 `T0`、新实例可连 `T1`、哨兵数据齐全 `T2`。**RTO = T1-T0**，**数据损失 = 最后一个已归档 WAL 与故障点之差**（本次演练理论上 0）。
5. 校验：

```sql
-- 新实例
SELECT count(*) FROM users;                       -- 与主库对比
SELECT max(ts) FROM ops_drill_marker;             -- 应等于最后一条写入时间
SELECT pg_is_in_recovery();                       -- 期望 f（新实例可写）
```

6. 释放实例，导出备份任务耗时曲线截图存档。

#### 验证方法 / 修复

| 检查 | 期望 | 不通过时 |
| --- | --- | --- |
| `DescribeBackupTasks` | `Progress=100%`，无 `Failed` | 看 `Engine`/`BackupMethod`；WAL 归档失败先查 OSS 授权（`AliyunRDSBackupDefaultRole`） |
| 可恢复时间点范围 | 覆盖近 7 天 | `EnableBackupLog=0` → 开启后**历史不可回补**，只能重新起算 |
| `ops_drill_marker` 最后一条时间 | = 发起恢复时刻 - ≤ 5min | 差距大 → `pg_switch_wal()` 未执行或归档延迟高；记录真实 RPO 并按 SLA 口径确认是否可接受 |
| 恢复后业务表行数一致 | 一致 | 不一致优先怀疑**恢复了错误的库**（多 DB 实例）|

#### 坑与注意事项

- **坑 1｜把"恢复到新实例"点成"覆盖原实例"。** 后果：**这是本方案里唯一会直接造成生产数据丢失的按钮**。改进：① 演练只在 `【演练窗口 + 双人复核】` 下执行；② Runbook 里把该按钮截图并打红叉（§13.3）；③ 主库开启**删除保护**（`DescribeDBInstanceAttribute.DeletionProtection`）。
- **坑 2｜恢复演练的实例规格照抄主库（16C64G）。** 后果：国际站按小时计费 + 跨 AZ，一次演练几十美元；更糟的是**恢复大实例常排队无库存**，演练超时失败。改进：选最小可用规格，只验数据正确性与耗时，不验性能。
- **坑 3｜WAL 归档到 OSS 但没测"OSS 不可写"分支。** 后果：OSS 权限被改坏后，PITR 静默退化成了只有每日全量 → RPO 从分钟级变 24 小时。改进：§10.8 告警加一条"WAL 归档延迟 > 15min"（RDS 监控指标 `wal_retention/LogSize` 或云监控事件）。
- **坑 4｜恢复耗时未计入 region 级故障场景。** 64GB 级实例 PITR 实测常在 **1.5–4 小时**。后果：SLA 承诺的 RTO 在 region 故障下不成立（属排除项②）。改进：把实测值写进 M5 证据，与客户口径对齐；不接受 → 只有第三 region 主库（超范围，需重新立项）。

### 6.6 任务 56｜上游供应商 IP 白名单提交与生效确认

这一步是**外部依赖**，不做完 D4 之后所有渠道调用都会被上游 403，而应用侧看到的往往只是"随机超时/连接失败"。

#### 操作步骤

1. 汇总 8 个 EIP（马尼拉 4 + 新加坡 4）：

```bash
for r in ap-southeast-6 ap-southeast-1; do
  aliyun vpc DescribeEipAddresses --RegionId "$r" --PageSize 50 \
    | jq -r --arg r "$r" \
      '.EipAddresses.EipAddress[]
       | select(.Name | test("^eip-(mnl|sg)-upstream"))
       | [$r, .IpAddress, .Name, .Status, .Bandwidth] | @tsv'
done
# 期望恰好 8 行（每 region 4 行），Status=InUse，Bandwidth 与 §9.9 规格一致
```

2. 逐渠道提交（OpenAI/Anthropic/Google/Azure/自建网关…），每家**分别记录**：提交时间、工单号、生效确认时间、联系人。
3. 对不支持 IP 白名单的渠道（多数头部模型厂商**不做**入向白名单），确认此项**不适用**并留书面结论；真正需要白名单的是企业专属渠道、Azure OpenAI（走 `ipRules`）、以及自建/私有化上游。
4. Azure OpenAI 类可自助的渠道，用 CLI/API 加规则后立即验。

#### 验证方法

```bash
# 从两 region 的 Pod 网段分别打上游探活（不消耗 token 的轻接口）
for ctx in mnl sg; do
  kubectl --context $ctx -n new-api run wl-probe-$ctx --image=curlimages/curl --rm -it --restart=Never -- \
    sh -c 'curl -s -o /dev/null -w "%{http_code} %{time_total}\n" https://api.openai.com/v1/models'
done
# 期望：非 000；401/403（无 key）也算通路正常，说明未被 IP 拦截
```

#### 坑与注意事项

- **坑 1｜以为"EIP 提交了就生效"。** 后果：对方审批 1–3 天，D4 起全渠道失败，被当成我方故障。改进：§3 门禁把"8 个 EIP 逐一确认生效"列为 **G0 出口条件之一**；未确认的渠道先不进流量。
- **坑 2｜把 SNAT 池当成固定出口。** 后果：4 个 EIP 轮询，白名单只加了 1 个 → **25% 概率成功**的间歇性故障，是本项目最难定位的一类。改进：一律 **4 个全加**；验证时用多次 curl 统计命中的出口 IP 分布（§6.1 V2 同法）。
- **坑 3｜上游按"来源 IP 信誉"限流，两 region 共享配额。** 后果：接管后新加坡流量叠加，QPS 超限被整体降速。改进：§11.5 上游配额盘点按 **8 个 EIP 合计峰值 QPS** 与上游确认。

### 6.7 D3 出口检查（M1 → M2 交界）

```
☐ RDS 公网串 + TLS 证书地址绑定正确（V1 的 SAN 匹配截图）
☐ 白名单三组（default / mnl_vpc / sg_standby_eip）逐条复核，无 0.0.0.0/0
☐ ExternalSecret Ready=True，KMS 改值后 K8s 侧跟随
☐ NODE_TYPE / MEMORY_CACHE_ENABLED / SYNC_FREQUENCY 在 Pod 内实测等于期望值
☐ ALB DNSName 可解析、listener 600s、TLS1.2+1.3、健康检查全绿
☐ 新加坡集群 2 节点 Ready，Pod 出口只出现 4 个登记 EIP
☐ PITR 演练完成：RTO / RPO 实测数字 + 截图入证据包
☐ 8 个 EIP 上游确认表（含"不适用"的书面结论）
```

---

## 7. 阶段 E：D4 落地（任务 11、18、28、29、45）

> D4 是"第一次让代码真跑起来"的一天，也是最容易在夜里出事的一天。顺序：**#11 节点池 → #18 master 迁移 → #45 staging/矩阵（与 #18 并行）→ #28 备 Deployment → #29 备缓存/日志**。

### 7.1 任务 11｜马尼拉 ECS 节点池（4×8C32G，跨 2 AZ，nofile 调优）

#### 操作步骤

1. **先验证机型可用（P0-3，不可跳过）**：

```bash
aliyun ecs DescribeAvailableResource --RegionId ap-southeast-6 --DestinationResource InstanceType \
  --InstanceChargeType PostPaid --IoOptimized optimized --NetworkCategory vpc --ResourceType instance \
  | jq -r '.AvailableZones.AvailableZone[] | .ZoneId as $z | .AvailableResources.AvailableResource[] \
           | .SupportedResources.SupportedResource[] | select(.Status=="Available") | [$z,.Value] | @tsv' \
  | grep -E "g8i|g8a|g7|c8i" | sort
```

从输出里挑 ≥3 个可用机型，写进节点池 `instance_types`（顺序即优先级）。**若 `g8i.2xlarge` 不在列表里，不要坚持改配置单**，直接换机型并把 §2.1 request/limit 按实际 vCPU 重算。

2. 建节点池（body 结构同 §6.4 Step 2，差异：`desired_size:4`、`min_size:4`、`max_size:8`、`site=ph-mnl`、`instance_types` 用第 1 步结果）。

3. **系统级 nofile**（User Data 脚本，节点初始化执行）：

```bash
#!/bin/bash
set -euo pipefail
mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nDefaultLimitNOFILE=200000\n' > /etc/systemd/system.conf.d/limits.conf
mkdir -p /etc/security/limits.d
printf '* soft nofile 200000\n* hard nofile 200000\nroot soft nofile 200000\nroot hard nofile 200000\n' \
  > /etc/security/limits.d/99-newapi.conf
mkdir -p /etc/systemd/system/kubelet.service.d
printf '[Service]\nLimitNOFILE=200000\n' > /etc/systemd/system/kubelet.service.d/10-limits.conf
sysctl -w net.ipv4.ip_local_port_range="10240 65535"
printf 'net.ipv4.ip_local_port_range = 10240 65535\nnet.core.somaxconn = 32768\nnet.ipv4.tcp_tw_reuse = 1\n' \
  > /etc/sysctl.d/99-newapi.conf
systemctl daemon-reload
```

> 节点上 `ulimit -n` 对**容器**不生效；容器的 nofile 由 containerd/kubelet 继承。所以三处都要设：systemd Manager、kubelet unit、以及 Pod 的 `securityContext`（部分运行时需在 `ulimit` 注解里显式）。

4. 数据盘（300G ESSD）挂载给容器运行时与日志：ACK 节点池里勾 "数据盘 → 挂载到 `/var/lib/containerd` 与 `/var/log`"，或改用 **`/var/lib/kubelet,eci` 自动初始化磁盘** 选项。

#### 验证方法

```bash
# V1 跨 AZ 分布
kubectl get nodes -L topology.kubernetes.io/zone -l site=ph-mnl
# 期望 6a / 6b 都有，且各 ≥2

# V2 nofile 三处齐验
kubectl run u --image=busybox --rm -it --restart=Never -- sh -c 'ulimit -n'          # 期望 200000
kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/debug/profile" >/dev/null 2>&1 || true
# 节点上（堡垒机）：
cat /proc/$(pgrep -o kubelet)/limits | grep "open files"
cat /proc/$(pgrep -o containerd)/limits | grep "open files"

# V3 数据盘
kubectl debug node/${NODE} -it --image=busybox -- sh -c 'df -h /host/var/lib/containerd'
# 期望 300G ESSD，非系统盘

# V4 机型实际落在候选内
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.node\.beta\.kubernetes\.io/instance-type}{"\n"}{end}'
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| `ulimit -n` = 1024 | 只改了 `/etc/security/limits.d`（登录会话才生效） | 必须改 systemd `DefaultLimitNOFILE` + kubelet drop-in，然后 `daemon-reload` 且**重启 kubelet/containerd**；已建节点需排水后换机 |
| 4 节点全在同一 AZ | 节点池 vSwitch 只挂了一个，或 `multi_az_policy` 偏向单区 | 补第二个 vSwitch；策略用 `COST_OPTIMIZED`/`BALANCE`（跨 AZ 均衡选 **BALANCE**） |
| Pod Pending + `Insufficient cpu` | request 总和 > 节点可分配（系统预留后 8C 实际约 7.2C） | 按 `allocatable` 重算：4 副本 × 2C = 8C > 单节点；确保 `topologySpread` 允许跨节点 |
| 数据盘没挂上 | 节点池磁盘"初始化"未勾选 | 只能加新节点池替换（数据盘不可给已有节点在线扩盘并重新分配给 containerd）；用 `kubectl cordon` + 迁移 |

#### 坑与注意事项

- **坑 1｜用 `PostPaid` 但没设"按量实例补偿/伸缩失败重试"。** 后果：库存抖动时节点池扩不出机器，HPA 空转。改进：多机型 + `min_size` 常备；§3.4 配额留 ≥20% 余量。
- **坑 2｜节点池开了"自动升级 OS 镜像"，与手动 nofile 脚本冲突。** 后果：升级后 ulimit 静默回到 1024，SSE 高并发时 `too many open files`。改进：升级窗口与 §13 变更冻结一致；并在 §10.8 加**节点 nofile 巡检告警**（node-exporter `process_max_fds`）。
- **坑 3｜`instance_types` 混了不同内存比（g 8C32G 与 r 8C64G）。** 后果：request/limit 与 HPA 阈值口径错乱，同规格判断失真。改进：只混同规格族或明确"CPU 相同即可"，并把 HPA 指标改为 **CPU 利用率**（默认 `Utilization` 基于 request，稳）。
- **坑 4｜系统盘 100G 不够。** 镜像层 + 日志把盘打满 → `Evicted` 风暴。改进：`LOG_DIR` 指向数据盘；logtail 侧限流；`emptyDir` 设 `sizeLimit`。

### 7.2 任务 18｜master Deployment 跑通 AutoMigrate（连跑两次验幂等）

#### 操作步骤

**Step 1 — master 专用 manifest**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-api-master, namespace: new-api}
spec:
  replicas: 1
  strategy: {type: Recreate}          # 必须 Recreate：两个 master 并发迁移会死锁
  selector: {matchLabels: {app: new-api-master}}
  template:
    metadata: {labels: {app: new-api-master, track: master, project: new-api, site: ph-mnl, env: prod}}
    spec:
      serviceAccountName: new-api-app
      containers:
      - name: new-api
        image: ${ACR_MNL_PREFIX}:<git-sha>
        env:
        - {name: NODE_TYPE, value: "master"}     # 只有这里允许 master
        envFrom:
        - configMapRef: {name: new-api-config}
        volumeMounts:
        - {name: data, mountPath: /app/data}     # master 独立 PVC（RWO）
        - {name: logs, mountPath: /app/logs}
        resources: {requests: {cpu: "1", memory: 2Gi}, limits: {cpu: "2", memory: 4Gi}}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: pvc-new-api-master}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: pvc-new-api-master, namespace: new-api}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: alicloud-disk-topology-alibabacloud-essd-cnfs   # 按实际 SC 名
  resources: {requests: {storage: 20Gi}}
```

> master **不挂 Service、不进 ALB 后端**（§6.3 Ingress 里没有它的 selector）。

**Step 2 — 观察迁移**

```bash
kubectl -n new-api logs deploy/new-api-master -f | grep -Ei "migrat|index|error|fatal"
```

new-api 用 GORM `AutoMigrate`，启动时同步执行。**幂等性验收 = 连续两次冷启动，第二次不得有 DDL**：

```bash
kubectl -n new-api rollout restart deploy/new-api-master
kubectl -n new-api logs deploy/new-api-master --since=3m | grep -Ec "ALTER TABLE|CREATE TABLE|CREATE INDEX"
# 第一次期望 >0；第二次期望 =0
```

**Step 3 — 版本化迁移收口（任务 54 的铺垫）**

在 staging 先把 `golang-migrate` 跑通再引到 prod；核心是把 `AutoMigrate` 关掉（新增 `MIGRATE_MODE=off` 环境变量能力需 G8 一并补建），迁移改为 Job 执行。当前若 G8 未完成，**保留 AutoMigrate 但严格约束"只有 master Pod 能迁"**（DB 层已用 `newapi_migrate` 账号强制，见 §5.5）。

#### 验证方法

```bash
# V1 只跑一个 master
kubectl -n new-api get deploy new-api-master -o jsonpath='{.status.readyReplicas}{"\n"}'   # 1
kubectl -n new-api get pods -l app=new-api-master -o wide                                   # 仅 1 个

# V2 DB 权限边界：stable 用的账号不能改表
kubectl -n new-api exec deploy/new-api-stable -- sh -c 'psql "$SQL_DSN" -c "create table _perm_probe(id int)"'
# 期望：ERROR: permission denied for schema public

# V3 表结构与代码期望一致（抽样关键表）
psql "$DSN_MIGRATE" -c "\d users" | grep -E "quota|used_quota|access_token|status"

# V4 master-only 任务只在 master 跑（如额度巡检、渠道自动禁用）
grep -rn "IsMasterNode" --include=*.go . | wc -l    # 记录数量，作为回归基线
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| 启动即 `log.Fatal`，日志含 `SESSION_SECRET` | 值为默认 `random_string` 或空（`common/init.go:50-55`） | KMS 里必须注入真实值；CI 加断言禁止默认值 |
| 第二次冷启动仍有 `ALTER TABLE` | AutoMigrate 非幂等（索引/类型漂移） | 记录漂移项，走 expand-contract 手工修表 + 补迁移文件；不要反复重启刷 |
| `PVC ... Multi-Attach error` | 滚动更新时旧 Pod 未释放 RWO 盘 | `strategy: Recreate`（已在 manifest）；若仍出现，检查 `podTerminationGracePeriod` 与 CSI 卷detach |
| master 与 stable 同时执行迁移（并发死锁 `lock timeout`） | stable 被判为 master → **坑 1（§6.2 NODE_TYPE）命中** | 立刻停 stable，核 `NODE_TYPE`，再恢复 |

#### 坑与注意事项

- **坑 1｜master 也接流量。** 后果：AutoMigrate 期间请求打到该 Pod → 5xx + 迁移锁等待，用户侧看到"偶发 500"。改进：master 无 Service；ALB 后端只挂 stable/canary；上线检查表核验。
- **坑 2｜`Recreate` 期间有秒级不可用窗口**（对 master 可接受）。但若误把 stable 也设成 Recreate → **发布时全站中断**。改进：stable 必须 `maxUnavailable: 0, maxSurge: 1`（§8.4）。
- **坑 3｜迁移在大表上长时间持锁。** 后果：`users`/`logs` 级表加索引时业务写阻塞。改进：任何加索引用 `CONCURRENTLY`（PG）并纳入版本化迁移，不允许 GORM 隐式做；§11.2 expand-contract 三步走。
- **坑 4｜AutoMigrate 失败但进程不退出**（部分版本仅记 error）。后果：schema 落后于代码，后续 SQL 报 `column does not exist`。改进：`Describe` 启动日志并**断言无 migrate 相关 ERROR**，把日志关键字做成告警。

### 7.3 任务 45｜staging / perf 环境 + 三数据库矩阵

#### 操作步骤

1. **落点**：马尼拉主站 ACK 的独立 Namespace `new-api-staging` / `new-api-perf`，RDS 复用主实例的**独立 schema/独立库**（不新建实例，避免与"新加坡不部署 RDS"红线口径冲突；见 §3.12 G13）。
2. 建库与账号：

```sql
CREATE DATABASE newapi_staging TEMPLATE newapi_owner_dev OWNER newapi_staging_app;
CREATE DATABASE newapi_perf    TEMPLATE newapi_owner_dev OWNER newapi_perf_app;
```

> 用**空模板 + 首启 AutoMigrate 建表**，而不是 `TEMPLATE newapi`（拷生产结构会把生产数据一起带来）。

3. 三数据库矩阵（new-api 必须同时兼容 SQLite/MySQL/PG，`model/main.go:145` 主库不支持 ClickHouse）：

| 组合 | SQLite | MySQL 8 | PostgreSQL 15 | ClickHouse（仅 `LOG_SQL_DSN`） |
| --- | --- | --- | --- | --- |
| 目的 | 单文件默认路径 | 兼容老部署 | **本次生产** | 日志库 |
| 实例 | Pod 内 emptyDir | 复用 RDS MySQL（临时）或 ACK 内 `bitnami/mysql` | 主站 RDS `newapi_perf` | 见 §4.5 决策树 |
| 用例 | 安装/升级 | 全回归 | 全回归 + 压测 | 写日志 + TTL + 降级 |

4. perf 环境用 2×`g8i.xlarge` 独立节点池（`taint: dedicated=perf:NoSchedule`），压测流量不污染 prod。

#### 验证方法

```bash
# V1 三库分别跑同一镜像的冒烟
for db in sqlite mysql pg; do
  kubectl -n new-api-staging run smoke-$db --image=${ACR_MNL_PREFIX}:${SHA} --env=DB=$db \
    --rm -i --restart=Never -- sh -c 'sleep 5; wget -qO- http://localhost:3000/api/status'
done
# 期望三份 JSON 都含 "success":true 且 "version" 与镜像 tag 一致

# V2 压测基线
hey -z 60s -c 200 -m POST -H "Authorization: Bearer $TOKEN" -D body.json https://api.likha.com/v1/chat/completions
# 记录 p50/p95/p99、错误率、上游 429 次数

# V3 环境隔离
kubectl -n new-api-staging get deploy -o jsonpath='{..image}' | tr ' ' '\n' | sort -u
# 期望：与 prod 同一 SHA，不出现 latest
```

#### 坑与注意事项

- **坑 1｜staging 用生产 `SESSION_SECRET`。** 后果：staging 里签的 token 在生产可用（越权/额度盗用）。改进：**必须不同**；但两 region 的 prod 之间必须相同（§6.2 坑 3）—— 两者不要混淆。
- **坑 2｜perf 压测打生产 RDS。** 后果：压测把主库连接打满，直接影响 SLA。改进：压测前核对 `SQL_DSN` 的 dbname 是 `newapi_perf`；用 `SELECT application_name, count(*) FROM pg_stat_activity GROUP BY 1` 实时看连接来源。
- **坑 3｜SQLite 矩阵被跳过。** 后果：一次依赖升级破坏 SQLite 路径，社区版用户安装失败（回归风险）。改进：CI 里三库并行必跑，SQLite 用例可只跑冒烟。
- **坑 4｜ClickHouse 决策未定就排矩阵（P0-1）。** 后果：D4 卡住。改进：§4.5 决策树 A0/A/B/C 必须 D3 前拍板，本表按选定方案填。

### 7.4 任务 28｜新加坡 PH 备 Deployment + Secret

#### 操作步骤

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-api-ph-standby, namespace: new-api, annotations: {config-version: "1"}}
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 0, maxSurge: 1}
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
        image: ${ACR_SG_PREFIX}:<git-sha>            # 与主站同一 SHA，SG VPC 域名拉取
        ports: [{containerPort: 3000}]
        env:
        - {name: NODE_TYPE, value: "slave"}          # 红线：备 region 固定 slave
        - {name: SQL_MAX_OPEN_CONNS, value: "150"}
        envFrom: [{configMapRef: {name: new-api-config}}]
        readinessProbe:
          httpGet: {path: /api/status, port: 3000}
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        livenessProbe:
          httpGet: {path: /api/status, port: 3000}
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 5                          # ⚠ 见坑 3
          initialDelaySeconds: 40
        lifecycle:
          preStop: {exec: {command: ["sh","-c","sleep 15"]}}
        resources: {requests: {cpu: "2", memory: 4Gi}, limits: {cpu: "4", memory: 8Gi}}
```

`ExternalSecret` 在新加坡另建一份（键同名），`SQL_DSN` 指向**马尼拉 RDS 公网串** + `sslmode=verify-full`（若走了 §6.1 路径 C 则是 `verify-ca`，并在文件注释里留风险编号）。

#### 验证方法

```bash
# V1 副本分布
kubectl --context sg -n new-api get pods -l app=new-api -o wide
kubectl --context sg get pods -l app=new-api \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'

# V2 确认备 region 只读不写：不能建表（权限已由 §5.5 强制）
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'psql "$SQL_DSN" -c "create table _sg_probe(id int)"'
# 期望 permission denied

# V3 跨区链路与连接健康
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c \
  'psql "$SQL_DSN" -Atc "select count(*), max(state) from pg_stat_activity where usename='"'"'newapi_sg'"'"'"'
# 期望：连接数 ≤ 150 × 2 = 300（含池化后实际值）

# V4 会话互通：在主站登录拿到的 token，在备站接口能直接用
curl -s -H "Authorization: Bearer $MNL_TOKEN" https://<SG_ALB_DNS>/v1/dashboard/billing/subscription | jq -e '.success'
# 期望 true —— 这条是 SESSION_SECRET 一致性的真实验收
```

#### 验证不通过的修复

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| Pod 起来但 readiness 不过 | 跨区 DSN 握手失败（TLS/白名单） | 回 §6.1 V1–V3 定位；不要先怀疑应用 |
| V4 返回 401 | 两集群 `SESSION_SECRET` 不同 | 统一 KMS 源；改后 `rollout restart` 两侧 |
| 频繁重启（`Liveness probe failed: timeout`） | PG 慢时 `/api/status` 也慢 | 加大 `timeoutSeconds`/`failureThreshold`；根治要补 `/healthz`（不查库）即 G8 |
| 备站把表结构改了 | `NODE_TYPE` 非 slave（§6.2 坑 1） | 立刻回滚 + 数据核对；这是最高优先级修复项 |

#### 坑与注意事项

- **坑 1｜镜像 tag 用了 `latest`。** 后果：接管时新加坡跑的是与主站不同的代码，schema 不一致 → 全站 SQL 错。改进：**两集群必须同 SHA**，CI 双推（§4.6 ACR 双地域同步），GitOps 里 pin SHA。
- **坑 2｜`topologySpread` 用 `WhenUnsatisfiable: ScheduleAnyway`（默认值）。** 后果：2 副本同 AZ，AZ 故障时备站全灭。改进：用 `DoNotSchedule`（已在 manifest），并在 §12 里以"两 AZ 各 1 副本"为验收项。
- **坑 3｜liveness 比重度依赖 DB 的探针绑定。** 后果：主库抖动 → 全 Pod 被 kill → 重启风暴（K8s 经典事故）。改进：liveness 用**纯进程存活**探针；G8 未落地前，把 `failureThreshold: 5` + `timeoutSeconds: 5` 当保底，并在 §13 预案里写"主库故障时先关 liveness 自动重启"。
- **坑 4｜`preStop sleep 15` 与 `terminationGracePeriodSeconds: 45` 的关系。** 15s 只是给 endpoint 摘除传播留时间；Go 侧还要正确处理 SIGTERM（new-api 有 graceful shutdown，但 SSE 长连接需等其自然结束或超时）。改进：`SESSION`/SSE 的 drain 时长必须 < grace period。
- **坑 5｜把 `new-api-ph-standby` 挂进主站 ALB 后端。** 后果：常态流量跨区走马尼拉→新加坡→马尼拉 RDS，延迟翻倍且成本上升。改进：备站只接 **GTM 备地址池**（新加坡 ALB），常态零流量。

### 7.5 任务 29｜备 region 本地 Tair / 日志库

#### 操作步骤

1. **Tair（新加坡）**：主备版 4GB，`maxmemory-policy allkeys-lru`，密码 + 内网 ACL；VPC 内网串。**禁止跨区用马尼拉 Tair**（缓存 RTT 放大，限流窗口失真）。
2. 限流键设计：new-api 的全局 API 限流走 Redis；跨区缓存会让主备两侧**看到不同计数器** → 接管瞬间限流形同虚设。要么接受"接管后限流重新计数"（并在 §12 记为已知行为），要么限流改走 PG 计数（成本高，不推荐）。
3. **日志库**：按 §4.5 选定方案落地（推荐 A：新加坡 CK 实例）；`LOG_SQL_DSN` 各 region 指向**本地**日志库。
4. 日志采集：`logtail-ds` + `sls-newapi-sg`，`/app/logs/*.log` 与 stdout 双路（容器 stdout 为兜底）。

#### 验证方法

```bash
# V1 Tair 策略与连通
redis-cli -h ${TAIR_SG_HOST} -p 6379 -a ${PWD} CONFIG GET maxmemory-policy   # allkeys-lru
redis-cli -h ${TAIR_SG_HOST} -p 6379 -a ${PWD} info clients | grep connected_clients

# V2 限流在备站生效（不依赖主站 Redis）
for i in $(seq 1 400); do curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $SG_TOKEN" https://<SG_ALB>/v1/chat/completions \
  -H 'content-type: application/json' -d '{"model":"gpt-3.5-turbo","messages":[{"role":"user","content":"x"}]}'; done | sort | uniq -c
# 期望：出现足量 429（阈值 360/180s）

# V3 日志跨区不外写
kubectl --context sg exec deploy/new-api-ph-standby -- sh -c 'echo "$LOG_SQL_DSN" | grep -o "tcp([^)]*)"'
# 期望：host 是 SG 本地 CK/Pg 地址，不是马尼拉
```

#### 坑与注意事项

- **坑 1｜Redis 不可用时应用 fail-closed。** 后果：Tair 抖动 → 全站 429/503，实际服务完全正常 —— 这正是 G8 要求"限流降级为放行而非拒绝"的原因。改进：G8 未合入前，把"Tair 可用性"当作 **P1 依赖**并加告警；预案见 §13.2。
- **坑 2｜`allkeys-lru` 误清了非限流数据。** new-api 会缓存渠道/用户配置；LRU 会按最后使用时间清，**包括业务缓存**。后果：缓存雪崩打穿 PG。改进：给限流键独立 Redis DB 或前缀 + `volatile-ttl`；并配置 Tair 内存告警 70%。
- **坑 3｜写日志失败拖垮请求线程。** 改进：日志写必须异步 + 失败丢弃计数（方案 AB 列已要求）；压测 V2 场景里包含"kill 掉日志库"分支（§11.1）。

### 7.6 D4 出口检查（M2）

```
☐ 机型候选表回填，节点池 4 节点跨 2 AZ，容器内 ulimit -n = 200000
☐ master Recreate + 独立 PVC，连续两次冷启动第二次 DDL=0
☐ stable/newapi 账号建表被 DB 层拒绝（权限边界生效）
☐ staging 三库矩阵通过；perf 环境可承载压测且 DSN 指向 perf 库
☐ 备站 2 副本分属 2 AZ，NODE_TYPE=slave，建表被拒
☐ 主站 token 在备站直接可用（SESSION_SECRET 一致性实证）
☐ Tair 限流在备站独立生效，日志库无跨区写
```

---

