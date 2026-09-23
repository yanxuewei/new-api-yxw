# WSL 故障处理

记录环境：WSL2（宿主 `DESKTOP-S259MJS`），用户 `fanyan`，宿主 IP 别名 `winhost`。

---

## 一、典型现象

```
$ git clone git@github.com:xxx/yyy.git
ssh: Could not resolve hostname ssh.github.com: Temporary failure in name resolution
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
```

最后那句 `Please make sure you have the correct access rights` **具有极强误导性**——它会被误读成"SSH key 没配好 / 权限不足"。实际上只要出现 `Could not resolve hostname`，问题就与权限无关，是 **DNS 解析失败**。

同类表现：

- 所有域名操作失败（`apt update`、`curl https://...`、`ping github.com`）
- 但 `ping 1.1.1.1`、`ping 8.8.8.8` 等 **IP 直连正常**
- 浏览器（Windows 侧）上网正常，只有 WSL 里不正常

---

## 二、快速定位：三步区分故障类型

排查第一步永远是**把"链路不通 / DNS 不通 / 认证不通"三者分开**，否则容易在错误的方向上折腾。

```bash
ping -c 2 1.1.1.1          # 步骤 1：链路是否通
getent hosts github.com    # 步骤 2：DNS 是否通
ssh -T git@github.com      # 步骤 3：SSH 认证是否通
```

判断表：

| `ping 1.1.1.1` | `getent hosts github.com` | 结论与下一步 |
|---|---|---|
| 通 | 有输出 | 链路与 DNS 均正常，转去查 SSH 认证（key、`~/.ssh/config`、代理） |
| 通 | **无任何输出** | **DNS 故障**（本次情况），执行第三节 |
| 不通 | — | 网络链路故障：查 WSL 网络模式、宿主防火墙、`ip route` |

补充查看 DNS 配置本体：

```bash
cat /etc/resolv.conf
ls -la /etc/resolv.conf          # 注意是否 "No such file or directory"
cat /etc/wsl.conf
```

---

## 三、根因分析

### 3.1 表层原因

`/etc/resolv.conf` 指向失效的 DNS：

```
nameserver 172.18.0.1
```

`172.18.0.1` 是 WSL 的网络网关（同时是宿主地址 `winhost`）。该地址不具备 DNS 解析能力，因此所有域名查询失败。

### 3.2 深层原因（坑在这里）

为阻止 WSL 用失效网关覆盖 DNS，在 `/etc/wsl.conf` 中加入了：

```ini
[network]
generateResolvConf = false
```

这解决了"覆盖"问题，却引入新问题：**WSL 从此不再生成 `/etc/resolv.conf`**。一旦该文件缺失（重启、清理、误删），系统就变成"没有任何 DNS 服务器"，全站解析失败。

也就是说，`generateResolvConf = false` 必须配一套**自己重建该文件**的机制，否则等于把系统置于随时失去 DNS 的状态。**只改 `wsl.conf` 而不做持久化，是本故障的真正来源。**

### 3.3 加剧困惑的因素

`~/.ssh/config` 中把 GitHub 映射到了 443 端口抗阻断：

```
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    HostKeyAlias github.com
```

因此报错里出现的是 `ssh.github.com` 而不是 `github.com`，容易被误判为"某个特殊域名被墙"，进一步偏离 DNS 这个正确方向。

---

## 四、修复步骤

### 步骤 1：确认哪些公共 DNS 可用

```bash
for s in 223.5.5.5 114.114.114.114 8.8.8.8 1.1.1.1; do
  echo "== $s =="
  timeout 5 nslookup github.com $s 2>&1 | tail -n 5
done
```

只要能解析出 `Address`，该 DNS 就可用。

### 步骤 2：写入 `/etc/resolv.conf`

```bash
sudo sh -c 'cp -n /etc/resolv.conf /etc/resolv.conf.wslbak'
sudo sh -c 'printf "nameserver 223.5.5.5\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf'
```

立即验证（无需重启）：

```bash
getent hosts github.com
getent hosts ssh.github.com
```

### 步骤 3：建立自愈机制（关键，不可省略）

因为 `generateResolvConf = false`，必须自己保证该文件存在。做法是挂到 WSL 启动钩子 `[boot] command`，每次 VM 启动自动补齐。

**3.1 创建 `/usr/local/bin/wsl-dns-refresh`：**

