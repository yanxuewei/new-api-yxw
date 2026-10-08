#!/usr/bin/env bash
# 任务 53 · 排障：options 现有键清单 + 循环节拍管道为何 0 命中
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
NS=new-api
echo "== UTC $(date -u '+%F %T') =="
kubectl -n $NS delete pod t53-pg --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'YAML' | kubectl -n $NS apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: t53-pg, labels: {app: t53-probe}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: p
    image: postgres:17
    command: ["sleep","3600"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    volumeMounts: [{name: ca, mountPath: /etc/ssl/rds, readOnly: true}]
    resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
  volumes: [{name: ca, secret: {secretName: rds-ca-apse6, optional: true}}]
YAML
kubectl -n $NS wait --for=condition=Ready pod/t53-pg --timeout=180s || { echo "探针未就绪"; exit 1; }
q() { printf '%s\n' "$1" | kubectl -n $NS exec -i t53-pg -- sh -c 'psql "$SQL_DSN" -qAt -F"|"' 2>&1; }

echo "-- options 全表（只报键名/长度/摘要，值可能是配置口令，不回显） --"
q "SELECT key, length(value), md5(value) FROM options ORDER BY key" | sed 's/^/  /'
echo "-- /api/status 实际暴露的字段数与前若干键名（取一个副本） --"
IP=$(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,I:.status.podIP,P:.status.phase | awk '$1 ~ /^new-api-/ && $3=="Running"{print $2; exit}')
echo "  pod ip=$IP"
curl -s --max-time 5 "http://$IP:3000/api/status" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  顶层键:", sorted(d.keys()))
data = d.get("data") or {}
print("  data 键数:", len(data))
for k in ("footer_html","system_name","server_address","version","start_time","chats","docs_link"):
    print("   data.%s = %s" % (k, repr(data.get(k))[:60]))
'
echo "-- 循环节拍管道排障（对第一个副本） --"
NAME=$(kubectl -n $NS get pods --no-headers -o custom-columns=N:.metadata.name,P:.status.phase | awk '$1 ~ /^new-api-/ && $2=="Running"{print $1; exit}')
echo "  1) 原始 grep 命中数: $(kubectl -n $NS logs $NAME --tail=3000 2>/dev/null | grep -c 'syncing options from database')"
echo "  2) awk 输出前 3 行:"
kubectl -n $NS logs "$NAME" --tail=3000 2>/dev/null | awk '/syncing options from database/{print "OPT "$2" "$4}' | head -3 | sed 's/^/     /'
echo "  3) 完整管道:"
kubectl -n $NS logs "$NAME" --tail=3000 2>/dev/null | awk '/syncing options from database/{print "OPT "$2" "$4} /syncing channels from database/{print "CHN "$2" "$4}' | python3 -c '
import sys, datetime
rows = [ln.split() for ln in sys.stdin if ln.strip()]
print("    收到行数:", len(rows))
for kind in ("OPT", "CHN"):
    ts = []
    for r in rows:
        if r[0] != kind: continue
        try: ts.append(datetime.datetime.strptime(r[1] + " " + r[2], "%Y-%m-%d %H:%M:%S"))
        except Exception as e: print("    解析失败:", r, e)
    if len(ts) >= 2:
        d = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
        print("    %s n=%d min/avg/max=%.1f/%.1f/%.1f" % (kind, len(ts), min(d), sum(d)/len(d), max(d)))
    else:
        print("    %s n=%d" % (kind, len(ts)))
'
echo "-- 清理 --"
kubectl -n $NS delete pod t53-pg --ignore-not-found --wait=false
echo "== DONE =="
