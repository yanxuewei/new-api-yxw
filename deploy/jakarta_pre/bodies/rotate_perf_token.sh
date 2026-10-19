#!/bin/bash
# bodies/rotate_perf_token.sh —— 轮换 perf 压测令牌 key（§18.7 自纠）
# 起因（我自己的违规，不遮）：diag_perf_token.sh 的 D0 段为判形态，把 `left(key,4)` 的**明文头 4 字符**打进了输出
#   （`db_head4=siop`），而 §18.7 定的规矩是"凭据只出 文件名+字节数+sha256 前缀，**任何派生子串都不许出**"。
#   4/48 字符对 perf 夹具不构成现实危害（库里只有 mock 渠道、无真实厂商凭据），但**规则不打折**：
#   正确处置 = 轮换这个 key，并把"形态检查"改成只用长度/连字符**计数**（`tr -cd | wc -c`），永不取子串。
# 动作：删旧令牌 → 建新令牌（key 由服务端生成）→ SQL 回读并**只做形态计数校验** → 回写 Secret → 单发一条 SSE 验证。
# 输出纪律：key 与口令一律只出 长度 / 连字符数 / md5 前 10 位指纹；不打任何明文片段。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
# fp：同时支持"参数"和"管道"两种喂法。⚠ 上一版只读 $1，导致 `... | fp` 走到 `set -u` 的
#   `$1: unbound variable`，管道里的值被丢掉、算出来的是 **md5(空串)=d41d8cd98f…** —— 于是那一行
#   "指纹已变"是拿 md5(空串) 和新 key 指纹比出来的**假证据**（本轮如实登记，见台账 §21.5）。
fp() { if [ $# -ge 1 ] && [ -n "${1:-}" ]; then printf '%s' "$1"; else cat; fi | md5sum | cut -c1-10; }
jval() { python3 -c "import sys,json
d=json.load(sys.stdin)
for k in '$1'.split('.'):
    d = d.get(k) if isinstance(d, dict) else None
print('' if d is None else d)"; }
ADMIN_PW=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d)
OLD_FP=$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.token_key}' 2>/dev/null | base64 -d | fp)
[ -n "$ADMIN_PW" ] || { echo "  [XX] Secret 无 admin_password ⇒ 先跑 wire_perf_a/b"; exit 0; }
printf '=== R0 旧 key 指纹=%s（轮换后必须变）\n' "${OLD_FP:-无}"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-rot, namespace: new-api-perf, labels: {app: t2p-rot, track: perf, env: dev}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 480
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 460"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-rot --timeout=240s >/dev/null 2>&1 || {
  echo "  [XX] psql Pod 未 Ready"; kubectl -n $NS delete pod t2p-rot --ignore-not-found >/dev/null 2>&1; exit 0; }
Q() { kubectl -n $NS exec -i t2p-rot -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }
[ "$(Q 'select current_database()')" = "newapi_perf" ] || {
  echo "  [XX] 不是 newapi_perf ⇒ 拒绝动令牌"; kubectl -n $NS delete pod t2p-rot --ignore-not-found >/dev/null 2>&1; exit 0; }

echo "=== R1 登录 + 删除旧令牌（旧 key 立即失效）"
AT=$(curl -sS -m 15 -H 'Content-Type: application/json' --data "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\"}" \
  "$GW/api/user/login" 2>&1 | jval data.access_token)
[ -n "$AT" ] || { echo "      [XX] 登录失败"; kubectl -n $NS delete pod t2p-rot --ignore-not-found >/dev/null 2>&1; exit 0; }
OLDID=$(Q "select id from tokens where name='perf-load' order by id limit 1" | tr -dc '0-9')
printf '      旧令牌 id=%s 删除应答=%s\n' "${OLDID:-无}" \
  "$(curl -sS -m 20 -X DELETE -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' \
     --data '{}' "$GW/api/token/$OLDID" 2>&1 | head -c 110)"
printf '      DB 回读：tokens 行数=%s\n' "$(Q "select count(*) from tokens")"

echo "=== R2 建新令牌并回读形态（只出计数，不出子串）"
printf '      add 应答=%s\n' "$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" \
  --data '{"name":"perf-load","status":1,"unlimited_quota":true,"expired_time":-1,"group":"default"}' "$GW/api/token/" 2>&1 | head -c 110)"
TKID=$(Q "select id from tokens where name='perf-load' order by id desc limit 1" | tr -dc '0-9')
TKKEY=$(Q "select key from tokens where id=$TKID" | head -1 | tr -d ' \r\n')
KLEN=${#TKKEY}; KHASDASH=$(printf '%s' "$TKKEY" | tr -cd '-' | wc -c)
KPREFIXSK=$(printf '%s' "$TKKEY" | grep -c '^sk-')
NEW_FP=$(fp "$TKKEY")
printf '      新 key 形态：len=%s 连字符数=%s sk-前缀命中数=%s 指纹=%s\n' "$KLEN" "$KHASDASH" "$KPREFIXSK" "$NEW_FP"
if [ "$KLEN" -lt 20 ] || [ "$KHASDASH" != 0 ] || [ "$NEW_FP" = "$OLD_FP" ]; then
  echo "      [XX] 形态不符或指纹未变 ⇒ 停，不把脏值写进 Secret"
  kubectl -n $NS delete pod t2p-rot --ignore-not-found >/dev/null 2>&1; exit 0
fi
kubectl -n $NS create secret generic $SEC --from-literal=admin_username=perfroot \
  --from-literal=admin_password="$ADMIN_PW" --from-literal=token_id="$TKID" --from-literal=token_key="$TKKEY" \
  --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
echo "      已回写 Secret：token_id=$TKID，key 指纹 $OLD_FP → $NEW_FP"

echo "=== R3 新 key 单发一条 SSE（旧 key 已随 DELETE 失效；其值本地无留存，只比指纹）"
SSE=/tmp/rot_$$.sse
M=$(curl -sS -m 30 -N -o "$SSE" -w '新key http=%{http_code} ttfb=%{time_starttransfer}' \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TKKEY" \
  --data '{"model":"mock-gpt","messages":[{"role":"user","content":"hi"}],"stream":true}' "$GW/v1/chat/completions" 2>&1)
printf '      %s data=%s\n' "$(printf '%s' "$M" | tr -d '\r')" "$(grep -c '^data:' "$SSE" 2>/dev/null)"
[ "${OLD_FP:-无}" != "$NEW_FP" ] && echo "      指纹已变（$OLD_FP → $NEW_FP）⇒ 旧值不可再 used" \
  || echo "      [!] 指纹未变 ⇒ 轮换没生效，按失败处理"
rm -f "$SSE"
echo "=== R4 额度未受影响（轮换令牌不动 users.quota）"
Q "select 'users.quota='||quota::text||' used='||used_quota::text||' req='||request_count::text from users order by id" | sed 's/^/      /'
kubectl -n $NS delete pod t2p-rot --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- R0–R4 结束"
exit 0
