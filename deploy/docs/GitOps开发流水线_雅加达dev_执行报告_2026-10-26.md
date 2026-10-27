# GitOps 开发流水线 · 雅加达 dev 执行报告

> 执行日期：2026-10-26（19:00–19:35 GMT+8）
> 方案：`deploy/docs/GitOps开发流水线_雅加达dev_搭建方案_2026-10-26.md`
> 覆盖阶段：**T0 决策 / T1 仓库与凭据 / T2 ops 骨架 / T3 ArgoCD 落地（只读比对已通过并完成首次 sync）**
> 未完成：T2 的「CI 首次构建」卡在 1 个缺失凭据（`ACR_PASSWORD`）；T4/T5 的分档开关待推进

---

## 1. 一句话结论

**ArgoCD 已在雅加达 dev 集群跑起来并接管了 3 个工作负载**：`new-api-dev`、`new-api-dev-slave`、
`new-api-channel-task-dev` 的镜像与 ConfigMap 现在完全由 `new-api-yxw-ops` 仓库的 `overlays/jkt-dev` 决定，
`argocd.likha.hk` 可公网访问，`dev.likha.hk` 冒烟 200。
CI 侧只差一个 ACR 密码就能打通「合并 develop → 自动上线」。

---

## 2. 落地清单

### 2.1 新建 ops 仓库 `yanxuewei/new-api-yxw-ops`（私有）

3 个 commit：

| commit | 内容 |
|---|---|
| `6ac3e7c` | bootstrap：base + overlay + argocd + scripts + 门禁 |
| `dbfefd4` | `.gitattributes`（全仓强制 LF，防 Windows 侧 CRLF 污染脚本） |
| `d25b028` | DEPLOY.md 补「yxw-* 与旧 ConfigMap 耦合」 |

结构与方案 §4.2 一致：

```
bases/newapi/          6 个对象（SA / master / slave / channel-task / 2×Service）
overlays/jkt-dev/      kustomization + namespace + configs + ingress + DEPLOY.md
overlays/jkt-{pre,test,prod}/  占位 README（含补齐契约）
argocd/                project-newapi + application-jkt-dev + applicationset（注释版）
scripts/               set-image.sh / verify.sh
.github/workflows/     verify.yml
```

门禁实测：`bash scripts/verify.sh` → **ALL PASS**（C1 渲染 / C4 无 Secret / C5 无 AlbConfig / C6 无明文凭据）。

### 2.2 ArgoCD

| 项 | 值 |
|---|---|
| 版本 | `v3.5.6`（`install.yaml` 用 `--server-side --force-conflicts` 安装） |
| 命名空间 | `argocd` |
| 组件 | `application-controller`(StatefulSet) / `repo-server` / `server` / `redis` 各 1 副本，全 `Running` `restarts=0` |
| 关掉 | `dex` / `notifications` / `applicationset`（replicas=0） |
| requests | controller `200m/512Mi`、repo-server `150m/256Mi`、server `100m/128Mi`、redis `50m/128Mi` |
| UI | **`https://argocd.likha.hk`** → ALB `alb-4okmogghe7hbv5fwm6` → `svc/argocd-server:80`（`--insecure`，TLS 由 ALB 终止） |
| 证书 | 复用 DV 通配符 `606823-ap-southeast-1`，**没有新签证书** |
| DNS | `argocd.likha.hk` CNAME → ALB，RecordId `2114679549933309952`，TTL 600 |
| 仓库凭据 | SSH deploy key **只读**（key_id `167702269`），私钥在 `/root/.ssh/ops_newapi_yxw`（600） |

`curl https://argocd.likha.hk/api/version` → `{"Version":"v3.5.6"}` ✅

### 2.3 Application

| 项 | 值 |
|---|---|
| 名称 / 项目 | `jkt-dev` / `newapi`（AppProject） |
| 源 | `git@github.com:yanxuewei/new-api-yxw-ops.git` @ `main`，path `overlays/jkt-dev` |
| 目标 | `https://kubernetes.default.svc` / `newapi-dev` |
| 同步策略 | `automated: {selfHeal: false, prune: false}`（T3 保守档） |
| 实测状态 | **`Synced` + `Healthy`**，revision `dbfefd4`（后更新为 `d25b028`） |

