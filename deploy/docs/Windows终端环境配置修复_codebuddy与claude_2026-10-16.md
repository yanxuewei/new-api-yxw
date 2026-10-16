# Windows 终端环境配置修复记录

日期：2026-10-16
环境：Windows + PowerShell 5.1（nvm4w 管理的 Node）
范围：`codebuddy-code` 无法启动、`cb` 快捷命令、Claude Code 安装与命令别名

---

## 一、`codebuddy-code` 无法运行（PowerShell 执行策略）

**现象**

```
无法加载文件 C:\nvm4w\nodejs\codebuddy-code.ps1，
因为在此系统上禁止运行脚本。
```

**原因**

PowerShell 执行策略为默认的 `Restricted`，npm 生成的 `.ps1` shim 脚本被拦截。此时 `MachinePolicy` / `UserPolicy` / `CurrentUser` / `LocalMachine` 均为 `Undefined`。

**修复**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

**验证**

- 注册表 `HKCU\Software\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell` → `ExecutionPolicy = RemoteSigned`
- 新进程 `Get-ExecutionPolicy -List` → `CurrentUser = RemoteSigned`
- `codebuddy-code --version` → `2.168.0`

**注意**

- 需**新开终端**生效（旧终端仍持有旧策略）。
- 若被域策略 `MachinePolicy` / `UserPolicy` 覆盖，可用替代方案：
  - 仅当前会话：`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
  - 调用不走脚本的入口：`codebuddy-code.cmd`
  - 在 `cmd` 中直接运行 `codebuddy-code`

---

## 二、`cb` 快捷命令（等价 `codebuddy-code -y`）

PowerShell 的 `Set-Alias` **不支持带参数**，因此改用函数。

**配置文件**：`D:\Users\pc260829\Documents\WindowsPowerShell\profile.ps1`（`$PROFILE.CurrentUserAllHosts`，所有 host 均加载）

```powershell
# ---- custom shortcuts ----
# cb  =>  codebuddy-code -y
# PowerShell 的 Set-Alias 不支持带参数，因此用函数实现
function cb {
    & codebuddy-code -y @args
}
```

**使用**：新开终端后 `cb`，支持透传参数（`cb --version` ≡ `codebuddy-code -y --version`）。
**立即生效**：`. $PROFILE.CurrentUserAllHosts`

**注意**

- 终端若以 `-NoProfile` 启动，profile 不加载，`cb` 不可用。
- 本机未安装 PowerShell 7（`pwsh`）；若以后安装，需在 `D:\Users\pc260829\Documents\PowerShell\profile.ps1` 再放一份同样内容。

---

## 三、安装 Claude Code 失败（E404）

**错误命令**

```powershell
npm i g @claude-ai/claude-code
```

```
npm error 404 Not Found - GET https://registry.npmjs.org/@claude-ai%2fclaude-code
```

**原因（两个错误叠加）**

1. **包名错误**：`@claude-ai/claude-code` 在 npm 官方源不存在，正确包名是 `@anthropic-ai/claude-code`。
2. **参数错误**：`npm i g` 少了一个减号，`g` 会被当成一个名为 `g` 的包安装，全局安装必须写 `-g`。

**正确命令**

```powershell
npm i -g "@anthropic-ai/claude-code"
```

**验证**

- `where claude` → `C:\nvm4w\nodejs\claude`、`claude.cmd`
- `claude --version` → `2.1.301 (Claude Code)`

**关于 postinstall 警告**

初次安装时 npm 提示 `1 package has install scripts not yet covered by allowScripts`（新版 npm 的 `allowScripts` 安全拦截）。当前版本已可正常运行，如遇原生依赖异常可放行安装：

```powershell
npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code"
```

---

## 四、`claude-code` 命令不存在（别名补齐）

**现象**

```
claude-code : 无法将“claude-code”项识别为 cmdlet、函数、脚本文件或可运行程序的名称。
```

**原因**

npm **包名与安装后的命令名不同**：

| 项目 | 值 |
|---|---|
| npm 包名 | `@anthropic-ai/claude-code` |
| 实际命令 | `claude` |

安装本身是成功的，只是不存在 `claude-code` 这个命令。

**修复**（追加到同一个 `profile.ps1`）

```powershell
# claude-code  =>  claude
# npm 包名是 @anthropic-ai/claude-code，但安装后的命令名是 claude
function claude-code {
    & claude @args
}
```

**验证**：`(Get-Command claude-code).CommandType` → `Function`；`claude-code --version` → `2.1.301 (Claude Code)`。

**兜底**：若终端未加载 profile，`claude-code` 会失效，此时直接用真正的命令 `claude`。

---

## 速查表

| 需求 | 命令 |
|---|---|
| 启动 CodeBuddy CLI（自动确认） | `cb` 或 `codebuddy-code -y` |
| 启动 Claude Code | `claude` 或 `claude-code` |
| 安装 / 升级 Claude Code | `npm i -g "@anthropic-ai/claude-code"` |
| 重新加载 profile | `. $PROFILE.CurrentUserAllHosts` |
| 查看执行策略 | `Get-ExecutionPolicy -List` |

---

## 核心经验

1. PowerShell 中带参数的“别名”只能用**函数**，`Set-Alias` 做不到。
2. **npm 包名 ≠ 命令名**，安装后先 `where <猜测名>` 或 `npm ls -g --depth=0` 确认。
3. `-g` 前面的减号不能漏，否则会被当成包名安装。
4. 修改执行策略或 profile 后，都必须**新开终端**才生效。
