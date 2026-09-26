# G6 配置模板 · 证书部署任务清单（对应指南 §3.8 / §4.7 任务 3 / §9.8 任务 40）

> 时序红线（v2.0 教训）：**D1 只做"证书就绪 + 本模板预置"，部署动作固定排 D6（任务 40）**——ALB/WAF 在 D3/D5 才建，提前部署会找不到资源、最终靠手工补、D6 才发现残留自签/旧证书。

## 1. 证书真源与就绪状态（D1 收口）

| 项 | 值 / 状态 |
| --- | --- |
| 证书 | `*.likha.com` 通配符（DigiCert/GlobalSign/Rapid 付费，国际站无免费 DV，P0-7） |
| SAN 必须覆盖 | `api.likha.com`, `ops.likha.com`, `*.likha.com`（裸域另加 SAN 或 301 → api） |
| CAS CertId | `${CERT_ID}`（D6 回填） |
| 私钥位置 | 仅 CAS/KMS（`new-api/prod/tls-wildcard`），**禁止落 Git/ConfigMap/本地磁盘**；导出仅限轮换窗口并即时销毁 |
| 有效期 | 2026-02-25 起最长约 199/200 天，1 年订单拆两张 ~6 个月 → **必须开托管自动续期 + 自动部署** |
| 到期告警 | notAfter < 今 + 30 天 → 告警到 §10.8 值班通道；每里程碑人工复核一次 |

## 2. 部署目标资源清单（D6 任务 40 逐条执行并回填资源 ID）

| # | 目标 | 绑定方式 | 资源 ID（D6 回填） | 完成 |
| --- | --- | --- | --- | --- |
| 1 | 马尼拉 ALB 443 listener | **只经 AlbConfig 声明式管理**（`certificates: [{CertIdentifier: ${CERT_ID_ALB}}]`，见 albconfig.yaml.tpl），禁止控制台手工挂载 | `${ALB_MNL_ID}` / `${HTTPS_LISTENER_MNL_ID}` | ☐ |
| 2 | 新加坡 ALB 443 listener | 同上（备 region AlbConfig 复用同一 CertId） | `${ALB_SG_ID}` | ☐ |
| 3 | WAF 3.0（马尼拉/新加坡） | 云原生接入模式下证书仍在 ALB 一份（§7.1.1 方案①）；若回退 CNAME 接入则 WAF 侧绑定同一 CertId 并改 HTTPS 回源 | `${WAF_MNL_ID}` / `${WAF_SG_ID}` | ☐ |
| 4 | DCDN（如启用） | OpenAPI 绑定同一 CertId；未启用则记录"不适用" | `${DCDN_DOMAIN}` | ☐ |
| 5 | RDS SSL（独立证书链，不混用） | §6.1：证书连接地址**必须选公网地址**，否则备 region verify-full 握手失败（P0-4） | `${RDS_MNL_ID}` | ☐ |

## 3. 验证（D6 执行，照抄 §9.8）

```bash
aliyun cas DescribeUserCertificateDetail --CertId ${CERT_ID} | jq -r '.CommonName, .Sans'
# 期望 Sans 含 api.likha.com, ops.likha.com, *.likha.com

# V1 SNI：正确域名返回证书；未知域名必须告警/拒绝
echo | openssl s_client -connect ${ALB_VIP}:443 -servername api.likha.com 2>/dev/null | openssl x509 -noout -dates -subject
echo | openssl s_client -connect ${ALB_VIP}:443 -servername nonexistent.likha.com 2>&1 | grep -Ei "alert|error"

# V2 证书链完整 + 无弱套件
curl -sSIv https://api.likha.com/api/status 2>&1 | grep -E "SSL certificate|issuer"
nmap --script ssl-enum-ciphers -p 443 api.likha.com | tail -20    # 期望 grade A

# V3 到期与自动续期
aliyun cas DescribeUserCertificateList --ShowSize 50 | jq -r '.CertificateList[] | [.Name,.Fingerprint,.AfterDate] | @tsv'
# 期望 AfterDate ≥ 今天 + 25 天
```

## 4. 坑（原文照录，执行前重读）

- **只换 CAS 证书、不同步 AlbConfig** → ALB 继续用旧证书。改进：证书部署纳入 GitOps（CertManager + alibabacloud DNS-01 webhook，或同步 Job 调 `UpdateListenerAttribute`）。
- **通配符不覆盖多级**：`*.likha.com` 不覆盖 `a.b.likha.com`。域名规划统一二级。
- **ALB → Pod 段为 VPC 内明文**（设计决策，见 impl_deploy §7.1.1）；任何 CNAME 回源/DCDN → 源站出 VPC 的段一律强制 HTTPS。
