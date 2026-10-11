#!/bin/bash
# 任务 28 · 马尼拉侧配对核查（只读）：两地 SESSION_SECRET 一致性 + 镜像工具链
# 用途：卡片前置要求「两地域 SESSION_SECRET 必须一致」，V2/V3 需要在 Pod 内跑 psql。
set -u
export KUBECONFIG="${K8S:-/tmp/k8s/kubeconfig}"
NS=new-api

echo "== A) mnl Secret 键名 + 指纹（值不落输出）=="
kubectl -n "$NS" get secret new-api-secrets -o json > /tmp/t28_mnl_sec.json 2>/dev/null
python3 - <<'PY'
import json, base64, hashlib
it = json.load(open('/tmp/t28_mnl_sec.json'))
data = it.get('data') or {}
print('   keys =', sorted(data.keys()))
for k in ('SESSION_SECRET', 'SESSION_SECRET_OLD'):
    v = data.get(k)
    if not v:
        print('   %s MISSING' % k)
        continue
    raw = base64.b64decode(v).decode('utf-8', 'replace')
    print('   %s len=%d sha12=%s' % (k, len(raw), hashlib.sha256(raw.encode()).hexdigest()[:12]))
# DSN 只打印骨架：scheme/user/host/port/db/query，口令掩码
for k in ('SQL_DSN', 'SQL_DSN_MIGRATE', 'LOG_SQL_DSN'):
    v = data.get(k)
    if not v:
        continue
    raw = base64.b64decode(v).decode('utf-8', 'replace')
    head, sep, rest = raw.partition('://')
    cred, _, hostpart = rest.rpartition('@')
    user = cred.split(':')[0]
    print('   %s skeleton = %s://%s:***@%s' % (k, head, user, hostpart))
PY
rm -f /tmp/t28_mnl_sec.json

echo "== B) 业务镜像工具链（exec 现网 stable Pod，不建 Pod、不改状态）=="
kubectl -n "$NS" exec deploy/new-api-stable -c new-api -- sh -c \
  'for t in psql pgbench curl wget nc openssl sh; do printf "   %s=%s\n" "$t" "$(command -v $t || echo MISSING)"; done; echo TOOLCHECK-DONE' 2>&1 | head -12

echo "== C) mnl stable Pod 数与镜像 tag（备站必须同 SHA）=="
kubectl -n "$NS" get deploy new-api-stable -o jsonpath='{.spec.replicas}{" ready="}{.status.readyReplicas}{" img="}{.spec.template.spec.containers[0].image}{"\n"}' 2>&1

echo "== D) mnl ConfigMap 与 sg 的差异位（只列键值，找 sg 缺哪些）=="
kubectl -n "$NS" get configmap new-api-config -o json > /tmp/t28_mnl_cm.json 2>/dev/null
python3 - <<'PY'
import json
d = json.load(open('/tmp/t28_mnl_cm.json'))
for k, v in sorted((d.get('data') or {}).items()):
    print('   %s = %s' % (k, v))
PY
rm -f /tmp/t28_mnl_cm.json
echo "### DONE-28-MNL"
