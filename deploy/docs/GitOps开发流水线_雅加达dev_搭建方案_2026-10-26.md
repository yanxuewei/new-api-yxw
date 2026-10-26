# GitOps 开发流水线 · 雅加达 dev 环境搭建方案

> 目标：把 `newapi-dev` 命名空间的手工部署（`kubectl set image` / 控制台改 Deployment / `dev_deploy.sh` 逐条 apply）换成
> **「代码合并 → CI 出镜像 → GitOps 仓库自动提变更 → 集群自愈收敛」**的闭环。
>
> 版本 v1.1 ｜ 编制 2026-10-26 ｜ 适用集群 ACK 雅加达 `cb0abf5bc06034f7bbdb991752f6f3e62`（`ap-southeast-5`）
> 依据文档：`deploy/docs/git开发-发布-值班规范.md`（下称《规范》）、`impl_tech.md`（§6.5/6.6/7.7/7.9）
>
> **状态（2026-10-26 19:35）**：T0–T3 已落地并实测通过，详见
> `deploy/docs/GitOps开发流水线_雅加达dev_执行报告_2026-10-26.md`。
> 未完成：CI 首次构建（缺 `ACR_PASSWORD`）、T4/T5 分档开关。
> 执行中新踩的 6 个坑（CRD 262144 字节上限、`argocd-server` args 写法、controller 是 StatefulSet、
> `local` 同行求值、`yxw-*` 耦合旧 CM、第 3 台节点来源）已记录在执行报告 §3，**本文件未逐条回改**。

---

## 0. 结论摘要（先看这 12 行）

| 项 | 结论 |
|---|---|
| CD 引擎 | **ArgoCD v3.x 非 HA**，装在本集群 `argocd` 命名空间；**不用 Flux**（理由 §5-D1） |
| 仓库拓扑 | **独立 ops 仓库** `github.com/yanxuewei/new-api-yxw-ops`（私有）：只放 manifest，不含业务代码；`bases/` + `overlays/{jkt-dev,jkt-pre,jkt-test,jkt-prod}` 为后续三环境预留（fanyan 2026-10-26 裁定，理由 §5-D2） |
| 部署触发源 | `develop` 分支 push（**不是 tag**；本仓 `release.yml` 抢 `tags:'*'`，打 tag 会触发上游三平台构建，见 §12-R1） |
| 镜像 | 继续推**马尼拉 ACR EE** `newapi-dev/newapi-master`，jkt 节点跨区公网拉取（现状已跑通，零改造） |
| tag 规则 | `dev-<yyyymmdd>-<sha7>`，**不可变、禁 latest**；GitOps 里写 **digest**，不写 tag |
| 配置变更 | kustomize `configMapGenerator` 替代现在 `__CONFIG_CHECKSUM__` 占位符渲染（改 CM 必滚动） |
| 密钥 | **Secret 永不进 Git**，ArgoCD 不声明该资源，沿用 `dev_deploy.sh --secret` 手工注入（§9） |
| 纳管范围 | 3 个工作负载（`new-api-dev` / `new-api-dev-slave` / `new-api-channel-task-dev`）+ Service + Ingress；**AlbConfig/IngressClass 不纳管**（finalizer 会级联删云上 ALB） |
| 隔离 | AppProject 只允许 `namespace: newapi-dev` + 集群级资源白名单为空 ⇒ **ArgoCD 打不到同集群的 pre/perf** |
| 访问 | ArgoCD UI 经既有 ALB 暴露 `argocd.likha.hk`（`*.likha.hk` 证书已覆盖）+ IP 白名单；**API server 保持无公网 IP** |
| 资源代价 | ArgoCD requests 约 **450m / 1.1Gi**；集群剩余 requests 只有 **~2.0 核**，装完剩 ~1.5 核（§11 有压到 400m 的方案） |
| 工作量 | 6 个阶段 **T0–T5**，纯施工约 1.5 人日（§11） |

**一句话**：这套方案的核心不是「装个 ArgoCD」，而是**先把三件会互相打架的事拆开**——镜像 tag 谁写、ConfigMap 谁渲染、Secret 谁注入。这三件不解决，ArgoCD 装上去当天就会和 `dev_deploy.sh` 互相覆盖。

---

## 1. 现状盘点（2026-10-26 实测，非推测）

### 1.1 集群与节点

| 项 | 实测值 |
|---|---|
| 集群 | `cb0abf5bc06034f7bbdb991752f6f3e62` / ACK 雅加达 / k8s **v1.35.7-aliyun.1** |
| 节点池 | `np-jkt-dev-x4c`，2 × `ecs.g9i.xlarge`（可弹性） |
| 节点 allocatable | 每台 **3920m / 14.5Gi / 48 pods**（4C16G 规格被系统预留） |
| 已分配 requests | node1 **3170m (80%)**、node2 **2630m (67%)**；内存 38% / 36% |
| **剩余 requests** | **约 2.0 核 / 18.8Gi** ← ArgoCD 只能吃这个预算 |
| API server | `https://10.2.25.173:6443`（**纯私网，无公网 IP**） |
| 节点出网 | `https://github.com` → **200 / 0.13s**（NAT 通，ArgoCD 拉 Git 可行） |
| 已装 CRD | 无任何 `argo*` / `flux*` ⇒ **全新安装，无迁移包袱** |

### 1.2 命名空间与工作负载（`newapi-dev`）

| Deployment | selector | 镜像 tag | requests | 副本 |
|---|---|---|---|---|
| `new-api-dev` | `app=new-api, track=dev` | `newapi-master:202610201645` | 50m / 256Mi | 1 |
| `new-api-dev-slave` | `app=new-api-dev-slave` | 同上 | 100m / 256Mi | 1 |
| `new-api-channel-task-dev` | `app=new-api-channel-task-dev` | `newapi-channel-task:202610201555` | 100m / 512Mi | 1 |
| `yxw-new-api-master` | `app=yxw-new-api-master` | `newapi-master:20261015-c62445555` | 60m / 256Mi | 1 |
| `yxw-new-api-slave` | `app=yxw-new-api-slave` | 同上 | 100m / 256Mi | 1 |

- Secret `new-api-secrets`（7 keys，含 `SQL_DSN` / `SQL_DSN_MIGRATE` / `SESSION_SECRET` / `REDIS_CONN_STRING` / `LOG_SQL_DSN`）**手工注入，不在 Git**。
- ConfigMap `new-api-config`（10 keys）；Deployment 靠 `checksum/config: "__CONFIG_CHECKSUM__"` 注解手工渲染实现「改 CM 就滚动」。
- SA `new-api-app` 挂 `imagePullSecrets: acr-credential-secret-aggregation`（免密拉取组件，跨区拉马尼拉 ACR 已通）。
- 同集群还有 `new-api-pre`、`new-api-perf`、`arms-prom` 三个 ns。**ArgoCD 必须被限制在 `newapi-dev`**，否则一次手滑能改掉 pre/perf。

### 1.3 已经乱在哪（改 GitOps 的直接动因）

1. **ReplicaSet 堆积**：`new-api-dev-slave` 有 9 个历史 RS、`yxw-new-api-master` 有 6 个 ⇒ 长期靠 `set image` 反复迭代，没有版本元数据，事故时说不清「线上跑的是哪个 commit」。
2. **镜像 tag 不统一**：一处 `202610201645`（时间戳，无 sha），一处 `20261015-c62445555`（日期+sha）⇒ 无法从 tag 反查 commit。
3. **配置漂移无感知**：CM 改完靠脚本渲染 checksum 才滚动，漏了就静默不生效（`dev_deploy.sh --apply-app` 忘了跑 = 白改）。
4. **手工止血无痕**：《规范》§11.4 要求「所有线上处置留痕」，现状是云助手 body + 控制台，git 里看不到。

### 1.4 CI 现状（`.github/workflows/`）

