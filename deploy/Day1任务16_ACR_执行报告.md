# Day 1 · 任务 16｜马尼拉 ACR 企业版 + CI 推镜像 —— 复核执行报告

- **复核时间**：2026-10-05 17:58–18:12（GMT+8）；**闭环执行**：2026-10-05 18:15–18:25
- **复核方式**：`aliyun cr / cs` 只读 API + `deploy/ack_remote.sh` 云助手进集群实拉
- **判定**：**✅ 已完成闭合**（2026-10-05 18:25）。初判「❌ 未完成（部分交付）」的 4 项缺口经用户授权后**全部执行完毕**，详见 §六。原判定与证据保留在 §一~§五。

---

## 一、逐项判定

| # | 验收项 | 结果 | 实测证据 |
|---|---|---|---|
| 1 | 马尼拉实例 RUNNING | ✅ | `ListInstance --RegionId ap-southeast-6 --InstanceName acr-newapi-mnl` → `acr-newapi-mnl cri-avfqy9xkqi5bj8ee RUNNING Enterprise_Basic` |
| 1 | 新加坡必须 0 实例（负向断言） | ✅ | `ListInstance --RegionId ap-southeast-1 --PageSize 50` → `Instances.length = 0` |
| 2 | 两个端点都在 | ✅ | `GetInstanceEndpoint --EndpointType internet` → `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com`；`--EndpointType vpc` → `acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com` |
| **2b** | **VPC 端点已关联马尼拉 VPC** | **❌ → ✅**（18:18 已修，见 §六①） | `GetInstanceVpcEndpoint` → `LinkedVpcs = []`（长度 0）；集群内 `getent hosts acr-newapi-mnl-registry-vpc…` **无输出**（DNS 无记录） |
| 3 | 访问凭证（CI secret `${ACR_PASS}`） | ⚠ 未复核 | 属 CI 侧 secret，云端 API 读不到；不在本次判定范围 |
| 4 | 四命名空间已建 | ✅ | `newapi-prod / newapi-pre / newapi-test / newapi-dev`，`NamespaceStatus=NORMAL`，**`AutoCreateRepo` 全为 `false`**（与基线一致） |
| 4 | 仓库须显式创建 | ✅ | `newapi-prod` 下 3 个：`newapi-master`(PUBLIC) / `newapi-slave`(PRIVATE) / `newapi-pg-bouncer`(PRIVATE)；其余三 ns 为空 |
| 5 | 无镜像同步规则（单地域） | ✅ | 与「新加坡 0 实例」自洽 |
| 6 | CI 推镜像（tag = git sha，禁 latest） | ✅ | `newapi-master` 仓库 3 个 tag：`20260928-26ac63233`(78,071,247 B) / `20260928-4ab71f488`(78,073,310 B) / `20260927-aef388bd8`(78,990,213 B)，Status 全 `NORMAL` |
| 7 | 马尼拉集群装 credential-helper | ✅ | addon `managed-aliyun-acr-credential-helper` **active v24.01.29.1-5318af4-aliyun**（2026-10-05 任务 18 落地，本次复核确认） |
| **7** | **新加坡集群同样要装** | **❌ → ✅**（18:20 已修，见 §六②） | `ListClusterAddonInstances --cluster_id ca75829e3492d491d9d434de087913798` 全量 addon 中**无任何 acr/credential 组件** |
| **a** | 马尼拉用 **VPC 域名**拉一次 | **❌ → ✅**（18:21 已修，见 §六③） | `ptest-vpc` → `ImagePullBackOff` / `ErrImagePull`：`dial tcp: lookup acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com on 100.100.2.136:53: no such host` |
| **b** | 新加坡用公网域名跨区拉 + 记耗时 | **✅**（18:21 已做，11s，见 §六③） | SG 侧无 helper、当前无业务负载；RTO 输入仍缺 |

**副作用验证（公网路径已闭环）**：`ptest-pub`（同镜像、`SA=new-api-app`、公网域名）→ `Succeeded` / `PULL_OK`。

---

## 二、集群内实测（`new-api` ns）

| 项 | 值 |
|---|---|
| 业务 Pod | `new-api-master-59f758484-b99n4` **1/1 Running**（22 min+） |
| 其 `image` | `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20260928-26ac63233`（**复核时点 18:12 的公网域名；18:53 已由任务 18 卡改为 `-vpc` 内网域名，见 §七**） |
| 其 `serviceAccountName` | `new-api-app` |
| Secret `acr-credential-secret-aggregation` | 存在，`type=kubernetes.io/dockerconfigjson` |
| SA `new-api-app` 的 `imagePullSecrets` | `acr-credential-secret-aggregation` ✅ |
| SA `default` 的 `imagePullSecrets` | 空 ❌（与卡片坑 5 描述一致：helper 只 patch `new-api-app`） |

