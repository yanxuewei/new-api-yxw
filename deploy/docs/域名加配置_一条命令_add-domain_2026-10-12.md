# add-domain.sh —— 一条命令给 ACK 托管 ALB 加域名（转发 / 跳转）

- **日期**：2026-10-12
- **文件**：`deploy/ops/add-domain.sh`（≈600 行，`bash` + `python3` + `aliyun` CLI）
- **一句话**：把「生成真源 → 预检 → apply（走云助手到集群）→ 云端对账 → 回写真源」串成一条命令，**加域名的手感对齐控制台，但保留声明式的一切好处**。
- **相关**：`新增域名转发配置口径_Ingress优先_2026-10-12.md`（口径与坑）· `REFERENCE.md §10` · `deploy/lib/ack_remote.sh`

---

## 1. 为什么需要它

这批 ALB 是 **ACK 托管派生资源（`ServiceManagedResource`）**：控制台「插入新规则 / 排序 / 批量删除」是灰的，OpenAPI 直调 3/3 被拒（`OperationDenied.ServiceManagedResource`），**唯一合法通道是 Ingress / AlbConfig**。

而手写 Ingress 有 6 类**静默失败**（不报错、甚至 HTTP 仍回 200）。本脚本把这些坑全部前置成**预检**，并在 apply 后做**云端对账**。

---

## 2. 快速上手

```bash
# 只在本地生成 yaml + 跑预检（不碰集群）
bash deploy/ops/add-domain.sh plan   --site mnl --host api.likha.hk --forward

# 真正落地（生成 + 预检 + apply + 对账 + 回写真源）
bash deploy/ops/add-domain.sh apply  --site mnl --host api.likha.hk --forward

# 域名收敛（old.likha.hk → www.likha.hk，80 侧 301 / 443 侧 308）
bash deploy/ops/add-domain.sh apply  --site sg  --host old.likha.hk --redirect --to www.likha.hk

# 只看现状（集群 Ingress 表 + 两地 ALB 规则表）
bash deploy/ops/add-domain.sh ls     --site mnl

# 单独复核某个域名
bash deploy/ops/add-domain.sh verify --site mnl --host api.likha.hk

# 回退（删 Ingress；规则由 Controller 立即收回）
bash deploy/ops/add-domain.sh delete --site mnl --prefix api-likha-hk --yes
```

**默认 `plan`，`apply` 才落地**；`apply` 里预检未通过会**拒绝执行**（要强行推进得显式 `--force`）。

---

## 3. 三个真实场景

| 场景                | 命令要点                                                                   | 生成的真源                                                          |
| ----------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------- |
| 给业务加一个新域名         | `--forward`（默认后端 mnl=`new-api-stable` / sg=`new-api-ph-standby`，端口 80） | `ingress-<site>-<prefix>-forward.yaml`                         |
| 把旧域名收敛到 canonical | `--redirect --to www.likha.hk`                                         | `…-http-redirect.yaml`（301）+ `…-https-canonical.yaml`（**308**） |
| 只做 HTTP→HTTPS 升级  | `--redirect --to <自己> --ports 80`                                      | `…-http-redirect.yaml`                                         |

> ⚠️ `--redirect` 的 `--to` 不能等于 `--host`（自跳死循环），脚本会直接拦下。

---

## 4. 子命令与退出码

| 子命令            | 行为                           | 退出码                               |
| -------------- | ---------------------------- | --------------------------------- |
| `plan`         | 生成真源 + 预检 + 打印 YAML          | 预检失败 = **3**（已打印 YAML，但不建议 apply） |
| `apply`        | 预检 → 下发 → 等 reconcile → 云端对账 | 对账未全绿 = **1**；预检失败 = 3            |
| `verify`       | 只做云端对账（任何模式下都可用）             | 1 = 有问题                           |
| `ls`           | 集群 Ingress 表 + 两地 ALB 规则表    | 0                                 |
| `delete`       | 删 Ingress 并复核规则已消失           | 无 `--yes` = 2（防误删）                |
| 参数错误 / 自跳 / IP | 立即退出                         | 1                                 |

> `verify` / `ls` / `delete` 若不传 `--ports`，默认按 **80,443** 双端口检查；`verify` **不预设模式**，会如实报出实际动作类型（`Redirect` / `ForwardGroup`），不会把合法的 Redirect 规则误判为失败。  
> `apply` 若远端在落地前主动 `[ABORT]`（如 Service 不存在），会**立即中止**并明确告知「零变更」，不会空等 60 秒 reconcile。

---

## 5. 参数

