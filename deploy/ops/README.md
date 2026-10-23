# deploy/ops —— ops 工具镜像构建与推送

`~/git_code/service_ops/` 是**多工具仓库**，每个子目录一个独立工具（Go / Python / 其他语言），互不依赖；
本目录只放"对它们的运维动作"，目前是 `push.sh`（构建 + 推送镜像到 ACR EE）。

```
~/git_code/service_ops/
├── mock-upstream/          # Go：压测用 mock 上游（已有）
│   ├── go.mod              # 独立模块（脱离主仓库后必须）
│   ├── main.go
│   ├── Dockerfile          # 约定：COPY <module> /usr/local/bin/<module>
│   ├── mock-upstream.yaml  # 部署清单（部署到 new-api-perf）
│   └── mock_ctl.sh         # 运行时参数广播
└── <future-tool>/          # Python / Rust / Node…（可选 build.sh 自定义构建）
```

## push.sh

`push.sh` 支持双模式：主应用 `new-api`（模式 A，`-n <ns>`）和 service_ops 任意模块（模式 B，`-n <ns> --module <dir>`）。当前目录下有 `Dockerfile` 即可推送，与语言无关。

```bash
# 列出 service_ops 下所有模块（有 Dockerfile 的会标记）
bash deploy/ops/push.sh --list

# 构建并推送（tag 默认 = 日期-主仓 git 短 sha）
bash deploy/ops/push.sh -n dev --module ~/git_code/service_ops/mock-upstream
# 指定 tag
bash deploy/ops/push.sh -n dev --module ~/git_code/service_ops/mock-upstream -t 20261021-hotfix
# 跳过二进制构建（镜像已在本地）
bash deploy/ops/push.sh -n dev --module ~/git_code/service_ops/mock-upstream --no-build
# 简写 -m
bash deploy/ops/push.sh -n dev -m ~/git_code/service_ops/mock-upstream
```

环境变量（都可覆盖）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SERVICE_OPS_DIR` | `<repo>/../service_ops` | 工具仓库位置 |
| `ACR_REGISTRY` | `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com` | ACR EE 域名 |
| `ACR_NAMESPACE` | `newapi-dev` | 仓库命名空间 |
| `ACR_INSTANCE_ID` | `cri-avfqy9xkqi5bj8ee` | EE 实例 ID |
| `ACR_REGION` | `ap-southeast-6` | 实例地域 |

脚本做的事（按顺序）：

1. 校验模块目录与 `Dockerfile`；
2. **构建二进制**：优先执行模块内可执行的 `build.sh`；否则若含 `*.go`，用
   `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o <module> .`；
   其他语言跳过（由 Dockerfile 多阶段构建负责）；
3. **确保 ACR 仓库存在**（`GetRepository` 不存在则 `CreateRepository`，幂等）；
4. **登录**：`aliyun cr GetAuthorizationToken` 临时口令（1 小时有效），不落盘长期凭据；
5. `docker build` + `docker push`，最后回显 `RepoDigests`（tag 可追溯）。

## 新增一个工具模块

```bash
cd ~/git_code/service_ops
mkdir my-tool && cd my-tool
# 1) 代码（Go 就 go mod init；Python 直接写）
# 2) Dockerfile（必须）
# 3) 需要特殊构建时加 build.sh（可执行）
# 4) 部署清单（如需）<tool>.yaml，镜像处用 __IMAGE_TAG__ 占位
cd /home/fanyan/git_code/new-api-yxw
bash deploy/ops/push.sh -n dev --module ~/git_code/service_ops/my-tool
```

## 为什么要独立 go.mod

工具迁出主仓库后，`go build` 找不到原 module；`mock-upstream` 已有自己的 `go.mod`（module `mockupstream`）。
新增 Go 工具时同样需要 `go mod init <name>`，否则 `push.sh` 的自动构建会失败。

## 与主仓库的关系

- 主仓库只保留**调用方**：k6 压测脚本、`deploy/perf/perf_reports`、台账与文档；
- 工具的源码/构建/部署清单在 `service_ops`，主仓库文档用绝对路径 `~/git_code/service_ops/<tool>/` 引用；
- 镜像统一 `acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/<tool>:<tag>`，tag **禁止 latest**。