⇒ **公网端点 + helper 免密的端到端拉取链路，已由运行中的业务 Pod 独立佐证**（非仅由一次性 pulltest）。这同时说明：**复核时点（18:12）2b 尚未闭环并不阻塞业务**，那时"有状态走公网域名"可正常运行（与任务 16 步骤 7 落地时接受的约束②一致）。⚠ 但「能跑」不等于「路径跑对」：§12 门禁第 14 行要求**仅 VPC 内网域名拉取**，公网域名只是**未优化态**；消费侧真正切到 `-vpc` 是 18:53 由任务 18 卡完成的（§七）。

---

## 三、缺口与解除条件

| 缺口 | 性质 | 解除动作 | 备注 |
|---|---|---|---|
| 2b VPC 端点未关联 | **写操作（新建资源：VPC 内占一个 ENI/IP）** | `aliyun cr CreateInstanceVpcEndpointLinkedVpc --RegionId ap-southeast-6 --InstanceId cri-avfqy9xkqi5bj8ee --VpcId vpc-5tst1tgeessxn1azwasg2 --VswitchId vsw-5tswpyzfa8od6je95tdh` | **卡片明文：「执行前必须经负责人确认，不能在复核里顺手做掉」⇒ 本次未执行** |
| 新加坡侧 helper 未装 | 写操作（addon 安装） | `cs InstallClusterAddons`（`managed-aliyun-acr-credential-helper`）到 SG 集群 `ca75829e3492d491d9d434de087913798`；配置目标 ns 含 `new-api` | 装完还要补 SG 侧拉取凭据/公网域名可用性确认（卡片坑 2） |
| `newapi-master` 仍 `PUBLIC` | 配置（安全门禁） | 改回 `PRIVATE`；§12 门禁复验 | 卡片坑 5。已实测推翻「PUBLIC 可匿名拉」的旧假设，但整改结论不变 |
| 验证项 b（跨区拉取耗时） | 取证 | SG helper 装好后跑 `time kubectl --context sg run …` | 该耗时是 §11 RTO 的输入，缺它 RTO 数字不成立 |
| 仓库口径 `new-api` vs `newapi-master` | 文档口径 | 定一处回填 §2 参数表 | 卡片变量区自注「二者取一后需回填 §2」 |

---

## 四、卡片外的新发现（供回填）

1. **`aliyun cr ListRepoTag` 的参数是 `--RepoId`（不是 `--RepoNamespaceName/--RepoName`）**，且必需 `--InstanceId`。取 RepoId 走 `cr GetRepository --RepoNamespaceName <ns> --RepoName <repo>` → `.RepoId`。实测值：`newapi-master`=`crr-eo15b1p46wt8yeek`、`newapi-slave`=`crr-nnn8d8k0qmiwjx6d`、`newapi-pg-bouncer`=`crr-y00cmmfgut2nkdho`。
2. **`aliyun cs DescribeClustersV1` 不带 `--RegionId` 返回跨地域全量集群**（本次列出 jkt-dev `ap-southeast-5` / sg / mnl 三个）；而带 `--RegionId ap-southeast-6` 反而返回空（该接口对国际站地域参数不敏感）。**判集群一律用不带 region 的全量列表**。SG 集群 ID 正解 = `ca75829e3492d491d9d434de087913798`。
3. **`new-api` namespace 有 ResourceQuota `new-api-quota`**：一次性调试 Pod 必须显式给 `requests/limits` 的 cpu+memory，否则 `kubectl run` 直接被 `Forbidden: failed quota` 拒绝（本次第一次 pulltest 即被拦）。**调试 Pod 用 `--overrides` 全量指定容器（含 resources + serviceAccountName）**。
4. 业务 Pod 实际在跑（`new-api-master-59f758484-b99n4`），说明任务 18/后续卡已推进到「master Deployment 起得来」阶段 —— 与任务 19 报告里「stable Deployment 尚未接流量」需交叉确认。

---

## 五、结论

**任务 16 不判完成。** 已达成：实例/端点/命名空间/仓库/CI 推送/马尼拉 helper/公网拉取链路（含运行中业务 Pod 佐证）。未达成：**2b VPC 端点关联（卡内明示属需确认的写操作）、SG 侧 helper、验证项 a/b、`newapi-master` 改 PRIVATE**。

