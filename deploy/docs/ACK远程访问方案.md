# ACK 远程访问方案

> 编写日期：2026-10-18
> 适用集群：`ack-newapi-mnl`（马尼拉）、`ack-newapi-sg`（新加坡）
> 关联：任务 46（跳板机）、任务 19（ALB，`EXEC_MODE=ssh`）、`deploy/lib/ack_remote.sh`

---

## 1. 结论

本机 `kubectl` 无法直连 ACK，属**结构性限制**，不是配置问题：两个集群均未开启公网 endpoint，只暴露 VPC 私网 VIP，本机不在 VPC 内。

远程操作一律走 `deploy/lib/ack_remote.sh`（主用），或任务 46 跳板机 SSH。开公网 endpoint / 建隧道属写操作，须先授权。

---

## 2. 实测证据（2026-10-18）

| site | 集群 | intranet endpoint | 公网 endpoint | VPC |
|---|---|---|---|---|
| mnl | `ack-newapi-mnl` | `https://10.0.22.182:6443` | 空 | `vpc-5tst1tgeessxn1azwasg2` |
| sg | `ack-newapi-sg` | `https://10.1.19.73:6443` | 空 | `vpc-t4nimmwvruexbnene0a3r` |

本机缓存 kubeconfig 的 server 即上述 10.x 地址：`/tmp/ackctl-mnl/kubeconfig`、`/tmp/ackctl-sg/kubeconfig`。直接 `KUBECONFIG=<该文件> kubectl ...` 只会超时。

另注：`~/.kube/config` 里的 `kind-gitops-demo`（`https://127.0.0.1:62404`）是本地 kind 集群残留，Docker 未运行即报 `connection refused`，与 ACK 无关。排查时先确认 context，勿混淆。

---

## 3. 方案 A（主用）：`ack_remote.sh` + 云助手

### 3.1 链路

```
本机 aliyun CLI (profile default, AK)
  ├─ aliyun cs DescribeClusterUserKubeconfig --PrivateIpAddress true  → admin 私网 kubeconfig
  └─ aliyun ecs RunCommand → 节点内执行
        └─ 节点：写 /tmp/k8s/kubeconfig → kubectl 走 10.x VIP（节点在 VPC 内，通）
        └─ DescribeInvocationResults 轮询取 stdout
```

要点：kubectl 实际运行在 VPC 内的节点上，本机只负责下发 body 与回收输出。

### 3.2 用法

```bash
# 把命令写进 body
echo 'kubectl get pods -A' > /tmp/body.sh && bash deploy/lib/ack_remote.sh mnl /tmp/body.sh
```

完整一点：

```bash
cat > /tmp/body.sh <<'EOF'
kubectl get nodes -o wide
kubectl get pods -A | head -30
EOF

bash deploy/lib/ack_remote.sh mnl /tmp/body.sh
bash deploy/lib/ack_remote.sh sg  /tmp/body.sh
```

签名：

```
deploy/lib/ack_remote.sh <mnl|sg> <body.sh> [node_id] [loops]
```

- `loops`：轮询次数，每轮 5s，默认 24（=120s）
- 不指定 `node_id` 时取该集群第一台 worker
- body 内可直接用 `$KUBECONFIG` / `$K8S`（已 export）

### 3.3 环境与缓存

| 项 | 取值 |
|---|---|
| 区域/集群 | `mnl` → `ap-southeast-6` / `cd57e40ce9a634c1698c2f5c5e09bd93c`；`sg` → `ap-southeast-1` / `ca75829e3492d491d9d434de087913798` |
| kubeconfig 缓存 | `/tmp/ackctl-<site>/kubeconfig`，可用 `ACKCTL_DIR` 覆盖 |
| aliyun CLI | 自动补 `~/.workbuddy/binaries/aliyun-cli`（非交互 shell 不 source `.zshrc`） |
| 云助手超时 | `--Timeout 900` |
| 节点侧目录 | `/tmp/ackctl-<RUN_ID>`，退出即清理 |

### 3.4 已知坑（均为实测记录，勿踩）

1. **body 体积上限**：裸脚本 + kubeconfig 超限时 `RunCommand` 回 `403 CmdContent.ExceedLimit`（任务 18 的 22.7 KB 撞过）。脚本已改 gzip+b64 内嵌（约 30.3 KB → 11 KB），极端大 body 仍会命中。
2. **并发竞态**：`ACKCTL_DIR` 为固定路径时两会话互相覆盖 body，任务 23 的 `kubectl drain` 因此丢过 uncordon。现已按 `RUN_ID` 隔离执行期文件，但仍禁止两会话同时操作同一集群。
3. **空 InvokeId = 失败**：`aliyun` 出错返回合法 JSON `{"error_code":...}`，下游 `DescribeInvocationResults --InvokeId ''` 会取上一次结果，造成假成功（2026-10-05 实测）。脚本已拦截，见 `[!] 下发失败` 即视为失败。
4. **编码差异**：macOS/BSD `base64` 无 `-w0`，脚本统一走 python3 编码，勿改回 shell base64。

---

## 4. 方案 B：跳板机（任务 46）

`deploy/tasks/task46/jumphost.sh` 创建 `newapi-ops-mnl`。

- 跳板机绑定 RAM 角色 `new-api-ops-jumphost`，**不落长期凭据**；机上 `/usr/local/bin/newapi-kube` 按需换取 60 min 临时 kubeconfig
- 默认**零入向**（`ENABLE_SSH_ALLOWLIST=0`）。需 SSH 时以 `OFFICE_CIDR=<出口IP>/32` 建白名单（写操作，需授权）
- 两条通道：① 人工运维 `办公出口 IP → SSH(22) → 跳板机 → kubectl`（可开 `ENABLE_RECORDING=1` 会话录制投递 OSS）；② 自动化：云助手在跳板机执行，ActionTrail 留痕
- 任务 19 的 `deploy/tasks/task19/alb_mnl.sh` 默认 `EXEC_MODE=ssh` 即走此路

适用：需要连续交互、多条命令的场景。一次性取证仍用方案 A。

---

## 5. 方案 C：本机直连（当前不可用，需授权）

三种做法，任一都需先取得授权（云写 / 安全面变更）：

1. **开公网端点**：`ModifyCluster --api_server_public_eip=true` + ACL 白名单。代价：新增公网攻击面、额外费用。此前未采用。
2. **SSH 隧道（不开公网端点，推荐）**：

```bash
ssh -i <key> -N -L 6443:10.0.22.182:6443 root@<跳板机公网IP>
# 另一窗口：kubeconfig 的 server 改为 https://127.0.0.1:6443
KUBECONFIG=~/.kube/ack-mnl.yaml kubectl get pods -A
```

前提：跳板机有 SSH 白名单放行本机出口 IP。

3. **VPN / 专线进 VPC**：成本最高，仅长期运维场景考虑。

---

## 6. 操作口径

1. 本机 `kubectl` 的 context 与 ACK 无关，误用会浪费排查时间；操作 ACK 时不要依赖 `~/.kube/config`。
2. ACK 读操作统一 `deploy/lib/ack_remote.sh <site> <body.sh>`。
3. 云写（创建/修改/删除、改白名单、scale、轮换、开公网端点）须先向项目负责人说明并取得授权。
4. 证据落盘：`deploy/logs/<任务>_<时间戳>/`，输出先剥离密码/私钥字段。
5. 关联/开关类状态一律用查询 API 断言，不依赖文档或控制台元数据自证。
