# UPSTREAM_CHANGES.md — 我们对上游的定制清单

> 本仓库是 [`QuantumNous/new-api`](https://github.com/QuantumNous/new-api) 的二次开发分支
> （fork 至 `yanxuewei/new-api-yxw`）。本文件**逐条登记**我们改过上游的哪些文件、为什么改、
> 对应哪次提交/PR，**每次同步上游（sync fork）前必须对照本清单逐条检查冲突点**。
>
> 维护规则见 §「二次开发纪律」。**新增任何上游文件改动，必须同步在本表追加一行**，
> 并在 `ours_likha/ops/patches/` 下附可复现补丁 —— 否则视为不合规提交。

---

## 一、定制清单（逐条）

| # | 上游文件（行） | 改动 | 原因 | 我们的提交 / PR | 复现补丁 |
|---|---|---|---|---|---|
| 1 | `middleware/logger.go:38` | `param.TimeStamp.Format("2006/01/02 - 15:04:05")` → `…:05.000` | GIN 访问日志需毫秒，供 SLS 采集到 ms | `9fff2aa47` | `ours_likha/ops/patches/0001-log-ms-precision.patch` |
| 2 | `common/sys_log.go:20` | `t.Format("2006/01/02 - 15:04:05")` → `…:05.000` | `[SYS]` 日志需毫秒 | `9fff2aa47` | 同上 |
| 3 | `common/sys_log.go:27` | 同上（`SysError`） | `[SYS]` 错误日志需毫秒 | `9fff2aa47` | 同上 |
| 4 | `common/sys_log.go:34` | 同上（`FatalLog`） | `[FATAL]` 日志需毫秒 | `9fff2aa47` | 同上 |
| 5 | `logger/logger.go:113` | `now.Format("2006/01/02 - 15:04:05")` → `…:05.000` | `[INFO]/[ERR]` 应用日志需毫秒 | `9fff2aa47` | 同上 |

> **提交引用**：本批改动落在 `9fff2aa47`（分支 `feature/log-ms-precision`，PR **待开**）。
> 开 PR 后请把实际 PR 号补到本列（形如 `#NNN @ 9fff2aa47`）。

### 不动的地方（避免误改）

| 文件 | 为何不动 |
|---|---|
| `model/twofa.go:275,304` | `2006-01-02 15:04:05` 是**用户可见的错误文案**（账号锁定剩余时间），非日志 |
| `pkg/ionet/jsonutil.go:84-86` | 是**输入时间解析格式列表**，非输出日志格式 |
| `logger/logger.go:55` | `20060102150405` 是**日志文件名**命名，秒级足以唯一定位滚动文件 |

---

## 二、为什么这批改动必须动源码（而非扩展）

按纪律第 1 条「能扩展不改源码」，本应优先用插件 / hook / 配置覆盖。**本项经排查确认无扩展点**：

1. GIN 访问日志格式由 `middleware.SetUpLogger` 内**闭包硬编码**的 `gin.LogFormatterParams` 回调决定，
   无 env / 配置项可覆盖；`gin.LoggerWithFormatter` 的格式化函数无法在包外替换。
2. 应用日志由 `logger.logHelper` / `common.SysLog` 内 `fmt.Fprintf` 的 `time.Format` 字面量硬编码。
3. 该函数同时承载 `redactTaskArtifactAccessQuery()`（私有函数，脱敏任务产物访问 query）——
   若在 `main.go` 侧整体替换 `middleware.SetUpLogger` 会**丢失脱敏**，反而更糟。

⇒ 结论：**最小化原地改写 5 处时间布局字面量**，是此处代价最小、风险最低的做法。
改动**仅时间格式字符串**，不触碰控制流、无格式化噪音（符合纪律第 4 条）。

---

## 三、二次开发纪律（2026-10-09 fanyan 下达，全仓库适用）

> 本纪律与 `deploy/git开发-发布-值班规范.md §4.3「二次开发隔离原则」**同源**——
> 规范文档是**执行细则**（分支模型 / 发布流程 / 值班），本文件是**定制清单**（改了什么）。
> 二者口径必须一致：任何一条纪律变更，两处同时改（见本仓「口径同源连带扫」约定）。

1. **能扩展不改源码**：优先用插件 / hook / 配置覆盖方式实现定制，其次才是直接修改上游文件。
2. **定制清单**：仓库根目录维护 `UPSTREAM_CHANGES.md`，逐条记录「我们改了上游哪些文件、为什么、
   对应我们仓库的 PR 号」。**每次 sync 前对照该清单检查冲突点。**
3. **本地定制集中存放**：自研代码放独立目录 / 包（`ours_likha/{code,ops,doc}`），与上游目录**物理隔离**。
4. **禁止无意义的格式化改动上游文件**（一次格式化 = 永久冲突源）。
5. **merge 冲突解决后必须跑全量测试**；sync PR 的 CI **不允许 skip 任何 job**。

### 同步上游的标准流程

```bash
# 1) 拉上游（本仓库 origin = fork；上游为 QuantumNous/new-api，需另配 upstream remote）
git fetch upstream
git checkout -b sync/upstream-$(date +%Y%m%d) origin/main

# 2) ★ 先跑定制项在位检查（对照本清单机械校验，见 verify 脚本）
bash ours_likha/ops/verify-upstream-changes.sh

# 3) merge（有冲突则解决；本清单所列文件是**唯一预期冲突源**）
git merge upstream/main

# 4) 冲突解决后：重跑 verify + 全量测试（CI 不得 skip 任何 job）
bash ours_likha/ops/verify-upstream-changes.sh
make test && go vet ./... && go build ./...

# 5) 提 sync PR，CI 全绿后合并；更新本清单「我们的提交/PR」列
```

---

## 四、相关文档

- 自研目录说明：`ours_likha/README.md`
- 复现补丁：`ours_likha/ops/patches/`
- 在位校验脚本：`ours_likha/ops/verify-upstream-changes.sh`
- 部署侧背景（SLS 毫秒落地）：`deploy/Day3任务26_SLS与可观测_执行报告.md`
