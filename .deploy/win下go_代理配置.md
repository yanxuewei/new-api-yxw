# Windows 下 Go / 命令行工具代理配置指南

> 适用环境：Windows + PowerShell，本机 VPN 提供 HTTP 代理 `127.0.0.1:8800`
> 记录时间：2026-09-23
> 场景来源：IDE 安装 Go 工具链（`gopls` / `impl` / `goplay` / `dlv`）时报错
> `dial tcp [2607:f8b0:400a:802::2011]:443: connectex: A connection attempt failed ...`

---

## 一、问题现象

在 IDE 中自动安装 Go 工具时全部失败，报错指向 `proxy.golang.org`：

```
Tools install to false
Installing 4 tools at the configured GOBIN: C:\Users\pc260829\go\bin
Installing golang.org/x/tools/gopls@latest FAILED
  err: ... Get "https://proxy.golang.org/golang.org/x/tools/gopls/@v/list":
       dial tcp [2607:f8b0:400a:802::2011]:443: connectex: ...
Installing github.com/josharian/impl@v1.4.0 FAILED
```

同时浏览器上网正常，说明 VPN 本身可用。

---

## 二、根因：Windows 上存在"三套代理"，Go 只认其中一套

| 层级 | 存储位置 | 谁在读它 | 本次诊断结果 |
| --- | --- | --- | --- |
| WinINET 系统代理 | 注册表 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings` | 浏览器、部分 GUI 程序 | **已启用** `127.0.0.1:8800` |
| WinHTTP | `netsh winhttp show proxy` | 系统服务、部分安装器 | **Direct（无代理）** |
| 代理环境变量 | `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | Go、Git、Node/Bun、pip、Docker CLI 等 | **全部为空** ← 问题所在 |

关键结论：

> Go 仅通过环境变量识别代理（`golang.org/x/net/http/httpproxy` 的 `FromEnvironment`），
> **完全不读取 WinINET 系统代理设置**。

因此即使 VPN 已开启系统代理、浏览器可以正常访问 Google，`go install`、
`go mod download` 等命令仍然会直连 `proxy.golang.org`，从而超时失败。
这与"VPN 是否开启"无关，纯粹是代理层级不匹配。

---

## 三、诊断步骤

### 1. 查看当前 Go 环境

```powershell
go version
go env GOPROXY GOSUMDB GOBIN GOPATH GOFLAGS GOTOOLCHAIN
```

### 2. 查看系统代理（WinINET）与 WinHTTP

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL | Format-List

netsh winhttp show proxy
```

### 3. 查看代理环境变量

```powershell
Get-ChildItem Env: | Where-Object { $_.Name -match 'proxy' } | Format-List
```

### 4. 测试代理端口与目标站点连通性

```powershell
# 官方模块代理是否可达（IPv4 / IPv6 都会被测试）
Test-NetConnection proxy.golang.org -Port 443 -InformationLevel Quiet
# 国内镜像是否可达
Test-NetConnection goproxy.cn -Port 443 -InformationLevel Quiet
# VPN 代理端口是否监听
Test-NetConnection 127.0.0.1 -Port 8800 -InformationLevel Quiet
# 经代理访问官方模块代理，预期返回 200
Invoke-WebRequest -Uri 'https://proxy.golang.org/golang.org/x/tools/@v/list' `
    -Proxy 'http://127.0.0.1:8800' -TimeoutSec 20 -UseBasicParsing |
    Select-Object StatusCode
```

本次实测结果：`proxy.golang.org` 的 IPv4 与 IPv6 均不可达（`False`），
`goproxy.cn` 可达，`127.0.0.1:8800` 可达且经其访问官方源返回 `200`。

---

## 四、解决方案

采取**「国内镜像优先 + VPN 代理兜底」**的组合策略：

- 镜像域名是 `.cn`，走直连速度最快、不消耗代理流量；
- 镜像异常时自动降级到官方源，并由 VPN 代理接管；
- VPN 未开启时，第一档镜像仍然可用，不会整体瘫痪。

### 4.1 配置用户级代理环境变量

```powershell
$p  = 'http://127.0.0.1:8800'
$np = 'localhost,127.0.0.1,::1,.cn,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'

foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy') {
    [Environment]::SetEnvironmentVariable($k, $p, 'User')
}
foreach ($k in 'NO_PROXY', 'no_proxy') {
    [Environment]::SetEnvironmentVariable($k, $np, 'User')
}
```

说明：

- 写入 `User` 级而非 `Machine` 级，无需管理员权限，且只影响当前用户；
- Windows 的环境变量名**大小写不敏感**，`http_proxy` 与 `HTTP_PROXY` 实为同一个变量，
  此处一并书写只是为了兼容跨平台脚本习惯；
- `NO_PROXY` 中的 `.cn` 覆盖所有国内域名（与 VPN 客户端自带的绕过规则一致），
  网段项覆盖内网地址，避免本地/内网请求被错误地塞进代理。

### 4.2 配置 Go 模块代理

```powershell
go env -w GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct
go env -w GOSUMDB=sum.golang.google.cn
```