| 文件 | 触发 | 与本次的关系 |
|---|---|---|
| `ci.yml` | PR opened/synchronize/closed | **复用**：Go vet/build/test + bun typecheck/test，作为 PR 门禁 |
| `release.yml` | `tags: ['*']`（除 `*-alpha*`） | **必须避开**：打任何 tag 都会触发 Linux/macOS/Windows 三平台二进制构建（§12-R1） |
| `docker-build.yml` / `docker-image-branch.yml` | 上游推 GHCR/DockerHub 用 | 不动；与 ACR 无关 |
| `sync-release-to-gitcode.yml` | 上游 | 不动 |

**缺口**：当前**没有任何 workflow 会「构建镜像 → 推 ACR」**。dev 的镜像全部是本地 `bash deploy/ops/push.sh -n dev` 手工推的。

### 1.5 镜像仓库现状

| Region | ACR 实例 | 结论 |
|---|---|---|
| `ap-southeast-6`（马尼拉） | `acr-newapi-mnl` / `cri-avfqy9xkqi5bj8ee` / Enterprise_Basic | **唯一实例**，四套 ns 已建，dev 镜像在此 |
| `ap-southeast-5`（雅加达） | **`ListInstance` 返回 `TotalCount: 0`** | 无实例；是否新建见 §5-D5 |

---

## 2. 目标与非目标

### 2.1 目标（可验收）

| # | 目标 | 验收口径 |
|---|---|---|
| G1 | 一次合并自动上线 | `develop` 合入后 ≤8 min，`newapi-dev` + `-slave` 两个 Deployment 都换成新 digest，无需人工 kubectl |
| G2 | 线上状态可追溯 | 任意时刻能答出「线上跑的是哪个 commit、哪个 digest、谁改的、改了哪些 option key」 |
| G3 | 配置变更必生效 | 改 CM 值 ⇒ Pod 必然滚动（不是靠人记得跑 checksum 渲染） |
| G4 | 漂移自动收敛 | 手工 `kubectl edit/set image` 后 ≤3 min 被 ArgoCD 拉回（`selfHeal=true` 阶段） |
| G5 | 回滚 ≤3 min | `argocd app rollback` 或 revert 一个 commit |
| G6 | 密钥零入仓 | `git log -p deploy/gitops/` 里搜不到任何真实 DSN/密码（`deploy/ops/secret_scan.sh` 卡门禁） |
| G7 | 不误伤 pre/perf | AppProject destination 限制 + 一次负向测试（故意指向 `new-api-pre` 应被拒） |
| G8 | 门禁前置 | PR 阶段跑 `ci.yml` + `secret_scan`，红则不可合并 |

### 2.2 非目标（本期明确不做）

- ❌ 不动生产（mnl/sg）：本次只覆盖 jkt dev。生产 GitOps 在 dev 跑稳 ≥2 周后另立方案（届时需灰度 + ALB 权重，见 `impl_tech.md` §6.5.2）。
- ❌ 不做 canary / 蓝绿：dev 单副本无意义，直接 RollingUpdate（`maxUnavailable:0, maxSurge:1`）。
- ❌ 不做三数据库矩阵：dev 只跑 SQLite 单测（`make test` 已覆盖），三库矩阵归 pre（`impl_tech.md` §7.9）。
- ❌ 不引入 Sealed Secrets / External Secrets / KMS：2026-10-05 已裁定不用 KMS，Secret 继续手工注入。
- ❌ 不建雅加达 ACR（可选优化，见 §5-D5 决策表）。
- ❌ 不把 AlbConfig / IngressClass 纳入 GitOps（finalizer 风险，见 §5-D8）。

---

## 3. 目标架构

```mermaid
flowchart LR
    subgraph DEV["开发者"]
        A["feature/xxx"]
    end
    subgraph GH["GitHub · 业务仓 yanxuewei/new-api-yxw"]
        B["develop<br/>（dev 环境唯一源）"]
        C["main<br/>（生产基线）"]
        W1["ci.yml<br/>PR 门禁"]
        W2["dev-build.yml（新建）<br/>push develop 触发"]
    end
    subgraph OPS["GitHub · ops 仓 yanxuewei/new-api-yxw-ops"]
        O1["overlays/jkt-dev/<br/>（期望状态真源）"]
    end
    subgraph CI["GitHub Actions · ubuntu-latest"]
        S1["vet / build / test<br/>bun typecheck"]
        S2["docker buildx<br/>tag=dev-yyyymmdd-sha7"]
        S3["overlays/jkt-dev<br/>set-image.sh → digest"]
        S4["commit + push ops/main<br/>src=<业务仓 sha7>"]
    end
    ACR[("马尼拉 ACR EE<br/>newapi-dev/newapi-master")]
    subgraph JKT["ACK 雅加达 dev 集群"]
        AR["ArgoCD<br/>ns argocd"]
        NS["ns newapi-dev<br/>master / slave / channel-task"]
        SEC["Secret new-api-secrets<br/>（手工注入，不进 Git）"]
    end
    ALB["ALB alb-newapi-jkt-dev"]
    U["dev.likha.hk"]

    A -->|PR| W1 --> S1
    A -->|squash merge| B
    B -->|push| W2 --> S2 --> ACR
    S2 --> S3 -->     S4 -->|push| O1
    AR -->|"poll 3min<br/>path: overlays/jkt-dev"| O1
    AR -->|"kube apply（限 newapi-dev）"| NS
    SEC -.->|"dev_deploy.sh --secret"| NS
    ACR -->|"kubelet 跨区拉取（免密）"| NS
    U --> ALB --> NS
```

**控制面分离原则**（这是整套方案能成立的关键）：

| 谁 | 只做 | 绝不做 |
|---|---|---|
| CI | 构建镜像、改 Git 里的 `images:` 字段、commit | 不碰集群（**零 kubeconfig**，不需要集群凭据） |
| ArgoCD | 拉 Git、渲染、apply | 不构建镜像、不知道 ACR 密码 |
| 人 | 注入 Secret、改 AlbConfig、应急 | 不改 Deployment/CM（改了会被 selfHeal 覆盖） |

好处：CI 侧一旦被投毒，也拿不到集群权限；集群侧凭据不出集群。

---

## 4. 目录结构（落地后的形态）

### 4.1 业务仓库 `new-api-yxw`（只加 3 个文件 + 1 个目录）

```
new-api-yxw/
├── .github/workflows/
│   ├── ci.yml                    # 复用，不动
│   └── dev-build.yml             # 【新建】push develop → 构建 + 推 ACR + 回写 ops 仓 + 可选冒烟
└── deploy/
    ├── jakarta_dev/              # 保留：bootstrap / 应急 / Secret 注入
    │   ├── scripts/dev_deploy.sh # 保留 --secret/--grants/--rotate/--status/--verify/--smoke
    │   └── manifests/            # T3 后冻结（顶部加 DEPRECATED），AlbConfig 仍以此为准
    ├── gitops/bootstrap/         # 【新建】ArgoCD 一次性安装与接入（运维工具，非清单）
    │   ├── install-argocd.sh     # 云助手 body：装非 HA 版 + 压 requests + 关 dex
    │   ├── add-repo-secret.sh    # 云助手 body：注入 ops 仓只读 deploy key
    │   ├── apply-app.sh          # 云助手 body：apply AppProject + Application
    │   ├── expose-ui.sh          # 云助手 body：建 argocd Ingress（走既有 ALB）
    │   └── verify.sh             # 只读：ArgoCD 健康 + app 状态 + requests 汇总
    └── lib/ack_remote_jkt_dev.sh # bootstrap 通道（云助手 → 节点内 kubectl）
```

> 为什么 bootstrap 留在业务仓库：它要用 `deploy/lib/ack_remote_jkt_dev.sh`（15 min 临时 kubeconfig）和堡垒机凭据，
> 这套通道的凭据体系在业务仓库的 `deploy/` 下。ops 仓库存放「期望状态」，不存放「如何把 ArgoCD 装进去」。

### 4.2 ops 仓库 `new-api-yxw-ops`（新建，私有）

