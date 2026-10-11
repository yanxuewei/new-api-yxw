# Git PR 门禁注意点

> 适用范围：`git@github.com:yanxuewei/new-api-yxw.git`（new-api 的 fork 仓库）
> 记录日期：2026-09-24

---

## 0. 结论先行（TL;DR）

1. **两个 PR 不是重复劳动**：`feature → develop` 和 `release → main` 审查的是**不同对象、不同风险**，不能互相替代。
2. **release PR 可以砍掉直接打 tag，但会丢掉 4 样东西**（审计留痕、发布批次整体 review、差异化门禁挂载点、main 分支保护强制走 PR）。真要砍，唯一不降级的替代是 `GitHub Environment + Required reviewers`。
3. **本仓库存在门禁真空（已实测）**：6 个 workflow **没有任何一个监听 `push` 到 `main`**，所以"发布 PR 合入 main"之后不跑任何验证 —— 这正是"必须打 tag 才能触发构建"的根因。
4. **正确的门禁是两层，不是一层**：`merge 前的 required checks`（真门禁）+ `main push 的验证`（兜底）。只在合并后跑 CI 叫**事后审计**，不是门禁。

---

## 1. 标准 Git Flow 命令链与两个 PR 的职责

### 1.1 开发阶段

```bash
git switch develop && git pull --ff-only          # 保证本地 develop 是远程精确镜像
git switch -c feature/pay-retry                   # 从最新 develop 开特性分支
git rebase origin/develop                         # 把本地提交重放到最新 develop 之上（保线性历史）
git push --force-with-lease                       # rebase 改了 SHA，需安全强推
```

要点：
- `--ff-only`：只允许快进，绝不生成意外的 merge commit。
- `--force-with-lease`：带"租约"的强推，远程被别人推过就拒绝，**永远不要用 `--force`**。
- **只 rebase 自己未共享的分支**。

### 1.2 发布阶段

```bash
git switch -c release/1.2.3 develop
git push -u origin release/1.2.3                  # -> 发起 PR 到 main（2 approve）
git checkout main && git pull --ff-only           # 合并后同步本地 main（打 tag 前必须做）
git tag -a v1.2.3 -m "release v1.2.3"             # 用附注标签，含打标人/时间/说明
git push origin v1.2.3                            # 必须显式推 tag，普通 push 不会推
git switch develop
git merge --no-ff origin/release/1.2.3 -m "chore(release): v1.2.3 back to develop"
git push origin develop
git branch -d release/1.2.3 && git push origin --delete release/1.2.3
```

要点：
- `git push origin <tag>` 必须显式写，否则 CI 不会触发（最常见的"CI 没跑"原因）。
- `--no-ff` 强制生成合并提交，保留"这是一次发布回灌"的显式节点。
- 合并 `origin/release/1.2.3`（远程引用）而非本地分支，确保回灌的是已评审版本。
- **回灌不能省**：否则 release 分支上的版本号/热修会在下次发版时重新丢失。

### 1.3 两个 PR 守的是两道不同的关

| 维度 | PR ① feature/fix → develop | PR ② release → main |
|---|---|---|
| diff 内容 | 一个功能，几十行 | 一整个发布批次，几十个提交 + 版本号 + CHANGELOG |
| 审查人 | 模块 owner，1 人即可 | release manager / QA / 双人（2 approve） |
| 回答的问题 | "这段代码写对了吗？" | "这批东西能上线吗？" |
| CI 门禁 | lint + 单测（分钟级） | 全量回归 / 性能基准 / 安全扫描 / 版本一致性校验 |
| 失败代价 | 改一行再推 | 已进生产线，要回滚制品 |

> 图中的第三个 PR（`sync/upstream-YYYYMMDD → develop`）防的是另一件事：**fork 同步把上游未经审查的代码悄悄带进主干**。上游代码不是自研，风险等级不同，所以单独设门。

---

## 2. 发布 PR 能不能砍掉，直接手动打 tag

### 2.1 技术做法

