# newapi.token.yanxuewei.xyz 打开即 500 —— 坏 chunk 事故复盘

- 日期：2026-11-01
- 主机：`yxl-hsvr0`（宝塔 nginx + Docker 部署 `new-api`，上游 `127.0.0.1:3000`）
- 现象：`https://newapi.token.yanxuewei.xyz/` 与 `/sign-in?redirect=%2Fplayground` 渲染大号 **500** 页（「糟糕！出错了 :')」），而后端 `docker logs` 与 nginx access log 全为 200
- 结论：**不是镜像问题，也不是 nginx 问题**；是 10-31 一次手工热替换的二进制里夹带了一个被 nginx 503 错误页覆盖的前端 chunk

---

## 1. 现象与初始误判

- 页面显示 `GeneralError` 组件（`web/src/features/errors/general-error.tsx`），其状态码取 `error.response.status`，取不到时回落 `500`。
- 说明这是**前端路由级异常**，不是 HTTP 500：真正抛出的是 `ChunkLoadError`，无 `response`，因此渲染成 500。
- 后端与 nginx 侧全部 200，`/api/setup`、`/api/status` 正常。

## 2. 根因

### 2.1 容器里跑的二进制被热替换过

| 项 | 镜像原二进制 | 10-31 热替换版本 |
|---|---|---|
| 版本头 `X-New-Api-Version` | `dev-20261030-183836-6970657` | `dev-20261031-fixvideo` |
| md5 | `40cca4e7497f631a58d100da942425e9` | `90a74b55…` |
| Go 版本 / 构建 | Dockerfile 构建（bun 产出 dist） | `go1.26.0`、`-trimpath=true` |
| build info | — | `vcs.revision=29ee5c3d…`、`vcs.modified=true`、`vcs.time=2026-10-31T05:16:47Z`（北京时间 13:16） |
| 位置 | 容器 `/new-api` | `/tmp/new-api-linux-amd64`，备份 `/tmp/new-api-hotpatch-20261031.bak` |

时间线：

- 10-31 11:52　容器从镜像 `dev-20261030-183836-6970657` 创建
- 10-31 12:46　执行 `/tmp/fix_video_inline.sh`（nginx 侧：CSP 补 `media-src`、站点加 `/v1/(tasks|videos)/content` 隐藏 `Content-Disposition` 的 location）
- 10-31 13:16　本地仓库（commit `29ee5c3`，工作区有未提交改动）`go build` 出 `dev-20261031-fixvideo`
- 10-31 13:38　`docker cp` 覆盖容器 `/new-api` 并重启
- 11-01 15:0x　恢复镜像原生二进制

### 2.2 热替换版本嵌入了错误的 chunk

该二进制把构建机上的 `web/dist` 整个 `go:embed` 进去，其中：

```
web/dist/static/js/async/2860.61ebb578d1.js   ← 实际内容是 nginx 503 页面
```

内容为 190 字节、CRLF 换行：

```html
<html>
<head><title>503 Service Temporarily Unavailable</title></head>
<body>
<center><h1>503 Service Temporarily Unavailable</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

取证结果：

- 该二进制共嵌入 **1629** 个 async chunk，全盘只有 **1** 个 HTML 错误页（即 2860），其余正常
- 同一文件名在镜像二进制里是 **14975 字节**的正确 JS，md5 `af1f0afe797aa6646febc52fb30bae59`
- 文件名哈希 `61ebb578d1` 与正确内容一致 ⇒ **文件是构建完成后、打包前被一次 HTTP 503 的响应体覆盖的**（典型场景：从远端/代理「补」静态资源，或构建脚本下载资源时远端返回 503，错误页被当成文件写盘），不是编译参数或镜像缺陷

### 2.3 为什么只有登录页炸

`/sign-in`（以及 `?redirect=%2Fplayground`）按需加载的正是 `2860` 这个 chunk：

```
browser → 请求 2860.61ebb578d1.js → 收到 HTML（190B）
        → Uncaught SyntaxError: Unexpected token '<'
        → ChunkLoadError: Loading chunk 2860 failed
        → TanStack Router errorComponent → GeneralError → 显示 500
```

其余 chunk 正常，所以首页壳、其他资源都 200，问题只在这一条路由上暴露。

### 2.4 为什么替换前的验证没拦住

替换前用 `/tmp/verify_bin.sh` 起了临时容器（3001）抽查静态资源，清单是：

```
/  /favicon.ico  /static/css/index.8770d25a3f.css
/static/js/index.df73f9efa6.js  /static/js/async/67152.78da8a68b0.js
```

全部 200 ⇒ 判定通过。但**真正被按需加载的 2860 不在清单里**，所以坏文件漏检。

### 2.5 一次误判：并不存在「nginx 层 404」

排查中出现过 `via https nginx → 404 / 2236 字节"页面找不到了"` 的结论，系测试方法错误：

- `curl -k https://127.0.0.1/...` 用 IP 直连 443 时**没有 SNI**，命中 stream 层的 `default → 127.0.0.1:50443`（xray），返回的是 xray 的 404 页
- 带正确 SNI（`--resolve newapi.token.yanxuewei.xyz:443:127.0.0.1`）或直连 `127.0.0.1:51443` 时，chunk 返回 200 / 14975

