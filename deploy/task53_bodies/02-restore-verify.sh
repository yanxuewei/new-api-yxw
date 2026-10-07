#!/usr/bin/env bash
# =============================================================================
# 任务 53 · 复原 + 可观测点判读（只读优先，仅在确认残留值为空串时才 DELETE）
#
# 为什么需要它：2026-10-06 16:01 的 --probe 两条腿都在 T_REVERT 之后撞上
#   "连续 5 次读不到 DB" 而提前 break ⇒ 计划的 T_CLEAN(DELETE) 没执行，
#   options 残留 1 行 Footer（值已回滚成空串，行为上等价于不存在，但初始态是 3 行）。
#
# 判读纪律（本次异常的直接教训）：
#   sha(None) == sha("") ⇒ 上一版把「curl 失败/字段缺失」和「值确实是空串」混为同一个
#   指纹（e3b0c44298fc），导致 mnl 在 t=158.1 的"全体回落空值"无法归因。
#   ⇒ 本脚本把三态分开打印：HTTP 码 / 字段是否存在 / 值本身（空串显式写 EMPTY）。
#
# 密钥纪律：只输出 len 与 sha12，绝不输出 value 原文（options 里可能有配置口令）。
# =============================================================================
set -uo pipefail
export KUBECONFIG=${KUBECONFIG:-/tmp/k8s/kubeconfig}
: "${SITE:?SITE=mnl|sg}"
NS=new-api
PROBE=t53-pg
DO_DELETE="${DO_DELETE:-no}"

echo "== SITE=$SITE 复原复核 UTC=$(date -u '+%F %T') =="

cleanup_pod() { kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup_pod EXIT

kubectl -n "$NS" delete pod "$PROBE" --ignore-not-found --wait=true >/dev/null 2>&1
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: t53-pg, labels: {app: t53-probe, run: task53}}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: p
    image: postgres:17
    imagePullPolicy: IfNotPresent
    command: ["sleep","1800"]
    env:
    - name: SQL_DSN
      valueFrom: {secretKeyRef: {name: new-api-secrets, key: SQL_DSN}}
    volumeMounts:
    - {name: ca, mountPath: /etc/ssl/rds, readOnly: true}
    resources: {requests: {cpu: 200m, memory: 256Mi}, limits: {cpu: 200m, memory: 256Mi}}
  volumes:
  - name: ca
    secret: {secretName: rds-ca-apse6, optional: true}
YAML
if ! kubectl -n "$NS" wait --for=condition=Ready pod/"$PROBE" --timeout=180s; then
  echo "  [XX] 探针 Pod 未就绪"; exit 1
fi

q() { printf '%s\n' "$1" | kubectl -n "$NS" exec -i "$PROBE" -- sh -c 'psql "$SQL_DSN" -qAt -F"|"' 2>&1; }

echo "-- 库侧状态 --"
echo "    $(q "SELECT current_user, current_database()")"
echo "    键/值长度列：$(q "SELECT key, length(value) FROM options ORDER BY key" | tr '\n' ' ')"
FOOTER_CNT=$(q "SELECT count(*) FROM options WHERE key='Footer'" | head -1)
FOOTER_LEN=$(q "SELECT coalesce(length(value),-1) FROM options WHERE key='Footer'" | head -1)
echo "    Footer 行数=$FOOTER_CNT 值长度=$FOOTER_LEN"

if [ "$DO_DELETE" = "yes" ] && [ "${FOOTER_CNT:-0}" = "1" ] && [ "${FOOTER_LEN:-0}" = "0" ]; then
  echo "    [W] 条件成立（仅本卡插入的 Footer 行、且值为空串）⇒ DELETE 该行"
  echo "    结果: $(q "DELETE FROM options WHERE key='Footer' AND value=''")"
  echo "    复核: Footer 行数=$(q "SELECT count(*) FROM options WHERE key='Footer'" | head -1)｜总行数=$(q "SELECT count(*) FROM options" | head -1)"
elif [ "$DO_DELETE" = "yes" ]; then
  echo "    [XX] 复核条件不满足（行数/值长度不符）⇒ 不动手，交人工判读"
else
  echo "    （本轮 DO_DELETE=$DO_DELETE，纯取证）"
fi

echo "-- 副本侧 /api/status footer 三态判读（HTTP码｜字段存在性｜值形态）--"
kubectl -n "$NS" get pods --no-headers -o custom-columns=N:.metadata.name,I:.status.podIP,P:.status.phase 2>/dev/null | \
  awk -v probe="$PROBE" '$1 ~ /^new-api-/ && $3=="Running" && $1!=probe {print $1" "$2}' | \
  while read -r name ip; do
    [ -n "$name" ] || continue
    raw=$(curl -s --max-time 5 -w '\n%{http_code}' "http://$ip:3000/api/status" 2>&1)
    code=${raw##*$'\n'}
    body=${raw%$'\n'*}
    printf '%s\n' "$body" | python3 -c '
import sys, json, hashlib
code = sys.argv[1]
try:
    o = json.load(sys.stdin)
    d = o.get("data") if isinstance(o.get("data"), dict) else None
    if d is None:
        print("    %-42s http=%s data=MISSING" % (sys.argv[2], code)); raise SystemExit
    has = "footer_html" in d
    v = d.get("footer_html")
    form = "ABSENT" if not has else ("EMPTY" if v == "" else "len=%d sha12=%s" % (len(v), hashlib.sha256(v.encode()).hexdigest()[:12]))
    print("    %-42s http=%s footer=%s  (data 键数=%d)" % (sys.argv[2], code, form, len(d)))
except Exception as e:
    print("    %-42s http=%s 读取失败=%s" % (sys.argv[2], code, type(e).__name__))
' "$code" "$name"
  done

echo '-- 业务 Pod 重启计数（排除「Pod 重启导致内存态归零」这一解释）--'
kubectl -n "$NS" get pods -o custom-columns=N:.metadata.name,R:.status.containerStatuses[0].restartCount,S:.status.startTime --no-headers 2>/dev/null | \
  awk '$1 ~ /^new-api-/' | sed 's/^/    /'

echo "== DONE SITE=$SITE =="