```bash
git switch -c release/1.2.3 develop
# ... 冻结期收尾：改版本号、CHANGELOG、修发布前 bug ...
git switch develop && git merge --no-ff origin/release/1.2.3 -m "chore(release): v1.2.3"

git switch main && git pull --ff-only
git merge --no-ff release/1.2.3 -m "release: v1.2.3"
git push origin main                       # ← 此处需要放开 main 的 push 权限

git tag -a v1.2.3 -m "release v1.2.3"
git push --follow-tags origin main
```

### 2.2 会失去什么

只有 release PR 能提供、tag 替代不了的 4 样东西：

1. **"谁批准了上线"的审计证据**
   tag 是**无审批动作**——任何人 `git push origin v1.2.3` 就能触发构建，平台只留下"某人推了 tag"，没有 review/approve 记录。合规审计（客户合同、认证、金融政企）要看的正是这个。

2. **唯一能整体 review 发布批次的地方**
   feature PR 只看一个功能，看不出"这 20 个功能合在一起会不会互踩"。`release → main` 的 diff 是完整差异，是上线前最后一次整体把关。

3. **差异化门禁的挂载点**
   PR 是"事件"，可以把重量级检查只挂在这个事件上，不影响日常开发速度。tag 事件的 workflow 条件表达弱、粒度粗。

4. **发布上下文载体**
   Release Notes、测试报告、灰度计划、回滚方案贴在 PR 描述里，和 diff 一一对应，排查时翻一页就够。tag 只有一条 message。

补充：**GitHub 上 `main` 分支保护强制走 PR，是"生产分支只能 merge、不能 push"的唯一原生机制**。砍掉 release PR 就意味着要么放开 main 的 push 权限，要么每次 admin bypass。

### 2.3 必须补的保险

| 保险 | 做法 | 补的是什么 |
|---|---|---|
| **① Environment 审批（关键）** | GitHub：建 Environment `production` + **Required reviewers**，绑到 tag 触发的 workflow job。GitLab：**Protected Tags** + Environment 审批 | 用"构建前人工放行"替代 PR 的 2 approve |
| **② 附注标签 + 触发者记录** | `git tag -a`，CI 里打印 `github.actor` 与 tag 消息 | 审计留痕 |
| **③ 权限收紧** | main 的 push 权限只给 release manager；tag 命名用 Protected Tags `v*.*.*` | 防止"能打 tag 的人=有发版权" |

### 2.4 决策表

| 场景 | 建议 | 理由 |
|---|---|---|
| ≤5 人、发版频繁（每天多次）、自动化回归完善、一键回滚 | **可砍**，走"手动 tag + Environment 审批" | 人工闸门成瓶颈，trunk-based 更高效 |
| 有客户合同 / 认证审计 / 金融政企类交付 | **保留 release PR** | 审计证据不可替代 |
| 发版频率低（周/双周）、单次变更量大、回滚成本高 | **保留 release PR** | 爆炸半径大，需要整体把关点 |
| 想减负但不能丢闸门 | **折中：保留 release 分支 + 手动 tag + Environment required reviewers** | 省掉 PR 往返，上线前仍有人放行 |

> 提效的正确方向是砍掉**流程里的等待**（自动建 release 分支、自动 bump 版本号、自动生成 CHANGELOG），而不是砍掉闸门本身。

---

## 3. 实测：本仓库的 CI 触发矩阵与缺口

### 3.1 触发条件实测

`.github/workflows/` 共 6 个文件，触发条件如下：

| workflow | `on:` 触发条件 | 监听 main 的 push？ |
|---|---|---|
| `ci.yml` | `pull_request: types: [opened, synchronize, closed]` | ❌ |
| `release.yml` | `push: tags: ['*']`（排除 `*-alpha*`）+ `workflow_dispatch` | ❌ |
| `docker-build.yml` | `push: tags: ['*']`（排除 `nightly*`）+ `workflow_dispatch` | ❌ |
| `electron-build.yml` | `push: tags: ['*']`（排除含 `-` 的预发布）+ `workflow_dispatch` | ❌ |
| `docker-image-branch.yml` | 仅 `workflow_dispatch` | ❌ |
| `sync-release-to-gitcode.yml` | 仅 `workflow_dispatch` | ❌ |

