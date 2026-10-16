#!/bin/bash
# 查最近 12 分钟 xiangdong 相关事件（v5 修复后的门检现状）
set -uo pipefail
START=$(date -u -d '12 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
aliyun actiontrail LookupEvents --region ap-southeast-1 \
  --StartTime "$START" --EndTime "$END" --MaxResults 50 2>&1 | tr -d '\r' | python3 -c "
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print('RAW:', raw[:300]); sys.exit(0)
evts=d.get('Events',[])
if isinstance(evts,str): evts=json.loads(evts)
evts=[json.loads(e) if isinstance(e,str) else e for e in evts]
print('total events:',len(evts))
for e in sorted(evts,key=lambda x:x.get('eventTime','')):
    uid=e.get('userIdentity',{}) or {}
    name=str(uid.get('userName',''))
    svc=e.get('serviceName','') or e.get('eventSource','').split('.')[0]
    api=e.get('eventName','')
    err=(e.get('errorMessage') or '')[:160]
    low=json.dumps(e).lower()
    if 'xiangdong' in low or 'dms' in (svc+api).lower() or err:
        print(e.get('eventTime'),'|',uid.get('type'),'|',name[:50],'|',svc+':'+api,'|',err)
"
