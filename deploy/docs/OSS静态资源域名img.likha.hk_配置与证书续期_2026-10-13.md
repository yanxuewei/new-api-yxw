# OSS 静态资源域名 `img.likha.hk` · 配置落地与证书续期

> **日期**：2026-10-13（同日内完成建桶、迁移、切域名、验证、旧桶下线，并补齐证书续签登记）
> **目标**：把 `img.likha.hk` 指向 OSS 桶，用于**外网可匿名访问的静态资源**（HTTPS）
> **结论**：✅ 已闭环。`https://img.likha.hk/<对象名>` → 200，TLS 严格校验通过，匿名列举被拒
> **关联**：`deploy/cert/targets.yaml`（证书部署目标清单，本次新增 `oss` 目标）· `G5闭环_PlanC_DV通配符签发_2026-10-12.md` · `OSS_Bucket落地_执行报告.md`

---

## 1. 最终台账（现状）

| 项 | 值 |
|---|---|
| 桶名 | **`img-likha`**（注意：不是 `likha-logo`，也不是 `lihka-logo`） |
| 地域 | `oss-ap-southeast-6`（马尼拉） |
| ACL | **`public-read`** |
| 桶级阻止公共访问（BPA） | **`false`**（建桶默认是 `true`，必须显式关，见 §4.2） |
| 冗余 / 存储 | `ZRS` / `Standard` |
| 自定义域名 | **`img.likha.hk`**（`Type=CAS`，证书 `606823-ap-southeast-1`） |
| DNS | `img` **CNAME** → `img-likha.oss-ap-southeast-6.aliyuncs.com`，TTL 600（RecordId `2109907825186446336`） |
| 归属验证 TXT | `_dnsauth.img`（RecordId `2109907917465398272`，**保留勿删**） |
| 对象 | `LIKHA.png`（27842 B，`Content-Type: image/png`，ETag `2311DBFDB4D1C20DB8DCB7958DCC5EE4`） |
| 出口 IP | `8.212.139.178` |
| 旧桶 `lihka-logo` | **已删除**（对象清空 → `rb`，`stat` 回 `404 NoSuchBucket`） |

---

## 2. 关键前提：**OSS 桶名不可重命名**

桶名是**全局唯一主键**，且是对象 URL 的组成部分，所以没有 rename 操作。

**「改名」的等价做法 = 新建 → 迁移 → 切域名 → 删旧桶**：

```
新建 img-likha ──▶ sync 迁移对象 ──▶ 域名/DNS 切到新桶 ──▶ 删旧桶
```

> 本例起点是错拼的 `lihka-logo`（少了一个 `k`），目标是规范的 `img-likha`。

---

## 3. 落地步骤（可复现）

### 3.1 建桶

```bash
ossutil mb oss://img-likha --region ap-southeast-6 \
  --acl public-read --redundancy-type ZRS --storage-class Standard
```

### 3.2 迁移对象（保留元数据）

```bash
ossutil sync oss://lihka-logo/ oss://img-likha/ --region ap-southeast-6 --copy-props metadata

# 校验：ETag / Content-Type / 大小必须逐字一致（本例 ETag 2311DBFD…5EE4 一致）
ossutil ls   oss://img-likha/ --short-format
ossutil stat oss://img-likha/LIKHA.png
```

### 3.3 关闭新桶的「阻止公共访问」（**必做，否则一切白搭**）

```bash
ossutil api get-bucket-public-access-block --bucket img-likha       # 看现状（默认 true）
ossutil api put-bucket-public-access-block --bucket img-likha \
  --public-access-block-configuration '{"BlockPublicAccess":false}'
```

### 3.4 域名归属验证（OSS 的硬门槛）

`put-cname` 直接调会回 `403 NeedVerifyDomainOwnership`，必须先取 token 并把它写成 TXT：

```bash
# ① 取 token
ossutil api create-cname-token --bucket img-likha \
  --cname-configuration '{"Cname":{"Domain":"img.likha.hk"}}'
#   → <Token>xxxxxxxx</Token>  <ExpireTime>…</ExpireTime>

# ② 写 TXT 记录（主机记录 = _dnsauth.img）
aliyun alidns AddDomainRecord --DomainName likha.hk \
  --RR _dnsauth.img --Type TXT --Value "<Token>" --TTL 600

# ③ 等约 20s 让权威解析生效，再绑定（关键：证书节点名是 CertificateConfiguration）
ossutil api put-cname --bucket img-likha \
  --cname-configuration '{"Cname":{"Domain":"img.likha.hk","CertificateConfiguration":{"CertId":"606823-ap-southeast-1","Force":true}}}'
```

### 3.5 DNS 指向桶