```
new-api-yxw-ops/
├── README.md                        # 环境清单 + 谁能改什么
├── bases/newapi/                    # 与环境无关的骨架（当前只有 jkt 三站，但已按多环境设计）
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── resourcequota.yaml
│   ├── serviceaccount.yaml
│   ├── master-deployment.yaml       # 镜像占位 newapi-master:PLACEHOLDER（overlay 覆盖）
│   ├── slave-deployment.yaml
│   ├── channel-task-deployment.yaml
│   ├── service-master.yaml          # master 无 Service？dev 现状：无 ⇒ 只留 slave svc
│   └── service-slave.yaml
├── overlays/
│   ├── jkt-dev/
│   │   ├── kustomization.yaml       # ★ CI 唯一改动的文件（images: newTag→digest）
│   │   ├── patch-resources.yaml     # dev 收紧的 requests/limits（500m/1Gi）
│   │   ├── patch-node-type.yaml     # dev 偏差②：NODE_TYPE=master + SQL_DSN 取 MIGRATE
│   │   ├── configs/
│   │   │   ├── new-api-config.properties   # 非敏感配置（kustomize 生成，带 hash 后缀）
│   │   │   └── kustomization.yaml
│   │   ├── ingress-dev.yaml         # 只含 Ingress（AlbConfig/IngressClass 不在此）
│   │   └── DEPLOY.md                # 该环境的事实卡（集群 id / ns / 域名 / 依赖）
│   ├── jkt-pre/  └── README.md      # 占位：后续环境按同一 overlay 契约补
│   ├── jkt-test/ └── README.md      # 占位
│   └── jkt-prod/ └── README.md      # 占位
├── argocd/
│   ├── project-newapi.yaml          # AppProject：destinations 白名单到具体 env ns
│   ├── application-jkt-dev.yaml     # Application（path=overlays/jkt-dev）
│   └── applicationset.yaml          # 占位注释版：多环境后启用（git generator 扫 overlays/*）
├── scripts/
│   ├── set-image.sh                 # 被业务仓 CI 调用：改 overlay images → digest
│   └── verify.sh                    # kustomize build 全 overlay + 禁 latest + 禁明文 Secret
└── .github/workflows/verify.yml     # ops 仓自身门禁：PR 时跑 scripts/verify.sh
```

**真源唯一性**（《规范》§7.1「线上任何变更必须体现为 ops 仓库的一次 commit」）：

| 资源 | 真源 | 说明 |
|---|---|---|
| Deployment / Service / Ingress(dev) | `new-api-yxw-ops` → `overlays/jkt-dev/` | ArgoCD 管理 |
| ConfigMap（非敏感） | `overlays/jkt-dev/configs/` | kustomize `configMapGenerator` 生成 |
| Secret | **集群内**（`/root/.deploy_secrets_dev` 为 OOB 备份） | 不进任何 Git |
| AlbConfig / IngressClass | 业务仓 `deploy/jakarta_dev/manifests/dev_ingress.yaml` | 基础设施，人工 apply（D8） |
| Namespace / ResourceQuota / SA | `bases/newapi/` | 配额调整走 ops PR |
| ArgoCD 自身 | 业务仓 `deploy/gitops/bootstrap/` | 一次性 bootstrap，不自举 |

> `deploy/jakarta_dev/manifests/newapi-dev.yaml` 在 T4 之后**冻结**（顶部加 `DEPRECATED` 注释），
> 否则「两个真源」比现在的纯手工更危险。只保留其 AlbConfig 部分作为有效真源。

---

## 5. 关键设计决策（含被否掉的选项）

### D1 · CD 引擎：**ArgoCD**（否 Flux）

| 维度 | ArgoCD | Flux |
|---|---|---|
| UI | ✅ 有，4 人小组排障成本低 | ❌ 无（要配 Weave GitOps 才勉强有） |
| 多环境演进 | ApplicationSet 天然支持 mnl/sg/jkt 矩阵 | Kustomization CR 拼装，读起来更绕 |
| 资源占用 | 非 HA 最小集约 **450m / 1.1Gi** | 更轻（~250m / 400Mi） |
| 认知成本 | YAML 少，`app of apps` 直观 | 需要理解 `GitRepository`/`Kustomization`/`HelmRelease` 三层 |
| 与现有规范契合 | 《规范》§7.3 `bases/overlays/releases` 结构直接映射 kustomize | 同样支持但示例少 |

**结论**：多花 200m CPU 换排障效率和后续生产灰度扩展性，值得。dev 集群剩余 2.0 核够用。

### D2 · 仓库拓扑：**独立 ops 仓库 `new-api-yxw-ops`**（fanyan 2026-10-26 裁定）

> 原方案推荐单仓 + 路径隔离，**已按裁定改为独立 ops 仓库**。理由是提前为「预发 / 测试 / 正式」三环境铺路：
> 多环境一旦进来，manifest 的变更节奏就和业务代码完全脱钩（同一份代码可部署到 4 个环境，每次部署是一次独立 commit），
> 混在一个仓库里会导致 `develop` 的 revision 既代表「代码版本」又代表「部署状态」，两者语义冲突。

| 选项 | 优点 | 缺点 | 判定 |
|---|---|---|---|
| 单仓 + 路径隔离 | 无跨仓 token；改一处镜像只需一个 commit | revision 语义混淆；多环境后 commit 噪音指数增长 | ❌ |
| **独立 `<repo>-ops`（选）** | 部署状态与代码版本彻底解耦；多环境天然分目录；ops 仓库可单独给 ArgoCD 只读 deploy key；prod 目录可挂 CODEOWNERS | 需 1 个 `OPS_REPO_TOKEN`（PAT，90 天轮换）；镜像 bump 要跨仓 commit | ✅ |

**跨仓代价的消解**（这是选它的前提，必须做到）：

| 常规痛点 | 本方案的处理 |
|---|---|
| 改一处镜像要跨两仓 | CI 在同一个 job 里完成「推镜像 → 改 ops → 推 ops」，人只面对一次「合并 develop」 |
| 追不到「代码 commit ↔ 部署 commit」对应 | ops 的 commit message 强制带 `src=<业务仓 sha7>`，且镜像 digest 本身可反查 |
| PAT 过期导致流水线静默失效 | `dev-build.yml` 回写失败即 job 红（不吞错），并把 PAT 过期日写进值班 Checklist |
| ArgoCD 需要 ops 仓库凭据 | 用**只读 SSH deploy key**（绑单仓），不共用 PAT |

仓库命名与归属：

| 项 | 值 |
|---|---|
| 仓库 | `git@github.com:yanxuewei/new-api-yxw-ops.git`（**私有**） |
| 默认分支 | `main` |
| ArgoCD watch | `main` 分支（不做多分支模型，环境用目录区分） |
| 谁写 | 只有 CI（`gitops-bot`）与人工发布；**业务代码永不进此仓** |

### D3 · 触发模型：`push develop` 全自动，PR 只跑门禁

| 事件 | 动作 | 理由 |
|---|---|---|
| PR → develop | `ci.yml`（vet/build/test/typecheck）+ `gitops-verify.yml` | 不构建镜像，省 Actions 分钟（私有仓 2000 min/月） |
| push develop（含合并） | `dev-build.yml` → 构建 + 推 ACR + 改 gitops + commit | 唯一部署入口 |
| push main / tag | **不涉及 dev**（`release.yml` 会接管 tag，见 R1） | 生产另立方案 |

分支模型落地口径（现实 vs 规范的折中）：

- 《规范》§2 要求 `main` / `develop` / `feature/*` / `release/*` / `hotfix/*` 全套。
- **现状只有 `main`**。本期只引入 **`develop`** 一条（dev 环境源）+ 保留 `main`（生产基线），`feature/*` 按需。
- `release/*`、`hotfix/*` 留到生产 GitOps 那期再上——**先跑通一条链，别一次上全套**。

`develop` 分支保护建议（T1 配置）：

