#!/bin/bash
# 只读：查 new-api 工作负载 / Service / Endpoints / Ingress / 节点
K() { kubectl "$@"; }
say() { printf '\n===== %s =====\n' "$*"; }

say "nodes"
K get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,INTERNAL:.status.addresses[?(@.type=="InternalIP")].address,EXTERNAL:.status.addresses[?(@.type=="ExternalIP")].address,PODCIDR:.spec.podCIDR' --no-headers 2>&1

say "new-api ns: deploy / sts / ds"
K -n new-api get deploy,sts,ds -o wide 2>&1

say "new-api pods"
K -n new-api get pods -o wide 2>&1

say "new-api svc"
K -n new-api get svc -o wide 2>&1

say "new-api endpoints"
K -n new-api get endpoints -o wide 2>&1

say "new-api endpointslices (ports)"
K -n new-api get endpointslices -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('items',[]):
    ports=[(p.get('name'),p.get('port'),p.get('protocol')) for p in (s.get('ports') or [])]
    eps=[(e.get('ip'),e.get('nodeName'),e.get('conditions',{}).get('ready')) for e in (s.get('endpoints') or [])]
    print(s['metadata']['name'],'| svc=',s['metadata'].get('labels',{}).get('kubernetes.io/service-name'),'| ports=',ports)
    for e in eps: print('    ep',e)
" 2>&1

say "ingress (all ns)"
K get ingress -A -o wide 2>&1

say "ingress new-api yaml (摘要)"
K -n new-api get ingress -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('items',[]):
    m=i['metadata']; sp=(i.get('spec') or {})
    print('name=',m['name'],'| class=',sp.get('ingressClassName'),'| annotations=',json.dumps(m.get('annotations') or {},ensure_ascii=False)[:600])
    for r in (sp.get('rules') or []):
        for p in ((r.get('http') or {}).get('paths') or []):
            print('   host=',r.get('host'),'path=',p.get('path'),'->',json.dumps(p.get('backend'),ensure_ascii=False))
" 2>&1

say "所有 NodePort svc 汇总"
K get svc -A -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('items',[]):
    if s['spec'].get('type') in ('NodePort','LoadBalancer'):
        ps=[(p.get('name'),p.get('port'),p.get('nodePort'),p.get('targetPort')) for p in (s['spec'].get('ports') or [])]
        print(s['metadata']['namespace']+'/'+s['metadata']['name'],'|',s['spec']['type'],'|',ps)
" 2>&1

say "alb controller / addon 痕迹"
K -n kube-system get pods -o wide 2>&1 | grep -i -E "alb|NAME" || echo "(no alb pod)"
K get ingressclass 2>&1

say "app 自检（集群内 curl Service）"
SVCIP=$(K -n new-api get svc new-api-master -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
echo "new-api-master clusterIP=$SVCIP"
[ -n "$SVCIP" ] && curl -s -o /dev/null -w 'clusterIP:3000 -> HTTP %{http_code}\n' -m 5 "http://$SVCIP:3000/api/status" 2>&1
echo "done"