```bash
# 目标 = <桶名>.oss-<地域>.aliyuncs.com
aliyun alidns AddDomainRecord --DomainName likha.hk \
  --RR img --Type CNAME --Value "img-likha.oss-ap-southeast-6.aliyuncs.com" --TTL 600
# 已存在则改用 UpdateDomainRecord --RecordId <id>
```

### 3.6 切换时的顺序（一个域名同时只能绑一个桶）

```
先解绑旧桶 ──▶ 再绑新桶 ──▶ 随后切 DNS
```

若顺序反了（新桶先绑），OSS 回：

```
409 CnameAlreadyExists  "The cname has been attatched to your other bucket already."
```

---

## 4. ★ 四个「静默失败」坑（本文档最值得记的部分）

这些坑的共同特征：**调用返回成功，但配置没生效**。只靠"命令没报错"会被骗过。

### 4.1 证书节点名必须是 `CertificateConfiguration`

```jsonc
// ❌ 这样写：put-cname 返回成功，但证书根本没挂上（HTTPS 仍回 OSS 默认证书）
{"Cname":{"Domain":"img.likha.hk","Certificate":{"Type":"CAS","CertId":"606823-ap-southeast-1"}}}

// ✅ 正确
{"Cname":{"Domain":"img.likha.hk","CertificateConfiguration":{"CertId":"606823-ap-southeast-1","Force":true}}}
```

判据：`list-cname` 里必须出现 `<Certificate>` 段落（含 `CertId` / `Fingerprint` / `ValidEndDate`）。
**与项目里 `CertificateId` vs `CertIdentifier` 是同一类坑**（写错字段名被静默忽略）。

### 4.2 新桶的「阻止公共访问」(BPA) 默认开启 → `public-read` 静默失效

**症状**：桶 ACL 与对象 ACL 读回**都是 `public-read`**，但匿名访问全部 403：

```xml
<Error><Code>AccessDenied</Code>
<Message>Anonymous user has no right to access this bucket.</Message><EC>0003-00000002</EC></Error>
```

**根因**：桶级 BPA 默认为 `true`，此时 public ACL 在**访问判定**上被当作私有。
`ossutil mb` 建出的桶默认就是 `true`（本例旧桶是 `false`，所以能匿名读）。

**教训**：**判「公共读是否生效」不能只看 `GetBucketAcl`** —— 那是「存了什么」，不是「能不能访问」。
正确判据是**匿名实读一次**（见 §5）。

### 4.3 `NeedVerifyDomainOwnership`

`put-cname` 直接调必失败，必须先 `create-cname-token` + 写 `_dnsauth.<rr>` TXT。
token 有效期很短（本例 `ExpireTime` 为 3 天后），过期需重取。

### 4.4 残留的 `www.likha.hk` 绑定 = 劫持隐患

迁桶前，旧桶上除 `img.likha.hk` 外还挂着一条 **`www.likha.hk`** 的自定义域名绑定（状态为"未生效"，
因为 DNS 里 `www` 仍指向马尼拉 ALB，所以当时**无害**）。

**风险**：一旦有人按 OSS 控制台的「配置 CNAME」提示去把 `www` 解析到 OSS，**整站会被劫持到 OSS**。

**处置**：已删除该绑定。**经验：给 OSS 绑域名时，只绑专用子域；生产主域名绝不绑到静态桶上。**

附带一条：证书绑定的字段形态也说明 **OSS 不读 AlbConfig** —— 它是独立的证书通道（见 §6）。

---

## 5. 验证清单（怎么判"真的生效"）

```bash
D=img.likha.hk

# ① DNS：权威 + 公共递归都要看
dig +short $D @ns7.alidns.com
dig +short $D @8.8.8.8          # 期望 → img-likha.oss-ap-southeast-6.aliyuncs.com → 8.212.139.178

# ② 匿名可读（HTTP/HTTPS 都要）
curl -sS -o /dev/null -w "%{http_code} %{size_download}\n" http://$D/LIKHA.png
curl -sS -o /dev/null -w "%{http_code} %{ssl_verify_result}\n" https://$D/LIKHA.png   # 期望 200 / 0

# ③ 权限判定：不存在对象应 404（403 说明没有读权限）
curl -sS -o /dev/null -w "%{http_code}\n" https://$D/__nope__.png

# ④ 匿名列举应被拒（确认对象清单未暴露）
curl -sS -o /dev/null -w "%{http_code}\n" "https://$D/?list-type=2"    # 期望 403

# ⑤ 内容一致性（防迁移损坏）
curl -sS https://$D/LIKHA.png -o /tmp/a.png && md5sum /tmp/a.png
#   本例 2311dbfdb4d1c20db8dcb7958dcc5ee4 == 对象 ETag（十六进制）

# ⑥ TLS 证书
echo | openssl s_client -connect $D:443 -servername $D 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha1
```

