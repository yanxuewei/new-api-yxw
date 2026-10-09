# ADR-0001：自研代码目录命名与 `internal` 可见性边界

- 状态：Accepted
- 日期：2026-10-09
- 范围：`ours_likha/` 目录骨架、Go 包命名与导入可见性纪律
- 验证环境：go1.27.1（Windows，源码引用行号以该版本为准）

## 1. 背景

本仓库是 `QuantumNous/new-api` 的 fork。自研逻辑集中放在 `ours_likha/`，按三段式与上游物理隔离：

| 目录 | 用途 |
|---|---|
| `code/` | 自研 Go 代码 / 包、可独立构建的工具、扩展插件 |
| `ops/` | 上游补丁、漂移校验、构建/发布、CI 辅助 |
| `doc/` | 定制设计与运维文档（本目录） |

两个待决问题：

1. Go 源码目录能否用下划线命名（如 `ours_likha`）？有什么优缺点和坑？
2. 是否应把 `ours_likha` 改名为 `internal/likha`，以求"限制可见性"？

## 2. 决策

1. **保留 `ours_likha/{code,ops,doc}` 现状，顶层目录名不改。**
2. **不把 `ours_likha` 改名为 `internal/likha`**：它拦不住"上游反向依赖"，且与三段式语义冲突。
3. **未来首次出现非 `main` 的自研库包时**，把它放到 `ours_likha/code/internal/<pkg>`，让纪律由编译器强制。

## 3. 依据

### 3.1 下划线目录名对 Go 构建无影响

分三种情况，答案不同：

| 情形 | 是否合法 | 是否符合 Go 惯例 |
|---|---|---|
| 仓库 / 模块根目录名含下划线（`ours_likha/`） | 合法 | 无影响，Go 不关心 |
| 包目录名含下划线（`my_code/`，包名 `my_code`） | 合法 | 不符合，`golint`/`revive`/`staticcheck` 报警 |
| 目录名**以** `_` 开头（`_code/`） | 文件系统合法 | 被 go 工具链**静默忽略** |

要点：

- **模块路径由 `go.mod` 决定，与文件夹名无关。** 本仓库即例证：目录名是 `new-api-yxw`（还带连字符 `-`），而：

  ```1:1:go.mod
  module github.com/QuantumNous/new-api
  ```

  构建完全正常。所以 `ours_likha` 这个顶层目录名对 Go 零影响。

- **包目录名会参与包名推断。** 下划线是合法标识符字符，`my_code/` 推断出的包名就是 `my_code`，编译通过，但违反 Go 官方评审规范（包名应小写、无下划线、非混合大小写）。裸 `_` 不能作包名（`package _` 报 `invalid package name _`）。
- **`_` / `.` 前缀是硬坑**：go 工具忽略以 `.` 或 `_` 开头的文件与目录（以及名为 `testdata` 的目录），`go build ./...` 会**静默跳过**，不报错。因此绝不可用 `_` 作源码目录前缀。
- 不含 `.go` 文件的目录会被 `go list ./...` 跳过（`ops/`、`doc/` 属于此类），但 `go build ./ours_likha/doc` 会报 `no Go files`。

### 3.2 `internal` 的可见性由谁保证

**不是编译器、不是运行时**，而是 `go` 命令的包加载器。规则出自 `golang.org/s/go14internal`，就写在实现注释里：

```1486:1489:$GOROOT/src/cmd/go/internal/load/pkg.go
	// golang.org/s/go14internal:
	// An import of a path containing the element “internal”
	// is disallowed if the importing code is outside the tree
	// rooted at the parent of the “internal” directory.
```

判定入口是 `disallowInternal`，在**每次解析 import 时**无条件执行：

```803:808:$GOROOT/src/cmd/go/internal/load/pkg.go
	if mode&allowSimdInternalBridge == 0 || path != SimdBridgePkg { // Special case for just this import.
		// Checked on every import because the rules depend on the code doing the importing.
		if perr := disallowInternal(ld, ctx, srcDir, parent, parentPath, p, stk); perr != nil {
			perr.setPos(importPos)
			return p, perr
		}
	}
```

关键分支：

```1576:1579:$GOROOT/src/cmd/go/internal/load/pkg.go
		parentOfInternal := p.ImportPath[:i]
		if str.HasPathPrefix(importerPath, parentOfInternal) {
			return nil
		}
```

- **包在主模块内**（`p.Module != nil`）：纯**导入路径前缀**比较，不看物理目录（`replace` 到本地目录不改变规则，见 issue 23970）。
- **包不在模块内**（GOROOT 源码、旧 GOPATH 布局）：退化为**文件路径**前缀比较，并额外展开符号链接（`expandPath`）。
- 定位用 `findInternal`，取**最后一个** `internal` 元素，因为最靠后的限制最严（`$GOROOT/src/cmd/go/internal/load/pkg.go:1595`）。
- 前缀比较按 `/` 元素边界，不是裸字符串：`a/b` 匹配 `a/b/c`，不匹配 `a/bc`（`$GOROOT/src/cmd/go/internal/str/path.go:16`）。
- 失败时报 `use of internal package <path> not allowed`，退出码非 0。

