#!/bin/bash
# 服务端按用户过滤拉 xiangdong 事件（昨晚 10:20Z 至今）
set -uo pipefail
START="2026-10-15T10:20:00Z"
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "window: $START ~ $END"
aliyun actiontrail LookupEvents --region ap-southeast-1 \
  --StartTime "$START" --EndTime "$END" \
  --LookupAttribute.1.Key User --LookupAttribute.1.Value xiangdong \
  --MaxResults 50 2>&1 | tr -d '\r' | python3 -c "
import json,sys
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print('RAW:', raw[:400]); sys.exit(0)
evts=d.get('Events',[])
if isinstance(evts,str): evts=json.loads(evts)
evts=[json.loads(e) if isinstance(e,str) else e for e in evts]
print('events returned:', len(evts))
for e in sorted(evts,key=lambda x:x.get('eventTime','')):
    uid=e.get('userIdentity',{}) or {}
    svc=e.get('serviceName','') or e.get('eventSource','').split('.')[0]
    api=e.get('eventName','')
    err=(e.get('errorMessage') or '')[:150]
    mark='  <<ERR' if err else ''
    print(e.get('eventTime'),'|',uid.get('type'),'|',svc+':'+api,'|',err,mark)
print('NextToken:', (d.get('NextToken') or '')[:20])
"
