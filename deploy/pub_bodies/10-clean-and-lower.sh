#!/usr/bin/env bash
# 优化1：清 Completed 残留 Pod（先列名单+所属 Job）；优化2：降两个 slave 的 requests
set -uo pipefail
NS=newapi-dev

echo "########## A. 待清理的 Completed 残留 ##########"
kubectl get pods -A --field-selector=status.phase==Succeeded -o wide 2>&1
echo "--- 对应 Job（删 pod 可能被 Job 重建）---"
kubectl get jobs -A 2>&1 | head -20

echo
echo "########## B. 执行清理 ##########"
kubectl get pods -A --field-selector=status.phase==Succeeded -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for p in d.get('items', []):
    print('%s/%s' % (p['metadata']['namespace'], p['metadata']['name']))
" > /tmp/cp_list.txt
wc -l < /tmp/cp_list.txt | tr -d ' ' | xargs -I{} echo "  待删 {} 个"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ns="${line%%/*}"; name="${line##*/}"
  echo "  delete $line"
  kubectl -n "$ns" delete pod "$name" --wait=false 2>&1 | head -2
done < /tmp/cp_list.txt

echo
echo "########## C. 改前 slave 资源 ##########"
for d in new-api-dev-slave yxw-new-api-slave; do
  kubectl -n "$NS" get deploy "$d" -o json 2>/dev/null | python3 -c "
import sys, json
x = json.load(sys.stdin)
for c in x['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('  %-22s %-18s requests=%s limits=%s' % (x['metadata']['name'], c.get('name'), r.get('requests'), r.get('limits')))
"
done

echo
echo "########## D. 降 requests ##########"
kubectl -n "$NS" set resources deploy/new-api-dev-slave -c new-api-dev-slave --requests=cpu=100m,memory=256Mi 2>&1
kubectl -n "$NS" set resources deploy/yxw-new-api-slave -c yxw-new-api-slave --requests=cpu=100m,memory=256Mi 2>&1

echo
echo "########## E. rollout ##########"
kubectl -n "$NS" rollout status deploy/new-api-dev-slave --timeout=180s 2>&1
kubectl -n "$NS" rollout status deploy/yxw-new-api-slave --timeout=180s 2>&1

echo
echo "########## F. 终态 ##########"
kubectl -n "$NS" get deploy -o wide 2>&1
echo
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'
echo
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d = json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v = str(v)
    return int(v[:-1]) if v.endswith('m') else float(v)*1000
cnt = collections.Counter(); per = collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status', {}).get('phase') in ('Succeeded','Failed'): continue
    n = p['spec'].get('nodeName'); cnt[n] += 1
    for c in p['spec'].get('containers', []):
        per[n] += cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu'))
for n in sorted(cnt):
    print('  %-30s pods=%2d/15  req.cpu=%6.0fm 剩余=%.0fm' % (n, cnt[n], per[n], 1930-per[n]))
"
