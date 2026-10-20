# ⚠ 本目录（`deploy/jakarta_pre/`）已整体弃用

> **弃用日期**：2026-10-20 · **裁定人**：fanyan
> **原因**：`new-api-pre` / `new-api-perf` 两个环境的负载已按 **pod 名**重建
> **权威 IaC**（2026-10-20 起分环境两处，不再是一份合并清单）：
> - pre → [`manifests/pre-master-slave.yaml`](manifests/pre-master-slave.yaml)
> - perf → [`../jakarta_perf/manifests/perf-master-slave.yaml`](../jakarta_perf/manifests/perf-master-slave.yaml)
> **只读参考价值**：本目录保留作为审计痕迹（首跑口径、压测记录、诊断脚本），**不要重跑 apply 类脚本**

> 本目录在 2026-10-20 做过一次**目录分类整理**：`manifests/` `scripts/` `sql/` `bodies/`。
> 下文所有路径均为整理后的新路径；改造前的平铺文件名与新路径的对照见 §六。

---

## 一、旧名 → 新名对照

| 角色 | 旧对象名（旧清单使用） | 新对象名 | Service |
|---|---|---|---|
| pre master | `new-api-pre` + `svc/new-api-pre` | `pre-new-api-master` | **无**（不接流量） |
| pre slave | `new-api-pre-slave` + `svc/new-api-pre-slave` | `pre-new-api-slave` | 有（Ingress 后端） |
| perf master | `new-api-perf` + `svc/new-api-perf` | `perf-new-api-master` | **无**（不接流量） |
| perf slave | `new-api-perf-slave` + `svc/new-api-perf-slave` | `perf-new-api-slave` | 有（Ingress 后端） |

**标签选择器**同时变了：旧 `app=new-api,track=<env>[,role=...]` → 新 **单键 `app=<对象名>`**
（如 `app=pre-new-api-slave`）。⇒ 任何 `-l app=new-api -n new-api-pre|new-api-perf` 的查询现在**返回空**。

`newapi-dev` 环境**未改名**，针对 dev 的操作不受影响。

---

## 二、哪些东西仍然有效

| 项 | 状态 |
|---|---|
| 命名空间 `new-api-pre` / `new-api-perf` | ✅ **未改名**，仍然有效 |
| `Secret new-api-secrets`（4 键，含 `REDIS_CONN_STRING`） | ✅ 有效，被新负载沿用 |
| `ConfigMap new-api-config` | ✅ 有效，被新负载沿用 |
| `ServiceAccount new-api-app` | ✅ 有效 |
| `mock-upstream`（perf 压测上游） | ✅ 未动 |
| `bodies/` 下仅剩的 3 个（`diag_pending` `diag_sqlite_and_devroll` `inspect_dev_baseline`） | ⚠️ 部分可用：按**旧对象名/旧标签**定位的会 NotFound 或返回空；按命名空间罗列的仍可用 |
| `deploy/ops/bodies/` 下的**只读诊断**（`diag_mem` `diag_nodes` `probe_db_ports` `readback_capacity` `pull_probe` `verify_addon_scope` `inspect_ck_gone`） | ✅ 可用（2026-10-20 迁出本目录） |
| `scripts/pre_deploy.sh` 与 `deploy/ops/bodies/` 下的 **apply / 冒烟**（`apply_pre_app.sh`、`apply_pre_secret.sh`、`apply_pre_grants.sh`、`create_ns.sh`、`smoke_pre.sh`、`smoke_sqlite.sh`） | ❌ **作废**，重跑会造旧对象或误判 |
| perf 侧压测编排（`wire_perf_*` `run_perf_*` `topup_perf_quota` …） | ❌ **作废**，已迁至 [`../jakarta_perf/bodies/`](../jakarta_perf/bodies/) |

---

## 三、已加横幅的文件（统一标记 `⚠ DEPRECATED（2026-10-20 起）`）

**旧清单（`manifests/legacy/`）**

- `manifests/legacy/new-api-pre.yaml`
- `../jakarta_perf/manifests/legacy/new-api-perf.yaml`

**链路与编排**（2026-10-20 起跨环境部分在 `deploy/ops/bodies/`）

- `scripts/pre_deploy.sh`（渲染旧清单 + `APP=new-api-pre|new-api-perf`）
- `../../ops/bodies/apply_pre_app.sh`（apply 旧清单）
- `../../ops/bodies/smoke_pre.sh` / `smoke_sqlite.sh`（按 `APP=旧名` 选 pod）
- `../../ops/bodies/create_ns.sh` · `apply_pre_secret.sh` · `apply_pre_grants.sh`（两环境共用）

