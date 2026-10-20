# `deploy/ops/bodies/` —— 跨环境 / 环境无关的远端 body

> 建立于 2026-10-20，从 `deploy/jakarta_pre/bodies/` 迁入。判据：**同时作用于 `new-api-pre` 与
> `new-api-perf`，或根本不绑定命名空间**（集群级 / 其他环境）。

## ⚠ 这些不是「能直接跑」的脚本

每个文件都只是一段**远端 kubectl 命令体**，靠调用方拼接 header（临时目录、`export` 载荷变量、
退出清理）后才投递到节点执行。**单独 `bash` 它不会有正确结果**（缺 `$T`、缺 `$NS`、缺载荷）。

调用方：

```bash
# 经云助手通道（雅加达集群 cb0abf5bc06034f7bbdb991752f6f3e62）
bash deploy/lib/ack_remote_jkt_dev.sh <拼好的 body.sh>
```

现存的自动调用入口是 `deploy/jakarta_pre/scripts/pre_deploy.sh`（已弃用），它的 `run_body()` 会
**先查 `deploy/jakarta_pre/bodies/`、再查本目录**。

## 文件清单

| 文件 | 作用 | 作用域 |
|---|---|---|
| `create_ns.sh` | 建 `new-api-pre` / `new-api-perf` 的 Namespace + ResourceQuota + ServiceAccount | 两 ns |
| `apply_pre_app.sh` | apply 两环境的 ConfigMap + Deployment + Service（**旧名清单，已作废**） | 两 ns |
| `apply_pre_secret.sh` | 建/更新 `Secret new-api-secrets`（`NS`/`DBNAME` 由 header 注入） | 两 ns |
| `apply_pre_grants.sh` | pre/perf 两库的权限 SQL 落地（临时 psql Pod） | 两库 |
| `smoke_pre.sh` | 出口冒烟：PG（6432 池）+ SQLite 双库（`--smoke pre\|perf`） | 两 ns |
| `smoke_sqlite.sh` | SQLite 冒烟（矩阵第二格） | 两 ns |
| `pull_probe.sh` | 临时探针 Pod 实测 ACR 免密拉取 | 两 ns（白名单） |
| `verify_addon_scope.sh` | ACR 免密组件作用域双路取证（纯只读） | 集群级 |
| `readback_capacity.sh` | 换池后的集群容量回读（只读） | 集群级 |
| `diag_mem.sh` | 每节点 `requests.memory` 账目（只读） | 集群级 |
| `diag_nodes.sh` | 节点真实资源账目（只读） | 集群级 |
| `probe_db_ports.sh` | 节点侧实测雅加达 RDS 5432 / 6432 连通性（只读、不带凭据） | 基础设施 |
| `inspect_ck_gone.sh` | **马尼拉正式环境**只读取证：CK 删除后应用侧真实状态 | 其他环境 |

> **仍留在 `deploy/jakarta_pre/bodies/` 的 3 个**（pre 专属，未迁）：
> `diag_pending.sh`（硬编码 `new-api-pre`）、`diag_sqlite_and_devroll.sh`（pre 冒烟 + dev 回滚）、
> `inspect_dev_baseline.sh`（pre 部署前的 dev 基线）。

## 弃用状态

除 `inspect_ck_gone.sh` / `diag_*` / `readback_capacity.sh` / `probe_db_ports.sh` / `verify_addon_scope.sh`
这几个**纯只读**的以外，`apply_*` / `smoke_*` / `create_ns.sh` 都属旧链路，带 `⚠ DEPRECATED` 横幅。
权威 IaC 见：
- pre → [`deploy/jakarta_pre/manifests/pre-master-slave.yaml`](../../jakarta_pre/manifests/pre-master-slave.yaml)
- perf → [`deploy/jakarta_perf/manifests/perf-master-slave.yaml`](../../jakarta_perf/manifests/perf-master-slave.yaml)

弃用索引与新旧名对照：[`deploy/jakarta_pre/DEPRECATED.md`](../../jakarta_pre/DEPRECATED.md)
