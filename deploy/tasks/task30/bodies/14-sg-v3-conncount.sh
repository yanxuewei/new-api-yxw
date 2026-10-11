#!/bin/bash
# 14-sg-v3-conncount.sh — 任务 30 缺口④：V3 连接账目复核（探针 Pod 已删后池是否回收）
# 判据：newapi_sg 会话数 ≤ 10 × 备站副本数（备站 0 副本 ⇒ 期望逼近 0；托管池保活残留需记录）
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
POD=t30-v3

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
cat <<YAML | kubectl -n "$NS" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels: {app: t30-v3}
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
YAML

for i in $(seq 1 25); do
  ph=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Running" ] && break
  sleep 4
done
echo "pod phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)"

kubectl -n "$NS" exec -i "$POD" -- sh -s <<'EOS' 2>&1
set -u
echo "--- 会话按 usename/state 分组（普通账号可见 usename/state）---"
psql "$SQL_DSN" -Atc "select coalesce(usename,'-'), coalesce(state,'-'), count(*) from pg_stat_activity group by 1,2 order by 3 desc" 2>&1
echo "--- newapi_sg 专列 ---"
psql "$SQL_DSN" -Atc "select count(*) from pg_stat_activity where usename='newapi_sg'" 2>&1
echo "--- 备站命名面工作负载（应为空）---"
EOS
kubectl -n "$NS" get deploy,sts,ds --no-headers 2>&1 | head -5

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=60s 2>&1
echo "remaining=$(kubectl -n "$NS" get pod --no-headers 2>&1 | head -3)"
echo "### DONE"
