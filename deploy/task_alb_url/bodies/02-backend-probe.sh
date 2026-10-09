#!/bin/bash
# 只读：后端可达性 + pod 探针配置 + 节点 SG 视角
say() { printf '\n===== %s =====\n' "$*"; }

say "new-api-stable pod 详情（port / probe / node）"
kubectl -n new-api get pods -l app=new-api,track=stable -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d.get('items',[]):
    m=p['metadata']; st=p.get('status',{})
    c=(p['spec'].get('containers') or [{}])[0]
    print(m['name'],'| node=',p['spec'].get('nodeName'),'| podIP=',st.get('podIP'),'| phase=',st.get('phase'))
    print('   image=',c.get('image'))
    print('   ports=',[(x.get('name'),x.get('containerPort')) for x in (c.get('ports') or [])])
    print('   ready=',json.dumps(c.get('readinessProbe'),ensure_ascii=False))
    print('   live =',json.dumps(c.get('livenessProbe'),ensure_ascii=False))
    print('   start=',json.dumps(c.get('startupProbe'),ensure_ascii=False)[:300])
"

say "pod 直连自检（节点内 curl，4 个探针路径）"
for ip in 10.0.22.218 10.0.22.219 10.0.43.215; do
  for path in /api/status / /healthz /readyz; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$ip:3000$path" 2>/dev/null)
    printf '  %s:3000%-12s -> %s\n' "$ip" "$path" "$code"
  done
done

say "stable ClusterIP 经 svc:80"
curl -s -o /dev/null -w '  172.21.15.220:80/api/status -> HTTP %{http_code}\n' -m 5 "http://172.21.15.220:80/api/status" 2>&1

say "master pod 直连（label 口径核对）"
kubectl -n new-api get pods -l track=master -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for p in d.get('items',[]):
    print(p['metadata']['name'],'| labels=',json.dumps(p['metadata'].get('labels'),ensure_ascii=False))
"

say "kube-proxy NodePort 范围"
grep -m1 -o 'portRange: .*' /etc/kubernetes/kube-proxy-config.yaml 2>/dev/null || echo "(config not at default path)"
ss -lntp 2>/dev/null | awk 'NR==1 || ($4 ~ /:(3[0-9]{4})$/ )' | head -12

say "本机（节点）对外出口 IP（用于 ALB 白名单判断）"
curl -s -m 5 https://myip.ipip.net 2>/dev/null || curl -s -m 5 ifconfig.me 2>/dev/null || echo "(n/a)"
echo; echo "done"
