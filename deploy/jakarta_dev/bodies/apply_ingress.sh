#!/bin/bash
# bodies/apply_ingress.sh —— apply dev_ingress.yaml（AlbConfig/IngressClass/Service/Ingress）
# 载荷：INGRESS_B64 = deploy/jakarta_dev/dev_ingress.yaml 的单行 Base64（由 dev_deploy.sh --apply-ingress 打包）
# 开关：APPLY=0（默认，只 render 校验）/ 1 = 真 apply
set -e

[ -n "${INGRESS_B64:-}" ] || { echo '  [XX] 未传 INGRESS_B64 ⇒ 终止'; exit 2; }
printf '%s' "$INGRESS_B64" | base64 -d > /tmp/dev_ingress.yaml
echo "    dev_ingress.yaml $(wc -c < /tmp/dev_ingress.yaml) 字节落盘"

echo '--- 0) render 校验（kubectl --dry-run=client）'
kubectl apply --dry-run=client -f /tmp/dev_ingress.yaml 2>&1 | sed 's/^/    /'

if [ "${APPLY:-0}" != "1" ]; then
  echo '--- [计划模式] 未设 APPLY=1，到此为止'
  exit 0
fi

echo '--- 1) apply'
kubectl apply -f /tmp/dev_ingress.yaml 2>&1 | sed 's/^/    /'

echo '--- 2) 对象快照'
kubectl get albconfig 2>&1 | sed 's/^/    /' || true
kubectl get ingressclass 2>&1 | sed 's/^/    /' || true
kubectl -n newapi-dev get svc,ingress 2>&1 | sed 's/^/    /' || true

echo '--- 3) albconfig status（ALB 实例回填情况，开通需数分钟）'
kubectl get albconfig jkt-alb -o jsonpath='ALBID={.status.loadBalancer.id}{"\n"}DNS={.status.loadBalancer.dnsname}{"\n"}' 2>&1 | sed 's/^/    /' || true