```bash
#!/bin/bash
# 修复 WSL DNS 缺失问题
#
# 背景：/etc/wsl.conf 里设了 generateResolvConf = false（为了阻止 WSL 用失效的
# 虚拟网关 172.18.0.1 覆盖 DNS）。副作用是 WSL 不再自动生成 /etc/resolv.conf，
# 一旦该文件缺失，系统就完全没有 DNS 服务器可用，所有域名解析失败，表现为：
#   ssh: Could not resolve hostname ssh.github.com: Temporary failure in name resolution
#   fatal: Could not read from remote repository.
#
# 由 wsl-boot.sh 在每次 VM 启动时调用：缺失/为空则重建；已存在则保留，不覆盖手工改动。

if [ -s /etc/resolv.conf ]; then
  echo "wsl-dns-refresh: /etc/resolv.conf 已存在，跳过"
  exit 0
fi

printf 'nameserver 223.5.5.5\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
chmod 644 /etc/resolv.conf
echo "wsl-dns-refresh: 已重建 /etc/resolv.conf -> $(tr '\n' ' ' < /etc/resolv.conf)"
```

安装：

```bash
sudo install -m 755 wsl-dns-refresh /usr/local/bin/wsl-dns-refresh
```

**3.2 挂到 `/usr/local/bin/wsl-boot.sh`：**

必须插在 `wsl-proxy-refresh` **之前**，因为后者含 `awk '/^nameserver/{print $2}' /etc/resolv.conf` 的兜底逻辑，依赖该文件已就位。

```bash
# DNS 修复：generateResolvConf=false 后 WSL 不再自动生成 resolv.conf
# 文件缺失会导致全部域名解析失败，所以每次启动都要补上
[ -x /usr/local/bin/wsl-dns-refresh ] && /usr/local/bin/wsl-dns-refresh >> /var/log/wsl-boot.log 2>&1
[ -x /usr/local/bin/wsl-proxy-refresh ] && /usr/local/bin/wsl-proxy-refresh >> /var/log/wsl-boot.log 2>&1
```

> 注意：`wsl-boot.sh` 是 CRLF 行尾，用编辑器批量改时要确认行尾未被混用；脚本以 root 身份执行，无需 `sudo`。

### 步骤 4：验证

```bash
# 非破坏性验证：文件存在时应跳过
sudo /usr/local/bin/wsl-dns-refresh

# 破坏性验证：删除后应能自动重建（会短暂断 DNS，几秒即可恢复）
sudo sh -c 'mv /etc/resolv.conf /tmp/resolv.conf.bak4test && /usr/local/bin/wsl-dns-refresh && cat /etc/resolv.conf && rm -f /tmp/resolv.conf.bak4test'
getent hosts github.com

# 端到端验证
ssh -T git@github.com
```

`ssh -T` 返回 `Hi <username>! You've successfully authenticated, but GitHub does not provide shell access.` 即为成功（退出码 1 属正常，不是错误）。

---

## 五、附带故障：`git submodule` 拉取失败

DNS 恢复后，`git submodule update --init --recursive` 仍可能失败，原因有两个。

### 5.1 不要用 `timeout` 包裹 git

`timeout 600 git submodule update ...` 超时被杀后，会留下**损坏的半成品**：`.git/modules/<path>` 和子模块目录都在，但 clone 未完成。再跑时 git 会报 `already exists` 并尝试重试，往往再次失败后直接 abort。

清理方法：

```bash
cd /home/fanyan/git_code/fanyan_ai_cfg
git submodule deinit -f -- z_ext_lib/<name>
rm -rf .git/modules/z_ext_lib/<name> z_ext_lib/<name>
```

**正确做法**：后台跑 + 逐模块重试 + 日志落盘，避免受终端或工具超时影响。

### 5.2 逐模块重试脚本

```bash
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO=/home/fanyan/git_code/fanyan_ai_cfg
LOG=/tmp/submodule-sync.log
cd "$REPO" || exit 1
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

log "===== 开始同步子模块 ====="
mapfile -t paths < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

total=${#paths[@]}; idx=0; failed=()

for path in "${paths[@]}"; do
  idx=$((idx + 1))
  st=$(git submodule status -- "$path" 2>/dev/null | cut -c1)
  if [ "$st" = " " ]; then
    log "[$idx/$total] 跳过 $path（已就绪）"; continue
  fi

  log "[$idx/$total] 开始 $path（状态标记: ${st:-空}）"
  ok=0
  for attempt in 1 2 3; do
    git submodule update --init --recursive -- "$path" >> "$LOG" 2>&1
    if [ "$(git submodule status -- "$path" 2>/dev/null | cut -c1)" = " " ]; then
      ok=1; log "      $path 完成"; break
    fi
    log "      第 $attempt 次未成功，清理后重试"
    git submodule deinit -f -- "$path" >> "$LOG" 2>&1
    rm -rf "$REPO/.git/modules/$path" "$REPO/$path"
    sleep 3
  done
  [ $ok -eq 1 ] || { log "      $path 最终失败"; failed+=("$path"); }
done

log "===== 最终状态 ====="
git submodule status >> "$LOG" 2>&1
if [ ${#failed[@]} -eq 0 ]; then
  log "SYNC_FINISHED: 全部成功"
else
  log "SYNC_FINISHED: 失败 ${#failed[@]} 个 -> ${failed[*]}"
fi
```

