# G6 配置模板 · GTM 3.0 实例与地址池（对应指南 §3.8 / §8.4 任务 21）

> 状态：**已落地并在线生效（2026-10-13）**。本文件 = GitOps 单一真源（禁止只在控制台改）。
> 落地执行：`deploy/tasks/task21/gtm_setup.sh`；执行报告：`deploy/docs/Day2任务21_GTM实例与访问池_执行报告_2026-10-13.md`

## 0. 落地实况（实测 ID）

| 项 | 实测值 |
| --- | --- |
| 实例 | `gtm-post-2109945017262880768`（`postpay` / `postpay_standard`，到期 `9998-12-31` = 按量付费无到期） |
| 接入域名 | `www.likha.hk` — `cfg-2109945017409681408`，类型 **CNAME**、全局 **TTL 60**、**enable** |
| 地址池 | `pool-mnl` — `pool-2109945348675815424`（domain / enable / any_ok / SN=1 / W=1） |
| 地址 | `alb-newapi-mnl` — `addr-2109945408285264896`（= 马尼拉 ALB DNS 名，探测 443） |
| 探测模板 | `mt-www-https-60s` — `mtp-2109945303977115648`（https / 60s / 5s / 3 次 / 失败率 100%） |
| 探测节点 | 香港 `569/465` · 新加坡 `375/465` · 东京 `576/465` |
| 池间策略 | `sequence` + `preemptive`（主备顺序；当前仅 1 池） |
| 探测 ExtendInfo | `{"host":"www.likha.hk","path":"/api/status","code":500,"sni":true,"followRedirect":false}` |

**★ 与下方模板的偏离（3 处，均为 2026-10-13 实测裁定）**：
① 无「实例名/规格」概念 —— GTM 3.0 按量付费，实例随接入域名自动生成（无 Standard/Ultimate 档）；
② **不需要**「业务域名 CNAME 到 GTM 接入域名」—— GTM 3.0 直接接管业务域名本身；
③ 探测间隔取 **60s**（模板原写 15s）：15s 官方注明「面向旗舰版实例开放」且成本为 60s 档的 4 倍（19.4 → 77.8 USD/月）。

## 1. 实例

| 项 | 值 |
| --- | --- |
| 计费方式 | **按量付费（`ChargeType=postpay`）**，无需预购、无实例名（自动生成 `name-gtm-post-…`） |
| 接入域名 | `www.likha.hk`（直接接管；**不要**再往云解析加 CNAME） |
| 月成本构成 | 接入域名 0.45 + 探测 19.44（1 地址×3 节点×60s）+ 解析 ≈1.2 ≈ **21 USD/月** |

## 2. 地址池

| 池 | 内容 | 加入时机 |
| --- | --- | --- |
| 主池 `pool-mnl` | 马尼拉 ALB DNS 名 `alb-1riqckb1h8ezm0y7s9.ap-southeast-6.alb.aliyuncsslbintl.com`（实测取法：`aliyun alb ListLoadBalancers --region ap-southeast-6` 的 `DNSName`，或集群内 `kubectl get albconfig mnl-alb -o jsonpath='{.status.loadBalancer.dnsname}'`） | ✅ **2026-10-13 已挂**（SN=1） |
| 备池 `pool-sg` | 新加坡 ALB DNS 名 `alb-amdwm60xmznh7s1nae.ap-southeast-1.alb.aliyuncsslbintl.com` | **硬门禁：M4 接管演练（§11.3）通过前不得入池**（§8.4 坑 3）。入池后：`SerialNumber=2`，并**显式禁用它**直到演练窗口 |

> ⚠ **备池入池会新增一个「地址」⇒ 探测费 +19.44 USD/月**（探测次数 = 地址数 × 节点数 × 频率，与池数无关但与地址数成正比）。

## 3. 访问策略与健康探测