**按旧对象名/旧标签操作的诊断与压测脚本**（现位于 `../jakarta_perf/bodies/`）

- `diag_perf_403.sh` · `diag_perf_token.sh` · `fix_perf_channel_url.sh`
- `readback_perf_final_state.sh` · `readback_perf_resources.sh` · `readback_perf_scale.sh`
- `rotate_perf_token.sh` · `run_perf_sse_800_confirm.sh` · `run_perf_sse_staircase.sh`
- `topup_perf_quota.sh` · `wire_perf_a_setup.sh` · `wire_perf_b_channel.sh` · `wire_perf_relay.sh`

（`bodies/diag_sqlite_and_devroll.sh` 仍在本目录，同样带横幅。）
合计 **20 个**（2 清单 + 18 脚本）。

---

## 四、以后要动 pre / perf，怎么做

```bash
# 改配置 / 改规格 / 改副本数：只改权威 IaC，不要碰 legacy 与本目录脚本
vim deploy/jakarta_pre/manifests/pre-master-slave.yaml      # pre
vim deploy/jakarta_perf/manifests/perf-master-slave.yaml    # perf

# 应用（走云助手通道，命令体 <19KB）
bash deploy/lib/ack_remote_jkt_dev.sh deploy/jakarta_pre/manifests/pre-master-slave.yaml
# ↑ 实际用法：把上面这条 kubectl apply 写进 body 脚本再交给通道，见 README

# 查状态（新名 + 新 selector）
kubectl -n new-api-pre  get pod -l app=pre-new-api-slave
kubectl -n new-api-perf get pod -l app=perf-new-api-slave

# 日志
kubectl -n new-api-pre logs -l app=pre-new-api-slave --tail=200
```

**切换顺序铁律**（改 selector / 重建时）：先建新 slave + 新 svc → 等 Ready → 切 Ingress →
实测 200 → 再删旧 slave → 最后换 master。反了会 503。

---

## 五、相关记录

- 当日流水：`.workbuddy/memory/2026-10-20.md`
- 详版口径：`.workbuddy/memory/REFERENCE.md` → 「★★ master / slave 双角色」
- 权威 IaC 头部注释含角色差异（`NODE_TYPE` / `SQL_DSN` 来源 / `preStop` / 探针）与迁移顺序

---

## 六、平铺 → 分类 路径对照（2026-10-20 两轮整理）

**第一轮：按环境分类**

| 旧路径 | 新路径 |
|---|---|
| `pre_deploy.sh` | `scripts/pre_deploy.sh` |
| `pre_grants.sql` | `sql/pre_grants.sql` |
| `new-api-pre.yaml` | `manifests/legacy/new-api-pre.yaml` |
| `new-api-perf.yaml` | `../jakarta_perf/manifests/legacy/new-api-perf.yaml` |
| `perf_nodepool.json` | `../jakarta_perf/manifests/legacy/perf_nodepool.json` |
| `poll_rds_cpu_window.sh` | `../jakarta_perf/scripts/poll_rds_cpu_window.sh` |
| `bodies/{check,diag,fix,readback,rotate,run,topup,wire,mock,confirm}_*perf*.sh` 等 17 个 | `../jakarta_perf/bodies/`（同名） |

**第二轮：跨环境 / 环境无关件迁 `deploy/ops/`**

| 原路径 | 新路径 |
|---|---|
| `jkt_nodes.sh` · `poll_invocation.sh` · `secret_scan.sh` · `set_addon_scope.sh` · `set_rds_pooler.sh` · `find_rds_conn_metric.sh` | `../../ops/`（同名，平铺） |
| `bodies/create_ns.sh` · `apply_pre_app.sh` · `apply_pre_secret.sh` · `apply_pre_grants.sh` · `smoke_pre.sh` · `smoke_sqlite.sh` · `pull_probe.sh` · `verify_addon_scope.sh` | `../../ops/bodies/`（同名） |
| `bodies/diag_mem.sh` · `diag_nodes.sh` · `probe_db_ports.sh` · `readback_capacity.sh` · `inspect_ck_gone.sh` | `../../ops/bodies/`（同名） |

留在本目录的：`scripts/pre_deploy.sh` + `bodies/{diag_pending,diag_sqlite_and_devroll,inspect_dev_baseline}.sh`。
`pre_deploy.sh` 的 `run_body()` 已加回落：**先查 `bodies/`、再查 `deploy/ops/bodies/`**，旧子命令仍可用。

迁移用 `git mv`，历史可追溯（`git log --follow <新路径>`）。
