#!/bin/bash
# V4 补充 2：真实 stable 的容量与缩容通路（minReplicas 4→6→4，有界）
# 目的：(a) 6 副本在现有 4 节点 + AZ 硬约束下可调度、不撞配额；(b) 缩容真实发生；
#      (c) 取证缩容走 Eviction 还是 RS 直接删除（决定 PDB 拦不拦得住）。
NS=new-api
hpa() { kubectl -n $NS get hpa hpa-new-api-stable -o jsonpath='min={.spec.minReplicas} max={.spec.maxReplicas} target={.spec.metrics[0].resource.target.averageUtilization} cur={.status.currentReplicas} des={.status.desiredReplicas} cond={.status.conditions[-1].type} reason={.status.conditions[-1].reason}{"\n"}' 2>/dev/null; }
quota() { kubectl -n $NS get resourcequota new-api-quota -o json 2>/dev/null | python3 -c "
import sys,json
q=json.load(sys.stdin)
for k,v in sorted((q.get('status',{}).get('used',{}) or {}).items()):
    print('    %-16s used=%-10s hard=%s' % (k,v,(q.get('spec',{}).get('hard',{}) or {}).get(k,'-')))
"; }
nodecpu() {
kubectl get nodes -o name 2>/dev/null | sed 's#node/##' | while read -r N; do
  printf "    %-28s " "$N"
  kubectl get pods -A --field-selector spec.nodeName="$N" -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); t=0
for it in d.get('items',[]):
    if it['status'].get('phase') not in ('Running','Pending'): continue
    for c in (it['spec'].get('containers') or []):
        v=str(((c.get('resources') or {}).get('requests') or {}).get('cpu','0'))
        t += (int(v[:-1]) if v.endswith('m') else int(float(v)*1000))
print('requested=%dm / allocatable=7910m' % t)
"
done
}

echo "=== 1) 基线 ==="
echo "  $(hpa)"
kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "  deploy ready=%s avail=%s\n",$2,$4}'
quota

echo "=== 2) minReplicas 4 → 6（仍受 maxReplicas 15 与配额约束）==="
kubectl -n $NS patch hpa hpa-new-api-stable --type merge -p '{"spec":{"minReplicas":6}}'
echo "  patched: $(hpa)"
for i in $(seq 1 9); do
  printf "  [%2s] deploy=%s  %s" "$i" "$(kubectl -n $NS get deploy new-api-stable --no-headers | awk '{print $2}')" "$(hpa)"
  sleep 20
done

echo "=== 3) 6 副本取证：节点/AZ 分布 + 配额 + endpoints ==="
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-38s %-8s r=%-3s node=%s\n",$1,$3,$4,$7}'
echo "  AZ："
for n in $(kubectl -n $NS get pods -l track=stable -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null); do
  kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null
done | sort | uniq -c | sed 's/^/    /'
echo "  每节点 requests.cpu："
nodecpu
echo "  endpoints："
kubectl -n $NS get endpoints new-api-stable -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{":3000 "}{end}{"\n"}' 2>/dev/null | sed 's/^/    /'
quota
echo "  扩容事件："
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei "hpa-new-api-stable|Scaled up|SuccessfulRescale" | tail -8 | sed 's/^/    /'

echo "=== 4) minReplicas 还原 6 → 4，观察缩容 ==="
kubectl -n $NS patch hpa hpa-new-api-stable --type merge -p '{"spec":{"minReplicas":4}}'
echo "  restored: $(hpa)"
for i in $(seq 1 14); do
  printf "  [%2s] deploy=%s pods=%s\n" "$i" "$(kubectl -n $NS get deploy new-api-stable --no-headers | awk '{print $2}')" "$(kubectl -n $NS get pods -l track=stable --no-headers 2>/dev/null | awk '{c[$3]++} END{for(k in c) printf "%s:%s ",k,c[k]}')"
  sleep 25
done

echo "=== 5) 缩容终态 ==="
echo "  $(hpa)"
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-38s %-8s node=%s\n",$1,$3,$7}'
kubectl -n $NS get pdb pdb-new-api-stable --no-headers | awk '{printf "  pdb min=%s allowed=%s\n",$2,$4}'
echo "  缩容事件（Eviction vs 直接删除）："
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null | grep -Ei "Scaled down|SuccessfulDelete|Killing|Evict" | tail -14 | sed 's/^/    /'
echo "  配额终态："
quota
