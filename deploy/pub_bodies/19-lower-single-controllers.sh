#!/usr/bin/env bash
# 批3：5 个单实例控制器 requests 100m -> 20m
set -uo pipefail

LIST="storage-operator loongcollector-operator policy-template-controller ack-node-problem-detector-eventer gatekeeper"

echo "########## 改前 ##########"
for d in $LIST; do
  kubectl -n kube-system get deploy "$d" -o json 2>/dev/null | python3 -c "
import sys, json
x = json.load(sys.stdin)
print('  %-42s replicas=%s' % (x['metadata']['name'], x['spec'].get('replicas')))
for c in x['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('     %-38s cpu=%-7s mem=%s' % (c.get('name'), (r.get('requests') or {}).get('cpu'), (r.get('requests') or {}).get('memory')))
"
done

echo
echo "########## 执行 ##########"
for d in $LIST; do
  for c in $(kubectl -n kube-system get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null); do
    reqc=$(kubectl -n kube-system get deploy "$d" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$c\")].resources.requests.cpu}" 2>/dev/null)
    case "$reqc" in
      *m) v=${reqc%m}; [ "$v" -ge 100 ] && { echo "  $d/$c : ${reqc} -> 20m"; kubectl -n kube-system set resources deploy/"$d" -c "$c" --requests=cpu=20m 2>&1 | grep -v '^Warning'; } ;;
      *) ;;
    esac
  done
done

echo
echo "########## rollout ##########"
for d in $LIST; do
  kubectl -n kube-system rollout status deploy/"$d" --timeout=150s 2>&1 | tail -1
done

echo
echo "########## 改后 ##########"
for d in $LIST; do
  kubectl -n kube-system get deploy "$d" -o json 2>/dev/null | python3 -c "
import sys, json
x = json.load(sys.stdin)
print('  %-42s ready=%s/%s' % (x['metadata']['name'], x.get('status',{}).get('readyReplicas'), x['spec'].get('replicas')))
for c in x['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('     %-38s cpu=%-7s mem=%s' % (c.get('name'), (r.get('requests') or {}).get('cpu'), (r.get('requests') or {}).get('memory')))
"
done

echo
echo "########## 健康检查 ##########"
kubectl get pods -A 2>&1 | grep -v -E 'Running|Completed|NAME' | head -8
echo "(空=全部正常)"
echo "--- 策略引擎可用 ---"
kubectl get constrainttemplate 2>&1 | head -3
echo "--- metrics ---"
kubectl top nodes 2>&1 | head -5

echo
echo "########## 节点 requests 终值 ##########"
kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys, json, collections
d=json.load(sys.stdin)
def cpu(v):
    if not v: return 0
    v=str(v); return int(v[:-1]) if v.endswith('m') else float(v)*1000
cnt=collections.Counter(); per=collections.defaultdict(float)
for p in d.get('items', []):
    if p.get('status',{}).get('phase') in ('Succeeded','Failed'): continue
    n=p['spec'].get('nodeName'); cnt[n]+=1
    for c in p['spec'].get('containers', []):
        per[n]+=cpu(((c.get('resources') or {}).get('requests') or {}).get('cpu'))
for n in sorted(cnt): print('  %-30s pods=%2d/15 req=%6.0fm 余=%.0fm' % (n,cnt[n],per[n],1930-per[n]))
"
