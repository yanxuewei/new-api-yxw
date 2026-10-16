#!/bin/bash
# bodies/diag_mem.sh —— 每节点 requests.memory 账目 + dev 负载的真实 requests/limits（只读）
set -uo pipefail
echo "=== M1 requests.memory 按节点求和"
kubectl get pod -A --field-selector=status.phase!=Succeeded \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{range .spec.containers[*]}{.resources.requests.memory}{" "}{end}{"\n"}{end}' 2>/dev/null | awk '
function tobytes(v){ if(v=="") return 0
  if(v ~ /Ki$/){gsub(/Ki$/,"",v); return v*1024}
  if(v ~ /Mi$/){gsub(/Mi$/,"",v); return v*1048576}
  if(v ~ /Gi$/){gsub(/Gi$/,"",v); return v*1073741824}
  return 0 }
{n=$1; t=0; for(i=2;i<=NF;i++) t+=tobytes($i); s[n]+=t}
END{for(k in s) printf "    %-28s %.2f Gi\n", k, s[k]/1073741824}'
echo "=== M2 可分配上限"
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{"  alloc.mem="}{.status.allocatable.memory}{"  alloc.cpu="}{.status.allocatable.cpu}{"\n"}{end}' 2>&1 | sed 's/^/    /'
echo "=== M3 dev 负载的真实 requests/limits（现网与仓库清单已不一致，判据以现网为准）"
kubectl -n newapi-dev get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  rep="}{.spec.replicas}{"  req="}{.spec.template.spec.containers[0].resources.requests}{"  lim="}{.spec.template.spec.containers[0].resources.limits}{"\n"}{end}' 2>&1 | sed 's/^/    /'
echo "=== M4 实际用量（metrics-server；只有 Running Pod 才有数）"
kubectl top node 2>&1 | sed 's/^/    /'
kubectl top pod -A --sort-by=cpu 2>&1 | head -12 | sed 's/^/    /'
