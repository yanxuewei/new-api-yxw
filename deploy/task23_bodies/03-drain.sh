#!/bin/bash
# V3 PDB 实测：drain ap-southeast-6.10.0.43.200（1 个 stable Pod、无 master；用户 2026-10-06 核准）
NS=new-api
NODE="${T23_DRAIN_NODE:-ap-southeast-6.10.0.43.200}"

echo "=== 0) 目标节点 = $NODE ==="
kubectl get node "$NODE" --no-headers | awk '{printf "  status=%s\n",$2}'

echo "=== 1) drain 前基线 ==="
kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "  deploy: ready=%s updated=%s unavailable=%s\n",$2,$3,$4}'
kubectl -n $NS get pdb pdb-new-api-stable --no-headers | awk '{printf "  pdb: min=%s max=%s allowed=%s\n",$2,$3,$4}'
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-40s %-8s r=%-3s node=%s\n",$1,$3,$4,$7}'

echo "=== 2) ⚠ kubectl drain（破坏性，核准留痕 2026-10-06）==="
date -u +"  start=%Y-%m-%dT%H:%M:%SZ"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s >/tmp/drain.log 2>&1
RC=$?
tail -20 /tmp/drain.log | sed 's/^/  /'
date -u +"  end=%Y-%m-%dT%H:%M:%SZ rc=$RC"

echo "=== 3) 逐 20s 取证：被驱逐数 / 其余是否 Running / 新 Pod 能否调度 ==="
for i in 1 2 3 4 5 6 7 8; do
  printf "  [%s] " "$(date -u +%H:%M:%S)"
  kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "ready=%-6s unavail=%-3s ",$2,$4}'
  kubectl -n $NS get pdb pdb-new-api-stable --no-headers | awk '{printf "allowed=%s", $4}'
  printf "  pods=%s\n" "$(kubectl -n $NS get pods -l track=stable --no-headers 2>/dev/null | awk '{c[$3]++} END{for(k in c) printf "%s:%s ",k,c[k]}')"
  sleep 20
done

echo "=== 4) 结果快照 ==="
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-40s %-8s r=%-3s age=%-6s node=%s\n",$1,$3,$4,$5,$7}'
kubectl -n $NS get pods -l track=master -o wide --no-headers | awk '{printf "  MASTER %-40s %-8s r=%-3s node=%s\n",$1,$3,$4,$7}'
echo "  AZ 分布："
kubectl -n $NS get pods -l app=new-api -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | xargs -I{} kubectl get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' 2>/dev/null | sort | uniq -c | sed 's/^/    /'
echo "  目标节点上剩余非 DS Pod："
kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in d.get('items',[]):
    if 'DaemonSet' in [o.get('kind','') for o in (it['metadata'].get('ownerReferences') or [])]: continue
    print('    %-14s %-46s %s' % (it['metadata']['namespace'], it['metadata']['name'], it['status'].get('phase')))
"

echo "=== 5) uncordon 恢复 ==="
kubectl uncordon "$NODE"
sleep 5
kubectl get nodes --no-headers | awk '{printf "  %-28s %s\n",$1,$2}'
