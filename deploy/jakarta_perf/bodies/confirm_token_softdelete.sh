#!/bin/bash
# bodies/confirm_token_softdelete.sh —— 确认旧令牌 id=2 是"应用侧已不可用"，不是"我数错了"
# 为什么要这一步：rotate_perf_token 里 DELETE 成功后 psql 仍数到 tokens 有旧行 ⇒ 两种解释：
#   ① GORM 软删（deleted_at 非空，应用查询自动排除）——那旧 key 确实失效；
#   ② 删除根本没落到那一行（我 DELETE 的 id 取错）——那旧 key 还活着，§18.7 的处置就不成立。
#   不猜：直接读 deleted_at。
set -uo pipefail
NS=new-api-perf
kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-c, namespace: new-api-perf, labels: {app: t2p-c, track: perf, env: dev}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 280"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-c --timeout=240s >/dev/null 2>&1
Q() { kubectl -n $NS exec -i t2p-c -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }
[ "$(Q 'select current_database()')" = "newapi_perf" ] || { echo "  [XX] 库不对"; kubectl -n $NS delete pod t2p-c --ignore-not-found >/dev/null 2>&1; exit 0; }
echo "=== X1 令牌行的软删状态（alive=false ⇒ 应用查不到该 key）"
Q "select 'id='||id||' name='||name||' alive='||(deleted_at is null)::text||' deleted_at='||coalesce(deleted_at::text,'(空)') from tokens order by id" | sed 's/^/      /'
echo "=== X2 应用视角的有效令牌数（与 GORM 同条件：deleted_at is null）"
Q "select '有效令牌='||count(*) from tokens where deleted_at is null" | sed 's/^/      /'
Q "select 'Secret 里的 token_id 是否有效='||coalesce((select id::text from tokens where deleted_at is null order by id desc limit 1),'无')" | sed 's/^/      /'
echo "=== X3 渠道也顺手确认只有一条活的（压测只打 mock，不打真实厂商）"
Q "select 'id='||id||' '||name||' status='||status||' alive='||(deleted_at is null)::text from channels order by id" 2>&1 | sed 's/^/      /'
Q "select '非 mock 渠道数（应为 0 ⇒ 压测不可能打到真实厂商）='||count(*) from channels where deleted_at is null and coalesce(base_url,'') not like '%mock-upstream%'" 2>&1 | sed 's/^/      /'
kubectl -n $NS delete pod t2p-c --ignore-not-found --wait=false >/dev/null 2>&1
echo "--- X1–X3 结束（只读）"
exit 0
