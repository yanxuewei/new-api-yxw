# ours_likha — 本地自研代码 / 运维 / 文档

> 本目录是我们（likha）在 `QuantumNous/new-api` 上游之上的**全部自研产物**，与上游目录
> **物理隔离**（纪律第 3 条）。上游目录里只允许存在**最小化的原地补丁**（见根目录
> `UPSTREAM_CHANGES.md` 清单），任何成规模的自研逻辑都放这里。

## 三段式

| 目录 | 用途 | 典型内容 |
|---|---|---|
| `code/` | **自研 Go 代码 / 包**、可独立构建的工具、扩展插件 | 新中间件、自定义 hook、CLI 工具、生成器 |
| `ops/` | 运维脚本：上游补丁、漂移校验、构建/发布、CI 辅助 | `patches/*.patch`、`verify-upstream-changes.sh` |
| `doc/` | 设计与运维文档（本仓库特有的定制说明、架构决策） | ADR、变更说明、部署注意事项 |

## 约束

1. `code/` 下的包**不得**被上游目录反向依赖（保持单向：上游 ← 我们的补丁；`ours_likha` 独立生长）。
   若确需上游调用，走**最小化原地补丁 + 登记 UPSTREAM_CHANGES.md**，而非让上游 import 本目录。
2. `ops/patches/` 下每个补丁对应 `UPSTREAM_CHANGES.md` 里的一个/一组条目，编号递增。
3. 不做无意义的整文件格式化（纪律第 4 条）。
4. 合并上游后先跑 `bash ours_likha/ops/verify-upstream-changes.sh` 再跑全量测试（纪律第 5 条）。

## 当前状态

- `code/`：暂无（当前唯一定制为日志毫秒补丁，属原地补丁，故落在 `ops/patches/`）。
- `ops/`：`patches/0001-log-ms-precision.patch` + `verify-upstream-changes.sh`。
- `doc/`：见 `doc/README.md`。
