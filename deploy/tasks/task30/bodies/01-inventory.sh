#!/bin/bash
# 任务 30 · 步骤 1：集群清单探针（只读 kubectl，不打印任何凭据值）
set -uo pipefail

echo "== 节点 =="
hostname
ip -4 addr show 2>/dev/null | grep -oE 'inet 10\.[0-9.]+' | head -4

echo "== kubectl / API Server =="
kubectl version 2>&1 | head -3

echo "== Namespace =="
kubectl get ns 2>&1 | head -20

echo "== 工作负载（全集群）=="
kubectl get deploy,sts,ds,po -A 2>&1 | head -40

echo "== new-api 命名面资源 =="
kubectl -n new-api get deploy,cm,secret,sa,ing,pvc,job 2>&1 | head -40

echo "== Secret 的 key 名（只列名，绝不打印值）=="
for s in $(kubectl -n new-api get secret -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  keys=$(kubectl -n new-api get secret "$s" -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin).get("data",{}).keys()))' 2>/dev/null)
  echo "  $s -> $keys"
done

echo "== SQL_DSN 的非敏感骨架（host:port / sslmode；口令与库名一律不外显）=="
DSN=$(kubectl -n new-api get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$DSN" ]; then
  echo "  (无 new-api-secrets/SQL_DSN 或该集群未建)"
else
  echo "  hostport = $(printf '%s' "$DSN" | sed -E 's#.*@([^/?[:space:]]+).*#\1#')"
  echo "  sslmode  = $(printf '%s' "$DSN" | grep -oE 'sslmode=[A-Za-z0-9.-]+' | head -1)"
  echo "  port6432 = $(printf '%s' "$DSN" | grep -c ':6432')"
  echo "  ispublic = $(printf '%s' "$DSN" | grep -c 'pub\.pgsql')"
fi

echo "== ConfigMap 里的连接相关键（只列 key，值打码）=="
for c in $(kubectl -n new-api get cm -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "  cm/$c: $(kubectl -n new-api get cm "$c" -o jsonpath='{.data}' 2>/dev/null | tr -d '{}' | tr ',' '\n' | cut -d: -f1 | tr -d '"' | tr '\n' ' ' | cut -c1-300)"
done

echo "== 节点上是否已有 psql/pgbench =="
command -v psql pgbench || echo "  节点无 psql/pgbench（需走一次性 Pod）"
echo "DONE"
