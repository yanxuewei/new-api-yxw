#!/bin/bash
# 任务 28 · V2/V3/V4 补强取证（只读 + 一个临时探针 Pod，用完即删）
# 起因：--verify 首跑暴露三处判据不严谨，需按实况修正：
#   ① V2b `inet_server_addr()` 对非 superuser 返回 NULL ⇒ 不能这样证明"连的是马尼拉主库"，
#      改用 verify-full 的证书校验事实（libpq 校验 SAN/CN 与该 host 匹配）+ DSN host 口径。
#   ② V3b `client_addr` 全是 127.0.0.1 ⇒ 连接经 RDS 侧代理，**无法**按 Pod IP 归因；
#      改用"副本数 ↔ 会话数"差分（0 副本基线取任务 30 留档，2 副本取现值）。
#   ③ V3c `show pool_mode/default_pool_size/max_client_conn` 在该端点全部
#      `unrecognized configuration parameter` ⇒ 池参数**不可 SHOW**，卡片判据只能引用配置侧。
#   ④ V1c 只打了 `/api/status`（不鉴权）⇒ 不能声称"鉴权链路已证"，补一次带无效 token 的
#      401（而非 500）探针，证明鉴权中间件真的查了库并正常拒绝。
#   ⑤ 补：镜像实际来源（公网域名 / imageID digest），证明确走差异① 的公网拉取路径。
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
APP=new-api-ph-standby
PROBE=t28-pg2

echo "== ⑤ 镜像来源核对（Pod 实际 image/imageID + 节点上镜像仓库域名）=="
kubectl -n "$NS" get pod -l app=new-api -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,IMAGEID:.status.containerStatuses[0].imageID' 2>&1

echo "== ④ 鉴权中间件对无效 token 的响应（期望 401 而非 500）=="
POD1=$(kubectl -n "$NS" get pod -l app=new-api -o jsonpath='{.items[0].metadata.name}')
for path in /api/user/self /api/log/self; do
  printf '   %s -> ' "$path"
  kubectl -n "$NS" exec "$POD1" -c new-api -- sh -c \
    "wget -S -qO- --header='Authorization: Bearer t28-invalid-token' --timeout=8 http://127.0.0.1:3000$path 2>&1 | grep -E 'HTTP/|[Ee]rror|message' | head -3" 2>&1 | tr '\n' ' '
  echo
done

echo "== ②③ 会话账目与归因差分 =="
kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
cat <<'PY' | kubectl -n "$NS" apply -f - 2>&1 | head -2
apiVersion: v1
kind: Pod
metadata:
  name: t28-pg2
  namespace: new-api
  labels: {app: t28-probe}
spec:
  restartPolicy: Never
  serviceAccountName: new-api-app
  containers:
  - name: pg
    image: postgres:17
    command: ["sh","-c","sleep 600"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    resources:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "1",    memory: "512Mi"}
    volumeMounts:
    - {name: rds-ca, mountPath: /etc/ssl/rds, readOnly: true}
  volumes:
  - name: rds-ca
    secret: {secretName: rds-ca-apse6}
PY
for i in $(seq 1 30); do
  PH=$(kubectl -n "$NS" get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PH" = "Running" ] && break
  sleep 4
done
echo "   probe phase=$PH"

kubectl -n "$NS" exec -i "$PROBE" -- bash -c 'set -u
echo "--- 1) 马尼拉主库的等价证据（直接证据受 superuser 限制，方法沿用任务 30 §V1）---"
psql "$SQL_DSN" -Atc "select ssl, version from pg_stat_ssl where pid=pg_backend_pid()" 2>&1 | head -2
psql "$SQL_DSN" -Atc "select pg_postmaster_start_time()" 2>&1 | head -2
echo "     （任务 30 留档：实例启动时刻 2026-09-29 15:59:16+08、server_version 17.10、库名 newapi）"
echo "--- 2) 当前 newapi_sg 会话总数 / 按状态 ---"
psql "$SQL_DSN" -Atc "select count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"'" 2>&1 | head -2
psql "$SQL_DSN" -Atc "select state, count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"' group by 1" 2>&1 | head -5
echo "--- 3) 会话的 backend_start 分布（备站 05:55:10Z 起 ⇒ 新会话应集中在该时刻之后）---"
psql "$SQL_DSN" -Atc "select date_trunc('"'"'minute'"'"', backend_start), count(*) from pg_stat_activity where usename='"'"'newapi_sg'"'"' group by 1 order by 1" 2>&1 | head -8
echo "--- 4) 池参数可见性（卡片口径核对）---"
for p in pool_mode default_pool_size max_client_conn max_connections; do
  printf "   show %s -> " "$p"; psql "$SQL_DSN" -Atc "show $p" 2>&1 | head -1
done
echo "--- 5) 备站能否读业务表（数据面同源，V4 的数据层前提）---"
psql "$SQL_DSN" -Atc "select count(*) from information_schema.tables where table_schema='"'"'public'"'"'" 2>&1 | head -2
psql "$SQL_DSN" -Atc "select count(*) from users" 2>&1 | head -2
echo EXTRA-DONE' 2>&1 | tail -30

kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true --timeout=60s 2>&1
echo "   探针已删；剩余 Pod："
kubectl -n "$NS" get pod --no-headers 2>&1 | head -5
echo "### DONE-28-EXTRA"