| 项 | 值 | 依据 |
| --- | --- | --- |
| 池间策略 | **`sequence` + `preemptive`**（主备顺序、前序恢复即抢占回主） | §8.4 步骤 3「主备 + 自动切换，不是多活分摊」 |
| 池内策略 | `round_robin`（当前仅 1 地址，无实际影响） | 默认 |
| 池健康判定 | `any_ok`（池内**至少 1 个**地址可用即认为池可用） | 卡片「可用 IP 最小数量阈值 = 1」 |
| 地址健康判定 | `any_ok`（所有探测模板至少一个正常） | — |
| 探测协议/端口 | **https / 443**，`Host: www.likha.hk`，`sni=true`，`code=500`，`followRedirect=false` | 与真实用户路径一致（经 ALB 443 监听 + 通配符证书） |
| 探测路径 | `GET /api/status` ⇒ **G8 补 `/readyz` 后必须切换** | §8.4 坑 2（`/api/status` 不反映 DB） |
| 间隔 / 超时 / 判定 | **60 s** / 5000 ms / 连续 **3** 次失败 | 用户 2026-10-13 裁定（成本）；判定窗口 ≈ 最坏 3×60s + 开销 |
| **失败率阈值** | **100%**（3 个节点**全部**失败才判地址异常） | ★ **安全性设计**：当前备池为空 ⇒ 误摘主池 = 全站解析失败。故取最保守。**备池入池后应重新评估**（建议降至 50–80%） |
| 切换 TTL | `Ttl=60`（实测权威直答 `TTL 60`） | 只控制 GTM 权威层（第 1 层） |
| 探测源 IP | 无需加白（2026-10-12 F15：账号无 WAF 实例；ALB 入向 `0.0.0.0/0` 不拦探测源） | §8.4 坑 4 当前无触发对象 |

## 4. SLA 口径（三层延迟，写进演练报告）

1. **GTM 判定与摘除**：最坏 `3 × 60s` + 判定开销 ≈ **180 s**（60s 档；若升到 15s 则 ≤60s，代价是成本 ×4）；
2. **递归 DNS 缓存**：不可控，实际 5–30 分钟（TTL 60 + 客户端 SDK 定期重建连接 + 5xx 后强制重解析来压）；
3. **已建立的长连接/SSE 不迁移**：RTO 真实上限，以 D8 接管演练实测值为准。

**对外承诺"切换时间"用第 3 层实测值，不引用"60 秒"。** 回切后需稳定 15 分钟再结束观察（§11.2）。

## 5. 验证（照抄 §8.4 + 本轮实测口径）

```bash
# 权威直答（最可信）：应返回 CNAME → 马尼拉 ALB DNS 名，TTL 60
dig @ns7.alidns.com www.likha.hk CNAME +noall +answer
# 公共递归
dig +short @223.5.5.5 www.likha.hk
# 应用层
curl -sS https://www.likha.hk/api/status | head -c 120
# GTM 侧状态（只读，一键）
bash deploy/tasks/task21/gtm_setup.sh plan
bash deploy/tasks/task21/gtm_setup.sh verify
# 故障发现演练（窗口内；备池未挂时不切换，只验"能否发现"）
# ⚠ 破坏性：需 scale 生产 Deployment，仅在演练窗口执行
#   kubectl --context mnl -n new-api scale deploy/new-api-stable 0  → 期望 ≤180s 判异常并告警
#   kubectl --context mnl -n new-api scale deploy/new-api-stable 4
```

## 6. 回退

- **解析回退**：`bash deploy/tasks/task21/gtm_setup.sh disable` ⇒ `www` 立即回落云解析 A 记录
  （`8.212.161.49` / `8.212.183.7`，两条 ENABLE，**本轮刻意保留未删**作为兜底；
  RecordId `2107455274482150400` / `2107455278295137280`）。
- **完全停费**：`teardown`（删除接入域名会连带删除按量实例；⚠ **禁用不禁费**，探测任务会继续跑）。