| 规则 | 值 |
|---|---|
| 禁止直接 push | 否（单人阶段允许，`enforce_admins=false`） |
| 必过检查 | `Backend vet, build, and test` + `Frontend typecheck and test` + `GitOps manifest verify` |
| 允许 CI 回写 | ✅ `dev-build.yml` 用 `GITHUB_TOKEN` push——**`GITHUB_TOKEN` 触发的 push 不会引发新 workflow，天然防循环** |

### D4 · 镜像 tag：`dev-<yyyymmdd>-<sha7>`，GitOps 记 **digest**

```text
tag    : dev-20261026-a3f9c21        # 人类可读，不可变（ACR 侧开 TagImmutability）
digest : sha256:6f1c…                # GitOps 里写这个
```

- **为什么 GitOps 写 digest 不写 tag**：tag 可被覆盖（ACR 虽可开不可变，但别赌），digest 是内容寻址，回滚时字节级确定。
- **禁令**：`latest` 永不出现在 `deploy/gitops/`（`gitops-verify.yml` 用 grep 卡）。
- `VERSION` 注入：`-ldflags "-X .../common.Version=dev-20261026-a3f9c21"`，`/api/status` 能回读 ⇒ 验证「线上版本」不需查集群（`impl_tech.md` §6.6 硬性约束 3）。

### D5 · 镜像仓库：**继续用马尼拉 ACR**（暂不开雅加达）

| 选项 | 月成本 | 延迟 | 改造量 |
|---|---|---|---|
| **A. 复用马尼拉 EE（选）** | 已有实例 **$0 增量**；跨区流量按拉取量计（单镜像约 120–200 MB，dev 一天几次可忽略） | 跨区拉取首次 ~20–40s，有节点本地缓存后近 0 | **0**（免密拉取 `acr-credential-secret-aggregation` 已配好、实测可用） |
| B. 雅加达新开 ACR 个人版 | 个人版通常免费额度内 | 同 region，秒级 | 需新建实例 + 命名空间 + 重新配免密拉取 + CI 改 registry |
| C. ACR EE 跨 region 同步 | 按同步流量计费 | 同 region 拉取 | 需 EE 高级版能力（当前 Basic，不支持） |

**结论**：dev 不是拉取瓶颈，选 A。**触发 B 的条件**：单日拉取 >50 次，或拉取失败成为 Top1 故障。

### D6 · 密钥：**不进 Git，ArgoCD 不声明**

| 方案 | 判定 | 理由 |
|---|---|---|
| Sealed Secrets / SOPS | ❌ 否 | 引入新密钥体系，dev 收益 < 复杂度 |
| External Secrets + KMS | ❌ 否 | 2026-10-05 已裁定不用 KMS |
| **existingSecret + 手工注入（选）** | ✅ | 沿用 `dev_deploy.sh --secret`（源 `/root/.deploy_secrets_dev`，600）；ArgoCD 的 Application 里**不写 Secret 资源** |

要点：

1. Secret 不在 Git ⇒ ArgoCD 不认识它 ⇒ **不会 prune 它**（ArgoCD 只删「自己管理过」的资源）。
2. Deployment 里 `envFrom.secretRef.name: new-api-secrets` 保持不变，名字固定 ⇒ 注入与 GitOps 解耦。
3. 轮换流程：`dev_deploy.sh --rotate`（RDS 口令）→ `--secret` 重新注入 → `kubectl rollout restart`。**这一步可以手工，因为它不改变期望状态**。
4. `gitops-verify.yml` 跑 `deploy/ops/secret_scan.sh` 卡门禁（已有工具，直接复用）。

### D7 · 配置变更：`configMapGenerator` 替代 checksum 渲染

现在：`dev_deploy.sh` 用集群现值渲 `checksum/config` 注解，改 CM 忘了跑脚本 ⇒ 静默不生效。
GitOps 后：kustomize `configMapGenerator` 生成 `new-api-config-<hash>`，Deployment 里的引用由 kustomize 自动替换 ⇒ **改配置必然产生新 Pod 模板 ⇒ 必然滚动**。

```yaml
# new-api-yxw-ops/overlays/jkt-dev/configs/kustomization.yaml
configMapGenerator:
  - name: new-api-config
    envs: [new-api-config.properties]   # KEY=VALUE，纯非敏感
generatorOptions:
  disableNameSuffixHash: false          # 关键：保留 hash 后缀
```

⚠️ 副作用：改配置会在集群里留下历史 `new-api-config-<旧hash>`（`prune: true` 后由 ArgoCD 清理）。首次切换时旧的无后缀 `new-api-config` 会残留，T4 手工删一次。

### D8 · 纳管边界：**不纳管 AlbConfig / IngressClass**

`deploy/jakarta_dev/manifests/dev_ingress.yaml` 里 `AlbConfig jkt-alb` 带 finalizer `ingress.k8s.alibaba/resources`，
**`kubectl delete albconfig jkt-alb` 会级联删除云上 ALB**（文件头注释已警告）。

| 资源 | 纳管 | 理由 |
|---|---|---|
| Deployment / Service / Ingress(dev) | ✅ | 日常变更对象 |
| Namespace / ResourceQuota / SA | ✅ | 配额与身份要可审计 |
| **AlbConfig / IngressClass** | ❌ | 一次性基础设施；一旦被 ArgoCD prune（比如误删 app、误改 path）会删掉云资源，爆炸半径 = 全部 dev 入口 |
| Secret | ❌ | 见 D6 |
| `yxw-new-api-*` 个人负载 | ❌（本期） | 个人调试场，纳入会产生噪音 commit；后续用独立 Application 承接 |

AppProject 侧的硬约束：

```yaml
spec:
  destinations:
    - { server: https://kubernetes.default.svc, namespace: newapi-dev }
  clusterResourceWhitelist: []          # 集群级资源一律禁止
  namespaceResourceBlacklist:
    - { group: "", kind: ResourceQuota }  # 可选：配额不许自改
```

**负向验收**：T5 时故意把 Application path 指到 `new-api-pre` 的清单，必须被 `destination` 拒绝（G7）。

### D9 · ArgoCD 访问：ALB 暴露 UI，API server 不加公网

| 通道 | 用途 | 做法 |
|---|---|---|
| **ArgoCD UI** | 日常看 Sync 状态、点回滚 | 新增 `argocd.likha.hk` Ingress（`*.likha.hk` 通配符证书已覆盖，无需新证书）+ ALB `ipWhiteList` 白名单（办公室/家庭出口 IP）+ ArgoCD 本地账号（关 dex） |
| **argocd CLI** | 脚本化操作 | 无公网 API server ⇒ 本地 CLI 连不上。需要时经 `ack_remote_jkt_dev.sh` 在节点内跑，或对 ArgoCD 做 `kubectl port-forward svc/argocd-server` |
| **kubectl** | bootstrap / 应急 | 继续走 `deploy/lib/ack_remote_jkt_dev.sh`（15 min 临时 kubeconfig） |

**为什么不给 API server 加 EIP**：加公网 = 新增攻击面 + 每小时 EIP 费 + 必须配审计。
《规范》§7.1 的「集群里禁止手工 kubectl」靠 ArgoCD 的 selfHeal 保证，不靠收走 kubectl。

### D10 · 过渡期开关（防止第一天就打架）

| 阶段 | `selfHeal` | `prune` | 效果 |
|---|---|---|---|
| T3（纳管首日） | **false** | **false** | 只读比对，看 OutOfSync 差异，不改集群 |
| T4（差异清零后） | **true** | false | 漂移自动收敛，但不删资源 |
| T5（验收通过） | **true** | **true** | 完整 GitOps（含清理历史 CM/RS） |

`prune` 放到最后开，是因为它会删掉「Git 里没有、集群里有」的资源——**第一次开之前必须先 `argocd app diff` 逐条确认**。

---

## 6. CI 流水线设计（`dev-build.yml`）

### 6.1 触发与并发

