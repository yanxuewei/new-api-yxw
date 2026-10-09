#!/bin/bash
# V3 收尾：回收 drain 取证（本地 /tmp/drain.log + 集群事件）→ uncordon → 复核
NS=new-api
NODE=ap-southeast-6.10.0.43.200

echo "=== 1) drain 输出全文（执行节点 .22.194 上的 /tmp/drain.log）==="
if [ -s /tmp/drain.log ]; then wc -l /tmp/drain.log | sed 's/^/  lines=/'; cat /tmp/drain.log | sed 's/^/  |/'; else echo "  (无 /tmp/drain.log)"; fi

echo "=== 2) 驱逐被谁记录：new-api ns 近 30 min 事件 ==="
kubectl -n $NS get events --sort-by=.lastTimestamp 2>/dev/null \
  | grep -Ei "evict|xrw42|qggpc|successfulcreate|scale" | tail -20 | sed 's/^/  /'

echo "=== 3) 被驱逐 Pod 与替补 Pod 的节点/时间 ==="
kubectl -n $NS get pods -l track=stable -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in sorted(d['items'], key=lambda x: x['metadata']['creationTimestamp']):
    m=p['metadata']; s=p['status']
    print('  %-38s %-8s node=%-26s start=%s' % (m['name'], s.get('phase'), p['spec'].get('nodeName'), s.get('startTime')))
"
echo "  节点 AZ："
for n in ap-southeast-6.10.0.22.194 ap-southeast-6.10.0.22.195 ap-southeast-6.10.0.43.200 ap-southeast-6.10.0.43.201; do
  printf "    %-28s zone=%s\n" "$n" "$(kubectl get node "$n" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)"
done

echo "=== 4) 目标节点当前状态 + 剩余非 DaemonSet Pod ==="
kubectl get node "$NODE" --no-headers | awk '{printf "  status=%s\n",$2}'
kubectl get pods -A --field-selector spec.nodeName="$NODE" -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
n=0
for it in d.get('items',[]):
    kinds=[o.get('kind','') for o in (it['metadata'].get('ownerReferences') or [])]
    if 'DaemonSet' in kinds: continue
    n+=1
    print('    %-14s %-50s %s' % (it['metadata']['namespace'], it['metadata']['name'], it['status'].get('phase')))
print('    非 DS Pod 数=%d' % n)
"

echo "=== 5) uncordon 恢复调度 ==="
kubectl uncordon "$NODE"
sleep 8
kubectl get nodes --no-headers | awk '{printf "  %-28s %s\n",$1,$2}'

echo "=== 6) 恢复后终态 ==="
kubectl -n $NS get deploy new-api-stable --no-headers | awk '{printf "  deploy ready=%s updated=%s avail=%s unavail=%s\n",$2,$3,$4,$5}'
kubectl -n $NS get pdb pdb-new-api-stable --no-headers | awk '{printf "  pdb min=%s allowed=%s\n",$2,$4}'
kubectl -n $NS get pods -l track=stable -o wide --no-headers | awk '{printf "  %-38s %-8s node=%s\n",$1,$3,$7}'
kubectl -n $NS get pods -l app=new-api-migrate -o wide --no-headers | awk '{printf "  MASTER %-38s %-8s node=%s\n",$1,$3,$7}'
echo "  endpoints："
kubectl -n $NS get endpoints new-api-stable --no-headers 2>/dev/null | sed 's/^/    /'
