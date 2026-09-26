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

