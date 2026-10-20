# `deploy/jakarta_dev/` —— 雅加达 dev 环境（`newapi-dev` 命名空间）

> 集群：ACK 雅加达 `cb0abf5bc06034f7bbdb991752f6f3e62`（`ap-southeast-5`）
> 命名空间：**`newapi-dev`**（注意：**无**横线；pre / perf 是 `new-api-pre` / `new-api-perf`，**有**横线）
> 对外域名：`dev.likha.hk` → `new-api-dev-slave`；`dev-yxw` / `dev-zzj` / `dev-xd` → 按人指负载
> 目录分类整理：2026-10-20

## 目录结构

```
jakarta_dev/
├── manifests/                     声明式 IaC（唯一真源，改配置只改这里）
│   ├── newapi-dev.yaml            Namespace / ResourceQuota / SA / ConfigMap / Deployment / Service 六合一
│   ├── dev_ingress.yaml           AlbConfig + IngressClass + SVC + Ingress（dev.likha.hk 入口）
│   └── dev_routes.yaml            按人指负载的 6 Ingress（dev / dev-yxw / dev-zzj / dev-xd + 2 条跳转）
├── scripts/                       本地执行器
│   ├── dev_deploy.sh              dev 工作负载执行器（--precheck/--apply-base/--secret/--grants/
│   │                              --apply-app/--verify/--smoke/--status/--delete/--apply-ingress …）
│   └── dev_rds_finalize.sh        dev RDS 口令轮转 + 账号授权 + 回读（--rotate/--grant/--verify）
├── sql/
│   └── dev_grants.sql             权限 SQL（`scope|SQL` 逐行，runner 一条一次 `psql -c`）
└── bodies/                        远端 body（云助手 → 节点内 kubectl；由 dev_deploy.sh 拼 header 后投递）
```

> 端口/DB 口径：DSN 走 **6432 托管池**（`pgbouncer.pool_mode=session`）；`newapi_logs` 日志库同实例。

## 怎么用

```bash
# 只读预检（零凭据、零 kubectl）
bash deploy/jakarta_dev/scripts/dev_deploy.sh --precheck

# 首跑顺序
bash deploy/jakarta_dev/scripts/dev_deploy.sh --precheck
bash deploy/jakarta_dev/scripts/dev_deploy.sh --apply-base
bash deploy/jakarta_dev/scripts/dev_deploy.sh --secret      # 值来自 /root/.deploy_secrets_dev（600）
bash deploy/jakarta_dev/scripts/dev_deploy.sh --grants
bash deploy/jakarta_dev/scripts/dev_deploy.sh --apply-app
bash deploy/jakarta_dev/scripts/dev_deploy.sh --verify
bash deploy/jakarta_dev/scripts/dev_deploy.sh --smoke
```

**注意**：`dev_deploy.sh` 内部用 `ENVDIR="$(cd "$HERE/.." && pwd)"` 定位 `manifests/` `sql/` `bodies/`，
所以**必须按上面的路径调用**，不要把它拷到别处单独跑。

## 关键约定

| 项 | 值 |
|---|---|
| master / slave | `new-api-dev`（master）+ `new-api-dev-slave`；另有 `yxw-new-api-master` / `yxw-new-api-slave` |
| Ingress 后端 | **slave**（dev 的既定模式：对外走 slave，master 只跑迁移与后台任务） |
| Redis | jkt 本地 Tair `r-d9j5iy2q82p1ugiwrt`（内网 `10.2.54.77`），**db `/0`**（pre=`/1`、perf=`/2`） |
| secret keys | 5 个：`SQL_DSN` / `SQL_DSN_MIGRATE` / `SESSION_SECRET` / `REDIS_CONN_STRING` / `LOG_SQL_DSN` |
| 节点池 | `np-jkt-dev-app`（desired=3 / max=3，未开自动伸缩） |

## 与其他两个环境目录的分工

| 目录 | 环境 | 状态 |
|---|---|---|
| `jakarta_dev/`（本目录） | dev | 在用 |
| `jakarta_pre/` | pre | 旧链路**已弃用**，保留审计痕迹；权威 IaC 在 `jakarta_pre/manifests/pre-master-slave.yaml` |
| `jakarta_perf/` | perf | 旧链路**已弃用**，保留压测记录与 body |

> `deploy/jakarta_dev_ledger.md`、`deploy/docs/*.md` 等**历史台账**记录的是整理前的平铺路径
> （如 `deploy/jakarta_dev/dev_deploy.sh`）。那是当时的事实记录，未回改；按 §「目录结构」的新路径为准。