### 3.2 结论：门禁真空

**没有任何一个 workflow 写 `push: branches: [main]`** → "发布 PR 合入 main"这个动作在 main 上不触发任何验证。

唯一勉强覆盖"合并之后"的，是 `ci.yml` 里这个 hack：

```yaml
types: [opened, synchronize, closed]
# ...
if: github.event.action != 'closed' || github.event.pull_request.merged == true
```

它确实会在合并那一刻跑一次（checkout `base.ref` = main），但这个 run 挂在**已关闭的 PR** 上，没人会回去看，体感就是"没跑"。

> 另注：本仓库**当前只有 `main` 一个分支**（远端也只有 `origin/main`，无 `develop`/`release`），上述 Git Flow 目前仍是**设计态**。

### 3.3 负反馈死循环

```
main 上没有 CI  →  合并后也不知道对不对  →  只能靠打 tag 触发构建
      ↑                                              ↓
      └────────── tag 成了唯一的 trigger ─────────────┘
```

在这套配置下，**tag 不是"可选方案"，而是"唯一的触发器"** —— 这是触发条件配置留下的坑，不是架构选择。

### 3.4 "看不到 CI 跑"的 4 个候选原因

按概率排序：

| # | 原因 | 验证命令 |
|---|---|---|
| 1 | **fork 仓库的 Actions 默认被禁用**（GitHub 对 fork 默认关闭 workflow，需手动 enable） | `gh api repos/yanxuewei/new-api-yxw/actions/permissions` → 看 `enabled` |
| 2 | **`types` 是覆盖不是追加**：PR 若先建 draft 再点 "Ready for review"，`opened` 早已触发，而 `ready_for_review` 不在列表里 → 没有新 run | `gh run list --limit 20 --json name,event,status,conclusion,headBranch` |
| 3 | **跨 fork PR 需人工批准**：Settings → Actions → General → Fork pull request workflows，未批准状态是 `Action required` | `gh run list --status action_required` |
| 4 | **main 分支保护没勾 Required status checks**：CI 跑了也不是门禁，合并按钮不变灰 | `gh api repos/yanxuewei/new-api-yxw/branches/main/protection` |

**反向陷阱**：GitHub 要求某个 check **至少运行过一次**才会出现在 required checks 的可选列表里。所以"改完 workflow 要先合进 main 跑一次，才能设为必需" —— 典型的鸡生蛋问题。

---

## 4. 正确的门禁结构：两层

### 4.1 两层分工

| 层 | 位置 | 机制 | 作用 | 本仓库现状 |
|---|---|---|---|---|
| **① 门禁（闸门）** | PR 上、**merge 之前** | branch protection 的 **Require status checks** | 绿灯才允许合并，坏代码进不去 | ⚠️ 待确认是否勾选 |
| **② 兜底（验证）** | main 上、**merge 之后** | `push: branches: [main]` 触发 | 覆盖 direct push / admin bypass / required checks 未配全 | ❌ 完全缺失 |

关键点：GitHub 对 PR 的 CI 跑在 `refs/pull/N/merge` 上，**测的已经是"合并后的结果"**。所以 ① 才是真正的门禁，② 是安全网。

### 4.2 修正后的完整顺序

```
1. release → main 提 PR
2. ⛔【门禁】required checks 全绿 + 2 approve      ← branch protection 里勾选，缺了就没有闸门
3. merge 进 main
4. ✅【兜底】main push 触发 CI（新增 ci-main.yml）   ← 当前完全缺失
5. 确认 main 是绿的
6. 打 tag → release.yml / docker-build.yml 开始构建
```

### 4.3 必须避开的坑

**不要把 `make test` 塞进 `release.yml` 的构建步骤里当门禁。**

原因：每次发版都要等一遍全量测试，而且**失败时 tag 已经打出去了** —— 只能删 tag 或再打补丁 tag，非常脏。

正确做法：让 **tag 只建立在"main 已绿"的基础上**，构建 workflow 只管构建。

---

## 5. 修复方案

