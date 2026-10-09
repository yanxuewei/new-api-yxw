# ours_likha/doc — 定制设计与运维文档

本目录放**本仓库特有**的定制说明、架构决策记录（ADR）、变更背景。

| 文档 | 主题 |
|---|---|
| `ADR-0001-naming-and-internal-visibility.md` | 自研目录命名（下划线）与 `internal` 可见性边界的决策与依据 |
| （见根目录 `UPSTREAM_CHANGES.md`） | 上游定制清单（权威） |
| （见 `deploy/docs/Day3任务26_SLS与可观测_执行报告.md`） | SLS 毫秒/纳秒落地全过程与判据 |

## 约定

- 上游 v2.0 部署指南、方案 xlsx 等**部署类**文档仍在 `deploy/`，不迁入本目录。
- 本目录只放「为什么要这样定制上游代码」这类**与 fork 维护相关**的说明。
- 命名建议：`ADR-0001-xxx.md`、`CUSTOM-xxx.md`。
