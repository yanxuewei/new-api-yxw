#!/bin/bash
# deploy/ops/bodies/ensure_jq.sh —— 幂等给节点装 jq（ACK 节点内执行）
#
# 用法：
#   bash deploy/lib/ack_remote_jkt_dev.sh deploy/ops/bodies/ensure_jq.sh          # jkt dev（自动选一台）
#   bash deploy/lib/ack_remote_jkt_dev.sh deploy/ops/bodies/ensure_jq.sh i-xxxx   # 指定实例，逐台跑
#   bash deploy/lib/ack_remote.sh mnl deploy/ops/bodies/ensure_jq.sh              # 生产集群（慎用）
#
# 背景（2026-11-01 实测）：
#   - 节点 OS = Alibaba Cloud Linux 3.2104 U13.3，包在 alinux3-updates（jq 1.6-19.al8.0.2，+oniguruma 依赖，共 361KB）。
#   - 节点能出网（mirrors.aliyun.com / www.aliyun.com 均可达），dnf 可直接装。
#   - 节点自带 python3（无 jq 时可作 JSON 处理兜底）。
#
# ⚠ 这不是持久化安装：节点池扩容 / 节点升级 / 换盘 / 替换实例产生的新节点都没有 jq。
#   因此 **节点侧 body 仍须零依赖**（优先 kubectl -o custom-columns / jsonpath / go-template / awk），
#   jq 只当"有则更好"的加速项。要持久化请用节点池「实例自定义数据」（只对新节点生效）。
set -uo pipefail

echo "node=$(hostname) ip=$(hostname -I | awk '{print $1}')"

if command -v jq >/dev/null 2>&1; then
  echo "SKIP：jq 已存在 $(jq --version) @ $(command -v jq)"
  exit 0
fi

# 先解算再安装：仓库不通时给出明确原因，而不是留个半装状态
if ! timeout 60 dnf -q makecache >/dev/null 2>&1; then
  echo "WARN：dnf makecache 失败，尝试直接安装（可能用的是本地缓存元数据）"
fi

timeout 120 dnf -y -q install jq 2>&1 | tail -4

if command -v jq >/dev/null 2>&1; then
  echo "OK：$(jq --version) @ $(command -v jq)"
  rpm -q jq oniguruma 2>/dev/null
else
  echo "FAIL：安装后仍无 jq（检查 alinux3-updates 仓库与出网）"
  exit 1
fi