启动（`setsid` 脱离终端，不受工具超时影响）：

```bash
chmod +x /tmp/submodule-sync.sh
setsid nohup /tmp/submodule-sync.sh >/dev/null 2>&1 < /dev/null &
tail -f /tmp/submodule-sync.log
```

**`git submodule status` 行首标记含义：**

| 标记 | 含义 | 处理 |
|---|---|---|
| （空格） | 已初始化且 commit 匹配 | 无需处理 |
| `-` | 未初始化 | 需 `update --init` |
| `+` | 已 checkout 但 commit 与父仓库记录不符 | 需 `update` 纠正 |
| `U` | 存在冲突 | 手工解决 |

### 5.3 耗时参考（直连 ~120–150 KiB/s）

| 子模块 | 耗时 | 备注 |
|---|---|---|
| `superpowers` | < 1 分钟 | |
| `everything-claude-code` | < 1 分钟 | |
| `OpenSpec` | < 1 分钟 | |
| `spec-kit` | 约 2 分钟 | |
| `last30days-skill-cn` | 约 1.5 分钟 | |
| `get-shit-done` | 约 9 分钟 | |
| `gstack` | 约 16 分钟 | 144 MB，最大 |
| `claude-code-best-practice` | 约 8 分钟 | |

总计约 38 分钟。**开代理后走 HTTPS 会快很多。**

---

## 六、代理相关

WSL **不会继承 Windows 侧的代理设置**，需显式配置。本机方案：Windows 上跑 QuickQ，经 portproxy 暴露给 WSL，`winhost` 别名由 `wsl-proxy-refresh` 每次启动写入 `/etc/hosts`。

排查代理：

```bash
proxystat                      # 查看代理状态与端口可达性（定义在 /etc/profile.d/99-wsl-proxy.sh）
grep winhost /etc/hosts        # 确认别名
```

实测本次两个端口均不可达：

```
172.18.0.1:18800  不可达      # HTTP 代理
172.18.0.1:11020  不可达      # SOCKS5 代理
```

说明 **QuickQ 当时未启动或 Windows 侧 portproxy 未生效**。这会导致 git 只能直连，速度很慢。

要点：

- `http_proxy` / `https_proxy` 对 **SSH 协议无效**，SSH 需走 `ProxyCommand` 或直连
- 本机 SSH 通过 `ssh.github.com:443` 直连绕过阻断，不依赖代理
- 临时跳过自动配代理：`export WSL_PROXY_SKIP=1`

---

## 七、速查表

| 现象 | 原因 | 处理 |
|---|---|---|
| `Could not resolve hostname` | DNS 故障，与权限无关 | `cat /etc/resolv.conf`，确认文件存在且 nameserver 有效 |
| `/etc/resolv.conf` 不存在 | `generateResolvConf=false` 且无重建机制 | `sudo /usr/local/bin/wsl-dns-refresh` |
| 重启后又失效 | 自愈脚本未挂到 `wsl-boot.sh` | 检查 `grep wsl-dns-refresh /usr/local/bin/wsl-boot.sh` |
| `ping IP` 通但域名不通 | 纯 DNS 问题 | 同上 |
| `ssh -T git@github.com` 失败但 DNS 正常 | SSH key / config 问题 | 查 `~/.ssh/config`、`id_ed25519` 权限 |
| submodule 反复失败 | 上次超时留下半成品 | `deinit` + `rm -rf .git/modules/<path>` 后重试 |

**日常自检命令：**

```bash
cat /etc/resolv.conf && getent hosts github.com && tail -5 /var/log/wsl-boot.log
```

---

## 八、相关文件清单

| 路径 | 作用 |
|---|---|
| `/etc/resolv.conf` | DNS 服务器配置（本机已改为公共 DNS，不再自动生成） |
| `/etc/wsl.conf` | WSL 全局配置，含 `generateResolvConf = false` 与 `[boot] command` |
| `/etc/resolv.conf.wslbak` | 修改前的原始备份 |
| `/usr/local/bin/wsl-dns-refresh` | DNS 自愈脚本 |
| `/usr/local/bin/wsl-boot.sh` | WSL 启动钩子，调用 dns-refresh 与 proxy-refresh |
| `/usr/local/bin/wsl-proxy-refresh` | 刷新宿主 IP 别名 `winhost` |
| `/etc/profile.d/99-wsl-proxy.sh` | 代理环境变量与 `proxystat` |
| `/var/log/wsl-boot.log` | 启动钩子日志 |
| `/etc/hosts` | 含 `winhost` 别名 |