```yaml
name: dev-build
on:
  push:
    branches: [develop]
    paths-ignore:
      - '**/*.md'
      - 'deploy/docs/**'
      - 'deploy/**'             # 运维脚本改动不重新构建镜像（要构建请手动 dispatch）
  workflow_dispatch:

concurrency:
  group: dev-build-${{ github.ref }}
  cancel-in-progress: true      # 连续合并只保留最后一次
permissions:
  contents: read                # 业务仓只读；回写目标在 ops 仓，用 OPS_REPO_TOKEN
```

> 与单仓方案的差异：业务仓不再需要 `contents: write`（不自回写），
> 因此 `GITHUB_TOKEN` 推送不触发 workflow 的那套防循环机制**不再适用**——ops 仓由 PAT 推送，
> 会在 ops 仓触发它自己的 `verify.yml`（这是期望行为，不是循环，因为 ops 仓不构建镜像）。

### 6.2 作业图

```mermaid
flowchart LR
    A["push develop"] --> B["build-image<br/>buildx + GHA cache"]
    B --> C["push ACR<br/>tag=dev-日期-sha7"]
    C --> D["取 digest<br/>docker buildx imagetools inspect"]
    D --> E["trivy 扫描<br/>CRITICAL 阻断"]
    E --> F["kustomize edit set image<br/>newName@sha256:…"]
    F --> G["commit + push<br/>[skip ci]"]
    G --> H["ArgoCD 3min 内 sync"]
    H --> I["smoke（可选）<br/>curl dev.likha.hk/api/status"]
```

### 6.3 关键片段

```yaml
jobs:
  build-image:
    runs-on: ubuntu-latest
    timeout-minutes: 25
    outputs:
      tag: ${{ steps.meta.outputs.tag }}
      digest: ${{ steps.push.outputs.digest }}
    steps:
      - uses: actions/checkout@<pinned-sha>
      - name: Compute tag
        id: meta
        run: |
          TAG="dev-$(date -u +%Y%m%d)-$(git rev-parse --short=7 HEAD)"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
      - uses: docker/setup-buildx-action@<pinned-sha>
      - uses: docker/login-action@<pinned-sha>
        with:
          registry: ${{ secrets.ACR_REGISTRY }}          # acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
          username: ${{ secrets.ACR_USERNAME }}
          password: ${{ secrets.ACR_PASSWORD }}
      - id: push
        uses: docker/build-push-action@<pinned-sha>
        with:
          context: .
          file: Dockerfile                # ★ CI 用上游原版（无 NPM_REGISTRY/GOPROXY ARG）
          push: true
          platforms: linux/amd64
          tags: ${{ secrets.ACR_REGISTRY }}/newapi-dev/newapi-master:${{ steps.meta.outputs.tag }}
          build-args: |
            VERSION=${{ steps.meta.outputs.tag }}
          cache-from: type=registry,ref=${{ secrets.ACR_REGISTRY }}/newapi-dev/newapi-master:buildcache
          cache-to: type=registry,ref=${{ secrets.ACR_REGISTRY }}/newapi-dev/newapi-master:buildcache,mode=max
```

> **`VERSION` build-arg**：Dockerfile 需支持（`ARG VERSION` + 传进 `go build -ldflags`）。当前上游 `Dockerfile` 不注入
> 版本号，T2 需确认；若不支持，退化为「构建后 `/api/status` 无版本」——不阻断，但 G2 追溯性打折。此项列为 T2 待验证项。

### 6.4 回写 ops 仓库的两种做法

| 做法 | 优点 | 缺点 | 判定 |
|---|---|---|---|
| `set-image.sh` + `git commit/push`（选） | 无需额外组件，diff 可读，跨仓也能一次 job 完成 | 需要 `OPS_REPO_TOKEN`（PAT） | ✅ dev 阶段 |
| ArgoCD Image Updater（集群内） | CI 更薄 | 多一个组件 + 回写凭据进集群，且要能写 ops 仓 | ❌ 本期不引入，列入演进 |

```bash
# CI 末尾：跨仓回写（OPS_REPO_TOKEN 拥有 ops 仓 contents:write）
git clone --depth 1 "https://x-access-token:${OPS_REPO_TOKEN}@github.com/yanxuewei/new-api-yxw-ops.git" /tmp/ops
bash /tmp/ops/scripts/set-image.sh jkt-dev \
     "acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-master@${DIGEST}"
cd /tmp/ops
git -c user.name="gitops-bot" -c user.email="gitops-bot@users.noreply.github.com" \
    commit -am "chore(jkt-dev): ${TAG} (src=${GITHUB_SHA:0:7})"
git push origin main
```

**两个 deployment 引用同一个 image key**（`newapi-master`）⇒ 一次 `set-image.sh` 同时改 master 与 slave
（这是把 `images:` 抽成 kustomize 唯一 key 的理由）。commit message 里的 `src=<业务仓 sha7>` 是双向追溯的锚点：
从 ops commit 能回到代码，从镜像 digest 也能。`set-image.sh` 内部用 `kustomize edit set image`，且失败即 `exit 1`（不吞错）。

---

## 7. ArgoCD 部署与配置

### 7.1 装什么、装多大

| 组件 | requests | 说明 |
|---|---|---|
| `argocd-application-controller` | 200m / 512Mi | 核心，必须 |
| `argocd-repo-server` | 150m / 256Mi | 渲染 kustomize |
| `argocd-server` | 100m / 128Mi | UI + API |
| `argocd-redis` | 50m / 128Mi | 缓存（单实例） |
| `argocd-dex-server` | **不装** | 不用 SSO，本地 admin 账号 |
| `argocd-notifications` | **不装** | 通知走既有告警通道 |
| `argocd-applicationset` | 50m / 128Mi | 可选，单环境可先不装 |
| **合计** | **~550m / 1.15Gi** | 占剩余 CPU 的 ~27% |

装完把 controller 的 `--kubectl-parallelism-limit 5` 限一下，避免并发 apply 冲爆 CPU。

### 7.2 Bootstrap 步骤（人工执行一次，走云助手通道）

```bash
# ① 建 ns + 装非 HA 版（版本钉死，禁 latest）
wsl -d Ubuntu -u root -- bash -c "cd /mnt/e/git_code/new-api-yxw && \
  bash deploy/lib/ack_remote_jkt_dev.sh deploy/gitops/bootstrap/install-argocd.sh"

# ② 注入 ops 仓只读 deploy key（私钥从堡垒机取，不进任何仓库）
bash deploy/lib/ack_remote_jkt_dev.sh deploy/gitops/bootstrap/add-repo-secret.sh

# ③ 应用 AppProject + Application（清单来自 ops 仓，本步只 apply 一次）
bash deploy/lib/ack_remote_jkt_dev.sh deploy/gitops/bootstrap/apply-app.sh

# ④ 暴露 UI（Ingress 走既有 ALB，证书复用 606823-ap-southeast-1）
bash deploy/lib/ack_remote_jkt_dev.sh deploy/gitops/bootstrap/expose-ui.sh
```

`install-argocd.sh` 的口径（body 内跑，受 15000 字节硬门禁约束）：

```bash
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.1.6/manifests/install.yaml
# 关 dex / notifications
kubectl -n argocd scale deploy/argocd-dex-server --replicas=0
# 压 requests（节点 CPU 只剩 2 核）
kubectl -n argocd set resources deploy/argocd-application-controller \
  --requests=cpu=200m,memory=512Mi --limits=cpu=1,memory=1Gi
kubectl -n argocd set resources deploy/argocd-repo-server \
  --requests=cpu=150m,memory=256Mi --limits=cpu=1,memory=1Gi
kubectl -n argocd set resources deploy/argocd-server \
  --requests=cpu=100m,memory=128Mi
```

> ⚠️ 装完必须回读 requests 总和，确认不超过集群余量（§12-R3 有撞满预案）。

### 7.3 Application 与 AppProject

