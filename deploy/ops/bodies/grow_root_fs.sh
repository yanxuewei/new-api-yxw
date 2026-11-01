#!/bin/bash
# 云盘扩容后的"盘内"扩展：分区 + 文件系统（幂等，已扩过会提示 NOCHANGE 并跳过）
set -uo pipefail
echo "node=$(hostname)"

echo "--- 1) 块设备现状"
lsblk -b -o NAME,SIZE,TYPE,MOUNTPOINT /dev/nvme0n1 2>/dev/null || lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

echo "--- 2) 根文件系统类型"
root_src=$(findmnt -n -o SOURCE /)
root_fstype=$(findmnt -n -o FSTYPE /)
echo "src=$root_src fstype=$root_fstype"

echo "--- 3) growpart 是否可用"
if ! command -v growpart >/dev/null 2>&1; then
  echo "growpart 缺失，安装 cloud-utils-growpart"
  timeout 120 dnf -y -q install cloud-utils-growpart 2>&1 | tail -3
fi

echo "--- 4) 扩分区（NOCHANGE 视为已扩）"
disk=$(echo "$root_src" | sed -E 's/p?[0-9]+$//')
partnum=$(echo "$root_src" | grep -oE '[0-9]+$')
echo "disk=$disk partnum=$partnum"
out=$(growpart "$disk" "$partnum" 2>&1); rc=$?
echo "$out  (rc=$rc)"

echo "--- 5) 扩文件系统"
case "$root_fstype" in
  xfs)      xfs_growfs / 2>&1 | tail -4 ;;
  ext4|ext3) resize2fs "$root_src" 2>&1 | tail -4 ;;
  *)        echo "未识别的文件系统 $root_fstype，跳过" ;;
esac

echo "--- 6) 结果"
df -hT / | sed 's/  */ /g'
