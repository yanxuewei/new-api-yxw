#!/bin/bash
# deploy/ops/bodies/diag_nodes.sh —— 节点真实资源账目（只读；回答"Insufficient cpu 到底缺在哪"）
set -uo pipefail
echo "=== Y1 每节点 Allocation（scheduler 用的就是这份账）"
for n in $(kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  echo "  --- $n"
  kubectl describe node "$n" 2>/dev/null | sed -n '/^Allocation Resources/,/^Events:/p' \
    | grep -E "cpu|memory|pods|Namespace|Resource" | sed 's/^/      /'
done
echo "=== Y2 节点上真实在跑的 Pod 与各自 requests.cpu（含 kube-system）"
kubectl get pod -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .spec.containers[*]}{.resources.requests.cpu}{","}{end}{"\n"}{end}' 2>/dev/null \
  | sort | awk -F'\t' '{printf "    %-28s %-46s %-10s %s\n", $1, $2, $3, $4}'
echo "=== Y3 requests.cpu 按节点求和（把 500m/1 两种写法统一成核）"
kubectl get pod -A --field-selector=status.phase!=Succeeded -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{range .spec.containers[*]}{.resources.requests.cpu}{" "}{end}{"\n"}{end}' 2>/dev/null | awk '
{n=$1; sub("node/","",n); t=0
 for(i=2;i<=NF;i++){c=$i; if(c=="") continue
   if(c ~ /m$/){gsub("m","",c); t+=c/1000}
   else if(c ~ /^[0-9]+(\.[0-9]+)?$/){t+=c}
   else if(c ~ /k$/){gsub("k","",c); t+=c*1000/1000000}}
 s[n]+=t; cnt[n]++}
END{for(k in s) printf "    %s  requests.cpu=%.3f  非终态 Pod 数=%d\n", k, s[k], cnt[k]}'
echo "=== Y4 每节点 Pod 数与上限（Too many pods 那条来自这里）"
kubectl get pod -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort | uniq -c | sed 's/^/    /'
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  pods-cap="}{.status.allocatable.pods}{"\n"}{end}' 2>&1 | sed 's/^/    /'
echo "=== Y5 弹性伸缩侧（节点池有没有扩第 4 台的通路；只读取证）"
kubectl -n kube-system get cm autoscaler-meta -o jsonpath='{.data}' 2>&1 | cut -c1-300 | sed 's/^/    cm=/'
echo
kubectl get lease -n kube-system 2>&1 | grep -iE "goatscaler|autoscaler" | sed 's/^/    /'