```yaml
# new-api-yxw-ops/argocd/application-jkt-dev.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jkt-dev
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: newapi
  source:
    repoURL: git@github.com:yanxuewei/new-api-yxw-ops.git
    targetRevision: main
    path: overlays/jkt-dev
  destination:
    server: https://kubernetes.default.svc
    namespace: newapi-dev
  syncPolicy:
    automated: { prune: false, selfHeal: false }   # T3 起步；T4 改 true/true
    syncOptions:
      - CreateNamespace=false          # ns 由 base 自己管，别让 ArgoCD 建
      - ServerSideApply=true           # 大对象 + 注解多时防 last-applied 爆炸
      - ApplyOutOfSyncOnly=true
    retry: { limit: 3, backoff: { duration: 10s, factor: 2, maxDuration: 2m } }
  revisionHistoryLimit: 10
```

`ServerSideApply=true` 不是可选：现有 Deployment 注解多（`checksum/config`、prometheus 三条），
client-side apply 会因 `last-applied-configuration` 超 256KB 或字段冲突报错。

### 7.4 配置差异收敛（ArgoCD 常见误报）

| 现象 | 根因 | 处置 |
|---|---|---|
| 一直 OutOfSync（`spec.replicas`） | HPA 改了副本（dev 无 HPA，风险低） | `ignoreDifferences: [{kind: Deployment, jsonPointers: [/spec/replicas]}]` |
| 一直 OutOfSync（`checksum/config`） | 注解由 kustomize 生成后值不同 | 该注解在 T4 直接删掉（D7 后不需要） |
| Secret 被标 OutOfSync | Secret 不在 Git 但 Deployment 引用 | 正常，Secret 不声明即不比对 |
| `Service.spec.clusterIP` 漂移 | client-side apply 残留 | `ignoreDifferences` 或 SSA（已开） |

---

## 8. 与现存手工链路的过渡（最容易翻车的一段）

### 8.1 `dev_deploy.sh` 的去留

| 子命令 | T3 之后 | 说明 |
|---|---|---|
| `--precheck` / `--verify` / `--status` / `--smoke` | ✅ 保留 | 只读，仍是排障主力 |
| `--apply-base` / `--apply-app` | ⚠️ 改为 `kubectl diff` 对账用途 | 不再 apply（会被 selfHeal 打回） |
| `--secret` / `--grants` / `--rotate` | ✅ 保留 | Secret/DB 不在 GitOps 范围 |
| `--apply-ingress` | ✅ 保留 | AlbConfig 不纳管（D8） |
| `--set-image` / `--rollout-restart` | ❌ 停用 | 由 Git commit 代替 |

T3 时在 `dev_deploy.sh` 顶部加护栏：`--apply-app` 若检测到 ArgoCD app `jkt-dev` 存在，则**打印警告并退出**（除非 `--force`）。

### 8.2 首次纳管的差异处理（T3 的核心工作）

纳管前必须先让「Git 里的期望状态」≈「集群现状」，否则第一次 sync 就是一次全量重启：

```bash
# 1. 从集群导出三个 Deployment 的真实 spec（去掉 status / managedFields）
# 2. 与 gitops 清单逐字段 diff
kubectl -n newapi-dev get deploy new-api-dev -o yaml > /tmp/live-master.yaml
kustomize build new-api-yxw-ops/overlays/jkt-dev > /tmp/desired.yaml
kubectl diff -f /tmp/desired.yaml          # 期望：只有 image tag → digest 与 checksum 注解两处差异
```

**判定标准**：`kubectl diff` 剩余差异 ≤ 2 类（image / checksum 注解），且不含 `replicas`、`resources`、`env`、`selector`。
`selector` 任何差异都必须先人工决策——**K8s 的 selector 不可变，改就是删重建**（§12-R2）。

### 8.3 首次部署顺序（避免双 Pod 抢 Service）

现有 dev 是 master + slave 双 Deployment，Ingress 只指向 **slave**。

1. ArgoCD 先 sync slave（滚动 1→1，`maxUnavailable:0` ⇒ 新旧不重叠、Service 不空）。
2. 再 sync master（master 无 Service，只跑迁移）。
3. 顺序反了会：master 新版本跑完 AutoMigrate，slave 还是旧代码读新 schema ⇒ 报错。
   （`impl_tech.md` §6.6 硬性约束 1：**master 先升级并跑完迁移**）

> 若 ArgoCD 一次性 sync 整个 app，两个 Deployment 的 apply 顺序不保证 ⇒ 用 `sync-wave` 注解：
> slave `wave: 0`、master `wave: 1`？**反了**——迁移必须先行 ⇒ master `wave: 0`、slave `wave: 1`。
> 但 master 先起来又要等迁移完成才 Ready。稳妥做法：**保持现状波次**（master wave 0 / slave wave 1）+ master 的 startupProbe 已经在 `failureThreshold: 30 × 5s = 150s` 内覆盖迁移耗时。

---

## 9. 验收标准（逐条可测）

| # | 项 | 命令 / 观察点 | 通过判据 |
|---|---|---|---|
| V1 | ArgoCD 健康 | `kubectl -n argocd get pods` | 4 个 Pod 全 `Running`，`restarts=0` |
| V2 | 资源不超卖 | `kubectl describe node \| grep -A6 "Allocated resources"` | 两节点 CPU requests 均 <95% |
| V3 | 应用 Synced | ArgoCD UI / `argocd app get jkt-dev` | `Synced` + `Healthy`，diff 为空 |
| V4 | 自动发布闭环 | 合并一个空 commit（改 README）到 develop | ≤8 min 内两个 Deployment 都换成新 digest，Pod `restarts=0` |
| V5 | 配置变更必滚动 | 改 `new-api-config.properties`（如 `SYNC_FREQUENCY: 30→45`）走 PR | CM 名带新 hash + Pod 自动滚动 + `kubectl exec` 回读为 45 |
| V6 | 漂移自愈 | 手工 `kubectl set image ... :xxx` | ≤3 min 被拉回正确 digest，ArgoCD 显示 `OutOfSync → Synced` |
| V7 | 回滚 | `argocd app rollback jkt-dev <id>` 或 `git revert` | ≤3 min 回到上一 digest，`/api/status` 版本号同步回退 |
| V8 | 密钥零入仓 | `bash deploy/ops/secret_scan.sh` | 0 命中 |
| V9 | 隔离负向测试 | Application 临时指 `namespace: new-api-pre` | 被 AppProject 拒绝，错误信息含 `destination` |
| V10 | 冒烟 | `curl -sk https://dev.likha.hk/api/status` | 200 + `success:true` + 版本号 = 最新 tag |
| V11 | 门禁生效 | 提一个含 CRITICAL 漏洞或写入明文密码的 PR | `dev-build` / `gitops-verify` 红，不可合并 |

---

## 10. 实施计划（6 阶段，含回滚）

