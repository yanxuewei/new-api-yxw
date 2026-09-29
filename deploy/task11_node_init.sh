#!/bin/bash
# =============================================================================
# 任务 11 Step 3 —— ACK 节点初始化（user_data）
# 依据：deploy/阿里云国际站菲律宾部署_详细操作指南-v2.0.md
#
# 作用（三段，全部幂等）：
#   1) nofile=200000：systemd Manager + kubelet/containerd drop-in + limits.d 三处
#      —— 节点 `ulimit -n` 对容器不生效，容器继承 containerd/kubelet，故必须改 unit
#   2) sysctl：ip_local_port_range / somaxconn / tcp_tw_reuse
#   3) 数据盘（≥200 GiB，cloud_essd PL1 300G）格式化并挂到 /var/lib/containerd
#      —— 步骤 4 的兜底；若节点池 disk_init 已挂载则自动跳过（mountpoint 检测）
#
# 执行时机：ACK 节点初始化脚本之后执行，可覆盖系统默认 ulimit
# 日志：/var/log/cloud-init-output.log（cloud-init 直采）
# =============================================================================
set -euo pipefail

NOFILE_LIMIT=200000
TARGET=/var/lib/containerd
DISK_MIN_BYTES=$((200 * 1024 * 1024 * 1024))   # 只认 ≥200GiB 的数据盘（系统盘 100G）

echo "[newapi-init] start $(date -Is) host=$(hostname)"

# -----------------------------------------------------------------------------
# 1. nofile=200000（三处都要设）
# -----------------------------------------------------------------------------
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-newapi-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=200000
EOF

cat > /etc/security/limits.d/99-newapi.conf <<'EOF'
* soft nofile 200000
* hard nofile 200000
root soft nofile 200000
root hard nofile 200000
EOF

mkdir -p /etc/systemd/system/kubelet.service.d /etc/systemd/system/containerd.service.d
printf '[Service]\nLimitNOFILE=%s\n' "$NOFILE_LIMIT" > /etc/systemd/system/kubelet.service.d/10-newapi-limits.conf
printf '[Service]\nLimitNOFILE=%s\n' "$NOFILE_LIMIT" > /etc/systemd/system/containerd.service.d/10-newapi-limits.conf

# -----------------------------------------------------------------------------
# 2. sysctl
# -----------------------------------------------------------------------------
cat > /etc/sysctl.d/99-newapi.conf <<'EOF'
net.ipv4.ip_local_port_range = 10240 65535
net.core.somaxconn = 32768
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl -p /etc/sysctl.d/99-newapi.conf >/dev/null 2>&1 || echo "[newapi-init] WARN sysctl -p failed"

# -----------------------------------------------------------------------------
# 3. 数据盘 → /var/lib/containerd（幂等兜底）
# -----------------------------------------------------------------------------
if mountpoint -q "$TARGET"; then
  echo "[newapi-init] $TARGET already a mountpoint, skip disk init"
else
  ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
  ROOT_DISK=""
  if [ -n "$ROOT_SRC" ]; then
    PK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)
    [ -n "$PK" ] && ROOT_DISK="/dev/$PK"
  fi

  DATA_DISK=""
  for dev in $(lsblk -dpno NAME 2>/dev/null); do
    [ -n "$ROOT_DISK" ] && [ "$dev" = "$ROOT_DISK" ] && continue
    sz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
    [ "$sz" -ge "$DISK_MIN_BYTES" ] || continue
    # 必须全新：无文件系统、无分区子设备、未挂载
    [ -z "$(lsblk -no FSTYPE "$dev" 2>/dev/null | tr -d ' \n')" ] || continue
    [ -z "$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | tr -d ' \n')" ] || continue
    DATA_DISK="$dev"
    break
  done

  if [ -n "$DATA_DISK" ]; then
    echo "[newapi-init] format+attach $DATA_DISK -> $TARGET"
    systemctl stop containerd 2>/dev/null || true
    mkfs.ext4 -F -L containerd "$DATA_DISK"
    if ! grep -q 'LABEL=containerd' /etc/fstab; then
      printf 'LABEL=containerd %s ext4 defaults,noatime 0 2\n' "$TARGET" >> /etc/fstab
    fi
    mkdir -p "$TARGET"
    mount "$TARGET" || mount -a
    systemctl start containerd 2>/dev/null || true
  else
    echo "[newapi-init] WARN no spare data disk found (>=200GiB, blank) - $TARGET stays on system disk"
  fi
fi

# -----------------------------------------------------------------------------
# 4. 生效（drop-in 改动后必须 daemon-reload + 重启两进程）
# -----------------------------------------------------------------------------
systemctl daemon-reload
systemctl restart containerd 2>/dev/null || true
systemctl restart kubelet 2>/dev/null || true

echo "[newapi-init] done $(date -Is) ulimit_n=$(ulimit -n)"