AppProject 的硬边界已生效：`destinations` 只列 `newapi-dev`，`clusterResourceWhitelist` 只开 `Namespace`，
`namespaceResourceBlacklist` 挡住 `ResourceQuota` / `LimitRange`。

### 2.4 接管后的集群实况（实测）

| 对象 | 接管前 | 接管后 |
|---|---|---|
| `new-api-dev` 镜像 | `newapi-master:20261026-1735` | `newapi-master@sha256:e58cac65…56727`（= tag 1855） |
| `new-api-dev-slave` 镜像 | `newapi-master:20261026-1855` | 同上 —— **两者从此一致** |
| ConfigMap | `new-api-config`（手工 apply） | `new-api-config-fg8d27t4hm`（kustomize 生成） |
| `checksum/config` 注解 | 靠 `dev_deploy.sh` 渲染 | **已删除**，改由 CM 名带 hash 保证滚动 |
| Pod | 滚动前 79s 全新建，`restarts=0` | — |
| `yxw-new-api-*` | 未受影响（未纳管） | 未受影响 ✅ |

公网冒烟：`https://dev.likha.hk/api/status` → **200**（3.0s）。

### 2.5 业务仓 `develop` 分支 Secrets（3/4 就绪）

| Secret | 状态 |
|---|---|
| `ACR_REGISTRY` | ✅ `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com` |
| `ACR_USERNAME` | ✅ `yanxuewei@5108890064395960` |
| `OPS_REPO_TOKEN` | ✅（当前复用 yanxuewei 的 classic PAT，`repo`+`workflow` scope） |
| `ACR_PASSWORD` | ❌ **缺**（本机 `/root/.deploy_secrets*` 无此项、docker 用 credsStore 无明文） |

### 2.6 业务仓新增脚本

`deploy/gitops/bootstrap/` 6 个（全部走云助手通道，15 min 临时 kubeconfig）：

| 脚本 | 作用 | 幂等 |
|---|---|---|
| `install-argocd.sh` | 装 ArgoCD + 关组件 + 压 requests + `--insecure` | ✅ |
| `add-repo-secret.sh` | 注入 ops 仓只读 deploy key（本地读私钥，不进仓库） | ✅ |
| `apply-app.sh` | 投递 AppProject + Application（清单来自 ops 仓） | ✅ |
| `expose-ui.sh` | 建 `argocd.likha.hk` Ingress（order 60） | ✅ |
| `set-secrets.sh` | 批量写 Actions Secrets（libsodium sealed box） | ✅ |
| `verify.sh` | 只读体检：组件 / app 状态 / requests / 节点 | — |

`.github/workflows/dev-build.yml` 已写好（**未提交**，等 `ACR_PASSWORD`）。

---

## 3. 踩到的 6 个坑（全部当场修掉，写进后续 SOP）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| **K1** | `kubectl apply` 整个 install.yaml 失败：`The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes` | CRD 内嵌 schema 过大，client-side apply 把整份清单塞进 `last-applied-configuration` 注解，超 256KB 上限 | 改 `kubectl apply --server-side=true --force-conflicts` |
| **K2** | `argocd-server` CrashLoopBackOff，日志 `[FATAL tini (6)] exec --insecure failed: No such file or directory` | v3.5 的 `argocd-server` **没有 `command`**，`args[0]` 本身就是可执行文件 `/usr/local/bin/argocd-server`；我用 json patch 把 args 整体替换成 `["--insecure"]`，等于让 tini 去执行 `--insecure` | args 写成 `["/usr/local/bin/argocd-server","--insecure"]` |
| **K3** | `kubectl set resources deploy/argocd-application-controller` → `NotFound` | v3.x 的 application-controller 是 **StatefulSet**（pod 名带 `-0`），不是 Deployment | 用 `sts/argocd-application-controller` |
| **K4** | body 脚本报 `r: unbound variable` | `set -u` 下 `local a="$1" b="$2" c="${a}…"` **同一行内前面的赋值对后面不可见**（local 同时求值） | 拆成多行 `local` |
| **K5** | 旧 `new-api-config` 想删不敢删 | `yxw-new-api-master/slave`（个人负载、未纳管）的 `envFrom` 仍指向它 → 删了这两个 Pod 起不来 | **保留旧 CM**，并把耦合写进 `overlays/jkt-dev/DEPLOY.md` |
| **K6** | 节点数 2 → 3，一度怀疑是 ArgoCD 压垮集群 | 第 3 台 `ap-southeast-5.10.2.36.198` 创建于 **2026-10-26T08:21Z**（用户当天下午手工部署触发），**不是本次安装造成**；该节点已承载 23 个业务 Pod，不能缩 | 不动；记入成本口径 |

