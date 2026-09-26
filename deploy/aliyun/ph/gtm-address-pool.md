# G6 配置模板 · GTM 实例与地址池（对应指南 §3.8 / §8.4 任务 21）

> 状态：**模板定稿，D5 执行**。资源 ID / ALB DNS 名在对应任务产出后回填本文件（GitOps 单一真源，禁止只在控制台改）。

## 1. 实例

| 项 | 值 |
| --- | --- |
| 实例名 | `gtm-newapi-ph` |
| 规格 | 国际站 **Standard / Ultimate** 两档，以购买页为准（P1-19，勿写"旗舰版"进工单） |
| 接入域名 | `${GTM_ACCESS_DOMAIN}`（创建后回填，同步进 dns-records.yaml 的 `api` 记录） |

## 2. 地址池

| 池 | 内容 | 加入时机 |
| --- | --- | --- |
| 主池 `pool-mnl` | 马尼拉 ALB DNS 名：`${ALB_MNL_DNS}`（§6.3 任务 19 产出，`kubectl get albconfig mnl-alb -o jsonpath='{.status.loadBalancer.dnsname}'`） | D5 建 GTM 时即挂 |
| 备池 `pool-sg` | 新加坡 ALB DNS 名：`${ALB_SG_DNS}`（§8.x 备 region 接入产出） | **硬门禁：M4 接管演练（§11.3）通过前不得入池**（§8.4 坑 3：0 副本/未 warm 的备池切过去比不切更糟） |

## 3. 访问策略与健康探测

| 项 | 值 | 依据 |
| --- | --- | --- |
| 调度 | 就近延迟（PH 用户 → 主池） | §8.4 步骤 3 |
| 探测协议/路径 | `GET /api/status`，G8 补建 `/readyz` 合并后**必须切换**为 `/readyz` | §8.4 坑 2：`/api/status` 不反映 DB，DB 挂了 GTM 仍判健康 |
| 间隔 / 超时 / 判定 | 15 s / 5 s / 连续 3 次失败判不可用 | §8.4、图 10 |
| 切换 TTL | `Ttl=60` | 只控制 GTM 权威层（第 1 层） |
| 探测源 IP | 加入 WAF 白名单 + `sg-mnl-alb` 入向 | §8.4 坑 4：未加白 → 探测被拦 → 误判抖动切换 |

## 4. SLA 口径（三层延迟，写进演练报告）

1. **GTM 判定与摘除**：最坏 3×15s + 判定开销 ≤ 60 s；
2. **递归 DNS 缓存**：不可控，实际 5–30 分钟（TTL 60 + 客户端 SDK 定期重建连接 + 5xx 后强制重解析来压）；
3. **已建立的长连接/SSE 不迁移**：RTO 真实上限，以 D8 接管演练实测值为准。

**对外承诺"切换时间"用第 3 层实测值，不引用"60 秒"。** 回切后需稳定 15 分钟再结束观察（§11.2）。

## 5. 验证（D5 执行时照抄 §8.4）

```bash
dig +short CNAME api.likha.com @8.8.8.8 ; dig +short api.likha.com @8.8.8.8   # 期望先 GTM 域名再 ALB DNS
dig api.likha.com +noall +answer | awk '{print $2}'                           # 期望 TTL=60
curl -sS https://api.likha.com/api/status | jq -e '.success == true and .version != ""'
# 故障发现演练（窗口内）：scale deploy/new-api-stable 0 → 期望 GTM ≤60s 判异常并告警（备池未挂时不切换）→ scale 回 4
```