**它不是安全边界。** 代码里存在一组显式豁免：导入者为空（命令行直接列包）、命令行文件模式、`testmain` 访问 `testing/internal`、bootstrap 阶段、gccgo 构建标准库、FIPS 快照特例。绕过方式：复制/fork 源码、直接调 `go tool compile`。另外 `go/build` 包已不再做这项检查，只有 `go` 命令链（含 `go list`/`go vet`/`gopls`）会拦。

### 3.3 为什么 `internal/likha` 无效

要拦的是 README 纪律第 1 条：

```17:18:ours_likha/README.md
1. `code/` 下的包**不得**被上游目录反向依赖（保持单向：上游 ← 我们的补丁；`ours_likha` 独立生长）。
   若确需上游调用，走**最小化原地补丁 + 登记 UPSTREAM_CHANGES.md**，而非让上游 import 本目录。
```

按 3.2 的前缀规则逐一代入：

| 目标路径 | `internal` 的父前缀 | 上游 `common/` 能否导入 |
|---|---|---|
| `.../new-api/internal/likha` | `github.com/QuantumNous/new-api` | **能**（上游路径也以该前缀开头） |
| `.../new-api/ours_likha/internal/x` | `.../new-api/ours_likha` | 不能 |
| `.../new-api/ours_likha/code/internal/x` | `.../new-api/ours_likha/code` | 不能 |

根目录 `internal/` 的语义是"**整个模块**私有"。但上游目录（`common/`、`relay/`、`model/`…）与自研目录**同属一个模块**，前缀相同，所以它对本仓库的目标**毫无隔离作用**。想让纪律机械化，父前缀必须收到 `ours_likha` 这一层。

### 3.4 当前为何也不需要 `internal`

`ours_likha/code/` 下目前唯一的 Go 代码是 `cmd/logms-check/`，为 `package main`。`main` 包在语言层面就不可被任何包 import，因此给它套 `internal` 收益为零；其唯一用途是 `go run`。

改名的其他代价：

1. **语义错位**：`ours_likha` 表达"归属（我们自己的、非上游）"，`internal` 表达"导入权限"，两者正交；改名会丢掉 fork 治理最核心的信息。
2. **破坏三段式**：`ops/` 是 shell + patch、`doc/` 是 markdown，都不是 Go 包；`internal` 与 `code` 平级会让 `code` 的定位变得不确定。
3. **挡住未来模块化**：`internal` 检查基于模块路径前缀，将来若把 `code/` 抽成独立模块（如 `relaykit/`），全部失效须先搬家。AGENTS.md 已规定 `relaykit/` 不得依赖主模块。
4. **成本真实、收益为零**：需同步改 `code/README.md`、目录骨架约定等。

## 4. 未来触发条件与正确形状

**触发条件**：出现第一个**非 `main`** 的自研库包——会被 `code/cmd/` 或其它自研代码 import，但**不希望上游目录** import。

**正确形状**：

```
ours_likha/code/internal/<pkg>/
```

效果精确匹配纪律第 1 条：

- `ours_likha/code/cmd/logms-check` 仍可正常 import（前缀匹配）；
- 上游 `common/`、`relay/`、`model/` 一律编译期拒绝；
- 纪律从"人工 review + `UPSTREAM_CHANGES.md` 登记"升级为编译器强制。

**不要**放到 `ours_likha/internal/`（与三段式混杂，且放宽到整个 `ours_likha` 可见）或模块根 `internal/`（完全无效，见 3.3）。

## 5. 注意事项

1. 绝不用 `_` 或 `.` 作源码目录前缀——会被工具链静默忽略。
2. 库包目录名用全小写、无下划线、无连字符的自解释词（`obs/`、`hook/`）。连字符更糟：工具会改写目录名推断出的包名，导致目录名与包名不一致。
3. `cmd/logms-check/` 带连字符是安全的，仅因为它是 `package main`（包名固定为 `main`，目录名不参与）；新建库包时不要照抄。
4. `internal` 只限制**导入**，不阻止 `go build ./...` / `go test ./...` 覆盖它，也不是运行时隔离。
5. 目录名 ≠ 包名虽合法但强烈避免；`goimports` 与 gopls 按目录名推断，不一致会反复出错。
6. 模块根目录名随意，但 `go.mod` 的 `module` 路径必须是真实可达、可被他人 import 的路径。

## 6. 验证方法

```bash
# 1) 确认自研目录被纳入构建（应列出 cmd/logms-check）
go list ./ours_likha/...

# 2) internal 生效性自测（临时创建后务必撤回）
#    在 common/ 下临时 import ".../ours_likha/code/internal/<pkg>"，
#    期望编译失败：use of internal package ... not allowed
go build ./common/

# 3) 现有定制项仍在位
bash ours_likha/ops/verify-upstream-changes.sh
```

## 7. 参考

- 规则来源：`golang.org/s/go14internal`
- `$GOROOT/src/cmd/go/internal/load/pkg.go`：`disallowInternal`(1485)、豁免清单(1500–1550)、命令行导入者(1519)、模块内前缀判断(1576–1579)、非模块文件路径判断(1552–1564)、`findInternal`(1595)、错误信息(1587)、`disallowVendorVisibility`(1643)
- `$GOROOT/src/cmd/go/internal/str/path.go`：`HasPathPrefix`(16)
- 同类先例：`relaykit/relayconvert/internal/`
