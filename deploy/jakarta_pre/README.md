# `deploy/jakarta_pre/` —— 雅加达 pre 环境（`new-api-pre` 命名空间）

> 集群：ACK 雅加达 `cb0abf5bc06034f7bbdb991752f6f3e62`（`ap-southeast-5`）
> 命名空间：**`new-api-pre`**（**有**横线；dev 是 `newapi-dev`，无横线）
> 对外域名：`pre.likha.hk` → `pre-new-api-slave`
> 目录分类整理：2026-10-20 · **本目录整体状态：旧链路已弃用**，详见 [`DEPRECATED.md`](DEPRECATED.md)

## 目录结构

```
jakarta_pre/
├── manifests/
│   ├── pre-master-slave.yaml      ★ 权威 IaC（3 对象：master/slave Deployment + slave Service）
│   ├── pre_routes.yaml            对外域名 Ingress（pre.likha.hk，HTTPS 443 + HTTP 301 跳转）
│   └── legacy/                    已作废的旧清单（保留审计痕迹，勿重跑）
│       └── new-api-pre.yaml       旧名 `new-api-pre`（含 Service），已被上面的权威 IaC 取代
├── scripts/
│   └── pre_deploy.sh              ⚠ 已弃用：旧链路执行器（渲染 legacy 清单 / 按旧标签选 pod）
├── sql/
│   └── pre_grants.sql             newapi_pre 库权限 SQL（旧链路，保留参考）
└── bodies/                        仅剩 pre 专属 3 个（跨环境 / 环境无关的已迁 deploy/ops/bodies/）
    ├── diag_pending.sh            硬编码 `new-api-pre` 的 Pending 诊断（只读）
    ├── diag_sqlite_and_devroll.sh pre 冒烟 + dev 回滚的合并诊断（只读）
    └── inspect_dev_baseline.sh    pre 部署前的 dev 基线取证（只读）
```

> **2026-10-20 二次整理**：19 个「跨环境 / 环境无关」的文件已迁到 `deploy/ops/`
> —— 13 个 body 进 `deploy/ops/bodies/`（申请登录、冒烟、集群容量、RDS 端口等），
> 6 个 jkt 公共工具（`jkt_nodes` / `poll_invocation` / `secret_scan` / `set_addon_scope` /
> `set_rds_pooler` / `find_rds_conn_metric`）进 `deploy/ops/` 平铺。

## 权威 IaC 的三个对象

| 对象 | 作用 |
|---|---|
| `Deployment pre-new-api-master` | `NODE_TYPE=master` —— 只做 DB 迁移 + 后台任务，**无 Service、不接流量** |
| `Deployment pre-new-api-slave` | `NODE_TYPE=slave` —— 接全部业务流量 |
| `Service pre-new-api-slave` | 唯一后端，Ingress `pre-route` 指向它 |

## 怎么用

```bash
# 只读查看
kubectl -n new-api-pre get deploy,svc,pod -o wide
kubectl -n new-api-pre logs -l app=pre-new-api-slave --tail=200

# 改配置 / 改规格 / 改副本数
vim deploy/jakarta_pre/manifests/pre-master-slave.yaml
# 应用（经云助手通道，命令体须 <19KB）：
#   写一个 body：kubectl apply -f - <<'EOF' ... EOF，再
#   bash deploy/lib/ack_remote_jkt_dev.sh <body.sh>
```

**切换顺序铁律**（改 selector / 重建时）：先建新 slave + 新 svc → 等 Ready → 切 Ingress →
实测 200 → 再删旧 slave → 最后换 master。反了会 503。

## 关键约定

| 项 | 值 |
|---|---|
| Redis | 复用 dev 的 Tair，**db `/1`**（dev=`/0`、perf=`/2`，隔离限流计数与渠道缓存） |
| secret keys | 4 个（**缺 `LOG_SQL_DSN`** ⇒ 日志库回落主库） |
| 规格 | master `100m/256Mi → 500m/512Mi`；slave `100m/256Mi → 200m/512Mi` |
| ResourceQuota | `new-api-pre-quota` 对象在、`spec` 为空 ⇒ **实际无资源上限**（fanyan 2026-10-20 裁定不恢复） |
| 探针差异 | slave 有 `preStop sleep 15` 与更大的 `initialDelay`（优雅摘流）；master 无 |

## 注意

- 可用的**只读诊断**现在多数在 `deploy/ops/bodies/`（`diag_mem` `diag_nodes` `probe_db_ports`
  `readback_capacity` `pull_probe` `verify_addon_scope` `inspect_ck_gone`）；本目录只剩
  `diag_pending` / `diag_sqlite_and_devroll` / `inspect_dev_baseline`。
  凡**按旧对象名/旧标签定位的会返回空**。
- `scripts/pre_deploy.sh` 已带弃用横幅，**不要重跑** —— 它会把旧名对象造回来，并与新对象抢标签。
