#!/usr/bin/env bash
NS=new-api
echo "### A. SA 上的 role-name 注解（现值）"
kubectl -n $NS get sa new-api-app -o jsonpath='{.metadata.annotations.pod-identity\.alibabacloud\.com/role-name}{"\n"}'
echo "(上一行为空 = 注解不在现值里)"

echo "### B. master Pod：状态 / RRSA 注入痕迹"
kubectl -n $NS get pods -l app --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[-1].type,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp 2>/dev/null
for p in $(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  echo "--- pod $p"
  echo "  pod annotations:"; kubectl -n $NS get pod $p -o jsonpath='{.metadata.annotations}{"\n"}' | tr ',' '\n' | grep -i 'pod-identity\|role' | head -5
  echo "  container env (RRSA 相关):"; kubectl -n $NS get pod $p -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
hit=0
for c in d['spec']['containers']:
    for e in (c.get('env') or []):
        if 'ALIBABA_CLOUD' in e['name']:
            v=e.get('value','')
            if 'TOKEN_FILE' in e['name'] or 'ARN' in e['name']:
                print('   ',e['name'],'=',v.split(',')[0][:70])
            else:
                print('   ',e['name'],'=',v)
            hit+=1
print('    ALIBABA_CLOUD_* 变量数 =',hit)
print('  projected SA token volumes:',[ (v.get('name'), (v.get('projected') or {}).get('sources',[{}])[0].get('serviceAccountToken',{}).get('audience')) for v in d['spec'].get('volumes',[]) if v.get('projected')])
"
done

echo "### C. 容器内实际 env（如有 sh）"
P=$(kubectl -n $NS get pods -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "${P:-}" ]; then
  kubectl -n $NS exec $P -- /usr/bin/env 2>&1 | grep -ci ALIBABA_CLOUD
  kubectl -n $NS exec $P -- /bin/sh -c 'id' 2>&1 | head -2
fi

echo "### D. master 启动是否成功（探针日志尾部，不含密钥）"
[ -n "${P:-}" ] && kubectl -n $NS logs $P --tail=5 2>&1 | cut -c1-160
echo "DONE-T17-PROBE"