- `GOPROXY` 中的逗号表示**失败即降级**：先试 `goproxy.cn`，失败后试官方源
  （此时会使用 `HTTPS_PROXY` 走 VPN），最后才是 `direct` 直连；
- `GOSUMDB` 改为 `sum.golang.google.cn`，避免校验数据库 `sum.golang.org` 同样被墙；
- 如需只走镜像、完全无视代理，可用 `GOPROXY=https://goproxy.cn,direct`。

### 4.3 让 WinHTTP 也继承系统代理（可选）

仅当有安装器/系统服务需要联网时执行：

```powershell
netsh winhttp import proxy source=ie
```

---

## 五、验证

```powershell
# 读取最终配置
go env GOPROXY GOSUMDB
[Environment]::GetEnvironmentVariables('User').GetEnumerator() |
    Where-Object { $_.Name -match 'proxy' } | Sort-Object Name | Format-Table -AutoSize

# 链路一：官方源 + VPN 代理
$t = Join-Path $env:TEMP 'proxy-verify'
New-Item -ItemType Directory $t -Force | Out-Null
Push-Location $t
go mod init verify | Out-Null
$env:HTTPS_PROXY = 'http://127.0.0.1:8800'
$env:NO_PROXY    = 'localhost,127.0.0.1,::1,.cn,.local'
$env:GOPROXY     = 'https://proxy.golang.org,direct'
go get rsc.io/quote/v3@v3.1.0        # 预期 exit 0

# 链路二：镜像优先
$env:GOPROXY = 'https://goproxy.cn,https://proxy.golang.org,direct'
go get github.com/google/uuid@v1.6.0 # 预期 exit 0
Pop-Location
Remove-Item $t -Recurse -Force
```

本次实测结果：

| 验证项 | 结果 |
| --- | --- |
| 官方源 + VPN 代理 | exit 0，成功拉取 `rsc.io/quote/v3` |
| 国内镜像直连 | exit 0，成功拉取 `github.com/google/uuid` |
| 代理连通性（HTTPS CONNECT → `proxy.golang.org`） | HTTP 200 |
| `gopls` / `impl` / `goplay` / `dlv` 安装 | 全部成功，位于 `C:\Users\pc260829\go\bin` |
| `gopls version` | `golang.org/x/tools/gopls v0.23.0` |

> 输出中出现 PowerShell 的 `NativeCommandError` 是将 `go` 的 stderr 误判为错误流所致，
> 退出码为 0，非真实失败。

---

## 六、必须执行的一步：重启 IDE

新环境变量只对**新启动的进程**生效。`gopls` 等语言服务器由 IDE 派生，
因此必须**完全退出 IDE 进程后重新打开**（仅 Reload Window 不够），
否则 IDE 内的 Go 工具链仍会沿用旧环境变量并继续报错。

---

## 七、三种方案的取舍

| 方案 | 做法 | 优点 | 缺点 |
| --- | --- | --- | --- |
| **TUN 模式** | VPN 客户端开启 TUN / 虚拟网卡（Clash Verge 需装 Service Mode + wintun） | 内核层接管所有进程流量，零配置，无需环境变量 | 需要安装驱动；全局流量走代理 |
| **代理环境变量** | 配置 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`（即本文方案） | 无需额外驱动，可控粒度细 | VPN 未启动时依赖代理的链路会失败；需维护 `NO_PROXY` |
| **国内镜像** | `GOPROXY` 指向 `goproxy.cn` 等 | 不依赖 VPN，速度最快，最稳定 | 仅覆盖单一生态（Go / pip / npm 需分别配置） |

**推荐组合**：TUN 模式（全局兜底）+ 国内镜像（速度优先）+ 代理环境变量（精确降级）。
三者互不冲突：`.cn` 域名会命中 `NO_PROXY` 直连镜像，其余流量由 VPN 接管。

---

## 八、其他生态的配套说明

- **Git**：`libcurl` 会自动读取 `http_proxy` / `https_proxy` 环境变量，配置完成后无需
  `git config --global http.proxy`。若需单独设置：
  `git config --global http.proxy http://127.0.0.1:8800`。
- **Bun / npm**：同样读取 `HTTPS_PROXY`，一般无需额外配置。npm 如需显式设置：
  `npm config set proxy http://127.0.0.1:8800` 与 `npm config set https-proxy http://127.0.0.1:8800`。
- **pip**：可额外配置国内源，如 `PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple`。
- **Docker Desktop**：Settings → Resources → Proxies 中手动填写。
- **`go env -w` 的写入位置**：`%USERPROFILE%\AppData\Roaming\go\env`，与系统环境变量相互独立。

---

## 九、回滚

```powershell
# 清除代理环境变量
[Environment]::SetEnvironmentVariable('HTTP_PROXY',  $null, 'User')
[Environment]::SetEnvironmentVariable('HTTPS_PROXY', $null, 'User')
[Environment]::SetEnvironmentVariable('NO_PROXY',    $null, 'User')

# 恢复 Go 默认代理
go env -u GOPROXY
go env -u GOSUMDB

# 恢复 WinHTTP 为直连
netsh winhttp reset proxy
```

将 VPN 客户端切换为 TUN 模式实现全局接管后，也可按上述方式清空环境变量，避免双重代理。
