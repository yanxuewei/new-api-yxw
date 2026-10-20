# bodies/channel_patch.sh —— 节点侧执行：admin 登录 → 按需 patch → 回读（只打印可变字段，密钥只报长度）
# 依赖 header 注入：CH_ID / CH_SHOW / CH_STATUS / CH_PATCH（单行 JSON，仅 id + 显式字段）
NS=new-api-perf
ADMIN_SECRET=perf-load-test-credentials

IP=$(kubectl -n $NS get svc perf-new-api-slave -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ -n "$IP" ] || { echo "  [XX] 取不到 svc/perf-new-api-slave"; exit 2; }
U=$(kubectl -n $NS get secret $ADMIN_SECRET -o go-template='{{index .data "admin_username"}}' | base64 -d)
P=$(kubectl -n $NS get secret $ADMIN_SECRET -o go-template='{{index .data "admin_password"}}' | base64 -d)
AT=$(curl -sS -m 8 -X POST -H 'Content-Type: application/json' \
      -d "{\"username\":\"$U\",\"password\":\"$P\"}" "http://$IP/api/user/login" \
      | python3 -c "import sys,json;print((json.load(sys.stdin).get('data') or {}).get('access_token',''))" 2>/dev/null)
[ -n "$AT" ] || { echo "  [XX] admin 登录失败"; exit 2; }

show() {
  curl -sS -m 8 -H "Authorization: Bearer $AT" "http://$IP/api/channel/$CH_ID" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
c=d.get('data') or {}
if not c: print('  [XX] 读不到 channel：', d); raise SystemExit(1)
for k in ['id','name','type','base_url','models','group','status','weight','priority','key']:
    v=c.get(k)
    if k=='key': v='<len=%d>'%len(v or '')
    print(f'  {k}={v}')"
}

echo "=== before"
show || exit 1

if [ "$CH_SHOW" = "1" ]; then
  echo "--- --show 模式：只读，未改动"
  exit 0
fi

echo "=== PUT /api/channel/ （只提交可变字段；status 不在其中）"
echo "  patch=$CH_PATCH"
RESP=$(curl -sS -m 10 -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
        -X PUT --data "$CH_PATCH" "http://$IP/api/channel/" 2>&1)
echo "  resp=$(printf '%s' "$RESP" | head -c 200)"
printf '%s' "$RESP" | grep -q '"success":true' || { echo "  [XX] patch 失败（未回 success:true）"; exit 3; }

if [ -n "${CH_STATUS:-}" ]; then
  echo "=== POST /api/channel/$CH_ID/status  status=$CH_STATUS"
  R2=$(curl -sS -m 8 -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
        -X POST -d "{\"status\":$CH_STATUS}" "http://$IP/api/channel/$CH_ID/status" 2>&1)
  echo "  resp=$(printf '%s' "$R2" | head -c 160)"
fi

echo "=== after（回读判效，不认返回码）"
show || exit 1