### 本例实测结果

| 检查 | 结果 |
|---|---|
| DNS（权威 / 8.8.8.8 / 223.5.5.5） | 全部 → `img-likha.oss-ap-southeast-6.aliyuncs.com` → `8.212.139.178` ✅ |
| `https://img.likha.hk/LIKHA.png` | **200**，27842 B，`ssl_verify_result=0` ✅ |
| 内容 MD5 比对 | `2311dbfd…5ee4` = 源对象 ETag ⇒ **字节一致** ✅ |
| TLS | `CN=*.likha.hk` / issuer `Aliyun RSA TLS DV G1` / 有效至 2027-04-28 ✅ |
| 不存在对象 | **404**（匿名读已放行）✅ |
| 匿名列举 | **403**（未暴露清单）✅ |
| 回归 | `www.likha.hk` 200、`sg.likha.hk` 200（未受影响）✅ |

> **两个观察，避免误判**：
> 1. **证书下发有延迟**：刚绑定时部分边缘节点仍回 OSS 默认证书（`CN=ap-southeast-6.oss.aliyuncs.com`），
>    取样 2/3 → 等 45s 后 8/8 全部 `*.likha.hk`。⇒ **绑定后不要立刻下结论，多取样几次**。
> 2. **执行机（WSL）到公网有网络抖动**：连测 6 次偶发 1 次 `000`，同一抖动在**旧桶**上也出现过
>    ⇒ 不要把偶发超时当配置问题；但也不能用"跑通一次"当验收，需连续多次 + 内容比对。

---

## 6. 证书续期与 OSS 的关系（重点）

### 6.1 OSS 按 `CertId` 引用证书，**不读 AlbConfig**

OSS 绑定里存的是证书**引用**：

```xml
<Certificate>
  <Type>CAS</Type>
  <CertId>606823-ap-southeast-1</CertId>
  <Status>Enabled</Status>
  <Fingerprint>74:94:59:28:43:BF:B9:62:87:D2:6D:73:08:38:E0:E7:16:2E:42:B3</Fingerprint>
  <ValidStartDate>Oct 12 00:00:00 2026 GMT</ValidStartDate>
  <ValidEndDate>Apr 28 23:59:59 2027 GMT</ValidEndDate>
</Certificate>
```

### 6.2 续期后要不要动 OSS —— 分两种情况

| 续期后的情形 | OSS 侧动作 |
|---|---|
| **CertId 不变**（同一张证书内容更新） | 一般会自动跟上，**但仍须复验**，不得假定 |
| **签出新 CertId**（新实例/新订单） | **必须重绑**，否则仍挂旧证，到期当晚 `img.likha.hk` 的 HTTPS 直接挂 |

**本项目既有口径倾向第二种**：`deploy/cert/targets.yaml` 已明确 ——
`AutoReissue=enable` **只保证 CAS 签出新证，不代表云产品自动换绑**；ALB 侧因此被钉死为「改 AlbConfig + apply」。
同理，**OSS 也必须人工复验/重绑**。

### 6.3 复验与重绑命令

```bash
# ① OSS 绑定侧：看 ValidEndDate / Fingerprint 是否跟上新证
ossutil api list-cname --bucket img-likha | sed -n '/Certificate/,/\/Certificate/p'

# ② 实际握手
echo | openssl s_client -connect img.likha.hk:443 -servername img.likha.hk 2>/dev/null \
  | openssl x509 -noout -dates -fingerprint -sha1

# ③ ① 仍是旧证（或 CertId 已换新）⇒ 重绑（幂等）
ossutil api put-cname --bucket img-likha \
  --cname-configuration '{"Cname":{"Domain":"img.likha.hk","CertificateConfiguration":{"CertId":"<新CertId>","Force":true}}}'
```

### 6.4 同一个 `CertId` 现在的三个落点（续签要一起走）

| 目标 | 资源 | 换证通道 |
|---|---|---|
| 马尼拉 ALB | `lsn-hjl2cz2g9oqvee4eix` | 改 `AlbConfig.certificates[].CertificateId` 再 apply（**不能**直调 ALB OpenAPI：`ServiceManagedResource`） |
| 新加坡 ALB | `lsn-iqn5i233mvv7eu4u6w` | 同上（另见 `deploy/cert/targets.yaml`） |
| **OSS `img-likha`** | 自定义域名 `img.likha.hk` | **`ossutil api put-cname`（独立通道）** |

### 6.5 已完成的登记动作（本文档同日）

