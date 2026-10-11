#!/bin/bash
# 只读：输出 new-api-stable 的 ready pod IP（一行一个）
kubectl -n new-api get endpoints new-api-stable -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
ips=[]
for s in (d.get('subsets') or []):
    for a in (s.get('addresses') or []):
        ips.append(a['ip'])
    for a in (s.get('notReadyAddresses') or []):
        print('# not-ready', a['ip'], file=sys.stderr)
for ip in ips: print(ip)
"
echo "-----"
kubectl -n new-api get pods -l app=new-api,track=stable -o wide --no-headers 2>&1
