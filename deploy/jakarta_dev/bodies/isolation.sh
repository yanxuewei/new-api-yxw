#!/bin/bash
# bodies/isolation.sh —— Phase 3 隔离验收 V1–V11（全程只读；不投递任何凭据；任何密钥值都不打印）
#
# 口径来源：用户红线「正式环境和开发/测试环境要彻底隔离，不能互通」+ 台账 §11.4（V1/V11 已在网络层做过一半）
#   + 指南「dev 复用马尼拉 EE 公网入口跨区拉」这条唯一许可通路（V5 专门反证它没有顺手打开生产内网面）。
# 执行位：dev 节点内 kubectl（15 分钟临时私网 kubeconfig，见 deploy/lib/ack_remote_jkt_dev.sh）。
# 网络探针统一在 **Pod 网络命名空间**里跑（节点侧 §11.4 已测过；Pod 走 terway ENI/IP，才是应用真实路径）。
set -uo pipefail
NS=newapi-dev
PROBE=t2d-netprobe
RDS_DEV_HOST=pgm-d9j9p421lzx4gw73.pgsql.ap-southeast-5.rds.aliyuncs.com
EE_VPC_HOST=acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com
EE_PUB_HOST=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com
trap 'kubectl -n $NS delete pod $PROBE --ignore-not-found --wait=false >/dev/null 2>&1; rm -rf "$T"' EXIT

echo "--- 探针 Pod（复用 smoke 同一镜像 postgres:17-alpine，节点侧已缓存；busybox 带 nc/nslookup）"
kubectl -n $NS delete pod $PROBE --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f - <<'PROBEY' 2>&1 | sed 's/^/  /'
apiVersion: v1
kind: Pod
metadata: { name: t2d-netprobe, namespace: newapi-dev }
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: net
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 420"]
      resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 128Mi } }
PROBEY
kubectl -n $NS wait --for=condition=Ready pod/$PROBE --timeout=180s >/dev/null 2>&1 || { echo "  [XX] 探针 Pod 未就绪"; exit 1; }
POD=$(kubectl -n $NS get pod -l app=new-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

np() {  # $1=host $2=port ⇒ OPEN / BLOCKED（含 DNS 解析失败）
  kubectl -n $NS exec $PROBE -- sh -c "timeout 6 nc -z -w4 $1 $2 2>/dev/null && echo OPEN || echo BLOCKED" 2>/dev/null | tail -1
}
dns() {  # $1=hostname ⇒ 解析到的 IP；解析不到印 NXDOMAIN
  # busybox nslookup 的头两条 Address 是 **DNS 服务器自身**（172.23.0.10:53），只有出现 Name: 行才是应答，
  # 所以必须先确认有 Name: 段，否则会把 CoreDNS 地址当成"解析成功"（2026-10-12 首跑就这么误判过）。
  OUT=$(kubectl -n $NS exec $PROBE -- sh -c "timeout 6 nslookup $1 2>&1" 2>/dev/null)
  if grep -q '^Name:' <<<"$OUT"; then
    awk '/^Address:/{a=$2} END{print a}' <<<"$OUT"
  else
    echo NXDOMAIN
  fi
}

echo
echo "=== V1 dev 出口 = 自己的 NAT EIP（Pod 侧与节点侧都要是 147.139.170.11，且不属于任何生产站点）"
echo "  Pod  侧出网 IP = $(kubectl -n $NS exec $PROBE -- sh -c 'timeout 8 wget -qO- https://api.ipify.org || timeout 8 wget -qO- http://ifconfig.me/ip' 2>/dev/null | tr -d '\r\n[:space:]')"
echo "  节点 侧出网 IP = $(curl -s --max-time 8 http://ifconfig.me/ip 2>/dev/null || echo '(节点无公网 curl 通路)')"

echo "=== V2 生产 RDS 公网端点从 Pod 内不可达（43.118.96.65:5432 ⇒ 期望 BLOCKED）"
echo "  43.118.96.65:5432 ⇒ $(np 43.118.96.65 5432)"

echo "=== V3 马尼拉生产 VPC 内网不可达（10.0.16.20:6443 与 10.0.0.1:443 ⇒ 期望 BLOCKED）"
for t in "10.0.16.20 6443" "10.0.0.1 443" "10.0.22.220 6443"; do echo "  $t ⇒ $(np $t)"; done

echo "=== V4 新加坡生产 API Server 内网不可达（10.1.19.73:6443 ⇒ 期望 BLOCKED）"
echo "  10.1.19.73:6443 ⇒ $(np 10.1.19.73 6443)"

echo "=== V5 生产 ACR EE 的 **内网域名** 不可达，公网域名可达（唯一被许可的跨区通路）"
echo "  -vpc 域名解析 = $(dns $EE_VPC_HOST)"
echo "  -vpc 域名 443 ⇒ $(np $EE_VPC_HOST 443)"
echo "  公网域名解析 = $(dns $EE_PUB_HOST)"
echo "  公网域名 443 ⇒ $(np $EE_PUB_HOST 443)"

echo "=== V6 dev RDS 只有 5432 通、6432 不通（清单偏差③的复核：无托管 PgBouncer）"
echo "  $RDS_DEV_HOST:5432 ⇒ $(np $RDS_DEV_HOST 5432)"
echo "  $RDS_DEV_HOST:6432 ⇒ $(np $RDS_DEV_HOST 6432)"

echo "--- V1–V6 采集结束（V7–V11 见 bodies/isolation_rbac.sh：云助手命令体上限拆分）"