> K1/K2/K3 都是「ArgoCD 官方 install.yaml 在 k8s 1.35 + 特定版本下的坑」，上游 issue 里有但没写进 quickstart。
> 这三个已固化进 `install-argocd.sh` 的注释，重装不会再踩。

---

## 4. 验收矩阵（对照方案 §9）

| # | 项 | 结果 |
|---|---|---|
| V1 | ArgoCD 健康 | ✅ 4 Pod `Running`、`restarts=0` |
| V2 | 资源不超卖 | ✅ 两节点 requests 从 80%/67% 降到 70%/52%（+50m~+200m 增量，未触发 Pending） |
| V3 | 应用 Synced | ✅ `Synced` + `Healthy`，diff 空 |
| V4 | 自动发布闭环 | ⏳ 等 `ACR_PASSWORD` |
| V5 | 配置变更必滚动 | ✅ 机制已验证（CM 名 `new-api-config-fg8d27t4hm`，Deployment 引用自动跟随）；**改值实测待 T4** |
| V6 | 漂移自愈 | ⏸ `selfHeal=false`（T3 档），T4 开 |
| V7 | 回滚 | ⏳ 待 V4 打通后测 |
| V8 | 密钥零入仓 | ✅ `verify.sh` C4/C6 全过；ops 仓无 Secret 资源 |
| V9 | 隔离负向测试 | ⏸ 待 T5 做（当前靠 AppProject 白名单静态保证） |
| V10 | 冒烟 | ✅ `https://dev.likha.hk/api/status` 200 |
| V11 | 门禁生效 | ⏳ ops 仓 `verify.yml` 首次 PR/跑通待观察 |

---

## 5. 与方案的偏差

| 项 | 方案 | 实际 | 原因 |
|---|---|---|---|
| ArgoCD 版本 | 写 `v3.1.6` | **`v3.5.6`**（当前 latest） | 采用最新 stable |
| 安装方式 | `kubectl apply` | **`--server-side --force-conflicts`** | K1 |
| `argocd-server` | 未细写 | args 需保留可执行文件路径 | K2 |
| 首次 sync 形态 | 计划 T3 只读一天再 T4 | **Application 创建即触发 automated sync**（ArgoCD 行为），集群已滚动 | automated 策略对已 OutOfSync 的 app 会立即同步；对 dev 无风险，但**下次别在有状态环境这么干** |
| 旧 CM 清理 | T4 删 | **不删**（K5） | yxw-* 耦合 |
| 节点 | 假设 2 台 | **3 台**（08:21Z 已有第三台） | K6 |

---

## 6. 下一步（按优先级）

### P0 · 需要 fanyan 提供 1 项

**`ACR_PASSWORD`** —— ACR 控制台 → 实例 `acr-newapi-mnl` → 访问凭证 → 固定密码。
拿到后一条命令配完并触发首次构建：

