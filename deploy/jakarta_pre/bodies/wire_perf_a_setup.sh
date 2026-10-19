#!/bin/bash
# bodies/wire_perf_a_setup.sh —— 压测链路第 1 步：把 new-api-perf 从"半初始化"恢复到可 setup，再 setup + 落 Secret
# 为什么要这一步（自曝）：上一版 wire_perf_relay.sh 把"口令写进 Secret"排在 `POST /api/token/` 之后，
#   而那个接口实测只回 `{"message":"","success":true}`（**没有 data.id**）⇒ 取空即 exit，口令随 shell 蒸发，
#   perfroot 已入库但无人持有口令。恢复依据是代码事实：`constant.Setup` 由 model.CheckSetup() 在**启动时**读
#   `setups` 表决定（本仓 createRootAccountIfNeed 无任何调用点），所以必须"删 setups+root 行 → 重启 → 重新 POST /api/setup"，
#   而不是重发一次 setup（会被"系统已经初始化完成"挡掉）。
# 凭据纪律（§18.7）：口令在节点现生成，命令体无凭据字面量，输出只有 md5 指纹。
set -uo pipefail
NS=new-api-perf
SEC=perf-load-test-credentials
GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r')
GWP=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -dc '0-9')
GW="http://${GWC}:${GWP:-80}"
[ -n "$GWC" ] || { echo "    [XX] 取不到网关 ClusterIP"; exit 0; }
fp() { printf '%s' "$1" | md5sum | cut -c1-10; }
printf '=== A0 网关=%s\n' "$GW"

kubectl -n $NS apply -f - <<'OMF' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: t2p-wire, namespace: new-api-perf, labels: {app: t2p-wire, track: perf, env: dev}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 600
  terminationGracePeriodSeconds: 0
  serviceAccountName: new-api-app
  containers:
    - name: psql
      image: postgres:17-alpine
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 560"]
      resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {cpu: 200m, memory: 256Mi}}
      envFrom: [{secretRef: {name: new-api-secrets}}]
OMF
kubectl -n $NS wait --for=condition=Ready pod/t2p-wire --timeout=240s >/dev/null 2>&1 || echo "    [!] psql Pod 未就绪"
Q() { kubectl -n $NS exec -i t2p-wire -- sh -c 'psql "$SQL_DSN" -Atq -c "$1"' sh "$1" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/g'; }

echo "=== A1 现状清点"
SROWS=$(Q "select count(*) from setups"); UROWS=$(Q "select count(*) from users where username='perfroot'")
HAVESEC=$(kubectl -n $NS get secret $SEC -o jsonpath='{.metadata.name}' 2>/dev/null)
printf '      setups=%s perfroot=%s secret=%s\n' "${SROWS:-?}" "${UROWS:-?}" "${HAVESEC:-无}"

if [ "${SROWS:-0}" != 0 ] && [ -z "$HAVESEC" ]; then
  echo "=== A2 恢复半初始化态：删 setups/root/残渠道令牌 → rollout restart → 确认门重开"
  Q "delete from setups; "; Q "delete from tokens where name='perf-load';"; Q "delete from channels where name='mock-perf';"
  Q "delete from user_sessions where user_id in (select id from users where username='perfroot');"
  Q "delete from users where username='perfroot';"
  kubectl -n $NS rollout restart deploy/new-api-perf 2>&1 | sed 's/^/      /'
  kubectl -n $NS rollout status deploy/new-api-perf --timeout=240s 2>&1 | tail -2 | sed 's/^/      /'
  GWC=$(kubectl -n $NS get svc new-api-perf -o jsonpath='{.spec.clusterIP}' 2>/dev/null | tr -d ' \r'); GW="http://${GWC}:${GWP:-80}"
  printf '      重启后网关=%s setup 门=%s\n' "$GW" "$(curl -sS -m 10 "$GW/api/setup" 2>&1 | head -c 130)"
fi

echo "=== A3 setup（Secret 已有口令就跳过生成，保证可重跑）"
if [ -n "$HAVESEC" ]; then
  printf '      Secret 已存在 ⇒ 口令已在，A3 跳过（指纹=%s）\n' \
    "$(fp "$(kubectl -n $NS get secret $SEC -o jsonpath='{.data.admin_password}' | base64 -d)")"
else
  ADMIN_PW=$(python3 -c 'import secrets;print(secrets.token_urlsafe(18))')
  R=$(curl -sS -m 15 -H 'Content-Type: application/json' --data \
    "{\"username\":\"perfroot\",\"password\":\"$ADMIN_PW\",\"confirmPassword\":\"$ADMIN_PW\",\"SelfUseModeEnabled\":true,\"DemoSiteEnabled\":false}" "$GW/api/setup" 2>&1)
  printf '      setup 应答=%s\n' "$(printf '%s' "$R" | head -c 120)"
  case "$R" in *'"success":true'*)
    kubectl -n $NS create secret generic $SEC --from-literal=admin_username=perfroot \
      --from-literal=admin_password="$ADMIN_PW" --from-literal=token_id=0 --from-literal=token_key=none \
      --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1
    printf '      口令已立刻落 Secret（指纹 %s）⇒ 不会再出现"建了用户没人持有口令"\n' "$(fp "$ADMIN_PW")" ;;
    *) echo "      [XX] setup 未成功 ⇒ 停（不猜口令、不碰生产）" ;;
  esac
fi
echo "=== A4 只读回读 + 清理临时 Pod"
Q "select 'users='||count(*) from users"; Q "select 'setup_rows='||count(*) from setups"
kubectl -n $NS get secret $SEC -o jsonpath='      secret={.metadata.name}{"\n"}' 2>&1
kubectl -n $NS delete pod t2p-wire --ignore-not-found --wait=false >/dev/null 2>&1
echo "      临时 Pod 清理=$(kubectl -n $NS get pod t2p-wire -o name 2>&1 | head -1)"
echo "--- A0–A4 结束（下一步：bodies/wire_perf_b_channel.sh）"
exit 0
