#!/usr/bin/env bash
# 步骤2：new-api-dev 降 requests.cpu 200m -> 50m，memory 512Mi -> 256Mi
set -uo pipefail
NS=newapi-dev

echo "########## 改前 ##########"
kubectl -n "$NS" get deploy new-api-dev -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('  %-14s requests=%s limits=%s' % (c.get('name'), r.get('requests'), r.get('limits')))
"

echo
echo "########## set resources ##########"
kubectl -n "$NS" set resources deploy/new-api-dev -c new-api \
  --requests=cpu=50m,memory=256Mi 2>&1

echo
echo "########## rollout status ##########"
kubectl -n "$NS" rollout status deploy/new-api-dev --timeout=200s 2>&1

echo
echo "########## 改后 ##########"
kubectl -n "$NS" get deploy new-api-dev -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d['spec']['template']['spec']['containers']:
    r = c.get('resources') or {}
    print('  %-14s requests=%s limits=%s' % (c.get('name'), r.get('requests'), r.get('limits')))
print('  ready =', d.get('status', {}).get('readyReplicas'), '/', d['spec'].get('replicas'))
"

echo
echo "########## quota ##########"
kubectl -n "$NS" describe resourcequota newapi-dev-quota 2>&1 | sed -n '/Resource/,/^$/p'

echo
echo "########## pods ##########"
kubectl -n "$NS" get pods -o wide 2>&1
