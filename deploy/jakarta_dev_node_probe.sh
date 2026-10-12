#!/usr/bin/env bash
# 在雅加达 dev ACK 节点内执行的零凭据探针（经 ECS 云助手下发，脚本本体不含任何凭据）
# 用途：2d 部署前确认「节点 → dev RDS / 马尼拉 EE 公网入口」通路，并回归隔离不变量
# 执行位：aliyun ecs RunCommand --RegionId ap-southeast-5 --Type RunShellScript --ContentEncoding Base64
set +e
RDS_HOST=pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com
EE_HOST=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
PROD_RDS=43.118.96.65

echo "### node=$(hostname) kernel=$(uname -r)"
echo "### date_utc=$(date -u +%FT%TZ)"

tcp() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2" && echo "OPEN" || echo "BLOCKED/FAIL(rc=$?)"; }

echo
echo "===== A. dev RDS 端点（数据面）====="
echo "RDS DNS            = $(getent hosts $RDS_HOST | awk '{print $1}' | head -1)"
echo "RDS 5432 (直连)    = $(tcp $RDS_HOST 5432)"
echo "RDS 6432 (托管池)  = $(tcp $RDS_HOST 6432)"
echo "PROD RDS $PROD_RDS:5432 = $(tcp $PROD_RDS 5432)   # 期望 BLOCKED（隔离不变量）"

echo
echo "===== B. dev RDS TLS ====="
if command -v openssl >/dev/null; then
  for v in -tls1_1 -tls1_2; do
    printf '%s ' "openssl $v:"
    echo | timeout 8 openssl s_client -connect $RDS_HOST:5432 $v 2>&1 \
      | grep -E "Protocol|Cipher|verify error|alert|connect/errno" | head -2 | tr '\n' ' '
    echo
  done
else
  echo "openssl 不在节点上"
fi

echo
echo "===== C. 镜像源（马尼拉 EE 公网入口，跨区拉取）====="
echo "EE DNS             = $(getent hosts $EE_HOST | awk '{print $1}' | head -1)"
echo "EE /v2/ HTTP       = $(timeout 12 curl -s -o /dev/null -w '%{http_code}' https://$EE_HOST/v2/)"
echo "  （401/200 = 网络与 TLS 通；401 属未带凭据的正常响应）"
echo "dev 镜像清单可达性  = $(timeout 12 curl -s -o /dev/null -w '%{http_code}' https://$EE_HOST/v2/newapi-dev/newapi-master/manifests/latest)"
echo "出网公网 IP        = $(timeout 10 curl -s https://ifconfig.me || echo FAIL)"

echo
echo "===== D. 节点上已有的 k8s 访问面 ====="
echo "kubectl 路径       = $(command -v kubectl || echo 无)"
echo "/etc/kubernetes    = $(ls /etc/kubernetes 2>/dev/null | tr '\n' ' ')"
echo "kubeconfig 环境变量= ${KUBECONFIG:-未设置}"
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "kubelet.conf 权限测试（期望 Forbidden，不得当作运维入口）:"
  timeout 15 kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get namespaces 2>&1 | head -2
fi

echo
echo "===== E. 当前已跑的容器（crictl，零凭据）====="
timeout 20 crictl pods 2>/dev/null | awk 'NR==1||$0!~/^$/{print}' | head -25
echo "sandbox 计数 = $(timeout 20 crictl pods -q 2>/dev/null | wc -l)"

echo
echo "===== F. 系统盘 / DNS ====="
df -h / /var/lib/containerd 2>/dev/null | tail -2
echo "resolv.conf = $(grep -E '^nameserver' /etc/resolv.conf | tr '\n' ' ')"
echo "### END"
