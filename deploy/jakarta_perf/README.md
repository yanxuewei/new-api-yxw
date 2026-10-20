# `deploy/jakarta_perf/` —— 雅加达 perf 环境（`new-api-perf` 命名空间，压测）

> 集群：ACK 雅加达 `cb0abf5bc06034f7bbdb991752f6f3e62`（`ap-southeast-5`）
> 命名空间：**`new-api-perf`**（**有**横线）
> 对外域名：`perf.likha.hk` → `perf-new-api-slave`
> **本目录 2026-10-20 新建** —— 原先 perf 相关物与 pre 混在 `deploy/jakarta_pre/`，本次按环境拆开
> 旧链路（按旧对象名的 apply / 压测编排）**已弃用**，见 [`../jakarta_pre/DEPRECATED.md`](../jakarta_pre/DEPRECATED.md)

## 目录结构

```
jakarta_perf/
├── manifests/
│   ├── perf-master-slave.yaml     ★ 权威 IaC（3 对象：master/slave Deployment + slave Service）
│   ├── perf_routes.yaml           对外域名 Ingress（perf.likha.hk，HTTPS 443 + HTTP 301 跳转）
│   └── legacy/                    已作废的旧物（保留审计痕迹，勿重跑）
│       ├── new-api-perf.yaml      旧名 `new-api-perf`（含 Service）
│       └── perf_nodepool.json     旧专用节点池建池载荷（现 pre/perf 共用 `np-jkt-dev-x4c`，作废但保留）
├── scripts/
│   └── poll_rds_cpu_window.sh     压测期 RDS CPU/连接使用率窗口采样（只读）
└── bodies/                        压测编排与取证（17 个，均带弃用横幅）
```

`bodies/` 分类：

| 用途 | 文件 |
|---|---|
| 压测编排 | `run_perf_sse_staircase.sh`（阶梯）· `run_perf_sse_800_confirm.sh`（800 档确认）· `check_perf_load_inputs.sh`（可驱性检查） |
| 上游接线 | `wire_perf_a_setup.sh` · `wire_perf_b_channel.sh` · `wire_perf_relay.sh` · `probe_mock_contract.sh` · `fix_perf_channel_url.sh` |
| 令牌 | `rotate_perf_token.sh` · `confirm_token_softdelete.sh` · `diag_perf_token.sh` |
| 状态回读 | `readback_perf_state.sh` · `readback_perf_final_state.sh` · `readback_perf_resources.sh` · `readback_perf_scale.sh` |
| 诊断/配额 | `diag_perf_403.sh` · `topup_perf_quota.sh` |

## 权威 IaC 的三个对象

| 对象 | 作用 |
|---|---|
| `Deployment perf-new-api-master` | `NODE_TYPE=master` —— 只做 DB 迁移 + 后台任务，**无 Service、不接流量** |
| `Deployment perf-new-api-slave` | `NODE_TYPE=slave` —— 接全部业务流量（**压测唯一入口**） |
| `Service perf-new-api-slave` | 唯一后端，Ingress `perf-route` 指向它 |

> `mock-upstream`（6 副本，假上游）不属于本 IaC，也未改动。

## 关键约定

| 项 | 值 |
|---|---|
| Redis | 复用 dev 的 Tair，**db `/2`**（dev=`/0`、pre=`/1`） |
| secret keys | 4 个（**缺 `LOG_SQL_DSN`**） |
| 规格 | master 与 slave **同档**：`requests 1C/2Gi` · `limits 2C/4Gi`，`GOMAXPROCS=2`、`SQL_SLOW_THRESHOLD_MS=200` |
| 为什么 slave 与 master 同档 | slave 是压测唯一入口，按开发档 `200m` 会先在它身上打满，测出来的就不是被测对象的数 |
| ResourceQuota | `new-api-perf-quota` 对象在、`spec` 为空 ⇒ **实际无资源上限**（fanyan 2026-10-20 裁定不恢复） |

## 怎么用

```bash
kubectl -n new-api-perf get deploy,svc,pod -o wide
kubectl -n new-api-perf logs -l app=perf-new-api-slave --tail=200

# 改配置 / 改规格
vim deploy/jakarta_perf/manifests/perf-master-slave.yaml
# 应用经云助手通道：写 body（kubectl apply -f - <<'EOF' … EOF）→ bash deploy/lib/ack_remote_jkt_dev.sh <body.sh>
```

## 提醒

- `manifests/perf_routes.yaml` 已于 2026-10-20 **修正 backend**：旧文件写的是 `new-api-perf`（已删除的旧
  Service），照它重跑会 503；现指向 `perf-new-api-slave`，与集群现状一致。
- `manifests/legacy/` 下两个文件都不要 apply。
