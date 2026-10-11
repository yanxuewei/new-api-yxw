#!/bin/bash
# 任务 28 · 前置侦察（SG 集群，**全部只读**：只有 get/describe，零写操作）
# 目的：卡片写的是一套，现网能不能落地是另一套。逐条取证后再决定清单与脚本。
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
IMG_PUB=acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/newapi-prod/newapi-master:20260928-26ac63233

echo "== 1) 节点：名称/IP/AZ/机型/可分配/调度状态 =="
kubectl get nodes -o custom-columns='NAME:.metadata.name,INTERNAL_IP:.status.addresses[?(@.type=="InternalIP")].address,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,INSTANCE_TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,Ready:.status.conditions[?(@.type=="Ready")].status,UNSCHED:.spec.unschedulable,CPU_alloc:.status.allocatable.cpu,MEM_alloc:.status.allocatable.memory' 2>&1

echo "== 1b) 节点已请求量（判 2 副本 requests 2C 能否放下）=="
kubectl describe nodes 2>/dev/null | grep -A6 "Non-terminated Pods:" | head -30

echo "== 2) ns $NS 现有工作负载/网络对象 =="
kubectl -n "$NS" get deploy,rs,st,ds,svc,ingress,hpa,pdb,job -o wide 2>&1 | head -40
echo "-- AlbConfig / IngressClass --"
kubectl -n "$NS" get albconfig 2>&1 | head -5
kubectl get ingressclass 2>&1 | head -5

echo "== 3) ConfigMap new-api-config（非敏感，全量打印）=="
kubectl -n "$NS" get configmap new-api-config -o jsonpath='{.data}' 2>&1 | tr ',' '\n' | sed 's/[{:}]//g' | head -40

echo "== 4) Secret 清单 + 键名（**只打印键名，不打印值**）=="
kubectl -n "$NS" get secret 2>&1 | head -20
for s in new-api-secrets rds-ca-apse6; do
  echo "-- $s keys --"
  kubectl -n "$NS" get secret "$s" -o jsonpath='{.data}' 2>&1 | tr ',' '\n' | sed 's/[{:}]//g' | awk '{print "   ", $1}' | sed 's/^[ \t]*[A-Za-z0-9_-]*:[[:space:]]*/   key: /' | head -20
done
echo "-- new-api-secrets 创建时间 --"
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.metadata.creationTimestamp}{"\n"}' 2>&1

echo "== 5) SQL_DSN 骨架（口令掩码，只留端点/端口/库/sslmode）=="
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.SQL_DSN}' 2>/dev/null | base64 -d 2>/dev/null | sed -E 's#://([^:/]+):[^@]*@#://\1:***@#'
echo
echo "== 5b) LOG_SQL_DSN 端点是否 -public（口令掩码）=="
kubectl -n "$NS" get secret new-api-secrets -o jsonpath='{.data.LOG_SQL_DSN}' 2>/dev/null | base64 -d 2>/dev/null | sed -E 's#://[^@]*@#://<REDACTED>@#' | grep -oE '[a-z0-9.-]+\.(clickhouseserver|rds\.aliyuncs\.com)[^,]*' | head -3
echo
echo "== 5c) SESSION_SECRET 指纹（sha256 前 12，两地比对口径，不打印值）=="
for k in SESSION_SECRET SESSION_SECRET_OLD; do
  V=$(kubectl -n "$NS" get secret new-api-secrets -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null)
  [ -n "$V" ] && echo "   $k len=${#V} sha12=$(printf %s "$V" | sha256sum | cut -c1-12)" || echo "   $k MISSING"
done

echo "== 6) SA new-api-app：imagePullSecrets =="
kubectl -n "$NS" get sa new-api-app -o jsonpath='{.imagePullSecrets}{"\n"}' 2>&1
kubectl -n "$NS" get secret acr-credential-secret-aggregation -o jsonpath='{.metadata.creationTimestamp} {.type}{"\n"}' 2>&1

echo "== 7) ResourceQuota（决定 2 副本 requests/limits 是否被拦）=="
kubectl -n "$NS" get resourcequota -o wide 2>&1 | head -5
kubectl -n "$NS" get resourcequota -o jsonpath='{range .items[*]}{.metadata.name}{" hard="}{.spec.hard}{"\n used="}{.status.used}{"\n"}{end}' 2>&1 | head -10

echo "== 8) 跨区拉取路径：节点侧解析 + 443 探测（公网域名）=="
getent hosts acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com 2>&1 | head -2
curl -s -o /dev/null -w 'pub  /v2/ http=%{http_code} connect=%{time_connect}s\n' --max-time 10 https://acr-newapi-mnl-registry.ap-southeast-6.cr.aliyuncs.com/v2/ 2>&1
curl -s -o /dev/null -w 'vpc  /v2/ http=%{http_code} connect=%{time_connect}s\n' --max-time 10 https://acr-newapi-mnl-registry-vpc.ap-southeast-6.cr.aliyuncs.com/v2/ 2>&1

echo "== 9) 节点出网到马尼拉 RDS 公网串 6432（TCP 层，只 probe 不通不算写）=="
timeout 6 bash -c 'exec 3<>/dev/tcp/pgm-5tstdhko64x2c01wpub.pgsql.ap-southeast-6.rds.aliyuncs.com/6432 && echo "6432 OPEN"' 2>&1 || echo "6432 不通/超时"

echo "== 10) 探针 Pod 残留（任务 30 的 t30-* 是否还在）=="
kubectl -n "$NS" get pod -l 'app in (t30-probe,t30-v3)' -o wide 2>&1 | head -6

echo "== 11) 新节点池机型/AZ 归属（云侧由本机 API 复核，这里只记 label 实况）=="
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" zone="}{.metadata.labels.topology\.kubernetes\.io/zone}{" type="}{.metadata.labels.node\.kubernetes\.io/instance-type}{" pool="}{.metadata.labels.alibabacloud\.com/nodepool-id}{"\n"}{end}' 2>&1

echo "== 12) 现网是否已有 standby 同名对象（防覆盖）=="
kubectl -n "$NS" get deploy new-api-ph-standby 2>&1 | head -3
kubectl -n "$NS" get svc new-api-ph-standby 2>&1 | head -3
echo "### DONE-28-RECON"