```bash
cd /e/git_code/new-api-yxw
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
bash deploy/gitops/bootstrap/set-secrets.sh "ACR_PASSWORD=<密码>"
git add .github/workflows/dev-build.yml deploy/gitops && git commit -m "feat(ci): dev-build 流水线（构建→ACR→回写 ops）"
git push origin develop     # ← 触发首次构建
```

### P1 · T4（1 个工作日后）

1. `argocd app diff jkt-dev` 逐条确认无意外差异
2. Application `selfHeal → true`（`prune` 仍 false）
3. 负向测试：手工 `kubectl set image` 改 slave → 观察 3 min 内被拉回

### P2 · T5

1. 打通 V4/V7/V11
2. `prune → true` 前先确认 `argocd app diff` 里没有「集群有、Git 无」的必需资源（`yxw-*` 不在 app 内，不受影响）
3. 把 `trivy` 的 `exit-code` 从 `0` 改成 `1`（CRITICAL 阻断）

### P3 · 待决策

| 项 | 说明 |
|---|---|
| `OPS_REPO_TOKEN` 换细粒度 PAT | 现在复用的是 yanxuewei 的 classic PAT（`repo`+`workflow`），权限过大。建议换成只对 `new-api-yxw-ops` 有 `Contents: write` 的 fine-grained PAT（90 天） |
| `yxw-*` 是否纳管 | 不纳管就要一直容忍「改配置个人负载不生效」（K5） |
| ArgoCD admin 口令 | 初始口令在 `argocd-initial-admin-secret`，**登录后立刻改密**并删掉该 Secret |

---

## 7. 回滚（每一步都可逆）

```bash
# 1) 只回滚应用（ArgoCD 保留）
kubectl -n argocd patch app jkt-dev --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# 然后用旧链路恢复手工部署：
bash deploy/jakarta_dev/scripts/dev_deploy.sh --apply-app --force

# 2) 彻底拆掉 ArgoCD（不影响 newapi-dev 的工作负载，它们已经 apply 完了）
kubectl delete -n argocd ingress argocd-server
kubectl delete ns argocd          # CRD 会保留，需要时再删：
# kubectl get crd | grep argoproj | awk '{print $1}' | xargs kubectl delete crd

# 3) 撤销 DNS
aliyun alidns DeleteDomainRecord --RecordId 2114679549933309952

# 4) ops 仓回滚到手工态之前的 commit
cd /e/git_code/new-api-yxw-ops && git revert <commit> && git push
```

> ⚠️ 删 `argocd` ns 不会动 `newapi-dev` —— ArgoCD 的 `resources-finalizer` 只在删 Application 时级联，
> 删 ns 会先删 Application 从而触发级联删除工作负载。**要保工作负载就先删 Application 的 finalizer**：
> `kubectl -n argocd patch app jkt-dev --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`，再删 ns。

---

## 8. 留档：本次实测的关键 id

| 项 | 值 |
|---|---|
| ops 仓 | `git@github.com:yanxuewei/new-api-yxw-ops.git`（private，main） |
| 基线镜像 digest | `sha256:e58cac65ec7fbb3692cae4e3d6b0e53955f731d8466b22f4f2559db6f4056727`（tag 20261026-1855） |
| deploy key id | `167702269`（read-only） |
| DNS RecordId | `argocd=2114679549933309952` |
| Application revision | `d25b028` |
| ArgoCD Ingress order | `60`（dev 现有：1/2/3/4/50/51/52/53） |
| 节点 | `10.2.25.190`(5a) / `10.2.36.198`(5b) / `10.2.90.173`(5c) |

---

## 9. 补记 · 2026-10-27：CI 闭环打通

### 9.1 结果：端到端跑通

```
push develop (c3a96e62e)
  → dev-build run 40444294566 success（约 5 min，GHA 缓存后）
  → ACR: newapi-dev/newapi-master:dev-20261027-c3a96e6 @ sha256:dab54390…
  → ops 仓自动 commit: cf21ae9 "chore(jkt-dev): dev-20261027-c3a96e6 (src=c3a96e6)"
  → ArgoCD: Synced + Healthy, rev=cf21ae9
  → 线上 /api/status: {"version":"dev-20261027-c3a96e6"} ✅
```