### 5.1 新增 `.github/workflows/ci-main.yml`

```yaml
name: CI (main)

on:
  push:
    branches: [main]

concurrency:
  group: ci-main-${{ github.ref }}-${{ github.sha }}
  cancel-in-progress: false          # 合并后的验证不允许被取消

permissions:
  contents: read

jobs:
  backend:
    name: Backend vet, build, and test
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      GOWORK: 'off'
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16 # v6.5.0
        with:
          go-version-file: go.mod
          cache-dependency-path: |
            go.sum
            relaykit/go.sum
      - run: mkdir -p web/dist && touch web/dist/index.html
      - run: go vet ./...
      - run: go build ./...
      - working-directory: relaykit
        run: go vet ./... && go build ./...
      - run: make test

  frontend:
    name: Frontend typecheck and test
    runs-on: ubuntu-latest
    timeout-minutes: 10
    defaults:
      run:
        working-directory: web
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2.2.0
        with:
          bun-version: '1.4.0'
      - run: bun install --frozen-lockfile
      - run: bun run typecheck
      - run: bun run test
```

### 5.2 修改 `.github/workflows/ci.yml` 第 5 行

```yaml
    types: [opened, synchronize, reopened, ready_for_review]
```

说明：加上 `push: branches: [main]` 之后，`ci.yml` 里的 `closed` 特例可以删掉 —— post-merge 验证交给 `ci-main.yml`，职责更清晰，也避免 `github.ref` 语义混乱。

### 5.3 分支保护配置（人工，必须做）

Settings → Branches → `main` 的保护规则：

- ✅ **Require status checks to pass before merging**
  - 勾选 `Backend vet, build, and test`
  - 勾选 `Frontend typecheck and test`
- ✅ **Require a pull request before merging**（Pull Requests: 2）

否则 CI 跑了也只是"参考信息"，不是门禁。

---

## 6. 自查命令清单

```bash
# 1. Actions 是否被禁用（fork 常见）
gh api repos/yanxuewei/new-api-yxw/actions/permissions

# 2. 最近的 workflow run 及触发事件
gh run list --limit 20 --json name,event,status,conclusion,headBranch,createdAt

# 3. 某个 PR 的 checks 状态
gh pr checks <PR号>

# 4. main 的分支保护与 required checks
gh api repos/yanxuewei/new-api-yxw/branches/main/protection

# 5. 是否有"等待批准"的 run
gh run list --status action_required
```

---

## 7. 附录：GitHub Actions 触发坑速查

| 坑 | 说明 | 规避 |
|---|---|---|
| `types` 覆盖而非追加 | 显式写 `types:` 后，未列出的 action 全部不触发（`reopened`、`ready_for_review`、`labeled`…） | 按需手动补全 types |
| `pull_request` 读 base 分支的 workflow 文件 | 在 head 分支改 `ci.yml`，该 PR 上不生效 | workflow 改动单独合进 base 后再验证 |
| `branches:` 过滤的是 **base** 分支 | 写反了会导致 PR 不触发 | 明确 `branches: [main, develop]` |
| 普通 `git push` 不推标签 | tag 没推上去 → CI 不跑 | `git push origin <tag>` 或 `--follow-tags` |
| fork PR 拿不到 secrets | 依赖 secrets 的构建只能在同仓库事件（tag push）上跑 | 构建放 tag push，验证放 PR |
| 首次贡献者的 fork PR 需批准 | 状态 `Action required`，看起来像没跑 | Settings → Actions → Fork pull request workflows 调整策略 |
| required check 必须先跑过一次 | 从未运行过的 check 无法被设为必需 | 先合一次 workflow 改动，让它跑起来再勾选 |
| `concurrency` + `cancel-in-progress` | 同 group 的新 run 会取消旧的 | post-merge 验证用 `cancel-in-progress: false` |

---

**一句话总结**：tag 只应该是**构建触发器**，不该兼任门禁。要补的不是"最后再触发一次 CI"，而是 **① merge 前的 required checks（真门禁）+ ② main push 的验证（兜底）** —— 两层都补上。
