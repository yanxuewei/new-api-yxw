#!/bin/bash
# =============================================================================
# new-api 节点 nofile 调优（任务 11 Step 3）
#   马尼拉 / 新加坡 节点池共用同一份，禁止手工点两遍（同一内容会被 base64 塞进
#   CreateClusterNodePool 的 kubernetes_config.user_data）
#
#   为什么三处都要设：
#     - /etc/security/limits.d/* 只对「登录会话」生效，对 systemd 服务无效
#     - Pod 的 ulimit 由 containerd 派生 → 必须改 systemd 的 DefaultLimitNOFILE
#       以及 containerd.service / kubelet.service 的 LimitNOFILE
#   执行时点：ACK 在节点初始化脚本之后执行 user_data，可直接覆盖
# =============================================================================
set -euo pipefail

LOG=/var/log/newapi-node-init.log
exec >>"$LOG" 2>&1
echo "===== newapi node init $(date '+%F %T') ====="

# ---- 1. systemd 全局默认 ------------------------------------------------
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-newapi-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=200000
EOF

# ---- 2. 登录会话（堡垒机/ssh 进去时也一致） ------------------------------
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-newapi.conf <<'EOF'
* soft nofile 200000
* hard nofile 200000
root soft nofile 200000
root hard nofile 200000
EOF

# ---- 3. kubelet / containerd 两个 unit ----------------------------------
mkdir -p /etc/systemd/system/kubelet.service.d /etc/systemd/system/containerd.service.d
cat > /etc/systemd/system/kubelet.service.d/10-newapi-limits.conf <<'EOF'
[Service]
LimitNOFILE=200000
EOF
cat > /etc/systemd/system/containerd.service.d/99-newapi-limits.conf <<'EOF'
[Service]
LimitNOFILE=200000
EOF

# ---- 4. 内核参数 --------------------------------------------------------
cat > /etc/sysctl.d/99-newapi.conf <<'EOF'
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 32768
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl -p /etc/sysctl.d/99-newapi.conf >/dev/null

# ---- 5. 生效 -----------------------------------------------------------
systemctl daemon-reload
# limits.d 不影响「已运行」的 containerd。
# 它可能在节点初始化阶段尚未启动（那样启动时会自带 drop-in），故仅在运行中才重启。
if systemctl is-active --quiet containerd; then
  systemctl restart containerd
  echo "containerd restarted"
else
  echo "containerd not active yet; drop-in will apply on first start"
fi

echo "DefaultLimitNOFILE=$(systemctl show -p DefaultLimitNOFILE --value)"
echo "containerd LimitNOFILE=$(systemctl show -p LimitNOFILE --value containerd)"
echo "===== done $(date '+%F %T') ====="