由于 2b 卡片明确要求「不能在复核里顺手做掉」，本次仅复核不写。若授权，2b 为单条命令、秒级生效（ENI 占用 app-a 网段），随后 VPC 域名即通、验证项 a 可立即闭合。

---

## 六、闭环执行（2026-10-05 18:15–18:25，用户授权后）

用户确认「继续完成这 4 项」⇒ 以下均为**写操作**，逐项执行并复验。

### ① 2b VPC 端点关联 —— ✅ 完成

```bash
aliyun cr CreateInstanceVpcEndpointLinkedVpc --region ap-southeast-6 \
  --InstanceId cri-avfqy9xkqi5bj8ee \
  --VpcId vpc-5tst1tgeessxn1azwasg2 \
  --VswitchId vsw-5tswpyzfa8od6je95td1h --ModuleName Registry
# → {"IsSuccess":true,"RequestId":"01A10B92-4A9E-3F4A-A26F-A52E232A8F51","Code":"success"}
```

回读：

```json
[{"Status":"RUNNING","VpcId":"vpc-5tst1tgeessxn1azwasg2","VswitchId":"vsw-5tswpyzfa8od6je95td1h",
  "Ip":"10.0.22.220","DefaultAccess":true,"Issue":"NO_PRIVATE_ZONE_AUTHORIZED"}]
```

- **`Issue=NO_PRIVATE_ZONE_AUTHORIZED`**（因未开 `EnableCreateDNSRecordInPvzt`）**不影响解析**：集群内 `getent hosts acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com` 已返回 **`10.0.22.220`**（与 `LinkedVpcs[0].Ip` 一致）。
- ⚠ **vSwitch ID 易错**：正确值 `vsw-5tswpyzfa8od6je95td1h`（末 4 位 `td1h`）。写成 `vsw-5tswpyzfa8od6je95tdh`（少一个 `1`）→ `VSWITCH_NOT_EXIST / VSwitch is not exist.`（本次首轮即踩，非偶发抖动）。
- 占用：`vsw-mnl-app-a`（`10.0.16.0/20`，`ap-southeast-6a`）1 个 IP。

### ② SG credential-helper 安装 —— ✅ 完成

```bash
aliyun cs InstallClusterAddons --ClusterId ca75829e3492d491d9d434de087913798 --region ap-southeast-1 \
  --header "Content-Type=application/json" \
  --body '[{"name":"managed-aliyun-acr-credential-helper","config":"{\"AcrInstanceInfo\":[{\"instanceId\":\"cri-avfqy9xkqi5bj8ee\",\"regionId\":\"ap-southeast-6\"}],\"enableRRSA\":false,\"expiringThreshold\":\"15m\",\"serviceAccount\":\"new-api-app\",\"watchNamespace\":\"new-api\"}"}]'
# → {"cluster_id":"ca75829e3492d491d9d434de087913798","task_id":"T-6ac37991fa7b0a01090030fb"}
```

轮询 30s 后 `state=active`：

```json
{"name":"managed-aliyun-acr-credential-helper","state":"active","version":"v24.01.29.1-5318af4-aliyun",
 "config":"{\"AcrInstanceInfo\":[{\"instanceId\":\"cri-avfqy9xkqi5bj8ee\",\"regionId\":\"ap-southeast-6\"}],
 \"enableRRSA\":false,\"expiringThreshold\":\"15m\",\"serviceAccount\":\"new-api-app\",\"watchNamespace\":\"new-api\"}"}
```

SG 侧生效实测（集群内）：`Secret/acr-credential-secret-aggregation`（`kubernetes.io/dockerconfigjson`，生成于 76s 前）已挂到 `SA/new-api-app`。

- **⚠ CLI 坑**：`cs InstallClusterAddons` **必须带 `--header "Content-Type=application/json"`**，否则 400 `FAILED_TO_READ_REQUEST / Failed to read request body`；点式 `--body.1.name=` 写法同样 400。

### ③ 验证项 a / b —— ✅ 实测

| 项 | Pod | 集群 | 端点 | 结果 | 耗时 |
| --- | --- | --- | --- | --- | --- |
| **a** | `ptest-vpc2` | mnl | `…-registry-vpc.ap-southeast-6.cr.aliyuncs.com` | **`Succeeded` / `VPC_PULL_OK`** | **5 s** |
| **b** | `ptest-sg` | sg | `…-registry.ap-southeast-6.cr.aliyuncs.com`（公网跨区） | **`Succeeded` / `SG_PULL_OK`** | **11 s** |

