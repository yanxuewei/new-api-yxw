#!/bin/bash
# __TITLE__ — MySQL 日志库连通探针（节点内执行；ack_remote body）
set -uo pipefail
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api
B64=__DSN_B64__

python3 - "$B64" <<'PY'
import base64, json, re, sys
dsn = base64.b64decode(sys.argv[1]).decode()
m = re.match(r'[^:]+:([^@]+)@tcp\(([^:]+):(\d+)\)/', dsn)
assert m, 'DSN parse failed'
sec = {"apiVersion":"v1","kind":"Secret",
       "metadata":{"name":"tmysql-probe","namespace":"new-api"},
       "stringData":{"MYSQL_PWD": m.group(1)}}
open('/tmp/tprobe_secret.json','w').write(json.dumps(sec))
open('/tmp/tprobe_host.txt','w').write(m.group(2))
print('probe host=%s' % m.group(2))
PY

kubectl -n "$NS" apply -f /tmp/tprobe_secret.json >/dev/null 2>&1
HOST=$(cat /tmp/tprobe_host.txt)
kubectl -n "$NS" delete pod tmysql-probe --ignore-not-found --wait=false >/dev/null 2>&1
cat <<YAML | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: tmysql-probe, namespace: new-api}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: mysql:8.0
    command: ["sh","-c","sleep 600"]
    env:
    - {name: MYSQL_PWD, valueFrom: {secretKeyRef: {name: tmysql-probe, key: MYSQL_PWD}}}
    resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 500m, memory: 256Mi}}
YAML

ph=""
for i in $(seq 1 40); do
  ph=$(kubectl -n "$NS" get pod tmysql-probe -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$ph" = "Running" ] && break
  sleep 4
done
echo "probe phase=${ph}"

kubectl -n "$NS" exec tmysql-probe -- sh -c \
  "echo '== plain =='; mysql -h ${HOST} -u newapi_logs --connect-timeout=8 -e 'SHOW TABLES;' newapi_logs 2>&1 | tail -4; \
   echo '== tls required =='; mysql -h ${HOST} -u newapi_logs --connect-timeout=8 --ssl-mode=REQUIRED -e 'SHOW STATUS LIKE \"Ssl_cipher\";' newapi_logs 2>&1 | tail -3; \
   echo '== tls verify_identity =='; mysql -h ${HOST} -u newapi_logs --connect-timeout=8 --ssl-mode=VERIFY_IDENTITY -e 'SELECT 1;' newapi_logs 2>&1 | tail -3; \
   mysql -h ${HOST} -u newapi_logs --connect-timeout=8 -e 'SELECT COUNT(*) AS log_rows FROM logs;' newapi_logs 2>&1 | tail -2" \
  | tr -d '\r'

kubectl -n "$NS" delete pod tmysql-probe --ignore-not-found --timeout=90s >/dev/null 2>&1
kubectl -n "$NS" delete secret tmysql-probe --ignore-not-found >/dev/null 2>&1
rm -f /tmp/tprobe_secret.json /tmp/tprobe_host.txt
echo PROBE_DONE