| 阶段 | 内容 | 产出 | 回滚 |
|---|---|---|---|
| **T0 · 决策确认**（0.2 人日） | §5 的 D1–D10 逐条过；**已完成**：Q1 `develop`（fanyan 已建，`c48790d`）/ Q2 UI 对外 / Q3 复用马尼拉 ACR / Q4 个人负载不纳管 / **新增：独立 ops 仓库 `new-api-yxw-ops`** | 本文件 §13 决策记录 | — |
| **T1 · 仓库与凭据**（0.3 人日） | ① 建私有空仓 `new-api-yxw-ops`（**必须建仓才能 push**）② 生成一对 ops 仓 SSH deploy key（只读，绑单仓）+ 一个 PAT（`OPS_REPO_TOKEN`，`contents:write` on ops，90 天到期）③ 业务仓配 4 个 Secrets：`ACR_REGISTRY` / `ACR_USERNAME` / `ACR_PASSWORD` / `OPS_REPO_TOKEN`（+ `SMOKE_URL` 可选）④ `develop` 分支保护（必过 `ci.yml` 两 job） | ops 仓可 push；业务仓 secrets 齐 | 删仓库 / 删 secrets，无集群副作用 |
| **T2 · ops 仓骨架 + 镜像流水线**（0.5 人日） | ① 按 §4.2 生成 `bases/newapi` + `overlays/jkt-dev`（**期望状态抄集群现状**，见 §8.2）② ops 仓 `verify.sh` + `verify.yml` 门禁 ③ 业务仓 `dev-build.yml`，先 `workflow_dispatch` 手动跑一次 | 一次成功的构建；`newapi-dev/newapi-master:dev-20261026-xxxxxxx` 在 ACR；ops 仓出现 1 个 `chore(jkt-dev)` commit | 删 workflow；ACR tag 保留无害 |
| **T3 · ArgoCD 落地（只读）**（0.4 人日） | 装 ArgoCD（§7.2）+ 注入 ops deploy key + AppProject/Application（**selfHeal=false, prune=false**）+ `argocd.likha.hk` 暴露 + 做 §8.2 的 live-vs-desired diff | UI 可访问，app 显示 OutOfSync 且差异已知（目标 ≤2 类） | `kubectl delete ns argocd`（selfHeal=false 期间没改集群，**newapi-dev 零影响**） |
| **T4 · 切换真源**（0.3 人日） | 首次 `sync`（master wave 0 / slave wave 1）；删 `checksum/config` 注解与旧 `new-api-config`；`dev_deploy.sh --apply-app` 上护栏；开 `selfHeal=true` | 集群状态完全来自 ops 仓 | `git revert` ops commit + `dev_deploy.sh --apply-app --force` 回手工态 |
| **T5 · 闭环与验收**（0.3 人日） | 打通「合并 develop → 自动上线」；跑 V1–V11；开 `prune=true`（先 `argocd app diff` 逐条确认）；出《执行报告》 | 11 项验收全绿 | 关 `prune` 即退到 T4 状态 |

**关键节奏建议**：T3 与 T4 之间**隔一个工作日**。先让 ArgoCD 以只读模式跑一天，
观察它对「手工改动的感知」是否符合预期（这一步能提前暴露 `ignoreDifferences` 的缺项）。

**T1 是唯一的硬阻塞**：`new-api-yxw-ops` 仓库必须先在 GitHub 上存在（私有），否则 T2 的 push 和 T3 的
ArgoCD 拉取都无从谈起。建仓方式在 §15。其余阶段都可自动推进。

---

## 11. 资源与成本

| 项 | 增量 | 说明 |
|---|---|---|
| 集群 CPU requests | **+550m**（占剩余 2.0 核的 27%） | 若撞满，见 R3 |
| 集群内存 requests | +1.15Gi（剩余 18.8Gi，无压力） | — |
| 云资源费 | **$0** | ArgoCD 自托管，无托管版费用 |
| 跨区镜像拉取 | 每次新 digest 约 120–200 MB × 节点数(2) | 马尼拉→雅加达跨区流量，dev 频次低，月度 <$1 |
| GitHub Actions | 每次构建约 **8–12 min**（Go + bun + buildx cache 命中后 5–7 min） | 私有仓 2000 min/月；按日均 5 次合并 ≈ 1500 min/月，**贴线**，需盯 |
| 域名/证书 | $0 | `*.likha.hk` DV 通配符已覆盖 `argocd.likha.hk` |

> **Actions 分钟数是隐藏成本**：如果超，选项是 ① 只在 `develop` 合并（非每次 push）触发 ② 把 `ci.yml` 的
> `closed` 事件去掉（现在 PR 合并后会再跑一遍，纯浪费）③ 上自建 runner（**本期不可行**：节点只剩 2 核，构建会打满）。

---

## 12. 风险与坑（按踩中概率排序）

| # | 风险 | 后果 | 预防 |
|---|---|---|---|
| **R1** | 误用 tag 触发 dev 发布 | `release.yml` 的 `tags: ['*']` 会启动 Linux/macOS/Windows 三平台二进制构建，白烧 30+ min 且大概率失败（macOS runner 缺 bun 兼容性未知） | dev 流水线**只用 branch + sha**；`dev-build.yml` 不监听 tag |
| **R2** | `selector` 漂移 | K8s **selector 不可变**；Git 里的 selector 与集群不一致 ⇒ apply 报 `field is immutable` ⇒ 只能删 Deployment 重建（每环境约 30s 无后端） | T3 diff 阶段把 selector 差异列为「必须人工决策」项；清单里 selector 用**单键** `app=<deploy 名>`（现有 `new-api-dev` 是双键 `app+track`，若保留双键则不许再加维度） |
| **R3** | ArgoCD 装完 CPU 撞满 | 两节点 requests 已 80%/67%，新 Pod Pending | 装前算总和；超了就 ① 压 requests（已压）② 给 `np-jkt-dev-x4c` 加 1 个节点（弹性已开，但 `skip_nodes_with_system_pods:true` ⇒ **不会自动缩**，加完记得 `task42/shrink_nodepool.sh`） |
| **R4** | 首次 sync 触发全量重启 | dev 短暂 503 | master wave 0 / slave wave 1（§8.3）；避开 perf 压测窗口 |
| **R5** | `prune=true` 删掉「Git 里没有但救灾用的」资源 | 如手工建的 debug Pod、临时 ConfigMap | 开 prune 前 `argocd app diff` 逐条确认；把救灾资源打 `argocd.argoproj.io/compare-options: IgnoreExtraneous` |
| **R6** | ArgoCD 拿不到私仓 | `ComparisonError: authentication required` | 装 SSH deploy key（只读）；先用 `ssh -T git@github.com` 在 repo-server Pod 内验 |
| **R7** | `kustomize edit set image` 写 tag 而非 digest | tag 被覆盖后回滚失效 | CI 里强制 `@sha256:` 形式；`gitops-verify.yml` grep 兜底 |
| **R8** | CM 改名导致 env 丢失 | Pod CrashLoop | `configMapGenerator` 必须保留 `name: new-api-config`，只是加后缀；Deployment 用 `envFrom.configMapRef.name: new-api-config`（kustomize 自动替换后缀，**不要手工写后缀**） |
| **R9** | Actions 分钟数耗尽 | 流水线停摆 | 见 §11 三个选项 |
| **R10** | ArgoCD 与 `dev_deploy.sh` 互相覆盖 | 状态反复横跳，排查困难 | T4 给脚本上护栏（§8.1）；团队公告「Deployment/CM 只经 Git 改」 |
| **R11** | `OPS_REPO_TOKEN`（PAT）过期 | `dev-build.yml` 在最后一步 403，镜像推了但部署没变 ⇒ **最危险的静默失败形态** | ① 回写步骤失败必须 `exit 1`（不写 `\|\| true`）② 把到期日写进值班 Checklist ③ 到期前 7 天 `dev-build.yml` 加一步校验 PAT 有效期（`/user` 返回的 `github-authentication-token-expiration`） |
| **R12** | 两个来源同时写 ops 仓 | `push` 被拒（non-fast-forward）或覆盖别人改动 | CI 用 `git pull --rebase` 后重推；**禁止 force push**（ops 仓 main 开分支保护 + 不允许 force） |
| **R13** | 跨仓 debug 链路变长 | 出问题要先搞清楚是代码仓还是 ops 仓 | commit message 强制带 `src=<sha7>`；《执行报告》里记录「三件套」：业务仓 sha / 镜像 digest / ops commit sha |

---

## 13. 决策记录（2026-10-26 fanyan 已确认）