| 参数                         | 默认                                                | 说明                                        |
| -------------------------- | ------------------------------------------------- | ----------------------------------------- |
| `--site mnl\|sg`           | 必填                                                | 决定 region / cluster / ALB / 默认 Service    |
| `--host <fqdn>`            | 必填                                                | **不接受 IP**（CAS DV 不签发 IP SAN ⇒ 443 必握手失败） |
| `--forward` / `--redirect` | 必填其一                                              | 模式                                        |
| `--service` / `--port`     | mnl=`new-api-stable` / sg=`new-api-ph-standby`；80 | forward 后端                                |
| `--to`                     | —                                                 | redirect 目标 host（必填）                      |
| `--code-80` / `--code-443` | 301 / **308**                                     | redirect 状态码（301/302/303/307/308）         |
| `--ports`                  | `80,443`                                          | 要声明的监听端口（**漏一个端口该端口就没有规则**）               |
| `--path`                   | `/`                                               | 路径前缀                                      |
| `--order`                  | forward=**40** / redirect=**1**                   | 必须 **< 50** 才压得过兜底                        |
| `--prefix`                 | host 的点换横线                                        | Ingress 名前缀，也是 `delete` 的定位键              |
| `--ns`                     | `new-api`                                         | namespace                                 |
| `--zone`                   | `likha.hk`                                        | 证书覆盖判定用                                   |
| `--allow-uncovered`        | 关                                                 | 证书不覆盖也放行（不建议）                             |
| `--curl`                   | 关                                                 | 额外做端到端 curl（需 DNS 已就绪）                    |
| `--force` / `--yes`        | 关                                                 | 强行推进 / 免确认删除                              |

调试：`ADD_DOMAIN_KEEP=1` 保留远端原始输出并打印其路径。

---

## 6. 预检替你挡住的坑

| # | 坑                                                | 预检行为                                                                           |
| - | ------------------------------------------------ | ------------------------------------------------------------------------------ |
| 1 | `order ≥ 50` ⇒ 被「无 Host 兜底」抢先命中，域名静默失效           | **FAIL**                                                                       |
| 2 | host 不在 `*.likha.hk` + 裸域覆盖内（多级域 / IP）           | **FAIL**（`--allow-uncovered` 可放行）                                              |
| 3 | 跳转目标在目的端口上没有规则 ⇒ 跳过去 **502**                     | 有显式规则 → OK；只靠兜底 → **WARN**（任务 47 删兜底后会 502）；都没有 → **FAIL**                     |
| 4 | 目标 host 上已存在规则（优先级赌博）                            | **WARN** 并列出既有规则                                                               |
| 5 | `Service` 不存在                                    | 在**远端 apply 前** `kubectl get svc` 拦截 ⇒ **零变更**（9 秒内返回，不空等）                     |
| 6 | 真源文件冲突                                           | 打印「将覆盖…」                                                                       |
| 7 | 自跳死循环 / IP host / 非法状态码                          | **FAIL**（参数解析阶段）                                                               |
| 8 | apply 后规则没生效（漏 `listen-ports` / 伪服务名不匹配 / 字段名写错） | **云端对账**：找 `Host=` 规则 + 核对 `RuleActions[].Type` + 比对 `Priority vs 兜底 Priority` |

**对账三项**（这是本工具的核心价值，只看 `curl` 是不够的）：

1. `Host=<host>` 规则**存在**；
2. 该规则 `Priority` **小于**本监听上「无 Host 兜底规则」的 `Priority`（否则**永远不会被命中**）；
3. `RuleActions[].Type` 是 `Redirect` / `ForwardGroup`（不是被静默降级成的 `ForwardGroup + 404`）。

---

## 7. 自测证据（2026-10-12 全量实测）

### 7.1 负向用例（只读，零变更）

| 用例                            | 期望        | 实测                                          |
| ----------------------------- | --------- | ------------------------------------------- |
| `--redirect --to` == `--host` | 拦下        | ✅ `[FAIL] --to 与 --host 相同 = 自跳死循环`（exit 1） |
| `--order 50`                  | FAIL      | ✅ `[FAIL] order=50 ≥ 50：压不过兜底规则`            |
| `--host a.b.likha.hk`（多级域）    | FAIL      | ✅ `[FAIL] 证书**不覆盖** a.b.likha.hk`           |
| 合法 forward（sg）                | PASS      | ✅ `[OK] 预检全部通过`（exit 0）                     |
| 跳转目标无显式规则                     | WARN/FAIL | ✅ 三态判定生效（explicit / fallback / missing）     |

### 7.2 正向端到端（生产探针，用后即删）

