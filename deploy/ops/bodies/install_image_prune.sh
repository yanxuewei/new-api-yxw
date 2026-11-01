#!/bin/bash
# deploy/ops/bodies/install_image_prune.sh —— 幂等安装「节点镜像定期清理」定时任务
#
# 目的：dev 节点系统盘长期被容器镜像累积占用（kubelet 只在用量 >85% 才自动 GC），
#       这里每天在低峰清一次「未被任何容器引用」的镜像。
#
# 用法：
#   bash deploy/lib/ack_remote_jkt_dev.sh deploy/ops/bodies/install_image_prune.sh              # jkt dev，逐台跑
#   bash deploy/lib/ack_remote_jkt_dev.sh deploy/ops/bodies/install_image_prune.sh i-xxxx
#   bash deploy/lib/ack_remote.sh mnl deploy/ops/bodies/install_image_prune.sh                   # 生产（慎用）
#
# 落地物：
#   /usr/local/sbin/newapi-image-prune.sh        清理脚本（带日志与自轮转）
#   /etc/cron.d/newapi-image-prune               每日 UTC 20:00（= CST 04:00）执行
#   /var/log/newapi-image-prune.log              每次一行：镜像数变化 + 根分区使用率变化
#
# ⚠ 与 jq 同样的问题：**节点被替换/升级后新节点没有这个 cron**。需要持久化时把本脚本的
#   落盘部分抄进节点池「实例自定义数据」（只对新节点生效）。
set -uo pipefail

echo "node=$(hostname)"

echo "--- 0) 前置检查"
if ! command -v crictl >/dev/null 2>&1; then
  echo "FAIL：节点上没有 crictl"
  exit 1
fi
echo "crictl=$(command -v crictl) $(crictl --version 2>/dev/null)"
if ! systemctl is-active crond >/dev/null 2>&1; then
  echo "crond 未运行 ⇒ 启用"
  systemctl enable --now crond 2>&1 | tail -2
fi
echo "crond=$(systemctl is-active crond) / $(systemctl is-enabled crond 2>/dev/null)"
echo "tz=$(date +%Z) now=$(date -Is)"

echo "--- 1) 写清理脚本"
cat > /usr/local/sbin/newapi-image-prune.sh <<'EOS'
#!/bin/bash
set -uo pipefail
LOG=/var/log/newapi-image-prune.log
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 10485760 ]; then
  tail -c 1000000 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
fi
img_before=$(crictl images -q 2>/dev/null | wc -l)
pct_before=$(df --output=pcent / | tail -1 | tr -dc '0-9')
crictl rmi --prune >/dev/null 2>&1
img_after=$(crictl images -q 2>/dev/null | wc -l)
pct_after=$(df --output=pcent / | tail -1 | tr -dc '0-9')
echo "$(date -Is) images ${img_before}->${img_after} root_used ${pct_before}%->${pct_after}%" >> "$LOG"
EOS
chmod 755 /usr/local/sbin/newapi-image-prune.sh

echo "--- 2) 写 cron 条目"
cat > /etc/cron.d/newapi-image-prune <<'EOC'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# UTC 20:00 = CST 04:00，每日清理未被任何容器引用的镜像
0 20 * * * root /usr/local/sbin/newapi-image-prune.sh
EOC
chmod 644 /etc/cron.d/newapi-image-prune

echo "--- 3) 立即执行一次（验证链路）"
/usr/local/sbin/newapi-image-prune.sh
tail -2 /var/log/newapi-image-prune.log 2>/dev/null

echo "--- 4) 结果"
echo "images_now=$(crictl images -q 2>/dev/null | wc -l)  root=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
ls -l /etc/cron.d/newapi-image-prune /usr/local/sbin/newapi-image-prune.sh 2>&1
