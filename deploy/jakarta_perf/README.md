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
| secret keys | 5 个：`SQL_DSN` / `SQL_DSN_MIGRATE` / `SESSION_SECRET` / `REDIS_CONN_STRING` / **`LOG_SQL_DSN`**（2026-10-20 与 dev 同源，三环境共用日志库 `newapi_logs`；由 `deploy/ops/bodies/sync_log_dsn.sh` 维护） |
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

## 管理员登录凭据（2026-10-20 排障结论）

> 症状：`perf.likha.hk` 登录报「用户名或密码错误，或用户已被封禁」。**实际是用户名填错** —— 库里根本没有
> `admin` 这个账号，唯一的管理员是 **`perfroot`**。

| 项 | 值 |
|---|---|
| 唯一账号 | **`perfroot`**（`users.id=2`，`role=100`，`status=1`，`display_name=Root User`） |
| 口令哈希 | `$argon2id$…`（97 字符，走 `common/crypto.go` 的 argon2id 分支，不是 bcrypt） |
| 凭据真源 | Secret **`perf-load-test-credentials`**（2026-10-19 建）含 4 个 key：`admin_username` / `admin_password` / `token_id` / `token_key` |
| 明文口令 | **不入库、不写文档** —— `deploy/ops/secret_scan.sh` 会扫出来；每次现从 Secret 取 |

取法（本机无 kubeconfig，必须经云助手通道在节点内跑 `kubectl`）：

```bash
# 1) 写一个只读 body
cat > /tmp/show_cred.sh <<'EOF'
kubectl -n new-api-perf get secret perf-load-test-credentials -o yaml
EOF
# 2) 经通道执行，输出里 admin_username / admin_password 是 base64
bash deploy/lib/ack_remote_jkt_dev.sh /tmp/show_cred.sh
# 3) 本地解码
echo '<admin_password 的 base64>' | base64 -d
```

**若口令也丢了**（Secret 被删或与库不一致），走台账 `jakarta_dev_ledger.md:1484` 记载的恢复路径：
删 `users`（+ `setups`）里 root 相关行 → `rollout restart` → 访问 `/api/setup` 门禁重开 → 用 `perfroot`
重设口令 → 立刻把口令写回 Secret `perf-load-test-credentials`。

> 附带发现：`POST /api/user/login` 默认收**明文口令**（`PASSWORD_LOGIN_ENCRYPTION_ENABLED` 默认 `false`，
> 只有置 `true` 才需要 `password_encrypted` + `encryption_key_id`）。登出接口是
> `POST /api/user/auth/logout`（**不是** `/api/user/logout`），会话管理在
> `GET /api/user/sessions`、`DELETE /api/user/sessions/<sid>`、`POST /api/user/sessions/revoke-others`。
> ⚠ `DELETE` 掉自己的 current 会话会让当前 token 立刻失效，后续请求全 401 —— 删多个时要**把 current 排最后**。

## 提醒

- `manifests/perf_routes.yaml` 已于 2026-10-20 **修正 backend**：旧文件写的是 `new-api-perf`（已删除的旧
  Service），照它重跑会 503；现指向 `perf-new-api-slave`，与集群现状一致。
- `manifests/legacy/` 下两个文件都不要 apply。
