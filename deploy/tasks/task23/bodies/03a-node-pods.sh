#!/bin/bash
# 只读：每个节点上的非 DaemonSet Pod 清单（决定 drain 选点，避免误伤单副本系统组件）
for N in $(kubectl get nodes -o name | sed 's#node/##'); do
  echo "=== $N ==="
  kubectl get pods -A --field-selector spec.nodeName="$N" -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for it in sorted(d.get('items',[]), key=lambda x:(x['metadata']['namespace'],x['metadata']['name'])):
    kinds=[o.get('kind','') for o in (it['metadata'].get('ownerReferences') or [])]
    if 'DaemonSet' in kinds: continue
    print('  %-14s %-46s %-9s owner=%-12s pdb=?' % (it['metadata']['namespace'], it['metadata']['name'], it['status'].get('phase'), (kinds[0] if kinds else 'BARE')))
"
done
echo "=== new-api ns 的 PDB 覆盖 ==="
kubectl -n new-api get pdb -o wide --no-headers
echo "=== kube-system 里是否有 PDB（drain 时会被尊重）==="
kubectl -n kube-system get pdb --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (无)"
echo "=== 全集群 autoscaler 检索（任务 42 口径复核）==="
kubectl get deploy,sts,ds -A 2>/dev/null > /tmp/allw.txt
if grep -qiE "autoscal" /tmp/allw.txt; then grep -iE "autoscal" /tmp/allw.txt | sed 's/^/  /'; else echo "  用户面未检索到 cluster-autoscaler"; fi
if kubectl -n kube-system get cm cluster-autoscaler-status >/dev/null 2>&1; then
  echo "  cluster-autoscaler-status CM 存在："
  kubectl -n kube-system get cm cluster-autoscaler-status -o yaml | grep -E "health:|scaleUpStatus|lastProcessedTime|nodeCount|readiness" | head -8 | sed 's/^/    /'
else
  echo "  无 cluster-autoscaler-status ConfigMap"
fi
