# Day 2 · 任务 17｜`LOG_SQL_DSN` 注入集群 —— 执行/核验报告

- **任务**：Day 2 · 任务 17 收尾项「把 `LOG_SQL_DSN` 注进集群」（任务 41 I-1 的 (a) 路线前置；任务 9 卡 S-4 销账项）
- **日期**：2026-10-05（复核 + 1 次 sg Secret 修正写操作）
- **通道**：`deploy/ack_remote.sh`（云助手 → worker 节点内 kubectl）· 两地（mnl `cd57e40c…` / sg `ca75829e…`）
- **结论**：✅ **已完成**。两地 `Secret/new-api-secrets` 均含 `LOG_SQL_DSN` 且端到端鉴权通过；同时**修正 sg 侧一处端点错误**（原指 CK 私网 VPC 端点 → 跨区不可达）。

---

## 一、最终状态（2026-10-05 实测）

| 站点 | ns | Secret 键数 | 键清单 | `LOG_SQL_DSN` 端点 | 鉴权 |
| --- | --- | --- | --- | --- | --- |
| mnl | `new-api` | **6** | LOG_SQL_DSN · REDIS_CONN_STRING · SESSION_SECRET · SESSION_SECRET_OLD · SQL_DSN · SQL_DSN_MIGRATE | `cc-5tsv2o51s1360b0pr-clickhouse.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（**VPC**，同区私网） | ✅ `SELECT 1`→`1` · `SHOW TABLES`→`logs` |
| sg | `new-api` | **3** | LOG_SQL_DSN · SESSION_SECRET · SQL_DSN | `cc-5tsv2o51s1360b0pr-public.clickhouseserver.ap-southeast-6.rds.aliyuncs.com:9000`（**PUBLIC**，跨区） | ✅ 同上 |

- DSN 结构（脱敏共通）：`clickhouse://newapi:<pw_len=24>@<host>:9000/newapi_logs`
- ConfigMap `new-api-config`（两地）：`LOG_SQL_CLICKHOUSE_TTL_DAYS=90` ✅ · `LOG_SQL_MAX_OPEN_CONNS=50`（⚠ 代码无此 env，空转配置，见任务 41 坑 11）
- CK 实例：`cc-5tsv2o51s1360b0pr` · 端点 `DescribeEndpoints` 回 PUBLIC + VPC 两条（`NetType=PUBLIC`/`VPC`）· 公网 IP `43.118.97.47`

## 二、修正事件（本次唯一写操作）

- **现象**：sg 侧 `LOG_SQL_DSN` 与 mnl **同值**，指 **VPC 端点**；从 SG worker（`i-t4nb4aj0ssltm7jjawuv`）实测 **TCP 9000 不可达**（超时）⇒ 备站写日志必然失败。
- **依据**：2026-09-30 裁定③「备站 → CK 走 `CreateEndpoint` 公网端点」（`sg_eip` 白名单组已含 SG 4 出口 EIP）。
- **动作**：`kubectl -n new-api patch secret new-api-secrets --type merge --patch-file <json>`，仅把 host 的 `-clickhouse.clickhouseserver` 换成 `-public.clickhouseserver`；**口令/库名/端口不变，明文不落盘、不进日志**（patch json 由节点内 python 生成，用后即删）。
- **验证**：改后 sg → public 端点 `SELECT 1` = `1`、`SHOW TABLES` = `logs` ✅；mnl 侧未动（同区走 VPC 是对的，私网更省 NAT 流量）。

## 三、判定与影响

| 项 | 结果 |
| --- | --- |
| 任务 17「`LOG_SQL_DSN` 注入」 | ✅ 完成（两地） |
| 任务 41 **I-1 (a) 路线** | ✅ 成立 —— CK 日志库分支 `16×100 + 24×10 = 1840 ≤ 2000`；**(b) 临时 `conns=45` 不再需要** |
| 任务 9 卡 **S-4** | ✅ 销账（原「DSN 未注入集群」结论作废） |
| 约束 | 应用首启前 DSN 必须指向 CK —— 现已满足（任务 18/23 部署 Pod 时即生效） |
| 未落地（不属本项） | `PAYMENT_PRIVATE_KEY` / `TLS_WILDCARD`（待用户提供，G5 依赖）；sg 侧 `REDIS_CONN_STRING` / `SESSION_SECRET_OLD` / `SQL_DSN_MIGRATE`（sg Tair 未建、备站迁移账号未下发） |

## 四、核验脚本

`deploy/task17_dsn_verify.sh [mnl|sg|both]`（幂等**只读**）
1. Secret 键清单（仅键名）
2. DSN 结构脱敏（scheme/user/pw_len/host/port/db）
3. **端点口径断言**：mnl 应 VPC（`-clickhouse.clickhouseserver.`）；sg 应 PUBLIC（`-public.clickhouseserver.`）
4. 端到端鉴权：节点内用 Secret 自身值连 CK HTTP 8123 跑 `SELECT 1` / `SHOW TABLES`；**内层重试 3 次**（VPC 端点偶发抖动），失败时自动用另一端点做判别
5. ConfigMap TTL 值
- 输出落 `deploy/logs/task17_verify_<ts>/{mnl,sg}.log`；出现 `[XX]` 即退出码 1。
- 最近一次全绿：`deploy/logs/task17_verify_20261005-162208/`。

## 五、本次踩到的坑（已固化）

1. **远端 curl `-w '%{http_code}'` 可能不回显**（得空串），导致"响应体正常但判定失败"的假阴性 ⇒ 改用 `curl -fsS -m 10 -o file` + 退出码 + 响应体判定。
2. **`ack_remote.sh` 的 body 是「不带引号的 heredoc」**：正文里出现**反引号**会被本地 shell 当命令替换执行（实测报 `-w: command not found`）；出现未转义 `$1/$2` 会被本地 `set -u` 打成 `unbound variable` ⇒ 正文一律 `\$` 转义、注释里别写 `$1`/反引号。
3. **mnl VPC 端点 8123 偶发超时**（同秒内另一次直连成功）—— 与项目「VPC 端点两端皆抖动」一致 ⇒ 鉴权检查必须带重试。
4. **SDK 参数差异**：`aliyun cas` 不带 `--region` 会报 `unknown endpoint for region ap-southeast-6`（CAS 该地域无端点），查证书须显式 `--region ap-southeast-1`。
5. **`patch secret --type merge` 用 `stringData`** 可直接传明文，避免手工 base64；配合 `--patch-file` 规避口令出现在 `ps` 参数里。

## 六、证据

- 站点日志：`deploy/logs/task17_verify_20261005-162208/{mnl,sg}.log`
- 关键行：mnl `[OK] SELECT 1 → 1` / `[OK] SHOW TABLES → logs`；sg `[OK] 端点=PUBLIC` / 同上查询结果
- 云侧：`aliyun clickhouse DescribeEndpoints --DBInstanceId cc-5tsv2o51s1360b0pr --RegionId ap-southeast-6` → `VPC` + `PUBLIC` 两条端点
