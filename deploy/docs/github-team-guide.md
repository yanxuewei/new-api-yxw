# GitHub Team 组织协作指南

> 适用场景：已购买 GitHub Team 计划（5 人），需要把团队成员加入组织、分配权限、管理仓库。
> 本文以你的实际环境为例：**个人账号 `ZY6861688`**，**组织 `ZYKJ-1688`**。

---

## 目录

- [一、核心概念](#一核心概念)
- [二、确认账号结构](#二确认账号结构)
- [三、邀请成员加入组织](#三邀请成员加入组织)
- [四、创建 Team 并添加成员](#四创建-team-并添加成员)
- [五、权限体系](#五权限体系)
- [六、控制成员创建仓库的能力](#六控制成员创建仓库的能力)
- [七、把外部仓库 fork 到组织](#七把外部仓库-fork-到组织)
- [八、计费与 Seats 管理](#八计费与-seats-管理)
- [九、常见问题排查](#九常见问题排查)
- [十、安全建议](#十安全建议)
- [附录：快捷链接](#附录快捷链接)

---

## 一、核心概念

| 概念 | 说明 | 能否作为仓库的归属 |
| --- | --- | --- |
| 个人账号（User） | 个人登录身份，如 `ZY6861688` | 可以 |
| 组织（Organization） | Team 计划的载体，如 `ZYKJ-1688` | 可以 |
| 团队（Team） | 组织内的**权限分组**，不是仓库容器 | **不可以** |

三个关键结论：

1. **个人账号无法转换成组织**。GitHub 只支持「新建组织 + 转移仓库」。
2. **Team 只负责授权**，仓库必须建在个人账号或组织下，再给 Team 授权访问。
3. **Team 计划必须挂在组织上**，个人账号没有 Team 计划入口。

---

## 二、确认账号结构

在 `Settings` → `Organizations` 页面可以确认：

| 名称 | 类型 | 判断依据 |
| --- | --- | --- |
| `ZY6861688` | 个人账号 | 标题标注 `Your personal account`，左侧为 `Public profile` |
| `ZYKJ-1688` | 组织 | 出现在 `Organizations` 列表中，角色为 `Owner` |

> **注意**：`ZY6861688` 与 `ZYKJ-1688` 名字高度相似，极易混淆。
> **所有 Team 相关操作（成员邀请、权限、计费）都在 `ZYKJ-1688` 里进行**，在个人账号下找不到这些入口。

**切换设置上下文**：点击 `Settings` 页右上角的 `Switch settings context`，选择 `ZYKJ-1688`，整页即变为组织设置。

---

## 三、邀请成员加入组织

### 操作步骤

1. 登录后点击右上角头像 → `Your organizations` → 进入 `ZYKJ-1688`
2. 顶部 `People` 标签 → 右侧 `Invite member`
3. 填入对方的 **GitHub 用户名** 或 **邮箱**（多个可换行 / 逗号分隔）
4. 角色选择：
   - `Member` —— 普通成员（默认，推荐）
   - `Owner` —— 组织管理员，拥有全部权限
5. 点击 `Send invitation`

### 对方如何接受

对方收到邀请邮件后，或直接访问以下地址，登录并接受：

```text
https://github.com/orgs/ZYKJ-1688/invitation
```

### 关键限制

| 限制 | 说明 |
| --- | --- |
| 有效期 | 邀请 **7 天** 过期，过期需重新发送 |
| 双因素认证 | 若组织强制 2FA，对方必须先开启 2FA 才能接受 |
| 邮箱匹配 | 用邮箱邀请时，对方必须用该邮箱对应的账号登录 |
| 前置条件 | 接受邀请后才能被加入 Team，无法绕过 |

---

## 四、创建 Team 并添加成员

### 创建 Team

```text
https://github.com/orgs/ZYKJ-1688/teams/new
```

命名建议：`dev`（开发）、`ops`（运维）等按职能划分。

### 把成员加进 Team

进入 Team → `Members` 标签 → `Add member` → 输入用户名 → 选择 Team 内部角色 → 添加。

Team 内部角色（**与组织角色无关**）：

- `Member` —— 普通成员
- `Maintainer` —— 可管理该 Team 的成员和设置

### 「可以直接加，而不用再 invite 吗？」

**取决于对方是否已经是组织成员：**

| 情况 | 结果 |
| --- | --- |
| 人**已在组织内**（如 `yanxuewei`、你自己） | **直接加入 Team，立即生效，不发任何邀请** |
| 人**不在组织内** | 系统连带发出**组织邀请**；在接受之前，Team 成员列表里显示 `Pending` |

**结论：GitHub 没有「免邀请」通道。** 这是刻意的设计，防止他人把你强行拉进某个组织。API 同理：

```bash
# 对非组织成员，同样会触发组织邀请
PUT /orgs/{org}/teams/{team_slug}/memberships/{username}
```

**推荐流程**：先发出全部组织邀请 → 对方接受后 → 统一拉进 Team。或者先建 Team 再把待邀请者加进去，效果一致。

---

## 五、权限体系

从大到小共 **5 个层级**：

| 层级 | 配置位置 | 作用范围 |
| --- | --- | --- |
| 1. 组织角色 | `People` → 勾选成员 → `Membership` 下拉 | Member ↔ Owner，Owner 拥有全部权限 |
| 2. 组织默认仓库权限 | `Settings` → `Member privileges` → `Base permissions` | 所有成员对组织**全部仓库**的默认权限 |
| 3. Team + 仓库授权 | `Teams` → 建 Team → 仓库里给 Team 授权 | 按 Team 批量授权（**推荐**） |
| 4. 单仓库授权 | 仓库 `Settings` → `Collaborators and teams` | 仅对某个仓库生效，最精细 |
| 5. 自定义仓库角色 | `Settings` → `Repository roles` | 组合式权限（Team 计划支持） |

### 权限档位

```text
Read  <  Triage  <  Write  <  Maintain  <  Admin
```

| 档位 | 适用场景 |
| --- | --- |
| `Read` | 只读代码 |
| `Triage` | 管理 Issue / PR，但不能推代码 |
| `Write` | 日常开发，推代码（**大多数人给这个**） |
| `Maintain` | 需管理分支保护、Webhook |
| `Admin` | 可删除仓库、改设置（**慎给**） |

### 推荐做法：用 Team 管权限

不要直接把个人设成 `Base permissions = Write`，那会让他们拿到组织**所有**仓库的写权限。正确姿势：

1. 建 Team（如 `dev`）
2. 把成员加进 Team
3. 进具体仓库 → `Settings` → `Collaborators and teams` → `Add teams` → 选 `dev` → 给 `Write`

好处：以后加人只需加进 Team，自动继承全部仓库权限。

---

## 六、控制成员创建仓库的能力

**默认情况下成员可以在组织内创建仓库。** 控制开关位于：

```text
https://github.com/orgs/ZYKJ-1688/settings/member_privileges
```

### `Repository creation`

- `Public` —— 勾选后成员可在组织内创建**公开**仓库
- `Private` —— 勾选后成员可创建**私有**仓库
- `Internal` —— 仅 Enterprise 计划可用

### 同页建议一并收紧的开关

| 开关 | 建议 |
| --- | --- |
| `Repository forking` | 按需开启；关闭则无法 fork 进本组织 |
| `Repository visibility change` | 建议只给 Owner |
| `Repository deletion and transfer` | **强烈建议只给 Owner**，否则成员可把仓库转走或删除 |

### 补充说明

- 成员在组织内创建的仓库 **归属组织**，Owner 可见可管
- 如果只是个人临时项目，建议让成员建在**自己的个人账号**下，别塞进组织

---

## 七、把外部仓库 fork 到组织

### 概念澄清

**仓库不能归属于 Team。** 正确理解是：**fork 到组织 → 再给 Team 授权**。

### 前提

必须先在 `Member privileges` 中开启：

- `Repository creation` 勾上 `Private`
- `Repository forking` 勾上（否则 fork 对话框的 Owner 下拉里不会出现 `ZYKJ-1688`）

### 方式一：网页 fork

打开上游仓库 → 点右上角 `Fork` → 在对话框里：

1. `Owner` 下拉 → 选 `ZYKJ-1688`
2. 可修改 `Repository name`
3. `Create fork`

或直接访问：`https://github.com/<上游owner>/<上游repo>/fork`

**限制：**

| 限制 | 说明 |
| --- | --- |
| 同名冲突 | 同一组织下不能有同名仓库，冲突需先改名 |
| 不能 fork 自己 | 自己拥有的仓库只能 `Transfer` 或 `Import` |
| 私有上游 | 通常不允许 fork 进不同的组织，会被直接拒绝 |

### 方式二：命令行

fork 远端仓库到组织：

```bash
gh repo fork owner/repo --org ZYKJ-1688 --clone=false
```

本地已有代码，想直接在组织中新建（这不叫 fork）：

```bash
gh repo create ZYKJ-1688/new-api-yxw --private --source=. --push
```

或用 git 手动指定远端：

```bash
git remote add org git@github.com:ZYKJ-1688/new-api-yxw.git
git push -u org main
```

### 方式三：fork 走不通时的替代方案

| 场景 | 做法 |
| --- | --- |
| 上游是私有的 / 组织禁止 fork | 访问 `https://github.com/new/import`，粘贴上游 URL 导入副本 |
| 只需要一份代码，不打算提 PR | Import，或本地 clone 后按方式二推送 |
| 仓库本来就是你的，想挪进组织 | 仓库 `Settings` → 底部 `Transfer` → 输入 `ZYKJ-1688` |

> **Import 的代价**：不产生 fork 关系，页面不显示 `forked from`，也无法一键 `Sync fork` 同步上游，需要自己配置 remote 手动同步。

### 最后一步：授权给 Team

进仓库 → `Settings` → `Collaborators and teams` → `Add teams` → 选 `dev` → 给 `Write`。

### 关于公开 fork 的可见性

fork 公开仓库后，副本在组织里默认也是**公开**的。若不想暴露，可在仓库 `Settings` → `General` → `Danger Zone` → `Change visibility` 改为 Private。

> **注意**：公开 fork 改私有时会**脱离 fork network**，同步上游和向上游提 PR 的能力会一并失去。

---

## 八、计费与 Seats 管理

### 查看计费

```text
https://github.com/organizations/ZYKJ-1688/settings/billing
```

查看 `GitHub Team` 一栏的 `Seats` 数量。

### 计费规则

| 项目 | 说明 |
| --- | --- |
| 单价 | `$4 / 人 / 月`，5 人约 `$20 / 月` |
| 待接受邀请 | **通常也占用 Seat 并计费**，发完邀请后回来看 Seats 是否变化 |
| 移除成员 | Seat 名额要到当月计费周期结算后才释放 |
| 超出容量 | Seats 满后新邀请会失败，需先加购或撤销不用的邀请 |

### 你的当前状态（示例）

| 项 | 值 |
| --- | --- |
| 成员 | 2 人（`yanxuewei` 为 Member，`ZY6861688` 为 Owner） |
| 待接受邀请 | 3 个 |
| Seats | `5 of 5 used`，剩余 `0` |

即 2 + 3 = 5，正好卡满。若 3 个邀请全部被接受则刚好用尽；还想加人则需先加购 Seats，或撤销不用的邀请（`People` 页左侧 `Invitations 3`）。

---

## 九、常见问题排查

| 现象 | 原因 / 解决 |
| --- | --- |
| 对方点链接显示 404 | 未用被邀请的邮箱/用户名登录，或邀请已过期 |
| 成员能进组织但看不到仓库 | 未在仓库里给 Team 或成员授权 |
| 邀请按钮灰色不可点 | 当前账号不是该组织的 Owner |
| 组织要求 2FA 但成员无法接受 | 成员需先开启双因素认证 |
| 找不到「邀请成员」入口 | 进错了账号，应在 `ZYKJ-1688` 而非 `ZY6861688` 下操作 |
| fork 对话框没有组织选项 | 组织未开启 `Repository forking` |
| Team 成员列表显示 `Pending` | 对方尚未接受组织邀请 |

---

## 十、安全建议

1. **不要使用第三方「共享账号」**
   多人共用一个登录身份违反 GitHub 服务条款，可能被判定账号共享而封号。
   正确做法：**每人用自己的 GitHub 账号，加入组织**。

2. **避免只有一个 Owner**
   你的组织目前只有 `ZY6861688` 一个 Owner，GitHub 会在顶部给出警告。
   一旦该账号无法登录，组织将彻底失控。建议把可信成员也设为 Owner。

3. **核查成品号的归属风险**
   若是从他人处购买的「成品组织」，原卖家可能仍是 Owner 或保留恢复权限，随时能把你踢出。
   请检查：
   - `People` 页面的 Owner 列表是否只有自己人
   - `Settings` → `Emails` 是否绑定了自己可恢复的邮箱

4. **最小权限原则**
   - `Admin` 权限只给确实需要的人
   - `Repository deletion and transfer` 只留给 Owner
   - 优先通过 Team 授权，而非直接给个人开全局权限

---

## 附录：快捷链接

| 功能 | 链接 |
| --- | --- |
| 组织成员 | `https://github.com/orgs/ZYKJ-1688/people` |
| 待接受邀请 | `https://github.com/orgs/ZYKJ-1688/people?query=is%3Ainvitation` |
| 成员接受邀请 | `https://github.com/orgs/ZYKJ-1688/invitation` |
| Team 列表 | `https://github.com/orgs/ZYKJ-1688/teams` |
| 新建 Team | `https://github.com/orgs/ZYKJ-1688/teams/new` |
| 成员权限设置 | `https://github.com/orgs/ZYKJ-1688/settings/member_privileges` |
| 自定义仓库角色 | `https://github.com/orgs/ZYKJ-1688/settings/repository-roles` |
| 计费与 Seats | `https://github.com/organizations/ZYKJ-1688/settings/billing` |
| 导入仓库 | `https://github.com/new/import` |