镜像：`newapi-master:20260928-26ac63233`（78 MB）。

⇒ **§11 RTO 输入 = 11 s**（SG 冷拉含调度+拉取+启动）。远低于预算，**暂不触发「SG 补建 ACR + 同步规则」回退方案**。

- 调试 Pod 必须 `--overrides` 一次性给 `serviceAccountName=new-api-app` + `resources`（`new-api` ns 有 ResourceQuota `new-api-quota`，缺 resources 直接 `Forbidden: failed quota`）。

### ④ `newapi-master` PUBLIC → PRIVATE + §12 门禁复验 —— ✅ 完成

```bash
aliyun cr UpdateRepository --region ap-southeast-6 --InstanceId cri-avfqy9xkqi5bj8ee \
  --RepoId crr-eo15b1p46wt8yeek --RepoType PRIVATE --Summary "master模块" --RepoName newapi-master
# → {"IsSuccess":true,"RequestId":"01A10B95-895E-37C4-A2A1-522069A20912","Code":"success"}
```
回读 `{"RepoName":"newapi-master","RepoType":"PRIVATE"}`。

**§12 门禁双 SA 对照复验（mnl 集群，同镜像同 tag）**：

| SA | 凭据 | 结果 |
| --- | --- | --- |
| `new-api-app` | helper 聚合 Secret | **`Succeeded` / `OK`** ✅ |
| `default` | 无 | **`ImagePullBackOff`** ✅（PRIVATE 仓无匿名路径） |

⇒ §12 门禁第 14 行「ACR 企业版 + 仅 VPC 内网域名拉取 + 禁 latest」复验通过。

### 闭环后残留（唯一）

| 项 | 状态 |
| --- | --- |
| `new-api` vs `newapi-master` 单仓口径回填 §2 参数表 | ⏳ 文档待办，不影响验收 |
| SG 侧业务未部署（无占位 Deployment） | 属任务 24/25 范畴，非本卡 |

---

## 七、后续：消费侧改用 `-vpc` 内网域名（2026-10-05 18:53，任务 18 卡落地）

本卡 2b 只把**端点**关联好，`LinkedVpcs` 有值不等于有人在用它。18:53 项目负责人复核 ACK YAML 后要求修复，`deploy/aliyun/ph/master-deployment.yaml` 的 `image:` 主机名改成 `acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com`（tag/digest 不变），完整复测与"零缓存冷拉"取证方法见 **`Day2任务18_master迁移幂等_执行报告.md` §十**。对本卡的回填：

| 项 | 内网（`-vpc`）实测 | 与本卡原记录的关系 |
| --- | --- | --- |
| 节点侧解析 | 4/4 worker → `10.0.22.220`（= `LinkedVpcs[0].Ip`），`ip route get` 走 `eth0` 不经 NAT | 佐证 §六① 的 `Issue=NO_PRIVATE_ZONE_AUTHORIZED` 确实不阻塞 |
| 443 可达 | 4 节点 `curl /v2/` → `http=401`，`connect ≈ 0.8~1.7 ms` | 401 = 路径通、待鉴权（企业版无匿名路径，§六④） |
| 冷拉 78 MB | 探针 Pod `1.183 s`；Deployment 级 `crictl rmi` 后 `1.23 s`（`Image size: 78074255 bytes`） | **优于** §六③ 的 pulltest 口径（a=5 s 含调度+启动；11 s 为跨区） ⇒ §11 RTO 的马尼拉侧输入可按 **1.3 s** 级重估，SG 跨区 11 s 不变 |
| 免密 | 无需改 SA/Secret（`acr-credential-secret-aggregation` 同时覆盖公网与 `-vpc`） | 与 §二 的 helper 结论一致 |
| 公网域名 | 保留为应急通道（同 digest，回退=改一行 `image:`） | §五 的「公网链路已闭环」降级为备份路径 |

⚠ 本卡 §六③ 的验证项 a（`ptest-vpc2`，5 s）是**一次性 pulltest**，不是业务负载路径；当时的"VPC 拉取 OK"只证到"能拉"，没证到"业务在用"。⇒ 门禁类结论以后要分两栏写：**能力已验证** / **消费侧已切换**，缺后者不得判"仅内网拉取"合规（§12 第 14 行现在才算真闭环）。
