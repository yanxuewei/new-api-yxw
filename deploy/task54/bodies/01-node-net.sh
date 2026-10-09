#!/bin/bash
# 任务54 侦察①：节点出网能力 + 工具存在性 + 集群 Secret 键名（不打印值）
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}

echo "### 0) 身份与 kubeconfig"
hostname; ls -la "$KUBECONFIG" 2>&1 | head -1

echo "### 1) 节点出网（GitHub / dl.k8s.io / docker hub / ACR）"
for u in "https://github.com" \
         "https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz" \
         "https://dl.k8s.io/release/v1.35.7/bin/linux/amd64/kubectl" \
         "https://registry-1.docker.io/v2/" \
         "https://cri-avfqy9xkqi5bj8ee-registry-vpc.ap-southeast-6.cr.aliyuncs.com/v2/"; do
  printf '%-95s ' "$u"
  timeout 20 curl -sI -o /dev/null -w 'http=%{http_code} t=%{time_total}s\n' "$u" 2>&1 || echo "FAIL"
done

echo "### 2) 工具存在性"
for b in curl tar gunzip gzip psql crictl jq python3 openssl; do
  printf '%-10s %s\n' "$b" "$(command -v $b 2>/dev/null || echo MISSING)"
done

echo "### 3) 集群 Secret 键名（只看键，不看值）"
kubectl -n new-api get secret new-api-secrets -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>&1; echo
kubectl -n new-api get cm new-api-config -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>&1; echo

echo "### 4) 命名空间与 master Pod"
kubectl get ns 2>&1 | head -12
kubectl -n new-api get pods -o wide 2>&1 | head -6

echo "### 5) RDS 内网 5432 连通（不连库，仅 TCP）"
for h in "pgm-5tstdhko64x2c01w.pg.rds.aliyuncs.com" "10.0.69.77"; do
  printf '%-45s ' "$h"
  timeout 5 bash -c "exec 3<>/dev/tcp/$h/5432" 2>/dev/null && echo "TCP OK" || echo "TCP FAIL"
done

echo "BODY DONE"