| # | 决策 | 结论 | 落地影响 |
|---|---|---|---|
| Q1 | 是否引入 `develop` | **引入**，已创建（`c48790db437e55e9a412c9ba71c269360c69a9d0`） | `dev-build.yml` 的触发源 = `push develop` |
| Q2 | ArgoCD UI 是否对外 | **对外**，`argocd.likha.hk` + IP 白名单 | §7.2 ④；DNS 加 A/CNAME 一条 |
| Q3 | 镜像仓库 | **复用马尼拉 ACR EE**，jkt 跨区公网拉取 | §5-D5 选项 A |
| Q4 | `yxw-new-api-*` 个人负载 | **本期不纳管** | §5-D8；后续用独立 Application 承接 |
| Q5 | 仓库拓扑 | **独立 ops 仓库 `new-api-yxw-ops`**（原方案单仓 → 已改） | §5-D2、§4.2 全量重写；CI 改跨仓回写 |
| Q6 | 是否预留多环境 | **是**：`bases/newapi` + `overlays/{jkt-dev,jkt-pre,jkt-test,jkt-prod}` | overlay 契约定了，后续环境只补目录 |

---

## 14. 后续演进（不在本期）

1. **生产 GitOps**（mnl/sg）：dev 跑稳 2 周后另立方案，需叠加 `impl_tech.md` §6.5.2 的 canary（ALB 权重）+ §6.6 的回滚决策树。
2. **ApplicationSet 多环境矩阵**：`jkt-dev` / `jkt-pre` / `mnl-prod` 用同一 base + 不同 overlay 生成。
3. **ArgoCD Image Updater**：把 CI 里的「回写 git」搬到集群侧，CI 变纯构建。
4. **Argo Rollouts**：需要 canary + 自动门禁时再引入（dev 不需要）。
5. **ops 仓库拆分**：出现第二审批人时 `git subtree split`。
6. **冒烟 job 常态化**：`dev-build.yml` 末尾 curl `/api/status`，失败自动 `git revert` 上一 commit（真正的自动回滚）。

---

## 15. 建仓与凭据准备（T1 操作清单）

### 15.1 建 ops 仓库（必须人工，SSH 不能建仓）

```bash
# 方式 A：网页（最快）
#   github.com → New repository → Name: new-api-yxw-ops → Private → 不勾 README/gitignore
#
# 方式 B：有 PAT 时用 API
curl -sS -X POST https://api.github.com/user/repos \
  -H "Authorization: Bearer $GH_TOKEN" \
  -d '{"name":"new-api-yxw-ops","private":true,"auto_init":false}'
```

建完立刻推本地骨架（骨架在 T2 生成）：

```bash
cd /e/git_code/new-api-yxw-ops
git init -b main
git add -A && git commit -m "chore: bootstrap ops repo (jkt-dev overlay)"
git remote add origin git@github.com:yanxuewei/new-api-yxw-ops.git
git push -u origin main
```

### 15.2 两把凭据（分开，不要复用）

| 凭据 | 用途 | 权限 | 存放 | 轮换 |
|---|---|---|---|---|
| **ops deploy key**（SSH，只读） | ArgoCD 拉 ops 仓 | 仅 `new-api-yxw-ops` 的 read | 集群内 Secret `argocd/repo-new-api-yxw-ops`；私钥备份在堡垒机 | 泄漏时重建（ArgoCD 侧改 Secret 即生效） |
| **`OPS_REPO_TOKEN`**（细粒度 PAT） | CI 回写 ops 仓 | 仅 `new-api-yxw-ops` 的 `Contents: Read and write` | 业务仓 Repository Secrets | **90 天**，到期日写进值班 Checklist |

生成 deploy key（在 WSL 里执行，私钥不进仓库）：

```bash
ssh-keygen -t ed25519 -C "argocd@jkt-dev" -f /root/.ssh/ops_newapi_yxw -N ""
cat /root/.ssh/ops_newapi_yxw.pub     # → GitHub: ops 仓 Settings → Deploy keys → Add（不勾 write）
```

### 15.3 业务仓 4 个 Secrets

| Secret | 值来源 |
|---|---|
| `ACR_REGISTRY` | `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com` |
| `ACR_USERNAME` | `yanxuewei@5108890064395960` |
| `ACR_PASSWORD` | ACR 控制台「访问凭证」里的**固定密码**（不是阿里云账号密码） |
| `OPS_REPO_TOKEN` | §15.2 的 PAT |

> `ACR_PASSWORD` 当前不在 `/root/.deploy_secrets*` 里（该目录只有 RDS/CK/SESSION/TLS 类），
> 需要从 ACR 控制台或密码管理器取一次；`push.sh` 之前是交互输入的。

### 15.4 ArgoCD 初始口令

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# 登录后立刻改密（UI → User Info → Update Password），并把新口令存密码管理器
```

---

## 附录 A · 命令速查

```bash
# ── 只读巡检（不变）
bash deploy/jakarta_dev/scripts/dev_deploy.sh --status
bash deploy/jakarta_dev/scripts/dev_deploy.sh --verify
bash deploy/jakarta_dev/scripts/dev_deploy.sh --smoke

# ── ArgoCD（集群内，经云助手通道）
bash deploy/lib/ack_remote_jkt_dev.sh <(echo 'kubectl -n argocd get app jkt-dev')   # 或写成 body 文件
kubectl -n argocd get app jkt-dev -o jsonpath='{.status.sync.status} {.status.health.status}'
kubectl -n argocd get app jkt-dev -o jsonpath='{.status.summary.images}'

# ── 本地渲染对账（不需要集群）
kustomize build new-api-yxw-ops/overlays/jkt-dev | grep 'image:'
kustomize build new-api-yxw-ops/overlays/jkt-dev | kubectl diff -f -   # 需 kubeconfig

# ── 手工发布（应急，GitOps 后应尽量避免）
git switch develop && git pull --ff-only
# 改代码 → PR → 合并即自动发布；不要 bash deploy/ops/push.sh 手工推

# ── 回滚
git revert <gitops commit> && git push          # ≤3 min 生效
# 或 ArgoCD UI → History → Rollback

# ── Secret 轮换（仍在 GitOps 之外）
bash deploy/jakarta_dev/scripts/dev_deploy.sh --rotate
bash deploy/jakarta_dev/scripts/dev_deploy.sh --secret
bash deploy/lib/ack_remote_jkt_dev.sh <(echo 'kubectl -n newapi-dev rollout restart deploy/new-api-dev-slave')
```

## 附录 B · 与《规范》条款的对照

| 《规范》条款 | 本方案落点 | 偏差说明 |
|---|---|---|
| §1.1 仓库拓扑（upstream/origin/ops 三仓） | ✅ **独立 ops 仓库** `new-api-yxw-ops` | 本轮按 fanyan 裁定对齐（原方案曾是单仓，已改） |
| §2 分支模型 Git Flow | 业务仓落 `main` + `develop` + `feature/*`；ops 仓单 `main` 分支 + 环境目录 | `release/*`/`hotfix/*` 随生产 GitOps 那期引入；ops 仓不需要分支模型 |
| §7.1 线上变更 = ops 仓库一次 commit | ✅ 逐字落地 | — |
| §7.2 禁 latest、tag 与 git tag 一致 | dev 用 `dev-日期-sha7`，GitOps 记 digest | dev 无 semver，生产那期对齐 |
| §7.3 ops 仓库结构（bases/overlays/releases） | ✅ `bases/newapi` + `overlays/*`；`releases/` 用 commit message `src=` 代替 | 单环境暂不建 `releases/vX.yaml` 目录，多种环境后再加 |
| §7.5 发布后健康检查 + 自动回滚 | T5 之后的演进项 6 | 本期只有冒烟，无自动 revert |
| §8.1 workflow 清单（ci/release/sync/e2e） | `ci.yml` 复用 + 新增 `dev-build.yml` / `gitops-verify.yml` | e2e-nightly 未建（dev 无 e2e 套件） |
| §8.2 Action 固定 commit SHA | ✅ 沿用现有 pin 风格 | — |
| §9 ACR 菲律宾 Region | ✅ 继续用马尼拉 EE | 雅加达无实例（§1.5） |
| §11 值班规范 | 本期不涉及 | 单人环境 |

---

_方案结束。确认 §13 四个决策点后，按 §10 的 T0→T5 推进，每个阶段产出独立执行报告。_