xray 的 404 页字样可作为识别特征：`404 – 页面找不到了`（2236 字节）。

---

## 3. 修复动作

1. 从 ACR 镜像取出原生二进制：

```bash
IMG=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-dev/newapi-master:dev-20261030-183836-6970657
docker create --name imgx "$IMG" >/dev/null
docker cp imgx:/new-api /tmp/img-new-api2
docker rm -f imgx
```

2. 覆盖回容器并重启（**原热替换文件仍留在 `/tmp/new-api-hotpatch-20261031.bak`**）：

```bash
docker cp /tmp/img-new-api2 new-api:/new-api
docker exec new-api chmod 755 /new-api
docker restart new-api
```

3. 恢复后状态：

```
容器状态      running
镜像          ...newapi-dev/newapi-master:dev-20261030-183836-6970657
版本头        x-new-api-version: dev-20261030-183836-6970657
chunk 2860    /static/js/async/2860.61ebb578d1.js → 200 / 14975 / md5 af1f0afe…
```

## 4. 验证结果

服务端（带 SNI 的公网路径）：

| 路径 | 状态 |
|---|---|
| `/` | 200 |
| `/playground` | 200 |
| `/sign-in` | 200 |
| `newapi.token.yanxuewei.xyz` 与 `token.yanxuewei.xyz` | 均 200 |

浏览器（禁用缓存的全新 profile，headless Chrome）：

- `/sign-in?redirect=%2Fplayground` 正常渲染「登录 / 注册」表单
- `2860.61ebb578d1.js` 加载 200
- Console 仅一条 401：未登录时 `POST /api/user/auth/refresh`，属预期

## 5. 残留影响：浏览器缓存

故障窗口内访问过的浏览器会缓存那份 190 字节假 chunk。原因是：

- 假文件当时是以 **200** 返回的，响应带 `middleware.Cache()` 设置的 `Cache-Control: max-age=604800`
- 修复后文件名哈希没有改变 ⇒ 浏览器 7 天内不会重新请求

识别方法（access log 中**没有** 2860 的请求即为命中本地缓存）：

```
15:36:40  GET /sign-in                          200
15:36:40  GET /static/js/index.df73f9efa6.js    200
15:36:42  POST /api/user/auth/refresh           401
          ← 全程无 GET /static/js/async/2860.*
```

清理方式（任选其一）：

1. `F12` → Network 勾选 **Disable cache** → `Ctrl+Shift+R`
2. `F12` → Application → Storage → **Clear site data**
3. `Ctrl+Shift+Delete` → 时间范围「时间不限」→ 只勾「缓存的图片和文件」
4. 无痕窗口验证

清理后日志应出现 `GET /static/js/async/2860.61ebb578d1.js 200 5085`（gzip 后），页面恢复。

## 6. 改进建议

1. **热更新必须走镜像构建**：禁止 `docker cp` 覆盖镜像内二进制；确需紧急热更时，产物必须来自可复现的 CI/镜像构建。
2. **构建前做 dist 完整性校验**：遍历 `web/dist/static/**/*.js`，任何一个文件首字节为 `<`（或以 `<!DOCTYPE`/`<html` 开头）直接失败，杜绝把 HTTP 错误页打进二进制。
3. **替换前验证要覆盖按需 chunk**：至少覆盖目标路由实际加载的 chunk（可从构建产物 manifest 或 `index.html` 引用枚举），不能只抽查首页几个路径。
4. **`X-New-Api-Version` 作为部署核对项**：热更前后各取一次响应头，确认版本符合预期。
5. （可选）静态资源缓存改为「哈希文件名 + 长缓存」并在 index.html 上保持 `no-cache`；本次事故的放大因素正是「文件名哈希未变 + 7 天强缓存」。

## 7. 关键文件与命令索引

| 用途 | 位置 |
|---|---|
| 镜像原生二进制（恢复用） | `/tmp/img-new-api2` |
| 10-31 热替换二进制（证据保留） | `/tmp/new-api-linux-amd64`、`/tmp/new-api-hotpatch-20261031.bak` |
| 当时的 nginx 修复脚本 | `/tmp/fix_video_inline.sh` |
| 当时的替换前验证脚本 | `/tmp/verify_bin.sh`（抽查清单有缺口） |
| 站点 vhost | `/www/server/panel/vhost/nginx/token.yanxuewei.xyz.conf` |
| stream（SNI 分流） | `/www/server/panel/vhost/nginx/stream-conf.d/*.conf` |
| access log | `/www/wwwlogs/token.yanxuewei.xyz.log` |
| 缓存中间件 | `middleware/cache.go` |
| 错误边界组件 | `web/src/features/errors/general-error.tsx` |