在 `deploy/cert/targets.yaml` 中补齐了 OSS 通道，避免续签时漏项：

- `targets:` 新增 **`- target: oss`**（`bucket: img-likha` / `domain: img.likha.hk` / `readback` / `renew_action` /
  含 BPA 与 `CertificateConfiguration` 两条坑的 `notes`）
- `renewal.steps` 的 **R1** 加 `note`：若出现新 CertId，除两地 ALB 换绑外**还必须重绑 OSS**
- `renewal.steps` 的 **R4** 扩展为三入口：`www.likha.hk` / `sg.likha.hk` / **`img.likha.hk`**
- `renewal` 新增 `oss_note`：OSS 换证是独立通道，与 R2 必须分别执行

**时间线**：证书 `606823-ap-southeast-1`，有效期 **2026-10-12 → 2027-04-28（198 天）**，
`AutoReissue=enable`（2026-10-12 经授权开启，双路回读），**续签窗口 `due_by: 2027-03-29`**。

---

## 7. 命令速查

| 目的 | 命令 |
|---|---|
| 列桶 / 建桶 | `aliyun oss ls` · `ossutil mb oss://<b> --region <r> --acl public-read --redundancy-type ZRS` |
| 清空 / 删桶 | `ossutil rm oss://<b>/ -r -f` · `ossutil rb oss://<b>` |
| 迁移 | `ossutil sync oss://<src>/ oss://<dst>/ --copy-props metadata` |
| 桶 ACL | `ossutil api get-bucket-acl --bucket <b>` · `... put-bucket-acl --bucket <b> --acl public-read` |
| 桶 BPA | `ossutil api get-bucket-public-access-block --bucket <b>` · `... put-bucket-public-access-block --bucket <b> --public-access-block-configuration '{"BlockPublicAccess":false}'` |
| 域名绑定 | `create-cname-token` → TXT `_dnsauth.<rr>` → `put-cname` |
| 域名回读 | `ossutil api list-cname --bucket <b>` |
| 域名解绑 | `ossutil api delete-cname --bucket <b> --cname-configuration '{"Cname":{"Domain":"<d>"}}'` |
| DNS | `aliyun alidns AddDomainRecord/UpdateDomainRecord/DescribeDomainRecords --DomainName likha.hk` |
| 对象 ACL/元数据 | `ossutil stat oss://<b>/<key>` · `ossutil api get-object-acl --bucket <b> --key <k>` |

> 别名小贴士：`aliyun oss` 是 deprecated 的简化 CLI（`ls/stat/cp/set-acl` 等够用）；
> 桶级新特性（BPA、CNAME、policy）走 **`ossutil api <op>`**（= 直接调 OSS OpenAPI）。
> `ossutil --help` 里没有 `--version`，用 `ossutil version`。

---

## 8. 使用与建议

```bash
# 上传（建议带缓存与正确的 Content-Type）
ossutil cp ./assets/logo.png oss://img-likha/ \
  --meta "Cache-Control:max-age=31536000"
# 访问：https://img.likha.hk/logo.png
```

- **桶是公共读**：任何人可读**已知路径**的对象；列举已被拒（403），对象名不会泄露。
  ⇒ 但**不要往这个桶放敏感文件**。若要更严：保持桶 `private`，逐个对象 `--acl public-read`。
- **只绑专用子域**（`img.likha.hk`）；不要再往这个桶绑 `www.likha.hk` 之类的主域名。
- **可选的下一步**：接入 DCDN 做加速与防盗链（源站指本桶），与本项目静态资源既有做法一致。

---

## 9. 附：本次连带的两个「文档坑」

1. **YAML 普通标量里出现 `: `（冒号+空格）会直接炸解析**。
   在 `targets.yaml` 里把 `` `- target: oss` `` 写进普通标量，`yaml.safe_load` 报
   `ScannerError: mapping values are not allowed here`。⇒ 含冒号的说明文字改用块标量（`|`）或加引号。
   提交前跑一次 `python3 -c "import yaml; yaml.safe_load(open(f))"` 兜底。
2. **OSS API 的错误码比 HTTP 状态更有信息量**（`EC` 字段）：
   `0003-00000002` = 匿名无权访问（BPA 拦截）· `0003-00000905` = 无权限列举 ·
   `0003-00000005` = 对象无读权限。排障时先看 `EC` 与 `Message` 原文。

---

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-13 | 首版：`img-likha` 建桶 + 对象迁移 + `img.likha.hk` 绑定（CAS 证书）+ DNS + 端到端验证；旧桶 `lihka-logo` 下线；`deploy/cert/targets.yaml` 新增 `oss` 目标与续签提醒 |