| 步骤                                 | 结果                                                                     |
| ---------------------------------- | ---------------------------------------------------------------------- |
| 基线                                 | SG 服务器组 **5** · mnl `:80` 规则 **6** · `:443` 规则 **3**                   |
| `apply --redirect`（探针 host，80+443） | `:80` **6→7**（`rule-80-3` prio 3）· `:443` **3→4**（`rule-443-2` prio 2） |
| 优先级校验                              | `3 < 兜底 6` / `2 < 兜底 4` ✅                                              |
| 动作校验                               | `Redirect 301` / `Redirect 308`（**未**被静默降级）✅                           |
| `delete` 后                         | 规则回到 **6 / 3**，SG 回到 **5** ✅ 零残留                                       |
| `apply --forward`（探针 host，80）      | `:80` **6→7**，动作 `ForwardGroup → sgp-vt5szuxv5upj963bt9` ✅             |
| Service 不存在                        | 远端 `[ABORT]` ⇒ **9 秒**内返回，**零变更**（规则数不变）✅                              |
| 真源文件                               | 探针文件全部清理，`残留=0` ✅                                                      |

### 7.3 附带确证的两条集群行为

1. **每个新 Ingress 会派生一个独立的服务器组**（同名 `new-api-<ns>-<svc>-80`，ID 不同）——  
   这就是「服务器组同名不同 ID」的成因；**删 Ingress 后 Controller 会 GC 该组**（实测 6→5）。
2. `ls` 输出的 Ingress 表与文档《两地 Ingress 地图》**逐行一致**（order 1/1/45/46/50/100）。

---

## 8. 本次踩到并已修掉的两个新坑

### 8.1 云助手 `RunCommand` 的输出有 ~24 KB 上限，且**截断是「掐中间」**

原本回读用 `kubectl get ingress -o json`（6 个 Ingress ≈ 25 KB）：

```
节点侧： NODE_SIZE=25236  NODE_MD5=ea138bd0b7cf78e89fa63e2d335f850f
本地收： RECV_SIZE=24371  RECV_MD5=9c4efadcf41095c5d435cd93ed94d7b9
行数：   424 / 424（**行数一样**，但丢了 865 字节的中间内容）
```

用 30 KB 的规律数据复现，结论更硬：

```
节点侧 30040 B（5 行 × 6008 B）→ 本地收到 24386 B
结果：BEGIN2 整段消失、第 1 行被拼接变长 —— 典型的「保留头尾、掐掉中间」
```

⇒ **JSON 解析报 `Expecting ':' delimiter`，且极易误判成「集群数据损坏」**。  
⇒ **规则：经云助手回传的载荷一律 < 2 KB**；本脚本改用 `kubectl -o go-template` 输出**紧凑 TSV**（一行一个 Ingress，约 600 B）。

### 8.2 `kubectl get <资源名> -o go-template='{{range .items}}'` 会**静默输出空**

指定资源名时 kubectl 返回的是**单个对象**、不存在 `.items` ⇒ `range` 空转、**不报错、退出码 0**。  
✅ 修复：回读一律 `kubectl get ingress`（不带名字，返回 List），本地再筛。

### 8.3 `kubectl -o custom-columns` 取不到带 `/` 的注解键

`…:.metadata.annotations.alb\.ingress\.kubernetes\.io/listen-ports` 实测**全部输出 `<none>`**（静默失败）。  
✅ 改用 `go-template` + `index .metadata.annotations "alb.ingress.kubernetes.io/listen-ports"`（并用 `{{with}}` 防 nil）。

---

## 9. 它不做的事（有意留白）

| 不做                     | 去哪做                                                                     |
| ---------------------- | ----------------------------------------------------------------------- |
| 加 DNS 记录               | `bash deploy/manifests/dns-likha-hk.sh add`（`RR=<前缀> IPS='<ALB 双 IP>'`） |
| 改监听端口 / 证书 / 超时 / 访问日志 | `deploy/manifests/albconfig-{mnl,sg}.yaml`（集群级，改一处两地生效）                 |
| 申请 / 续签证书              | `bash deploy/ops/cas_dv_cert.sh`（⚠ 2027-04-28 到期；`AutoReissue=enable` 只保证 CAS 签出新证。监听只认 AlbConfig 钉死的 `CertificateId`，ALB 又是 `ServiceManagedResource`（直调 OpenAPI 换绑被拒）⇒ 换绑＝**改 AlbConfig 再 apply**：`deploy/cert/targets.yaml` R1–R4，2027-03-29 前） |
| 删服务器组 / 手动改 ALB 规则     | **不提供**（托管资源；删 Ingress 后 Controller 自动 GC）                              |



---

## 10. 与既有约定的关系

- **真源**：只写 `deploy/manifests/`，改完**必须 git commit**（否则重演 `ingress-sg-standby.yaml` 漏回写的漂移）。
- **order**：forward 默认 40、redirect 默认 1，都 **< 50**（两地兜底 = 50）。
- **状态码**：承载 API 的域名收敛一律 **308**（保留 POST 方法与 body）；80 侧用 301。
- **SG 次序硬约束**已自动化：`--redirect` 会先验证目标在目的端口可达，否则拒绝。
- **只读优先**：`plan` 全程只查不改；所有探测都是 `ListXxx`。
