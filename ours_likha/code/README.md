# ours_likha/code — 自研代码区

规则：自研 Go 包 / 工具 / 扩展放这里，与上游目录物理隔离（上游**不得**反向 import 本目录）。

当前内容：

| 路径 | 作用 |
|---|---|
| `cmd/logms-check/` | 毫秒定制**运行时自检**：直接调用被改动的三条日志路径（`common.SysLog/SysError`、`logger.LogInfo/LogWarn/LogError`、`middleware.SetUpLogger` 的真实 GIN formatter），把 `gin.DefaultWriter` 重定向到内存 buffer 后机械断言「每行都带 `.mmm`、且无秒级行」。 |

## 运行

```bash
# 在仓库根目录执行；只编译/运行，不需要 DB、不需要 Redis、不需要 Docker
go run ./ours_likha/code/cmd/logms-check
# 期望最后一行：RESULT=MS_CONFIRMED
```

用途：`ours_likha/ops/verify-upstream-changes.sh` 只做**静态文本**在位校验；本工具提供**运行时**
证据，两者互补。改了任何日志时间格式后，两个都应重跑。

## 新增代码时请

- 目录名用自解释的包名（如 `obs/`、`hook/`、`cmd/<tool>/`）；
- 若该代码需要被上游调用，改为「最小化原地补丁 + 登记 `UPSTREAM_CHANGES.md`」，
  不要让上游 import 本目录（保持单向依赖）。
- 新增可执行工具后，确认 `make test`（会 `go test` 覆盖 `./...` 下所有非根包）仍然全绿。
