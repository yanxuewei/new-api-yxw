#!/bin/bash
# bodies/inspect_dev_baseline.sh —— pre 部署前的现网基线只读取证（dev 指纹 + CM/Secret 键面 + 节点形态）
# 为什么要这一步：① 卡片硬门禁要求"改 dev 之外的东西前先取 dev 的 Pod 身份指纹"；
#   ② pre 的清单要与 dev 同构，必须先看清 dev 现在**实际**跑的是什么（CM 键、镜像 tag、是否已挂 Redis），
#      不能照仓库里的 yaml 猜——现网已被人工改过（§16 的模板哈希与本次读数就已不同）。
set -uo pipefail
echo "=== D1 节点形态（实例类型 / taint / 状态）"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  type="}{.metadata.labels.node\.alibabacloud\.instance-type}{"  zone="}{.metadata.labels.topology\.kubernetes\.io/zone}{"  taints="}{.spec.taints}{"  ready="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>&1 | sed 's/^/  /'

echo "=== D2 dev 身份指纹（名字|模板哈希|重启数|镜像 tag）"
kubectl -n newapi-dev get pod -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.pod-template-hash}{"|"}{range .status.containerStatuses[*]}{.restartCount}{end}{"|"}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/  /'
kubectl -n newapi-dev get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.readyReplicas}/{.spec.replicas}{"  image="}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/  /'

echo "=== D3 dev CM 实际键（值一律不打印：dev 现网可能已被人工挂上 Redis/DSN，键名才是本次要的信息服务）"
kubectl -n newapi-dev get cm new-api-config -o go-template='{{range $k, $v := .data}}    {{$k}} valuelen={{len $v}}{{"\n"}}{{end}}' 2>&1 | sort | sed 's/^/  /'
kubectl -n newapi-dev get cm new-api-config -o jsonpath='{.data}' 2>&1 \
  | tr ',' '\n' | grep -oE '"[A-Z_]+":' | tr -d '":' | sort > "$T/cmkeys"
printf '    非敏感键的实际值：'
for k in NODE_TYPE SYNC_FREQUENCY SQL_MAX_OPEN_CONNS SQL_MAX_IDLE_CONNS MEMORY_CACHE_ENABLED TZ SQL_SLOW_THRESHOLD_MS GOMAXPROCS; do
  v=$(kubectl -n newapi-dev get cm new-api-config -o jsonpath="{.data.$k}" 2>/dev/null)
  [ -n "$v" ] && printf '%s=%s ' "$k" "$v"
done
echo

echo "=== D4 dev Secret 键面（只有键名与 base64 长度）"
kubectl -n newapi-dev get secret new-api-secrets -o go-template='{{range $k, $v := .data}}    {{$k}} b64len={{len $v}}{{"\n"}}{{end}}' 2>&1 | sed 's/^/  /'

echo "=== D5 dev Deployment 的 env / envFrom 接线（pre 要同构就得先看清）"
kubectl -n newapi-dev get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n    envFrom="}{.spec.template.spec.containers[0].envFrom}{"\n    env="}{.spec.template.spec.containers[0].env}{"\n  "}{end}' 2>&1 | cut -c1-700 | sed 's/^/  /'

echo "=== D6 pre / perf ns 现状（底座应已有 ns+quota+SA+ACR 聚合 Secret）"
for n in new-api-pre new-api-perf; do
  printf '  --- %s\n' "$n"
  kubectl -n "$n" get quota,sa,secret 2>&1 | sed 's/^/      /'
done

echo "--- D1–D6 结束（全程只读；未创建/未修改任何对象）"