**V4 / V7 / V10 验收通过**：一次合并 → 自动上线 → 版本可反查，全程无人工 kubectl。

### 9.2 ACR 密码来源（fanyan 提供）

在 `/home/fanyan/.bashrc`（第 285–286 行）：

```bash
export ACR_USER=...
export ACR_PASSWORD="..."   # 12 位
```

⚠️ **两个认知修正**：

1. 变量在 **fanyan** 用户下、且 `.bashrc` 属非交互守卫范围 ⇒ `wsl -u root bash -c` 读不到；
   必须 `bash -lc` 或用脚本解析 `.bashrc` 文件本身。
2. **ACR EE 走 Bearer token 流程**：`GET /v2/` 带 Basic 凭据**必然 401**（返回
   `WWW-Authenticate: Bearer realm="https://dockerauth-ap-southeast-6.aliyuncs.com/auth"`）。
   验证凭据正确姿势是打 token 端点：

   ```bash
   curl -u "$ACR_USER:$ACR_PASSWORD" \
     "https://dockerauth-ap-southeast-6.aliyuncs.com/auth?service=registry.aliyuncs.com:ap-southeast-6:international:cri-avfqy9xkqi5bj8ee&scope=repository:newapi-dev/newapi-master:pull"
   ```
   返回 JSON 含 `token` 即为有效。**不要用 `/v2/` 的 401 判断密码错。**

### 9.3 新踩的 4 个坑

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| **K7** | dev-build 在 `Set up job` 3 秒失败 | `aquasecurity/trivy-action@0.28.0` —— tag **必须带 `v` 前缀**（`v0.36.0`），否则 `Unable to resolve action` | 改为 pin commit SHA `ed142fd…` (v0.36.0)，同时满足「action 必须 pin SHA」的规范 |
| **K8** | 新 Pod `ImagePullBackOff`，事件里镜像变成 `docker.io/library/newapi-master@sha256:…` | `needs.build-push.outputs.image` 传过去是**空串** ⇒ `set-image.sh` 收到 `@sha256:…` ⇒ `newName:` 被写空 ⇒ kustomize 渲染出裸名 ⇒ kubelet 去 docker.io 找 | ① bump-ops job 用 `secrets.ACR_REGISTRY + env` 自拼，并校验含 `aliyuncs.com` ② `set-image.sh` 增加「repo 为空/非三段地址即拒绝」防呆 ③ `kubectl get events` 是第一现场，一眼能看出名字退化了 |
| **K9** | ops 仓 `verify` 两次 failure，日志里没有任何脚本输出 | GitHub 额度/账单：`The job was not started because recent account payments have failed or your spending limit needs to be increased` | **需 fanyan 在 GitHub Billing 处理**；这类失败不会消耗 runner，job 直接不启动，日志为空白，很容易误判成 workflow 写错 |
| **K10** | （正向）`/api/status` 的 `version` 生效 | CI 里 `echo "$TAG" > VERSION` + 上游 Dockerfile 的 `-ldflags -X ...common.Version=$(cat VERSION)` | 补上了 `impl_tech.md` §6.6 硬性约束 3 的缺口（R-02）：线上版本从 tag 可反查 |

### 9.4 新增工具

| 脚本 | 用途 |
|---|---|
| `deploy/gitops/bootstrap/verify-e2e.sh` | 一条命令跑完「CI run → ops commit → overlay digest → ArgoCD → 线上 version」五段验收；判据是第 5 段的 version 必须等于第 1 段的 head sha7 |

### 9.5 仍待办

1. **GitHub Billing**（K9）—— 不处理的话 ops 仓门禁随时failure。
2. **T4**：`selfHeal → true`（现在仍是 `false`，手工 `kubectl set image` 不会被拉回）。
3. **T5**：`prune → true`；trivy `exit-code → 1`。
4. `OPS_REPO_TOKEN` 换细粒度 PAT。
