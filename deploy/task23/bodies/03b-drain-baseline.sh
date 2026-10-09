#!/bin/bash
# 只读：drain 选点复核（stable Pod 完整分布 + AZ + 节点调度状态）
NS=new-api
echo "=== stable Pod 全量分布 ==="
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-40s %-9s r=%-3s node=%s\n",$1,$3,$4,$7}'
echo "  计数：$(kubectl -n $NS get pods -l track=stable --no-headers | wc -l) 个"
echo "=== master Pod ==="
kubectl -n $NS get pods -l app=new-api-migrate -o wide --no-headers | awk '{printf "  %-40s %-9s r=%-3s node=%s\n",$1,$3,$4,$7}'
kubectl -n $NS get pods --no-headers | grep -c -v stable | awk '{printf "  非 stable Pod 数=%s\n",$1}'
echo "=== 节点 + AZ + 调度状态 ==="
kubectl get nodes -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d['items']:
    n=it['metadata']['name']
    z=it['metadata']['labels'].get('topology.kubernetes.io/zone','?')
    st=[c.get('status') for c in it['status'].get('conditions',[]) if c.get('type')=='Ready']
    print('  %-28s zone=%-16s Ready=%s' % (n,z,(st[0] if st else '?')))
"
echo "=== deploy/HPA/PDB 现状 ==="
kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "  deploy: ready=%s updated=%s avail=%s unavail=%s\n",$2,$3,$4,$5}'
kubectl -n $NS get hpa hpa-new-api-stable --no-headers | awk '{printf "  hpa: min=%s max=%s replicas=%s targets=%s\n",$4,$5,$6,$3}'
kubectl -n $NS get pdb pdb-new-api-stable --no-headers | awk '{printf "  pdb: min=%s allowed=%s\n",$2,$4}'
